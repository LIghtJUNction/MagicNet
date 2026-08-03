import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const page = readFileSync(
  new URL("./src/components/pages/AppsPage.vue", import.meta.url),
  "utf8",
);

assert.match(page, /type="checkbox"[\s\S]*togglePackageSelection/);
assert.match(page, /function selectVisiblePackages/);
assert.match(page, /function requestBatchAdd/);
assert.match(page, /app add-many \$\{target\} \$\{quoted\}/);
assert.match(page, /pendingAppAction\.value = \{[\s\S]*批量归类/);
assert.doesNotMatch(
  page.match(/async function applyBatchAdd[\s\S]*?\n}\n\nfunction requestBatchAdd/)?.[0] ?? "",
  /\bfor\s*\([^)]*\)[\s\S]*await runCli/,
  "batch classification must use one CLI transaction instead of restarting once per app",
);

console.log("app batch policy tests passed");
