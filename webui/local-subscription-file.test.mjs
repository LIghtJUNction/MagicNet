import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  MAX_LOCAL_SUBSCRIPTION_BYTES,
  buildLocalSubscriptionApplyLaunch,
  parseLocalSubscriptionFile,
} from "./src/components/pages/localSubscriptionFile.ts";

const encoder = new TextEncoder();
const imported = parseLocalSubscriptionFile(
  "private-subscriptions.yaml",
  encoder.encode("proxies:\n  - name: redacted\n    type: vless\n    server: example.invalid\n"),
);
assert.equal(imported.fileName, "private-subscriptions.yaml");
assert.equal(imported.format, "clash");
assert.equal(imported.sizeBytes > 0, true);
assert.equal(
  imported.text,
  "proxies:\n  - name: redacted\n    type: vless\n    server: example.invalid\n",
);

const encoded = parseLocalSubscriptionFile("nodes.txt", encoder.encode("dmxlc3M6Ly9leGFtcGxl\n"));
assert.equal(encoded.format, "encoded");

assert.throws(() => parseLocalSubscriptionFile("empty.txt", new Uint8Array()), /文件为空/);
assert.throws(
  () => parseLocalSubscriptionFile("binary.txt", new Uint8Array([0xff, 0xfe])),
  /UTF-8/,
);
assert.throws(
  () => parseLocalSubscriptionFile("large.txt", new Uint8Array(MAX_LOCAL_SUBSCRIPTION_BYTES + 1)),
  /8 MiB/,
);

const launch = buildLocalSubscriptionApplyLaunch("magicnet-local-test.txt");
assert.equal(launch.args, "webui payload apply-subscription-source 'magicnet-local-test.txt'");
assert.doesNotMatch(launch.preview, /magicnet-local-test/);

const page = readFileSync(new URL("./src/components/pages/SubscriptionsPage.vue", import.meta.url), "utf8");
const importHandler = page.match(/async function importLocalSubscriptions[\s\S]*?\n}\n\nfunction normalizeSubscriptions/)?.[0] ?? "";
assert.match(importHandler, /startPrivateBackgroundCli/);
assert.match(importHandler, /stagePrivatePayload/);
assert.doesNotMatch(importHandler, /singBoxText\.value = imported\.text/);
assert.match(page, /type="file"[\s\S]*@change="importLocalSubscriptions"/);

console.log("local subscription file tests passed");
