import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { MODULE_DIR, OUTPUT_RENDER_LIMIT } from "./src/constants.ts";

// Run shipped functions with native/browser I/O replaced, not copied algorithms.
const historySource = readFileSync(new URL("./src/components/pages/terminalHistory.ts", import.meta.url), "utf8");
const pageSource = readFileSync(new URL("./src/components/pages/TerminalPage.vue", import.meta.url), "utf8");
const utilities = ts.createSourceFile("utils.ts", readFileSync(new URL("./src/utils.ts", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true);
const utilityNames = ["execFailed", "shellQuote", "compactOutput", "compactCommand"];
const utilsCode = utilities.statements.filter(n => ts.isFunctionDeclaration(n) && utilityNames.includes(n.name?.text)).map(n => n.getText(utilities).replace(/^export /, "")).join("\n");
const helpers = ts.createSourceFile("terminalHistory.ts", historySource, ts.ScriptTarget.Latest, true);
const helpersCode = helpers.statements.filter(n => !ts.isImportDeclaration(n)).map(n => n.getText(helpers).replace(/^export /, "")).join("\n");
const page = ts.createSourceFile("TerminalPage.ts", pageSource.split('<script setup lang="ts">')[1].split("</script>")[0], ts.ScriptTarget.Latest, true);
const pageNames = ["submitCommand", "runCommandDirect", "resetSession", "handleClearHistory"];
const functions = page.statements.filter(n => ts.isFunctionDeclaration(n) && pageNames.includes(n.name?.text));
assert.equal(functions.length, pageNames.length);
const code = ts.transpileModule(`${utilsCode}\n${helpersCode}\n${functions.map(n => n.getText(page)).join("\n")}\nglobalThis.historyLimit = MAX_HISTORY_LENGTH; globalThis.commandLimit = MAX_HISTORY_COMMAND_LENGTH; globalThis.entryLimit = MAX_TERMINAL_ENTRIES;`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;

function fixture(options = {}) {
  const storageCalls = [], shellCalls = [], cliCalls = [];
  const ref = value => ({ value });
  const context = vm.createContext({
    MODULE_DIR, OUTPUT_RENDER_LIMIT, Date, Math,
    t: (s, params = {}) => s.replace(/\{(\w+)\}/g, (_, k) => params[k] ?? k),
    inputCommand: ref(""), history: ref([]), historyIndex: ref(-1), draftInput: ref(""),
    executing: ref(false), executedList: ref([]), clearingHistory: ref(false),
    copiedAll: ref(false), copiedId: ref(null), historyClearFailed: ref(false), sessionRevision: 0,
    scrollToBottom() {}, focusInput() {}, nextTick: fn => Promise.resolve().then(fn),
    clearScreen() { context.executedList.value = []; },
    window: { localStorage: {
      getItem() { throw new Error("history must not be read"); },
      setItem() { throw new Error("history must not be persisted"); },
      removeItem(key) { storageCalls.push(key); if (options.storageFails) throw new Error("denied"); },
    } },
    runShell: async (...args) => { shellCalls.push(args); if (options.shellThrows) throw new Error("denied"); return options.shellResult ?? ""; },
    runCli: (...args) => { cliCalls.push(args); return options.runCli ? options.runCli(...args) : Promise.resolve("ok"); },
  });
  vm.runInContext(code, context);
  return { context, shellCalls, storageCalls, cliCalls };
}
const plain = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { resolve, promise }; };

test("history is synchronous, memory-only and bounded without mutating its input", () => {
  const { context: c, storageCalls, shellCalls } = fixture();
  const initial = ["health"];
  const next = c.appendTerminalHistory("  sub add https://example.test/?token=private  ", initial);
  assert.ok(Array.isArray(next)); assert.deepEqual(initial, ["health"]);
  assert.equal(next.at(-1), "sub add https://example.test/?token=private");
  assert.deepEqual(plain(c.appendTerminalHistory(next.at(-1), next)), plain(next));
  const full = Array.from({ length: c.historyLimit + 50 }, (_, n) => `cmd${n}`);
  assert.equal(c.appendTerminalHistory("new", full).length, c.historyLimit);
  assert.deepEqual(plain(c.appendTerminalHistory("x".repeat(c.commandLimit + 1), initial)), initial);
  assert.deepEqual(storageCalls, []); assert.deepEqual(shellCalls, []);
  assert.doesNotMatch(historySource, /localStorage\.(getItem|setItem)|\bcat\b|printf|>>/);
});

test("explicit clear attempts both legacy stores and reports native/storage failures", async () => {
  for (const options of [{}, { storageFails: true }, { shellResult: "[error] errno=1" }, { shellResult: "[exec-timeout]" }, { shellThrows: true }]) {
    const { context: c, storageCalls, shellCalls } = fixture(options);
    assert.equal(await c.clearTerminalHistory(c.runShell), Object.keys(options).length === 0);
    assert.deepEqual(storageCalls, ["magicnet.terminal.history.v1"]);
    assert.equal(shellCalls.length, 1);
    assert.equal(shellCalls[0][0], `rm -f '${MODULE_DIR}/.config/terminal_history.txt'`);
    assert.equal(shellCalls[0][2], true);
  }
});

test("two immediate submissions admit one command before the first await", async () => {
  const pending = deferred();
  const { context: c, cliCalls, shellCalls } = fixture({ runCli: () => pending.promise });
  c.inputCommand.value = "service restart sing-box";
  const first = c.submitCommand();
  c.inputCommand.value = "service stop sing-box";
  await c.submitCommand();
  assert.equal(cliCalls.length, 1); assert.equal(c.executing.value, true);
  assert.deepEqual(shellCalls, []);
  pending.resolve("ok"); await first;
  assert.equal(c.executing.value, false); assert.equal(c.executedList.value.length, 1);
});

test("leaving the page clears session data and rejects late completion without unlocking early", async () => {
  const pending = deferred();
  const { context: c, cliCalls } = fixture({ runCli: () => pending.promise });
  c.inputCommand.value = "sub add https://example.test/?token=private";
  const running = c.submitCommand();
  c.resetSession();
  assert.equal(c.history.value.length, 0); assert.equal(c.executedList.value.length, 0);
  assert.equal(c.inputCommand.value, ""); assert.equal(c.draftInput.value, "");
  assert.equal(c.executing.value, true);
  await c.runCommandDirect("service restart sing-box"); assert.equal(cliCalls.length, 1);
  pending.resolve("private result"); await running;
  assert.equal(c.executedList.value.length, 0); assert.equal(c.executing.value, false);
  assert.match(pageSource, /onDeactivated\(resetSession\)/); assert.match(pageSource, /onBeforeUnmount\(resetSession\)/);
  assert.doesNotMatch(pageSource, /loadTerminalHistory/);
});

test("native failures and diagnostic-looking successful output remain distinct", async () => {
  for (const output of ["[error] errno=1", "[error] unavailable: bridge", "[exec-timeout] deadline", "a log contains [error] as text"]) {
    const { context: c } = fixture({ runCli: async () => output });
    c.inputCommand.value = "health"; await c.submitCommand();
    assert.equal(c.executedList.value[0].ok, output.startsWith("a log"));
  }
  const { context: c } = fixture({ runCli: async () => { throw new Error("rejected"); } });
  c.inputCommand.value = "health"; await c.submitCommand();
  assert.equal(c.executedList.value[0].ok, false); assert.equal(c.executing.value, false);
});

test("previews and retained output have independent size/count bounds", async () => {
  const { context: c } = fixture({ runCli: async () => "x".repeat(100000) });
  for (let i = 0; i < c.entryLimit + 2; i++) {
    c.inputCommand.value = `health ${"y".repeat(10000)}`; await c.submitCommand();
  }
  assert.equal(c.executedList.value.length, c.entryLimit);
  assert.ok(c.executedList.value.every(entry => entry.output.length <= OUTPUT_RENDER_LIMIT && entry.command.length < 420));
  assert.equal(c.history.value.length, 0);
});

test("explicit clear reports partial failure and works with empty session history", async () => {
  const { context: c, shellCalls } = fixture({ shellResult: "[error] errno=1" });
  await c.handleClearHistory();
  assert.equal(c.historyClearFailed.value, true); assert.equal(c.clearingHistory.value, false);
  assert.equal(shellCalls.length, 1);
  assert.doesNotMatch(pageSource, /:disabled="history\.length === 0"/);
});
