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
assert.match(dialog, /问题概述/);
assert.match(dialog, /复现步骤/);
assert.match(dialog, /期望结果/);
assert.match(dialog, /实际结果/);
assert.match(dialog, /发生频率 \/ 影响范围/);
assert.match(dialog, /:disabled="!canConfirm"/);
assert.match(dialog, /将收集：\{\{ option\.context \}\}/);
assert.match(dialog, /请勿直接粘贴订阅地址、token、IP、目标域名或本地路径/);
assert.match(dialog, /role="dialog"/);
assert.match(dialog, /aria-modal="true"/);
assert.match(dialog, /@keydown\.esc\.prevent\.stop/);
assert.match(dialog, /trapFocusWithin\(event, dialog\.value\)/);

assert.match(reporter, /kind === "app-connectivity"/);
assert.match(reporter, /runCli\("api conns", "读取近期活动连接", true\)/);
assert.match(reporter, /runCli\("service logs sing-box 160", "读取近期连接日志", true\)/);
assert.match(reporter, /kind === "command-error"/);
assert.match(reporter, /commandFailureContext\(operation\)/);
assert.match(reporter, /state\.operationCapture\.command/);
assert.match(reporter, /lastCommand: captured\.command/);
assert.match(reporter, /kind === "subscription-node"/);
assert.match(reporter, /runCli\("sub status", "读取订阅状态", true\)/);
assert.match(reporter, /runCli\("health", "检查订阅相关健康状态", true\)/);
assert.match(reporter, /runCli\("transparent status", "检查 TUN 状态", true\)/);
assert.match(reporter, /kind === "dns-routing"/);
for (const command of ["health", "dns status", "network status", "transparent status"]) {
  assert.match(reporter, new RegExp(`runCli\\("${command}"`));
}

assert.match(magicnet, /state\.issueReporter\.open = true/);
assert.match(magicnet, /createMagicNetIssue\(\{ state, runShell, runCli \}, report\)/);
assert.match(app, /<IssueReporterDialog/);
assert.match(app, /@confirm="submitIssue"/);

console.log("issue reporter dialog tests passed");
