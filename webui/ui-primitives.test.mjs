import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const src = join(root, "src");
const read = (relativePath) => readFileSync(join(root, relativePath), "utf8");

const primitives = [
  "components/ui/Eyebrow.vue",
  "components/ui/CardHeading.vue",
  "components/ui/InsightChip.vue",
  "components/ui/RemovableTag.vue",
  "components/ui/SearchField.vue",
  "components/ui/StatusDot.vue",
  "components/ui/StatTile.vue",
  "components/ui/ConfirmPanel.vue",
  "components/ui/Field.vue",
];

for (const relativePath of primitives) {
  assert.ok(existsSync(join(src, relativePath)), `missing shared primitive: ${relativePath}`);
}

const styles = read("src/styles.css");
for (const token of [
  ".mn-eyebrow",
  ".mn-insight-chip",
  ".mn-tag",
  ".mn-empty",
  ".mn-stat-tile",
  ".mn-confirm-code",
  ".mn-overlay",
  ".mn-choice",
  ".mn-segmented",
]) {
  assert.match(styles, new RegExp(token.replace(".", "\\.")), `styles.css must define ${token}`);
}

const insightChip = read("src/components/ui/InsightChip.vue");
assert.match(insightChip, /statusChipClasses/, "InsightChip must use the shared statusChipClasses helper");

const confirmCard = read("src/components/pages/ToolActionConfirmCard.vue");
assert.match(confirmCard, /ConfirmPanel/, "tool confirms must reuse ConfirmPanel instead of a page-local card");

const consumers = {
  "src/App.vue": ["Eyebrow", "StatusDot"],
  "src/components/pages/AppsPage.vue": ["ConfirmPanel", "InsightChip", "RemovableTag", "SearchField"],
  "src/components/pages/BlocklistPage.vue": ["ConfirmPanel", "InsightChip", "RemovableTag", "SearchField"],
  "src/components/pages/ControlPage.vue": ["CardHeading", "ConfirmPanel", "RemovableTag", "StatTile"],
  "src/components/pages/ConfigPage.vue": ["InsightChip"],
  "src/components/IssueReporterDialog.vue": ["Field", "Textarea"],
};

for (const [file, names] of Object.entries(consumers)) {
  const body = read(file);
  for (const name of names) {
    assert.match(body, new RegExp(name), `${file} must reuse ${name}`);
  }
}

assert.doesNotMatch(
  read("src/components/pages/AppsPage.vue"),
  /mn-chip-ok': item\.tone === 'success'/,
  "AppsPage must not keep a page-local chip tone map",
);
assert.doesNotMatch(
  read("src/components/pages/BlocklistPage.vue"),
  /mn-chip-ok': item\.tone === 'success'/,
  "BlocklistPage must not keep a page-local chip tone map",
);

console.log("ui primitives contract tests passed");
