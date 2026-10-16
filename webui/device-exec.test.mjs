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


test("malformed native exit events fail without retaining callbacks", async () => {
  let callbackName;
  globalThis.ksu = { spawn: (_, __, ___, name) => { callbackName = name; } };
  for (const value of [undefined, null, "", "0", false, NaN, Infinity, 0.5]) {
    const pending = execAsync("unused");
    window[callbackName].emit("exit", value);
    assert.equal((await pending).errno, -1, `invalid exit ${String(value)}`);
    assert.equal(window[callbackName], undefined);
  }
});

const OUTPUT_UNITS = 8 * 1024 * 1024;
const OUTPUT_ENTRIES = 64 * 1024;

function pendingExecution() {
  let callbackName;
  globalThis.ksu = { spawn: (_, __, ___, name) => { callbackName = name; } };
  const pending = execAsync("unused");
  return { pending, callback: window[callbackName], callbackName };
}

test("output budgets accept the exact combined boundary including stream separators", async () => {
  const { pending, callback, callbackName } = pendingExecution();
  const stdout = "a".repeat(OUTPUT_UNITS - 2);
  callback.stdout.emit("data", stdout);
  callback.stdout.emit("data", "");
  callback.stderr.emit("data", "b");
  callback.emit("exit", 0);
  assert.deepEqual(await pending, { errno: 0, stdout: `${stdout}\n`, stderr: "b" });
  assert.equal(window[callbackName], undefined);
});

for (const terminal of ["success", "nonzero", "error"]) {
  test(`combined output overflow stays pending until native ${terminal} and returns no partial data`, async () => {
    const { pending, callback, callbackName } = pendingExecution();
    const rejected = assert.rejects(pending, (error) => {
      assert.equal(error.name, "ExecOutputLimitError");
      assert.ok(!error.message.includes("PRIVATE_OUTPUT"));
      return true;
    });
    let settled = false;
    void pending.then(() => { settled = true; }, () => { settled = true; });
    callback.stdout.emit("data", "a".repeat(OUTPUT_UNITS));
    callback.stderr.emit("data", "PRIVATE_OUTPUT");
    for (let count = 0; count < 100; count += 1) callback.stdout.emit("data", "more output");
    await Promise.resolve();
    assert.equal(settled, false, "overflow must not release the active command");
    assert.ok(window[callbackName]);
    if (terminal === "error") callback.emit("error", new Error("PRIVATE_OUTPUT native failure"));
    else callback.emit("exit", terminal === "success" ? 0 : 7);
    await rejected;
    assert.equal(window[callbackName], undefined);
    callback.stdout.emit("data", "late output");
    callback.emit("exit", 0);
  });
}

test("an empty line separator counts toward the output budget", async () => {
  const { pending, callback, callbackName } = pendingExecution();
  const rejected = assert.rejects(pending, { name: "ExecOutputLimitError" });
  callback.stdout.emit("data", "a".repeat(OUTPUT_UNITS));
  callback.stdout.emit("data", "");
  callback.emit("exit", 0);
  await rejected;
  assert.equal(window[callbackName], undefined);
});

test("a surrogate pair takes two units, accepting an exact fit but rejecting a one-unit gap", async () => {
  for (const overflow of [false, true]) {
    const { pending, callback, callbackName } = pendingExecution();
    const completion = overflow ? assert.rejects(pending, { name: "ExecOutputLimitError" }) : pending;
    const prefix = "a".repeat(OUTPUT_UNITS - (overflow ? 2 : 3));
    callback.stdout.emit("data", prefix);
    callback.stdout.emit("data", "😀");
    callback.emit("exit", 0);
    const result = await completion;
    if (!overflow) assert.equal(result.stdout, `${prefix}\n😀`);
    assert.equal(window[callbackName], undefined);
  }
});

test("empty output events have a combined count limit independent of their size", async () => {
  for (const overflow of [false, true]) {
    const { pending, callback, callbackName } = pendingExecution();
    const completion = overflow
      ? assert.rejects(pending, { name: "ExecOutputLimitError" })
      : pending;
    for (let count = 0; count < OUTPUT_ENTRIES; count += 1) {
      (count % 2 ? callback.stdout : callback.stderr).emit("data", "");
    }
    if (overflow) callback.stderr.emit("data", "");
    callback.emit("exit", 0);
    const result = await completion;
    if (!overflow) {
      assert.equal(result.stdout, "\n".repeat(OUTPUT_ENTRIES / 2 - 1));
      assert.equal(result.stderr, result.stdout);
    }
    assert.equal(window[callbackName], undefined);
  }
});

test("repeated completion and duplicate events leave no registered callbacks", async () => {
  const before = Object.keys(window).filter((name) => name.startsWith("magicnet_spawn_"));
  globalThis.ksu = { spawn: (_, __, ___, name) => {
    const callback = window[name];
    callback.stdout.emit("data", "one result");
    callback.emit("exit", 0);
    callback.stdout.emit("data", "late output");
    callback.emit("error", new Error("late error"));
  } };
  for (let iteration = 0; iteration < 500; iteration += 1) {
    assert.deepEqual(await execAsync("unused"), { errno: 0, stdout: "one result", stderr: "" });
  }
  assert.deepEqual(Object.keys(window).filter((name) => name.startsWith("magicnet_spawn_")), before);
});
