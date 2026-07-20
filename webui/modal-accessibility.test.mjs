import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");

for (const invariant of [
  'ref="advancedDialog"',
  "data-dialog-initial-focus",
  "trapAdvancedNavFocus(event)",
  "event.shiftKey",
  'event.key !== "Escape"',
  'document.body.style.overflow = "hidden"',
  "document.body.style.overflow = bodyOverflowBeforeDialog",
  "trigger instanceof HTMLElement",
  'typeof trigger.focus === "function"',
  "trigger.isConnected",
  "trigger.focus()",
  'role="dialog"',
  'aria-modal="true"',
]) {
  assert.ok(source.includes(invariant), `advanced navigation modal missing ${invariant}`);
}

assert.doesNotMatch(
  source,
  /ref="advancedNavTrigger"\s+v-for="item in primaryTabs"/,
  "advanced navigation trigger ref must not be attached to the primaryTabs v-for",
);
assert.match(
  source,
  /<button\s+ref="advancedNavTrigger"[\s\S]{0,1200}?aria-haspopup="dialog"/,
  "the actual More dialog trigger must own advancedNavTrigger",
);
assert.match(
  source,
  /function setTab[\s\S]{0,400}?if \(showAdvancedNav\.value\) closeAdvancedNav\(\)/,
  "selecting an advanced tab must close the dialog through guarded focus restoration",
);
assert.match(
  source,
  /function handleEscape[\s\S]{0,500}?if \(showAdvancedNav\.value\)[\s\S]{0,160}?closeAdvancedNav\(\)/,
  "Escape must close the dialog through guarded focus restoration",
);

console.log("modal accessibility tests passed");
