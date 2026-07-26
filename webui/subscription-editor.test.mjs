import assert from "node:assert/strict";
import {
  buildSubscriptionApplyLaunch,
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

const basename = "magicnet-webui-123.b64";
const launch = buildSubscriptionApplyLaunch(basename);
assert.equal(launch.args, "webui payload apply-subscription 'magicnet-webui-123.b64'");
assert.equal(launch.displayArgs, "webui payload apply-subscription [private-payload]");
assert.equal(launch.lifecycleArgs, "sub apply-file sing-box [redacted-payload]");
assert.equal(launch.preview.includes(basename), false);
assert.equal(launch.args.includes("subscription-url"), false);

console.log("subscription editor tests passed");
