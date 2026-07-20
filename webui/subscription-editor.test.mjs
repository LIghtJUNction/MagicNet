import assert from "node:assert/strict";
import {
  buildSubscriptionApplyLaunch,
  buildSubscriptionPayloadPlan,
  reconcileSubscriptionEditor,
} from "./src/components/pages/subscriptionPreview.ts";

const raced = reconcileSubscriptionEditor({
  draft: "C",
  lastLoadedSnapshot: "A",
  deviceSnapshot: "B",
  dirty: true,
  loadedOnce: true,
  editRevision: 2,
  pendingApply: { snapshot: "B", revision: 1 },
});
assert.equal(raced.draft, "C", "A -> apply B -> edit C -> device B must preserve C");
assert.equal(raced.lastLoadedSnapshot, "B");
assert.equal(raced.dirty, true);
assert.equal(raced.pendingApply, null);
assert.equal(raced.syncedDraft, false);

const unchanged = reconcileSubscriptionEditor({
  draft: "B",
  lastLoadedSnapshot: "A",
  deviceSnapshot: "B",
  dirty: true,
  loadedOnce: true,
  editRevision: 1,
  pendingApply: { snapshot: "B", revision: 1 },
});
assert.equal(unchanged.draft, "B");
assert.equal(unchanged.dirty, false);
assert.equal(unchanged.syncedDraft, true);

const encodedCanary = "U0VDUkVULUJB U0U2NC1DQU5BUlk=".replace(" ", "");
const directory = "/module/.state/webui-subscription-payload";
const payload = `${directory}/magicnet-webui-123.b64`;
const plan = buildSubscriptionPayloadPlan(encodedCanary.repeat(120), directory, payload, 80);
assert.match(plan.prepareCommand, /^umask 077 && mkdir -p /);
for (const token of ["chmod 700", "magicnet-webui-*.b64", ": >", "chmod 600", "printf %s"]) {
  assert.ok(plan.prepareCommand.includes(token), `prepare command missing ${token}`);
}
assert.ok(plan.prepareCommand.indexOf("mkdir -p") < plan.prepareCommand.indexOf("chmod 700"));
assert.ok(plan.prepareCommand.indexOf("magicnet-webui-*.b64") < plan.prepareCommand.indexOf(": >"));
assert.ok(plan.prepareCommand.indexOf(": >") < plan.prepareCommand.indexOf("chmod 600"));
assert.ok(plan.prepareCommand.indexOf("chmod 600") < plan.prepareCommand.indexOf("printf %s"));
assert.match(plan.cleanupCommand, /^rm -f /);
assert.ok(plan.appendCommands.length > 1);

const launch = buildSubscriptionApplyLaunch(payload);
assert.equal(launch.displayArgs, "sub apply-file sing-box [redacted-payload]");
assert.equal(launch.displayArgs.includes(encodedCanary), false);
assert.equal(launch.preview.includes(encodedCanary), false);
assert.equal(launch.args.includes(encodedCanary), false);
assert.equal(launch.cleanupCommand.includes(encodedCanary), false);

console.log("subscription editor tests passed");
