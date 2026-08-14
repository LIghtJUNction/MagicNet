import assert from "node:assert/strict";
import {
  ISSUE_KIND_OPTIONS,
  buildIssueBody,
  buildIssueUrl,
  classifyOperationCommand,
  commandFailureContext,
  sanitizeConnectionLog,
  sanitizeDiagnosticText,
  summarizeConnectionsForIssue,
} from "./src/composables/issueDrafts.ts";
import { redactedCliPreview } from "./src/utils.ts";

const canaries = [
  "https://node.example.invalid/private/path?token=URL-CANARY",
  "TOKEN-CANARY",
  "person@example.invalid",
  "192.0.2.44",
  "/data/adb/modules/MagicNet/private.conf",
  "NODE-CANARY",
];
const parts = {
  kind: "command-error",
  moduleProp: `version=v-test\nupdateJson=${canaries[0]}`,
  device: `model=test\nemail=${canaries[2]}\nip=${canaries[3]}\npath=${canaries[4]}`,
  support: `token=${canaries[1]}\nnode=${canaries[5]}\n${"safe event\n".repeat(800)}`,
  focusedContext: "captured failure errno=1",
  report: {
    summary: `订阅更新失败：${canaries[0]}`,
    reproduction: "打开订阅页面并点击更新；每次都会失败。",
    expected: "节点应被导入并启动核心。",
    actual: `实际输出包含 token=${canaries[1]}`,
    frequency: "每次更新，影响全部节点。",
  },
  operation: {
    phase: "error",
    lastCommand: `magicnet sub apply-file sing-box ${canaries[0]}`,
    lastOutput: `$ magicnet sub apply-file sing-box ${canaries[0]}\n[error] token=${canaries[1]}`,
    backgroundLabel: "refresh",
    backgroundArgs: `node=${canaries[5]}`,
    backgroundStatus: "timeout",
  },
};

const body = buildIssueBody(parts);
assert.equal(body, buildIssueBody(parts), "canonical body must be deterministic");
assert.ok(body.length <= 5200, "canonical body must fit the URL budget");
assert.match(body, /## Module/);
assert.equal((body.match(/## Module/g) || []).length, 1, "canonical body must not duplicate module metadata");
assert.match(body, /## Device/);
assert.match(body, /问题类型：命令或操作报错/);
assert.match(body, /## Focused Context/);
assert.match(body, /## Support Summary/);
assert.match(body, /## UI Operation/);
assert.match(body, /问题概述：/);
assert.match(body, /复现步骤：/);
assert.match(body, /期望结果：/);
assert.match(body, /实际结果：/);
assert.match(body, /发生频率 \/ 影响范围：/);
assert.doesNotMatch(body, /请在这里描述你遇到的问题/);
assert.doesNotMatch(body, /Service Status|## Health|## MCP|Network Probe/);
for (const canary of canaries) assert.equal(body.includes(canary), false, `leaked ${canary}`);

const url = buildIssueUrl("https://github.com/example/repo", "canary report", body);
const parsed = new URL(url);
assert.equal(parsed.searchParams.get("body"), body, "GitHub URL must carry the canonical clipboard body");
for (const canary of canaries) assert.equal(url.includes(encodeURIComponent(canary)), false, `URL leaked ${canary}`);

const sanitized = sanitizeDiagnosticText(canaries.join("\n"));
for (const canary of canaries) assert.equal(sanitized.includes(canary), false, `sanitizer leaked ${canary}`);

const reviewerBarePassword = "ReviewerBarePassword!2026";
const sensitiveCommands = [
  `su -M -c '/data/adb/modules/MagicNet/cli backup create ${reviewerBarePassword}'`,
  `cli backup restore-file ${reviewerBarePassword} /sdcard/Download/device-serial-123.backup`,
  `cli setup https://private.example.invalid/sub?token=token-canary`,
  `cli sub set sing-box https://private.example.invalid/sub?secret=secret-canary`,
  `cli mcp start --token device-id-canary`,
];
for (const command of sensitiveCommands) {
  const classified = classifyOperationCommand(command);
  assert.match(classified, /^command=(?:backup\.(?:create|restore-file)|setup|sub\.set|mcp\.start) arguments=filtered$/);
  for (const secret of [reviewerBarePassword, "device-serial-123", "private.example.invalid", "token-canary", "secret-canary", "device-id-canary"]) {
    assert.equal(classified.includes(secret), false, `classified command leaked ${secret}`);
  }
}
for (const [displayArgs, expected] of [
  ["app add [package] bypass", "command=app.add arguments=filtered"],
  ["block add-domain [domain]", "command=block.add-domain arguments=filtered"],
  ["config-editor get sing-box [private-output]", "command=config-editor.get arguments=filtered"],
  ["backup export [private-output]", "command=backup.export arguments=filtered"],
  ["support bundle [private-output]", "command=support.bundle arguments=filtered"],
  ["webui verify [private-output]", "command=webui.verify arguments=filtered"],
  ["route list [private-output]", "command=route.list arguments=filtered"],
  ["api preflight [private-output]", "command=api.preflight arguments=filtered"],
  ["refresh tools [private-output]", "command=refresh.tools arguments=filtered"],
  ["open external [filtered-url]", "command=open.external arguments=filtered"],
]) {
  assert.equal(classifyOperationCommand(redactedCliPreview(displayArgs)), expected);
}
const passwordBody = buildIssueBody({
  ...parts,
  focusedContext: commandFailureContext({
    ...parts.operation,
    lastCommand: sensitiveCommands[0],
    lastOutput: `$ ${sensitiveCommands[0]}\n[error] backup failed password=${reviewerBarePassword}`,
    backgroundArgs: sensitiveCommands[1],
  }),
  operation: { ...parts.operation, lastCommand: sensitiveCommands[0], backgroundArgs: sensitiveCommands[1] },
});
const passwordUrl = buildIssueUrl("https://github.com/example/repo", "password regression", passwordBody);
assert.match(passwordBody, /command=backup\.create arguments=filtered/);
assert.match(passwordBody, /command=backup\.restore-file arguments=filtered/);
for (const secret of [reviewerBarePassword, "device-serial-123"]) {
  assert.equal(passwordBody.includes(secret), false, `canonical body leaked ${secret}`);
  assert.equal(decodeURIComponent(passwordUrl).includes(secret), false, `GitHub URL leaked ${secret}`);
}

const stableNetworkCanaries = [
  "enx001122aabbcc",
  "br-deadbeefcafe1234",
  "veth0123456789abcdef",
];
const deviceCanaries = {
  device_id: "DEVICE-ID-CANARY",
  serial: "SERIAL-CANARY",
  imei: "IMEI-CANARY",
  android_id: "ANDROID-ID-CANARY",
};
const networkBody = buildIssueBody({
  ...parts,
  device: Object.entries(deviceCanaries).map(([key, value]) => `${key}=${value}`).join("\n"),
  support: [
    `2: ${stableNetworkCanaries[0]}: <BROADCAST,UP> state UP type ether`,
    `3: ${stableNetworkCanaries[1]}: state DOWN type bridge`,
    `4: ${stableNetworkCanaries[2]}@if5: state UP type ether`,
    "last_skipped_count=3 cache_provenance_count=2 cache_source=url_sha256_identity",
  ].join("\n"),
});
const networkUrl = buildIssueUrl("https://github.com/example/repo", "network identifier regression", networkBody);
for (const sensitive of [...stableNetworkCanaries, ...Object.values(deviceCanaries)]) {
  assert.equal(networkBody.includes(sensitive), false, `canonical body leaked ${sensitive}`);
  assert.equal(decodeURIComponent(networkUrl).includes(sensitive), false, `GitHub URL leaked ${sensitive}`);
}
assert.match(networkBody, /state UP type ether/);
assert.match(networkBody, /state DOWN type bridge/);
assert.match(networkBody, /last_skipped_count=3 cache_provenance_count=2 cache_source=url_sha256_identity/);

const deviceKeyInput = Object.entries(deviceCanaries).map(([key, value]) => `${key}: ${value}`).join("\n");
const sanitizedDeviceKeys = sanitizeDiagnosticText(deviceKeyInput);
for (const sensitive of Object.values(deviceCanaries)) {
  assert.equal(sanitizedDeviceKeys.includes(sensitive), false, `device-key sanitizer leaked ${sensitive}`);
}

assert.deepEqual(
  ISSUE_KIND_OPTIONS.map(({ value }) => value),
  ["app-connectivity", "command-error", "subscription-node", "dns-routing", "other"],
);
assert.ok(ISSUE_KIND_OPTIONS.every(({ context }) => context.startsWith("附带")));

const connections = JSON.stringify({
  connections: [
    {
      id: "private-connection-id",
      metadata: {
        host: "private.example.invalid",
        destinationIP: "192.0.2.44",
        sourceIP: "10.0.0.9",
        processPackageName: "com.example.browser",
        network: "tcp",
      },
      inbound: "tun-in",
      rule: "RuleSet",
      rulePayload: "private.example.invalid",
      chains: ["ai-proxy", "US-Private-Node"],
      upload: 1234,
      download: 5678,
    },
  ],
});
const connectionSummary = summarizeConnectionsForIssue(connections);
assert.match(connectionSummary, /active_connection_count=1/);
assert.match(connectionSummary, /process=com\.example\.browser/);
assert.match(connectionSummary, /inbound=tun-in/);
assert.match(connectionSummary, /rule=RuleSet/);
assert.match(connectionSummary, /chain=ai-proxy -> \[selected-node\]/);
for (const sensitive of ["private-connection-id", "private.example.invalid", "192.0.2.44", "10.0.0.9", "US-Private-Node", "1234", "5678"]) {
  assert.equal(connectionSummary.includes(sensitive), false, `connection summary leaked ${sensitive}`);
}

const sanitizedLog = sanitizeConnectionLog(
  "INFO inbound/tun connection from 10.0.0.9:41234 to private.example.invalid:443 outbound=ai-proxy",
);
assert.match(sanitizedLog, /from \[filtered-endpoint\] to \[filtered-endpoint\]/);
assert.match(sanitizedLog, /outbound=ai-proxy/);
assert.doesNotMatch(sanitizedLog, /private\.example\.invalid|10\.0\.0\.9/);
const selectedNodeLog = sanitizeConnectionLog("INFO selector=US-Private-Node selected node is JP-Secret");
assert.match(selectedNodeLog, /selector=\[selected-node\]/);
assert.match(selectedNodeLog, /selected node is \[selected-node\]/);
assert.doesNotMatch(selectedNodeLog, /US-Private-Node|JP-Secret/);

const commandContext = commandFailureContext(parts.operation);
assert.match(commandContext, /captured_command=command=sub\.apply-file arguments=filtered/);
assert.match(commandContext, /\[captured output\]/);
assert.doesNotMatch(commandContext, /^\$\s/m);
for (const sensitive of canaries) assert.equal(commandContext.includes(sensitive), false, `command context leaked ${sensitive}`);

console.log("issue reporter tests passed");
