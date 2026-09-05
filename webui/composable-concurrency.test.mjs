import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import ts from "typescript";
import * as background from "./src/composables/backgroundTasks.ts";
import { parseSubs, subscriptionDefaults } from "./src/composables/parsers.ts";
import { execFailed } from "./src/utils.ts";

// Execute the production functions with deferred device I/O and manual timers.
const source = ts.createSourceFile(
  "useMagicNet.ts",
  readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8"),
  ts.ScriptTarget.Latest,
  true,
);
const names = [
  "configDraftMatches", "loadConfig", "saveConfig", "syncConfigTemplate",
  "startBackgroundCli", "followBackgroundLogs",
  "refreshSubs", "canUpdateRefreshUi", "startForegroundCommand",
];
const functions = source.statements
  .filter((node) => ts.isFunctionDeclaration(node) && names.includes(node.name?.text))
  .map((node) => node.getText(source)).join("\n");
const code = ts.transpileModule(functions, {
  compilerOptions: { target: ts.ScriptTarget.ES2022 },
}).outputText;

function fixture() {
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const state = { config: { target: "sing-box", text: "original draft", dirty: true, status: "", validation: {} } };
  const context = vm.createContext({
    state, Date, Math,
    MODULE_DIR: "/module", shellQuote: (value) => `'${value}'`, redactedCliPreview: (value) => value,
    foregroundUiGate: { current: () => 1, owns: () => true },
    runCli: () => pending,
    execFailed: () => false, parseConfigValidation: () => ({ summary: "" }),
    stagePrivatePayload: async () => ({ basename: "payload", path: "/private/payload" }),
    runPrivateCli: () => pending,
    removePrivatePayload: async () => true,
  });
  vm.runInContext(code, context);
  return { context, state, resolve };
}

function backgroundFixture() {
  let token = 1;
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const timers = [];
  const state = {
    backgroundTask: { id: "operation", status: "running" },
    subscriptions: { ...subscriptionDefaults }, runtime: {},
    output: "new foreground output", notice: "new notice", phase: "done",
  };
  const context = vm.createContext({
    ...background, state, Date, backgroundLogTimer: 0,
    window: { setTimeout: (callback) => { timers.push(callback); return timers.length; } },
    foregroundUiGate: { begin: () => ++token, current: () => token, owns: (value) => value === token },
    nextTick: async () => {}, nextFrame: async () => {}, stopBackgroundLogFollow: () => {},
    createBackgroundOperationId: () => "operation", trackRedactedOperation: () => 1,
    redactedCliPreview: (value) => value,
    runShellOutcome: () => pending,
    runShell: async () => "[launch] id=operation label=restart\n[exit] id=operation status=0",
    runCli: async () => "status", parseSubs, execFailed,
    parseRuntime: (_, runtime) => runtime,
    publishTrackedOperation: (_, phase, notice, output) => { Object.assign(state, { phase, notice, output }); return true; },
  });
  vm.runInContext(code, context);
  return { context, state, timers, resolve, supersede: () => ++token };
}

test("late config reads preserve edits entered while loading", async () => {
  const { context, state, resolve } = fixture();
  const loading = context.loadConfig();
  state.config.text = "new draft";
  resolve("device config");
  await loading;
  assert.equal(state.config.text, "new draft");
  assert.equal(state.config.dirty, true);
});

test("saving a submitted snapshot leaves newer edits dirty and unvalidated", async () => {
  const { context, state, resolve } = fixture();
  const saving = context.saveConfig();
  state.config.text = "new unsaved draft";
  resolve({ ok: true, stdout: "[info] Saved and validated" });
  await saving;
  assert.equal(state.config.text, "new unsaved draft");
  assert.equal(state.config.dirty, true);
  assert.equal(state.config.validation.status, "idle");
});

test("unchanged submitted drafts become clean after a confirmed save", async () => {
  const { context, state, resolve } = fixture();
  const saving = context.saveConfig();
  resolve({ ok: true, stdout: "[info] Saved and validated" });
  await saving;
  assert.equal(state.config.dirty, false);
  assert.equal(state.config.validation.status, "ok");
});

test("template synchronization preserves edits entered while it was running", async () => {
  const { context, state, resolve } = fixture();
  const syncing = context.syncConfigTemplate();
  state.config.text = "new draft";
  resolve("template synced");
  await syncing;
  assert.equal(state.config.text, "new draft");
  assert.equal(state.config.dirty, true);
  assert.equal(state.config.validation.status, "idle");
});

test("foreground commands do not strand a completed background task", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  supersede();
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, "new foreground output");
});

test("launch acknowledgment still starts polling after foreground ownership changes", async () => {
  const { context, state, timers, resolve, supersede } = backgroundFixture();
  state.backgroundTask.status = "idle";
  const launching = context.startBackgroundCli("service restart");
  supersede();
  resolve({ ok: true, stdout: "[accepted] id=operation", text: "accepted" });
  await launching;
  assert.equal(timers.length, 1);
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, "new foreground output");
});

test("stale poll results do not complete a different background operation", async () => {
  const { context, state, timers } = backgroundFixture();
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  state.backgroundTask.id = "replacement";
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "running");
  assert.equal(state.output, "new foreground output");
});

test("background polling continues until completion after a foreground change", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  const completedLog = context.runShell;
  context.runShell = async () => "[launch] id=operation label=restart";
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  supersede();
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "running");
  assert.equal(timers.length, 1);
  context.runShell = completedLog;
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, "new foreground output");
});

test("subscription polling failures preserve newer foreground feedback and keep tracking", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  Object.assign(state.backgroundTask, {
    subscriptionBaselineKnown: true, subscriptionBaselineAttemptEpoch: 1,
    subscriptionBaselineGenerationId: "old-generation", subscriptionBaselineResult: "success",
  });
  context.runCli = async () => "[error] errno=1 subscription read failed";
  context.followBackgroundLogs("/task.log", "update", "sub update-all", "operation", 1, 1);
  supersede();
  await timers.shift()();
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
  assert.equal(state.phase, "done");
  assert.equal(state.backgroundTask.status, "running");

  context.runCli = async (args) => args === "sub status"
    ? "last_result=success\nlast_attempt_epoch=2\nlast_generation_id=new-generation"
    : "";
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, "new foreground output");
});

test("subscription launch waits for its lifecycle baseline before changing the device", async () => {
  const { context, state } = backgroundFixture();
  state.backgroundTask.status = "idle";
  let resolveBaseline;
  let launched = false;
  const baseline = new Promise((resolve) => { resolveBaseline = resolve; });
  context.runCli = () => baseline;
  context.runShellOutcome = async () => {
    launched = true;
    return { ok: true, stdout: "[accepted] id=operation", text: "accepted" };
  };
  const launching = context.startBackgroundCli("sub update-all");
  await Promise.resolve();
  assert.equal(launched, false);
  resolveBaseline("last_attempt_epoch=1\nlast_generation_id=old\nlast_result=success");
  await launching;
  assert.equal(launched, true);
  assert.equal(state.backgroundTask.subscriptionBaselineKnown, true);
  assert.equal(state.backgroundTask.subscriptionBaselineAttemptEpoch, 1);
  assert.equal(state.backgroundTask.subscriptionBaselineGenerationId, "old");
});
