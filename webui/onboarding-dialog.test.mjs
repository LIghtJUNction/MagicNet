import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const dialog = readFileSync(
  new URL("./src/components/OnboardingDialog.vue", import.meta.url),
  "utf8",
);
const draft = readFileSync(
  new URL("./src/components/pages/subscriptionDraft.ts", import.meta.url),
  "utf8",
);
const focus = readFileSync(
  new URL("./src/lib/focus.ts", import.meta.url),
  "utf8",
);

for (const required of [
  "订阅链接",
  "HTTPS 订阅链接",
  'placeholder="每行一个 HTTPS 订阅链接"',
  'emit("submit", trimmed)',
  '@submit="handleOnboardingSubmit"',
  "setPendingSubscriptionDraft(value)",
  "打开订阅",
  'setTab("subs")',
  "takePendingSubscriptionDraft",
]) {
  assert.ok(
    dialog.includes(required) ||
      app.includes(required) ||
      draft.includes(required),
    `missing onboarding invariant: ${required}`,
  );
}

assert.match(
  app,
  /const ONBOARDING_STORAGE_KEY = "magicnet\.webui\.onboarding\.v1"/,
);
assert.match(app, /window\.localStorage\.getItem\(ONBOARDING_STORAGE_KEY\)/);
assert.match(
  app,
  /window\.localStorage\.setItem\(ONBOARDING_STORAGE_KEY, value\)/,
);
assert.match(app, /if \(!readOnboardingPreference\(\)\)/);
assert.match(app, /<OnboardingDialog/);
assert.match(app, /@dismiss="closeOnboarding\(\)"/);
assert.match(app, /@submit="handleOnboardingSubmit"/);
assert.match(app, /closeUtilityMenu\(false\)/);
assert.match(app, /launchOnboarding\(utilityMenuTrigger\.value\)/);
assert.match(app, /restoreFocusAfterUpdate\(trigger\)/);
assert.match(app, /<ScrollText :size="18"[^>]*\/>新手引导/);

for (const invariant of [
  'role="dialog"',
  'aria-modal="true"',
  'aria-labelledby="onboarding-title"',
  "data-dialog-initial-focus",
  "@keydown.esc.prevent.stop",
  'document.body.style.overflow = "hidden"',
  "document.body.style.overflow = previousBodyOverflow",
  "trapFocusWithin(event, dialog.value)",
  'emit("submit", trimmed)',
  "emit('dismiss')",
]) {
  assert.ok(
    dialog.includes(invariant),
    `onboarding dialog missing ${invariant}`,
  );
}

for (const forbidden of [
  "步骤 1",
  "步骤 2",
  "步骤 3",
  "步骤 4",
  "MagicNet 默认使用 sing-box",
  "校验没通过时",
  "稍后再看",
  "完成引导",
  "保存并打开订阅",
  "<ol",
  /TProxy/,
  /ALLOW_MULTI/,
]) {
  assert.doesNotMatch(
    dialog,
    typeof forbidden === "string"
      ? new RegExp(forbidden.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      : forbidden,
  );
}

assert.match(
  focus,
  /if \(event\.shiftKey && \(active === first \|\| !root\.contains\(active\)\)\)/,
);
assert.match(
  focus,
  /else if \(!event\.shiftKey && \(active === last \|\| !root\.contains\(active\)\)\)/,
);
assert.match(focus, /restoreFocusAfterUpdate/);
assert.match(focus, /element\.isConnected/);

assert.match(draft, /pendingSubscriptionDraft/);
assert.match(draft, /setPendingSubscriptionDraft/);
assert.match(draft, /takePendingSubscriptionDraft/);

console.log("onboarding dialog tests passed");
