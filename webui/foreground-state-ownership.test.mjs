import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
  new URL("./src/composables/useMagicNet.ts", import.meta.url),
  "utf8",
);

assert.match(source, /function startForegroundCommand\(/);
assert.match(
  source,
  /token:\s*after\s*!==\s*before\s*\?\s*after\s*:\s*\(\s*inheritedToken\s*\?\?\s*before\s*\)/,
);

function functionSource(name) {
  const start = source.indexOf(`async function ${name}`);
  assert.notEqual(start, -1, `missing ${name}`);
  const next = source.indexOf("\nasync function ", start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

for (const name of [
  "refreshStatus",
  "refreshCliState",
  "refreshPackages",
  "refreshSubs",
  "refreshDns",
  "refreshWifiPolicy",
  "refreshPing",
  "refreshTopology",
  "refreshSysroute",
  "loadConfig",
  "syncConfigTemplate",
]) {
  const segment = functionSource(name);
  assert.match(
    segment,
    /startForegroundCommand\(/,
    `${name} must capture command ownership`,
  );
  assert.match(
    segment,
    /foregroundUiGate\.owns|canUpdateRefreshUi/,
    `${name} must guard stale completion`,
  );
}

// Shared readers must delegate both the read and its foreground ownership.
// refresh-cli-state.test.mjs also exercises stale/failed completion behavior.
for (const name of ["refreshHealth", "refreshApps", "refreshBlock", "refreshMcp", "refreshWarp"]) {
  const segment = functionSource(name);
  assert.match(segment, /return refreshCliState\(/, `${name} must use the guarded reader`);
  assert.match(segment, /quiet,\s*foregroundToken,\s*\);/, `${name} must forward ownership`);
}

const saveConfig = functionSource("saveConfig");
assert.match(saveConfig, /stagePrivatePayload\(/);
assert.match(saveConfig, /const stageToken = foregroundUiGate\.current\(\)/);
assert.match(saveConfig, /if \(!foregroundUiGate\.owns\(uiToken\)\) return/);

console.log("foreground state ownership tests passed");
