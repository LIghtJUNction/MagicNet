import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import ts from "typescript";
import * as background from "./src/composables/backgroundTasks.ts";
import { invalidateTransparentRuntime, parseRuntime, parseSubs, runtimeDefaults, subscriptionDefaults } from "./src/composables/parsers.ts";
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
  "refreshAll",
  "refreshStatus", "markQuietFailure",
];
const controlSource = ts.createSourceFile(
  "ControlPage.ts",
  readFileSync(new URL("./src/components/pages/ControlPage.vue", import.meta.url), "utf8")
    .split('<script setup lang="ts">')[1].split("</script>")[0],
  ts.ScriptTarget.Latest,
  true,
);
const functions = source.statements
  .filter((node) => ts.isFunctionDeclaration(node) && names.includes(node.name?.text))
  .map((node) => node.getText(source)).join("\n") + "\n" + controlSource.statements
  .find((node) => ts.isFunctionDeclaration(node) && node.name?.text === "rebuildNodeCache")
  .getText(controlSource);
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
    subscriptions: { ...subscriptionDefaults }, runtime: { ...runtimeDefaults },
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
    runCli: async () => "status", parseSubs, execFailed, parseRuntime, invalidateTransparentRuntime,
    withAction: async (_, action) => action(),
    refreshApps: async () => true,
    refreshBlock: async () => true, refreshDns: async () => true,
    refreshWarp: async () => true, refreshWifiPolicy: async () => true,
    refreshMcp: async () => true, refreshHealth: async () => true,
    refreshAllNotice: (completed, notice) => completed ? "panel refreshed" : notice,
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

for (const failedRead of ["sub list", "sub status"]) {
  test(`failed ${failedRead} baseline stops the launch and permits a retry`, async () => {
    const { context, state } = backgroundFixture();
    state.backgroundTask.status = "idle";
    let launches = 0;
    context.runCli = async (args) => args === failedRead ? "[error] errno=1 read failed" : "";
    context.runShellOutcome = async () => {
      launches += 1;
      return { ok: true, stdout: "[accepted] id=operation", text: "accepted" };
    };
    const result = await context.startBackgroundCli("sub update-all", "更新订阅");
    assert.equal(launches, 0);
    assert.equal(execFailed(result), true);
    assert.equal(state.backgroundTask.status, "idle");
    assert.equal(background.backgroundTaskBlocksLaunch(state.backgroundTask), false);
    assert.equal(state.phase, "error");
    assert.match(state.notice, /未执行/);
    assert.match(state.output, /重试/);

    context.runCli = async () => "last_attempt_epoch=1\nlast_generation_id=old\nlast_result=success";
    await context.startBackgroundCli("sub update-all", "更新订阅");
    assert.equal(launches, 1);
    assert.equal(state.backgroundTask.subscriptionBaselineKnown, true);
  });
}

test("a superseded baseline failure leaves the newer foreground feedback untouched", async () => {
  const { context, state, supersede } = backgroundFixture();
  state.backgroundTask.status = "idle";
  let resolveRead;
  const pendingRead = new Promise((resolve) => { resolveRead = resolve; });
  context.runCli = () => pendingRead;
  context.runShellOutcome = () => assert.fail("a failed baseline must never launch");
  const launching = context.startBackgroundCli("sub update-all");
  supersede();
  resolveRead("[error] errno=1 read failed");
  await launching;
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
  assert.equal(state.phase, "done");
});

test("ControlPage completion does not begin a foreground refresh over a newer action", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  state.backgroundTask.status = "idle";
  let attempt = 1;
  context.runCli = async (args) => args === "sub status"
    ? `last_attempt_epoch=${attempt}\nlast_generation_id=generation-${attempt}\nlast_result=success`
    : "";
  context.runShellOutcome = async () => ({ ok: true, stdout: "[accepted] id=operation", text: "accepted" });
  await context.rebuildNodeCache();
  const foregroundToken = supersede();
  attempt = 2;
  while (timers.length) await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.subscriptions.lastAttemptEpoch, 2);
  assert.equal(context.foregroundUiGate.current(), foregroundToken);
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
});

const serviceSnapshot = "sing-box: running\nfswatch: running";
const transparentSnapshot = "mode=ebpf\neffective_mode=hybrid\ncapability=ok\nlocal_cgroup=attached\nshared_tc=attached\nshared_interfaces=wlan2\ntransition=idle";

test("completed background tasks quietly refresh complete runtime after foreground ownership changes", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  state.runtime.singBoxState = "stopped";
  state.busy = true;
  context.runCli = async (args) => args === "service status" ? serviceSnapshot : transparentSnapshot;
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  supersede();
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.runtime.singBoxState, "sing-box");
  assert.equal(state.runtime.transparentMode, "ebpf");
  assert.equal(state.runtime.transparentEffectiveMode, "hybrid");
  assert.equal(state.runtime.transparentLocalCgroup, "attached");
  assert.equal(state.runtime.transparentSharedTc, "attached");
  assert.deepEqual(state.runtime.transparentSharedInterfaces, ["wlan2"]);
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
  assert.equal(state.phase, "done");
  assert.equal(state.busy, true);
});

test("completion refresh discards a runtime snapshot superseded while its reads were pending", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  let resolveRead, startRead;
  const pending = new Promise((resolve) => { resolveRead = resolve; });
  const started = new Promise((resolve) => { startRead = resolve; });
  context.runCli = async (args) => {
    startRead();
    await pending;
    return args === "service status" ? serviceSnapshot : transparentSnapshot;
  };
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  const polling = timers.shift()();
  await started;
  supersede();
  const newerRuntime = parseRuntime("sing-box: stopped\nmode=tun\neffective_mode=tun", runtimeDefaults);
  state.runtime = newerRuntime;
  resolveRead();
  await polling;
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.runtime, newerRuntime);
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
});

test("failed completion status reads preserve newer foreground feedback", async () => {
  const { context, state, timers, supersede } = backgroundFixture();
  context.runCli = async () => "[error] errno=1 status read failed";
  context.followBackgroundLogs("/task.log", "restart", "service restart", "operation", 1, 1);
  supersede();
  await timers.shift()();
  assert.equal(state.backgroundTask.status, "done");
  assert.equal(state.output, "new foreground output");
  assert.equal(state.notice, "new notice");
  assert.equal(state.phase, "done");
});
