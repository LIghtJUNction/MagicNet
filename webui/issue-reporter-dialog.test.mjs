import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dialog = readFileSync(
  new URL("./src/components/IssueReporterDialog.vue", import.meta.url),
  "utf8",
);
const reporter = readFileSync(
  new URL("./src/composables/issueReporter.ts", import.meta.url),
  "utf8",
);
const magicnet = readFileSync(
  new URL("./src/composables/useMagicNet.ts", import.meta.url),
  "utf8",
);
const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");

assert.match(dialog, /你遇到了哪类问题？/);
assert.match(dialog, /v-for="option in ISSUE_KIND_OPTIONS"/);
assert.match(dialog, /type="radio"/);
assert.match(dialog, /将收集：\{\{ option\.context \}\}/);
assert.match(dialog, /订阅地址、token、IP、目标域名和本地路径会被过滤/);
assert.match(dialog, /role="dialog"/);
assert.match(dialog, /aria-modal="true"/);
assert.match(dialog, /@keydown\.esc\.prevent\.stop/);

assert.match(reporter, /kind === "app-connectivity"/);
assert.match(reporter, /runCli\("api conns", "读取近期活动连接", true\)/);
assert.match(reporter, /runCli\("service logs sing-box 160", "读取近期连接日志", true\)/);
assert.match(reporter, /kind === "command-error"/);
assert.match(reporter, /commandFailureContext\(operation\)/);
assert.match(reporter, /kind === "subscription-node"/);
assert.match(reporter, /runCli\("sub status", "读取订阅状态", true\)/);
assert.match(reporter, /kind === "dns-routing"/);
for (const command of ["health", "dns status", "network status", "transparent status"]) {
  assert.match(reporter, new RegExp(`runCli\\("${command}"`));
}

assert.match(magicnet, /state\.issueReporter\.open = true/);
assert.match(magicnet, /createMagicNetIssue\(\{ state, runShell, runCli \}, kind\)/);
assert.match(app, /<IssueReporterDialog/);
assert.match(app, /@confirm="submitIssue"/);

console.log("issue reporter dialog tests passed");
