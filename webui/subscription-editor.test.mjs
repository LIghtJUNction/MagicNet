import assert from "node:assert/strict";
import {
  buildSubscriptionApplyLaunch,
  buildSubscriptionPreview,
  buildSubscriptionSavePlan,
  reconcileSubscriptionEditor,
  summarizeSubscriptionInput,
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

const httpPlan = buildSubscriptionSavePlan("http://example.invalid/sub");
assert.equal(httpPlan.status, "error", "HTTP subscriptions must be rejected before device submission");
assert.equal(httpPlan.http, 1);
assert.match(httpPlan.message, /HTTPS/);
const httpSummary = summarizeSubscriptionInput("http://example.invalid/sub\nhttps://secure.example.invalid/sub");
assert.equal(httpSummary.valid, 1, "only HTTPS subscriptions count as valid");
const credentialPlan = buildSubscriptionSavePlan("https://user:secret@example.invalid/sub");
assert.equal(credentialPlan.status, "error", "subscription credentials must be rejected before device submission");
assert.match(credentialPlan.message, /凭据/);
assert.equal(credentialPlan.invalid, 1, "credential-bearing URLs must be counted as invalid");
const summary = summarizeSubscriptionInput("https://EXAMPLE.invalid/sub\nhttps://example.invalid/sub\nhttp://other.invalid/sub");
assert.deepEqual(summary, { raw: 3, valid: 2, duplicate: 1, overLimit: 0 });
const previews = buildSubscriptionPreview([
  "not-a-url",
  "https://one.invalid/sub",
  "https://two.invalid/sub",
  "https://three.invalid/sub",
  "https://four.invalid/sub",
  "https://five.invalid/sub",
].join("\n"));
assert.equal(previews[5].status, "ok", "invalid lines must not consume the subscription limit");

console.log("subscription editor tests passed");
