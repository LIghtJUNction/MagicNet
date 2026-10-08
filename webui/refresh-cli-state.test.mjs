import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { execFailed } from "./src/utils.ts";

// Use the same production-function extraction as composable-concurrency.test.mjs.
const source = ts.createSourceFile("useMagicNet.ts",
  readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8"),
  ts.ScriptTarget.Latest, true);
const resources = [
  ["refreshHealth", "health", "health", "parseHealth"],
  ["refreshApps", "appPolicy", "app list", "parseApps"],
  ["refreshBlock", "blocklist", "block list", "parseBlock"],
  ["refreshMcp", "mcp", "mcp status", "parseMcp"],
  ["refreshWarp", "warp", "warp status", "parseWarp"],
];
const names = new Set(["refreshCliState", "startForegroundCommand", "canUpdateRefreshUi",
  "markQuietFailure", ...resources.map(([method]) => method)]);
const code = ts.transpileModule(source.statements
  .filter((node) => ts.isFunctionDeclaration(node) && names.has(node.name?.text))
  .map((node) => node.getText(source)).join("\n"), {
  compilerOptions: { target: ts.ScriptTarget.ES2022 },
}).outputText;

function fixture() {
  let token = 1;
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const calls = [];
  const parsed = [];
  const state = { busy: false, phase: "idle" };
  const parsers = {};
  for (const [, key, , parser] of resources) {
    state[key] = { previous: key };
    parsers[parser] = (text, previous) => {
      parsed.push({ key, previous });
      return { text };
    };
  }
  const context = vm.createContext({
    state, ...parsers, execFailed, t: (text) => text,
    foregroundUiGate: { current: () => token, owns: (value) => value === token },
    runCli: (args, label, quiet) => {
      if (!quiet) token += 1;
      calls.push({ args, quiet });
      return pending;
    },
  });
  vm.runInContext(code, context);
  return { context, state, calls, parsed, resolve, supersede: () => { token += 1; } };
}

test("successful reads publish to the matching resource and preserve parser inputs", async () => {
  for (const [method, key, args] of resources) {
    const { context, state, calls, parsed, resolve } = fixture();
    const previous = state[key];
    const pending = context[method]();
    resolve("new observation");
    assert.equal(await pending, true);
    assert.deepEqual(calls, [{ args, quiet: false }]);
    assert.deepEqual(state[key], { text: "new observation" });
    assert.equal(parsed.length, 1);
    assert.equal(parsed[0].key, key);
    assert.equal(parsed[0].previous, ["blocklist", "mcp", "warp"].includes(key) ? previous : undefined);
  }
});

test("failed reads report failure without parsing or replacing previous data", async () => {
  for (const [method, key] of resources) {
    const { context, state, parsed, resolve } = fixture();
    const previous = state[key];
    const pending = context[method]();
    resolve("[error] errno=7 denied");
    assert.equal(await pending, false);
    assert.equal(state[key], previous);
    assert.equal(state.phase, "error");
    assert.equal(parsed.length, 0);
  }
});

test("late successful reads cannot overwrite a newer foreground operation", async () => {
  for (const [method, key] of resources) {
    const { context, state, parsed, resolve, supersede } = fixture();
    const previous = state[key];
    const pending = context[method]();
    supersede();
    state.phase = "new-operation";
    resolve("stale observation");
    assert.equal(await pending, true);
    assert.equal(state[key], previous);
    assert.equal(state.phase, "new-operation");
    assert.equal(parsed.length, 0);
  }
});

test("quiet reads while busy publish only with the caller's foreground ownership", async () => {
  for (const [method, key, args] of resources) {
    for (const inheritedToken of [undefined, 1]) {
      const { context, state, calls, parsed, resolve } = fixture();
      const previous = state[key];
      state.busy = true;
      const pending = context[method](true, inheritedToken);
      resolve("observation");
      assert.equal(await pending, true);
      assert.deepEqual(calls, [{ args, quiet: true }]);
      assert.equal(parsed.length, inheritedToken === undefined ? 0 : 1);
      if (inheritedToken === undefined) assert.equal(state[key], previous);
      else assert.deepEqual(state[key], { text: "observation" });
    }
  }
});
