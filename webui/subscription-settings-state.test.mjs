import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";
import { computed, nextTick, reactive, ref, watch } from "vue";
import { useActionLock } from "./src/composables/useActionLock.ts";
import { subscriptionDefaults } from "./src/composables/parsers.ts";
import { bytesToBase64, execFailed } from "./src/utils.ts";

const settings = [
  { component: "SubscriptionUserAgentCard", field: "userAgent", draft: "userAgentText", dirty: "userAgentDirty", save: "persistUserAgent", before: "before", submitted: "submitted", later: "later", external: "external" },
  { component: "SubscriptionFilterCard", field: "filters", draft: "filterKeywords", dirty: "filterDirty", save: "saveFilters", before: ["before"], submitted: ["submitted"], later: ["later"], external: ["external"] },
  { component: "SubscriptionScheduleCard", field: "scheduleIntervalHours", draft: "scheduleValue", dirty: "scheduleDirty", save: "saveSchedule", before: "12", submitted: "24", later: "48", external: "72" },
];

function fixture(setting, { refreshOk = true } = {}) {
  const source = readFileSync(new URL(`./src/components/pages/subscriptions/${setting.component}.vue`, import.meta.url), "utf8");
  const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1]
    .replace(/^import[\s\S]*?;\s*$/gm, "");
  const code = ts.transpileModule(script, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
  }).outputText;
  const state = reactive({ subscriptions: { ...subscriptionDefaults, [setting.field]: setting.before } });
  const calls = [];
  let complete;
  const response = new Promise((resolve) => { complete = resolve; });
  const stops = [];
  const dependencies = {
    computed, ref, watch: (...args) => { const stop = watch(...args); stops.push(stop); return stop; },
    defineProps: () => ({ configured: false }), defineExpose() {},
    t: (text) => text, useActionLock, bytesToBase64, execFailed,
    useMagicNet: () => ({
      state,
      runCli: (command) => { calls.push(command); return response; },
      refreshSubs: async () => {
        if (refreshOk) state.subscriptions[setting.field] = setting.submitted;
        await nextTick();
        return refreshOk;
      },
      startBackgroundCli: async () => { calls.push("sub update-all"); },
    }),
  };
  const expose = `\nreturn { draft: ${setting.draft}, dirty: ${setting.dirty}, save: ${setting.save} };`;
  const controller = new Function(...Object.keys(dependencies), code + expose)(...Object.values(dependencies));
  return { ...controller, state, calls, complete, stop: () => stops.forEach((stop) => stop()) };
}

for (const setting of settings) {
  test(`${setting.component}: a completed save preserves a newer draft across refreshes`, async () => {
    const f = fixture(setting);
    try {
      f.draft.value = setting.submitted;
      f.dirty.value = true;
      const saving = f.save();
      assert.equal(f.calls.length, 1);
      f.draft.value = setting.later;
      f.dirty.value = true;
      f.complete("[info] saved");
      await saving;
      assert.deepEqual(f.draft.value, setting.later);
      assert.equal(f.dirty.value, true, "the later edit has not been saved");
      f.state.subscriptions[setting.field] = setting.external;
      await nextTick();
      assert.deepEqual(f.draft.value, setting.later, "a subsequent read must not discard the draft");
    } finally { f.stop(); }
  });

  test(`${setting.component}: only a matching observation clears the saved draft`, async () => {
    const f = fixture(setting);
    try {
      f.draft.value = setting.submitted;
      f.dirty.value = true;
      const saving = f.save();
      f.complete("[info] saved");
      await saving;
      assert.equal(f.dirty.value, false);
      assert.deepEqual(f.draft.value, setting.submitted);
    } finally { f.stop(); }
  });

  test(`${setting.component}: failed observation retains the unconfirmed draft`, async () => {
    const f = fixture(setting, { refreshOk: false });
    try {
      f.draft.value = setting.submitted;
      f.dirty.value = true;
      const saving = f.save();
      f.complete("[info] saved");
      await saving;
      assert.equal(f.dirty.value, true);
      assert.deepEqual(f.draft.value, setting.submitted);
    } finally { f.stop(); }
  });
}

test("automatic updates can be restarted without changing a saved interval", async () => {
  const f = fixture(settings[2]);
  try {
    f.state.subscriptions.scheduleEnabled = true;
    f.state.subscriptions.scheduleOwner = "stale";
    f.state.subscriptions.scheduleOwnerValid = false;
    const saving = f.save();
    assert.deepEqual(f.calls, ["sub schedule set 12"]);
    f.complete("[info] saved");
    await saving;
  } finally { f.stop(); }
});
