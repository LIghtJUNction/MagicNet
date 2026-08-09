import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildPrivatePayloadCommand,
  buildPrivateSubscriptionApplyCommand,
  buildPrivateSubscriptionSourceApplyCommand,
  isSensitiveExternalUrl,
  parsePrivatePayloadPath,
  redactSensitiveText,
  stagePrivatePayload,
} from "./src/utils.ts";
import { buildSubscriptionApplyLaunch } from "./src/components/pages/subscriptionPreview.ts";

const moduleDir = "/data/adb/modules/MagicNet";
const basename = "webui-warp-test.conf";

assert.equal(
  buildPrivatePayloadCommand("create", "tmp", basename),
  "webui payload create tmp 'webui-warp-test.conf'",
);
assert.equal(
  buildPrivateSubscriptionSourceApplyCommand("magicnet-local-test.txt"),
  "webui payload apply-subscription-source 'magicnet-local-test.txt'",
);
assert.match(
  buildPrivatePayloadCommand("append", "tmp", basename, "YQ=="),
  /^webui payload append tmp 'webui-warp-test\.conf' 'YQ=='$/,
);
assert.equal(
  buildPrivateSubscriptionApplyCommand("magicnet-webui-test.b64"),
  "webui payload apply-subscription 'magicnet-webui-test.b64'",
);
assert.throws(
  () => buildPrivatePayloadCommand("create", "tmp", "../escape"),
  /basename is invalid/,
);
assert.throws(
  () => buildPrivatePayloadCommand("append", "tmp", basename, "not base64!"),
  /must be base64/,
);

const tmpPayloadDirectory = moduleDir + "/.tmp/webui-payload";
const ownedPath = tmpPayloadDirectory + "/" + basename;
assert.equal(parsePrivatePayloadPath(ownedPath + "\n", moduleDir, "tmp", basename), ownedPath);
assert.equal(parsePrivatePayloadPath(ownedPath + "\nextra\n", moduleDir, "tmp", basename), null);
assert.equal(parsePrivatePayloadPath("/tmp/" + basename + "\n", moduleDir, "tmp", basename), null);
assert.equal(parsePrivatePayloadPath(moduleDir + "/.tmp/" + basename + "\n", moduleDir, "tmp", basename), null);
assert.equal(
  parsePrivatePayloadPath(moduleDir + "/.tmp/webui-subscription/" + basename + "\n", moduleDir, "tmp", basename),
  null,
);

const successCalls = [];
const success = await stagePrivatePayload(
  async (args, label, preview) => {
    successCalls.push({ args, label, preview });
    if (args.startsWith("webui payload create")) return { ok: true, stdout: ownedPath + "\n" };
    return { ok: true, stdout: "" };
  },
  moduleDir,
  "tmp",
  basename,
  "A😀B",
  "测试私有载荷",
  2,
);
assert.deepEqual(success, { namespace: "tmp", basename, path: ownedPath });
assert.equal(successCalls[0].args, "webui payload create tmp 'webui-warp-test.conf'");
assert.ok(successCalls.slice(1).every((call) => call.args.startsWith("webui payload append tmp ")));
assert.ok(successCalls.every((call) => !call.preview.includes("A😀B")));

const failureCalls = [];
const failedBasename = "webui-backup-test.b64";
const failedOwnedPath = tmpPayloadDirectory + "/" + failedBasename;
const failed = await stagePrivatePayload(
  async (args, label, preview) => {
    failureCalls.push({ args, label, preview });
    if (args.startsWith("webui payload create")) return { ok: true, stdout: failedOwnedPath + "\n" };
    if (args.startsWith("webui payload append")) return { ok: false, stdout: "" };
    return { ok: true, stdout: "" };
  },
  moduleDir,
  "tmp",
  failedBasename,
  "backup",
  "测试私有载荷",
);
assert.equal(failed, null);
assert.equal(failureCalls.length, 3, "failed append must stop and request helper-owned cleanup");
assert.match(failureCalls[2].args, /^webui payload remove tmp 'webui-backup-test\.b64'$/);
assert.ok(failureCalls.every((call) => !call.preview.includes("backup")));

const subscriptionLaunch = buildSubscriptionApplyLaunch("magicnet-webui-test.b64");
assert.equal(subscriptionLaunch.args, "webui payload apply-subscription 'magicnet-webui-test.b64'");
assert.equal(subscriptionLaunch.displayArgs, "webui payload apply-subscription [private-payload]");
assert.equal(subscriptionLaunch.lifecycleArgs, "sub apply-file sing-box [redacted-payload]");
assert.doesNotMatch(subscriptionLaunch.preview, /magicnet-webui-test\.b64/);

const signedUrl = "https://downloads.example.test/panel.zip?token=short-lived-secret";
assert.equal(isSensitiveExternalUrl(signedUrl), true);
assert.equal(isSensitiveExternalUrl("https://downloads.example.test/panel.zip"), false);
const normalIssueText = "适配说明：公开仓库 https://example.test/panel.zip";
assert.equal(redactSensitiveText(normalIssueText), normalIssueText);
const sensitiveIssueText = "名称 ghp_exampleToken；下载 " + signedUrl + "；token=local-secret；X-Amz-Signature=aws-signature；普通说明";
const redactedIssueText = redactSensitiveText(sensitiveIssueText);
assert.doesNotMatch(redactedIssueText, /exampleToken|short-lived-secret|local-secret|aws-signature/);
assert.match(redactedIssueText, /\[filtered-token\].*\[filtered-url\].*token=\[filtered\].*X-Amz-Signature=\[filtered\]/);
assert.match(redactedIssueText, /普通说明/);
const bearerHeaders = "说明 aUtHoRiZaTiOn: BeArEr test-only-authorization-token-7; pRoXy-AuThOrIzAtIoN: bEaReR test-only-proxy-token-9; ordinary bEaReR test-only-plain-token-4。";
const redactedBearerHeaders = redactSensitiveText(bearerHeaders);
assert.doesNotMatch(redactedBearerHeaders, /test-only-authorization-token-7|test-only-proxy-token-9|test-only-plain-token-4/);
assert.match(redactedBearerHeaders, /Authorization: \[filtered\]/i);
assert.match(redactedBearerHeaders, /Proxy-Authorization: \[filtered\]/i);
assert.match(redactedBearerHeaders, /ordinary bearer \[filtered\]/i);
assert.match(redactedBearerHeaders, /说明/);

const toolsSource = readFileSync(new URL("./src/components/pages/ToolsPage.vue", import.meta.url), "utf8");
const subscriptionsSource = readFileSync(new URL("./src/components/pages/SubscriptionsPage.vue", import.meta.url), "utf8");
const webuiSource = readFileSync(new URL("./src/components/pages/WebuiPage.vue", import.meta.url), "utf8");
const useMagicNetSource = readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8");
const installPlanSource = readFileSync(new URL("./src/components/pages/webuiInstallPlan.ts", import.meta.url), "utf8");
const linksSource = readFileSync(new URL("./src/composables/useExternalLinks.ts", import.meta.url), "utf8");
for (const source of [toolsSource, subscriptionsSource]) {
  assert.doesNotMatch(source, /secureTempFilePrepareCommand|printf\s+%s|:\s*>|\bcat\s+|\brm\s+-f/);
}
assert.match(webuiSource, /copyText\(safeCommand\)/);
assert.doesNotMatch(webuiSource, /\{\{\s*installArgs/);
assert.match(webuiSource, /startPrivateBackgroundCli/);
assert.match(webuiSource, /const rawStatus = await runCli\("webui status", "读取 WebUI 配置", true\);/);
assert.match(webuiSource, /status\.value = redactSensitiveText\(rawStatus\);/);
assert.match(webuiSource, /const rawVerifyOutput = await runCli\("webui verify", "校验 WebUI 面板", true\);/);
assert.match(webuiSource, /const safeVerifyOutput = redactSensitiveText\(rawVerifyOutput\);/);
assert.match(webuiSource, /verifyOutput\.value = safeVerifyOutput;\s*state\.output = safeVerifyOutput;/);
assert.doesNotMatch(webuiSource, /verifyOutput\.value = await runCli\(/);
assert.match(webuiSource, /function sanitizeWebuiReport\(text: string\): string \{\s*return redactSensitiveText\(text\);\s*\}/);
assert.match(webuiSource, /buildWebuiInstallPlan\(\s*panel\.value\.url,\s*panel\.value\.sha256,\s*redactSensitiveText\(panel\.value\.name\.trim\(\) \|\| "custom"\),\s*\)/);
assert.match(webuiSource, /const displayName = redactSensitiveText\(name\);/);
assert.match(webuiSource, /会下载 \$\{displayName\} 面板压缩包/);
assert.match(webuiSource, /const issueName = redactSensitiveText\(panel\.value\.name\.trim\(\) \|\| "custom"\);/);
assert.match(webuiSource, /const issueMetadata = redactSensitiveText\(panel\.value\.metadata\.trim\(\)\) \|\| "\(empty\)";/);
assert.match(webuiSource, /`Name: \$\{issueName\}`,/);
assert.match(webuiSource, /\n    issueMetadata,\n/);
assert.match(webuiSource, /title: `申请适配 WebUI 面板：\$\{issueName\}`/);
assert.match(subscriptionsSource, /startPrivateBackgroundCli/);
assert.match(installPlanSource, /isSensitiveExternalUrl\(url\)/);
assert.match(installPlanSource, /webui install-local \[filtered-url\] \$\{sha256 \|\| "\[sha256\]"\}/);
assert.match(linksSource, /isSensitiveExternalUrl\(url\)/);
assert.match(linksSource, /redactedCliPreview\("open external \[filtered-url\]"\)/);
assert.match(useMagicNetSource, /async function runPrivateCli[\s\S]*?trackRedactedOperation\(redactedPreview\)[\s\S]*?runShellOutcome/);
assert.match(useMagicNetSource, /stagePrivatePayloadWithCli\(\s*runPrivatePayloadCli,/);
assert.match(useMagicNetSource, /removePrivatePayloadWithCli\(runPrivatePayloadCli,/);

console.log("private payload and signed URL contract tests passed");
