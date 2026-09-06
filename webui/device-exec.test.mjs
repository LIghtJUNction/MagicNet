import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { execAsync, hasAsyncExec } from "./src/composables/deviceExec.ts";
import { shellQuote } from "./src/utils.ts";

globalThis.window = globalThis;
afterEach(() => { delete globalThis.ksu; });

test("spawn leaves the event loop free and preserves quoted commands and line output", async () => {
  const command = `su -M -c ${shellQuote("printf '%s' '带空格的参数'")}`;
  let callback;
  let callbackName;
  globalThis.ksu = {
    exec: () => assert.fail("synchronous exec must never run"),
    spawn: (actual, args, options, name) => {
      assert.equal(actual, command);
      assert.equal(args, "[]");
      assert.equal(options, "{}");
      callbackName = name;
      callback = window[name];
      assert.ok(callback, "callbacks must exist before entering native code");
    },
  };
  assert.equal(hasAsyncExec(), true);
  let settled = false;
  const pending = execAsync(command).then((result) => { settled = true; return result; });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(settled, false, "timers run while the command is pending");
  for (const line of ["first", "", "中文 😀"]) callback.stdout.emit("data", line);
  callback.stderr.emit("data", "warning");
  callback.emit("exit", 7);
  assert.deepEqual(await pending, { errno: 7, stdout: "first\n\n中文 😀", stderr: "warning" });
  assert.equal(window[callbackName], undefined);
  callback.emit("error", new Error("duplicate error after nonzero exit"));
});

test("synchronous native launch failures reject and clean up the callback", async () => {
  const failure = new Error("bridge disconnected");
  let callbackName;
  globalThis.ksu = { spawn: (_, __, ___, name) => { callbackName = name; throw failure; } };
  await assert.rejects(execAsync("unused"), (error) => error === failure);
  assert.equal(window[callbackName], undefined);
});

test("an error emitted during native launch is caught before spawn returns", async () => {
  const failure = new Error("launch failed");
  let callbackName;
  globalThis.ksu = { spawn: (_, __, ___, name) => {
    callbackName = name;
    window[name].emit("error", failure);
  } };
  await assert.rejects(execAsync("unused"), (error) => error === failure);
  assert.equal(window[callbackName], undefined);
});

test("concurrent callers have isolated output and callbacks", async () => {
  const callbacks = [];
  globalThis.ksu = { spawn: (_, __, ___, name) => callbacks.push(name) };
  const first = execAsync("first");
  const second = execAsync("second");
  assert.notEqual(callbacks[0], callbacks[1]);
  window[callbacks[1]].stdout.emit("data", "second");
  window[callbacks[1]].emit("exit", 0);
  window[callbacks[0]].stdout.emit("data", "first");
  window[callbacks[0]].emit("exit", 0);
  assert.equal((await first).stdout, "first");
  assert.equal((await second).stdout, "second");
  assert.ok(callbacks.every((name) => window[name] === undefined));
});

test("missing spawn rejects without falling back to blocking exec", async () => {
  globalThis.ksu = { exec: () => assert.fail("blocking fallback must never run") };
  assert.equal(hasAsyncExec(), false);
  await assert.rejects(execAsync("unused"), /异步执行接口/);
  delete globalThis.ksu;
  assert.equal(hasAsyncExec(), false);
  await assert.rejects(execAsync("unused"), /异步执行接口/);
});
