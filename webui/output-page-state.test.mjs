import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { t } from "./src/i18n/index.ts";
import { backgroundLogCommand, backgroundTaskDefaults } from "./src/composables/backgroundTasks.ts";
import { SerialExecQueue } from "./src/composables/execQueue.ts";
import { ForegroundUiGate } from "./src/composables/foregroundUiGate.ts";
import { beginOperationCapture, emptyOperationCapture, updateOperationCapture } from "./src/composables/operationCapture.ts";
import { compactCommand, execFailed, ExecTimeoutError, normalizeExecOutcome, redactedCliPreview, shellQuote, unavailableExecOutcome } from "./src/utils.ts";

// Exercise the page handler and production command/outcome ownership together;
// only the KernelSU bridge and rendering waits are replaced by deferred I/O.
function functionsFrom(path, names) {
  const file = readFileSync(new URL(path, import.meta.url), "utf8");
  const script = path.endsWith(".vue") ? file.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1] : file;
  const source = ts.createSourceFile(path, script, ts.ScriptTarget.Latest, true);
  return names.map((name) => {
    const node = source.statements.find((entry) => ts.isFunctionDeclaration(entry) && entry.name?.text === name);
    assert.ok(node, `missing production function ${name}`);
    return node.getText(source);
  }).join("\n");
}

const code = ts.transpileModule([
  functionsFrom("./src/composables/useMagicNet.ts", [
    "trackRedactedOperation", "publishTrackedOperation", "runShellOutcome", "runTrackedQuietShellOutcome", "runShell",
  ]),
  functionsFrom("./src/components/pages/OutputPage.vue", ["refreshBackgroundLog"]),
].join("\n"), { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;

globalThis.window = { setTimeout, clearTimeout };
const settle = () => new Promise((resolve) => setImmediate(resolve));

function fixture({ available = true } = {}) {
  const pending = [];
  const commands = [];
  const state = {
    backgroundTask: { ...backgroundTaskDefaults, id: "fixture-operation", label: "后台测试", args: "sub update-all", log: "/fixture/task.log", startedAt: 1, updatedAt: 123, status: "done" },
    operationCapture: emptyOperationCapture(),
    phase: "idle", output: "previous output", notice: "", lastCommand: "", busy: false, task: "",
  };
  const context = vm.createContext({
    state, t, Date, copied: { value: true }, issueCopied: { value: true },
    backgroundLogCommand, compactCommand, execFailed, ExecTimeoutError, normalizeExecOutcome, redactedCliPreview, shellQuote, unavailableExecOutcome,
    beginOperationCapture, updateOperationCapture, foregroundUiGate: new ForegroundUiGate(),
    nextTick: async () => {}, nextFrame: async () => {}, hasAsyncExec: () => available,
    CLI_TIMEOUT_MS: 5000,
    execQueue: new SerialExecQueue(),
    execAsync: (command) => {
      commands.push(command);
      return new Promise((resolve, reject) => pending.push({ resolve, reject }));
    },
  });
  vm.runInContext(code, context);
  return { context, state, pending, commands };
}

function assertPrivateCapture(state) {
  assert.match(state.lastCommand, /refresh background log \[private-output\]/);
  assert.doesNotMatch(state.operationCapture.output, /fixture-secret|fixture\/task\.log/);
  assert.doesNotMatch(state.notice, /fixture-secret/);
}

test("background log success updates the view and time without exporting private log content", async () => {
  const f = fixture();
  const refreshing = f.context.refreshBackgroundLog();
  await settle();
  f.pending[0].resolve({ errno: 0, stdout: "[error] diagnostic log entry\nfixture-secret", stderr: "" });
  await refreshing;
  assert.equal(f.state.phase, "done");
  assert.ok(f.state.backgroundTask.updatedAt > 123);
  assert.match(f.state.output, /^后台日志已刷新：后台测试/);
  assert.match(f.state.output, /\[error\] diagnostic log entry/);
  assert.equal(f.context.copied.value, false);
  assert.equal(f.context.issueCopied.value, false);
  assertPrivateCapture(f.state);
});

test("empty successful background logs remain a confirmed refresh", async () => {
  const f = fixture();
  const refreshing = f.context.refreshBackgroundLog();
  await settle();
  f.pending[0].resolve({ errno: 0, stdout: "", stderr: "" });
  await refreshing;
  assert.equal(f.state.phase, "done");
  assert.ok(f.state.backgroundTask.updatedAt > 123);
  assert.match(f.state.output, /日志为空。/);
});

for (const failure of ["exit status", "timeout", "unavailable bridge"]) {
  test(`background log ${failure} preserves the previous update time and redacted failure`, async () => {
    const f = fixture({ available: failure !== "unavailable bridge" });
    const refreshing = f.context.refreshBackgroundLog();
    await settle();
    if (failure === "exit status") f.pending[0].resolve({ errno: 23, stdout: "fixture-secret partial log", stderr: "fixture-secret failure" });
    if (failure === "timeout") f.pending[0].reject(new ExecTimeoutError("fixture-secret timeout"));
    await refreshing;
    assert.equal(f.state.phase, "error");
    assert.equal(f.state.backgroundTask.updatedAt, 123);
    assert.match(f.state.notice, /^失败：/);
    assert.match(f.state.output, failure === "timeout" ? /\[exec-timeout\]/ : /\[error\] errno=/);
    assert.doesNotMatch(f.state.output, /后台日志已刷新|fixture-secret/);
    assert.equal(f.state.output, f.state.operationCapture.output);
    assertPrivateCapture(f.state);
  });
}

for (const errno of [0, 23]) {
  test(`late background log result (${errno}) cannot overwrite a newer foreground command`, async () => {
    const f = fixture();
    const refreshing = f.context.refreshBackgroundLog();
    await settle();
    const newer = f.context.runShell("cli health", "健康检查");
    f.pending[0].resolve({ errno, stdout: "fixture-secret old log", stderr: "" });
    await refreshing;
    await settle();
    assert.equal(f.state.backgroundTask.updatedAt, 123);
    assert.match(f.state.output, /cli health/);
    assert.doesNotMatch(f.state.output, /后台日志已刷新|fixture-secret/);
    assert.match(f.state.notice, /健康检查/);
    f.pending[1].resolve({ errno: 0, stdout: "current health result", stderr: "" });
    await newer;
    assert.equal(f.state.phase, "done");
    assert.match(f.state.output, /current health result/);
  });
}

test("background log completion does not update a replacement task", async () => {
  const f = fixture();
  const refreshing = f.context.refreshBackgroundLog();
  await settle();
  f.state.backgroundTask = { ...f.state.backgroundTask, id: "replacement", log: "/fixture/new-task.log", updatedAt: 456 };
  f.pending[0].resolve({ errno: 0, stdout: "fixture-secret old log", stderr: "" });
  await refreshing;
  assert.equal(f.state.backgroundTask.updatedAt, 456);
  assert.doesNotMatch(f.state.output, /后台日志已刷新|fixture-secret/);
});
