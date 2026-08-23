import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const focus = readFileSync(
  new URL("./src/lib/focus.ts", import.meta.url),
  "utf8",
);

for (const invariant of [
  'ref="utilityDialog"',
  "data-dialog-initial-focus",
  "trapUtilityMenuFocus(event)",
  "trapFocusWithin(event, utilityDialog.value)",
  'event.key !== "Escape"',
  'document.body.style.overflow = "hidden"',
  "document.body.style.overflow = bodyOverflowBeforeDialog",
  "restoreFocusAfterUpdate(trigger)",
  'role="dialog"',
  'aria-modal="true"',
]) {
  assert.ok(source.includes(invariant), `utility sheet missing ${invariant}`);
}

for (const invariant of [
  'event.key !== "Tab"',
  "event.shiftKey",
  "!root.contains(active)",
  "element.isConnected",
  "element.focus()",
]) {
  assert.ok(
    focus.includes(invariant),
    `shared focus helper missing ${invariant}`,
  );
}

assert.match(
  source,
  /<Button[\s\S]{0,500}?class="mn-mobile-action"[\s\S]{0,500}?aria-haspopup="dialog"[\s\S]{0,400}?@click="openUtilityMenu"/,
  "the mobile utility trigger must advertise and open the dialog",
);
assert.match(
  source,
  /function requestOnboarding[\s\S]{0,500}?if \(showUtilityMenu\.value\)[\s\S]{0,180}?closeUtilityMenu\(false\)/,
  "opening onboarding from the sheet must close it without an intermediate focus jump",
);
assert.match(
  source,
  /function handleEscape[\s\S]{0,500}?if \(showUtilityMenu\.value\)[\s\S]{0,180}?closeUtilityMenu\(\)/,
  "Escape must close the utility sheet and restore focus",
);
assert.match(
  source,
  /async function requestIssue[\s\S]{0,180}?closeUtilityMenu\(false\)[\s\S]{0,120}?createIssue\(\)/,
  "issue creation must hand off from the utility sheet without focus thrash",
);

console.log("modal accessibility tests passed");
