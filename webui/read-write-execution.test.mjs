import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";
import vm from "node:vm";
import ts from "typescript";
import * as queues from "./src/composables/execQueue.ts";
import * as device from "./src/composables/deviceExec.ts";
import * as capture from "./src/composables/operationCapture.ts";
import * as background from "./src/composables/backgroundTasks.ts";
import * as utils from "./src/utils.ts";
import { ForegroundUiGate } from "./src/composables/foregroundUiGate.ts";
import { runtimeDefaults } from "./src/composables/parsers.ts";
import { machineFailureText } from "./src/composables/machineStatus.ts";
import { t } from "./src/i18n/index.ts";

// Exercise the production dispatch, refresh and polling functions through the
// native callback adapter. The fixture controls only device replies and time.
const source = ts.createSourceFile("useMagicNet.ts",
  readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8"),
  ts.ScriptTarget.Latest, true);
const code = ts.transpileModule(source.statements.filter(node =>
  ts.isFunctionDeclaration(node) || (ts.isVariableStatement(node) &&
    node.declarationList.declarations.some(item => item.name.getText(source) === "execQueue")))
  .map(node => node.getText(source).replace(/^export /, "")).join("\n"), {
  compilerOptions: { target: ts.ScriptTarget.ES2022 },
}).outputText;

function fixture(testContext, timeoutMs = 1000) {
  globalThis.window = globalThis;
  const started = [];
  globalThis.ksu = { spawn(command, _args, _options, name) {
    started.push({ command, name, callback: window[name] });
  } };
  const state = {
    hasKsu: true, busy: false, queueDepth: 0, phase: "idle", output: "", notice: "",
    operationCapture: capture.emptyOperationCapture(),
    backgroundTask: { ...background.backgroundTaskDefaults, id: "operation", status: "running" },
    runtime: {},
  };
  const context = vm.createContext({
    ...queues, ...device, ...capture, ...background, ...utils, t,
    state, window: globalThis, Date, Math, CLI: "/module/cli", CLI_TIMEOUT_MS: timeoutMs,
    foregroundUiGate: new ForegroundUiGate(), backgroundLogTimer: 0,
    nextTick: async () => {}, nextFrame: async () => {},
    // Parsing is covered independently; this suite observes dispatch and ownership.
    parseMachineRuntime: () => ({ observed: true }), runtimeDefaults, machineFailureText,
  });
  vm.runInContext(code, context);
  const finish = (request, text = "observation", errno = 0) => {
    request.callback.stdout.emit("data", text);
    request.callback.emit("exit", errno);
  };
  testContext.after(async () => {
    context.stopBackgroundLogFollow();
    // Drain pending callbacks even when the pre-fix dispatch assertion fails.
    for (let round = 0; round < 20 && state.queueDepth; round++) {
      for (const request of started) finish(request);
      await setImmediate();
    }
    delete globalThis.ksu;
  });
  return { context, state, started, finish };
}

test("status refresh completes during a write without releasing or overwriting it", async t => {
  const { context, state, started, finish } = fixture(t);
  const write = context.runCli("service restart", "restart");
  await setImmediate();
  const originalOutput = state.output;
  const refresh = context.refreshStatus(undefined, false);
  const nextWrite = context.runPrivatePayloadCli("webui payload remove tmp next", "remove", "private");
  await setImmediate();
  assert.equal(started.length, 2, "the observer must reach the device while the write is still running");
  assert.match(started[1].command, /--json service status/);
  finish(started[1]);
  assert.equal(await refresh, true);
  assert.equal(state.runtime.observed, true, "the fresh observation must reach the page while a write is busy");
  assert.equal(state.output, originalOutput, "quiet reads do not own foreground feedback");
  assert.equal(state.busy, true);
  assert.equal(started.length, 2, "the second mutation must remain queued");
  finish(started[0], "restart complete");
  await write;
  await setImmediate();
  assert.equal(started.length, 3);
  finish(started[2]);
  await nextWrite;
});

test("failed observations clear stale runtime without replacing running-write feedback", async t => {
  const { context, state, started, finish } = fixture(t);
  state.runtime = { ...runtimeDefaults, singBoxState: "sing-box", singBoxRssKib: 1234 };
  const write = context.runCli("service restart", "restart");
  await setImmediate();
  const originalOutput = state.output;
  const refresh = context.refreshStatus();
  await setImmediate();
  assert.equal(started.length, 2);
  finish(started[1], "failed", 1);
  assert.equal(await refresh, false);
  assert.equal(state.runtime.singBoxState, "unknown");
  assert.equal(state.runtime.singBoxRssKib, null);
  assert.equal(state.output, originalOutput);
  assert.equal(state.phase, "running");
  assert.equal(state.busy, true);
  finish(started[0]);
  await write;
});

test("timed-out writes keep their slot while observers can still reconcile", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
  const { context, state, started, finish } = fixture(t, 100);
  const write = context.runShellOutcome("long-write", "write");
  await setImmediate();
  t.mock.timers.tick(100);
  assert.equal((await write).timedOut, true);
  const queued = context.runPrivatePayloadCli("webui payload remove tmp later", "later", "private");
  const refresh = context.refreshStatus(undefined, false);
  await setImmediate();
  assert.equal(started.length, 2);
  assert.match(started[1].command, /--json service status/);
  finish(started[1]);
  assert.equal(await refresh, true);
  t.mock.timers.tick(100);
  const expired = await queued;
  assert.equal(expired.ok, false);
  assert.equal(expired.timedOut, false, "an expired queued mutation never reached the device");
  assert.equal(state.queueDepth, 1);
  finish(started[0]);
  await setImmediate();
  assert.equal(started.length, 2, "the expired mutation must never execute later");
  assert.equal(state.queueDepth, 0);
});

test("observers are bounded to one active read and their timeouts do not unlock writes", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
  const { context, state, started, finish } = fixture(t, 100);
  const write = context.runCli("service restart", "restart", true);
  const first = context.refreshStatus(undefined, false);
  const second = context.refreshStatus(undefined, false);
  await setImmediate();
  assert.equal(started.length, 2);
  assert.equal(state.queueDepth, 3);
  t.mock.timers.tick(100);
  await Promise.all([write, first, second]);
  assert.equal(state.queueDepth, 2, "only the two native operations retain slots");
  finish(started[1]);
  await setImmediate();
  assert.equal(started.length, 2, "the expired observer is discarded");
  assert.equal(state.queueDepth, 1, "finishing a read cannot release a running write");
});

test("background log polling and completion status bypass a pending foreground write", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
  const { context, state, started, finish } = fixture(t, 2000);
  const write = context.runCli("long-write", "write");
  await setImmediate();
  const originalOutput = state.output;
  context.followBackgroundLogs("/task.log", "update", "sub cache-rebuild", "operation", 0, 0);
  t.mock.timers.tick(700);
  await setImmediate();
  assert.equal(started.length, 2);
  assert.match(started[1].command, /task\.log/);
  finish(started[1], "[launch] id=operation label=update\n[exit] id=operation status=0");
  await setImmediate();
  assert.equal(started.length, 3);
  assert.match(started[2].command, /--json service status/);
  finish(started[2]);
  await setImmediate();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, originalOutput);
  finish(started[0]);
  await write;
});

test("generic shell, private payload and JSON mutation requests remain serialized", async t => {
  const { context, started, finish } = fixture(t);
  const operations = [
    context.runShell("arbitrary-command", "shell", true),
    context.runPrivateCli("config-editor save-file sing-box /payload", "save", "private"),
    context.runPrivatePayloadCli("webui payload remove tmp payload", "remove", "private"),
    context.runMachineCli("--json module-update check request_123", "update"),
  ];
  for (let i = 0; i < operations.length; i++) {
    await setImmediate();
    assert.equal(started.length, i + 1);
    finish(started[i]);
    await operations[i];
  }
});
