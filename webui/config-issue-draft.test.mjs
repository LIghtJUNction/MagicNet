import assert from "node:assert/strict";
import { buildUnifiedConfigDiff, MAX_CONFIG_ISSUE_DIFF_BYTES, sanitizeConfigForIssue } from "./src/components/pages/configEditorInsights.ts";

const canaries = ["HK-SECRET", "node.example.invalid", "44321", "PUBLIC_KEY_CANARY", "SHORT_ID_CANARY", "UUID_CANARY"];
const before = JSON.stringify({
  inbounds: [{ type: "tun", tag: "tun-secret", stack: "gvisor", auto_route: true }],
  outbounds: [{ type: "vless", tag: canaries[0], server: canaries[1], server_port: 44321, uuid: canaries[5], tls: { reality: { public_key: canaries[3], short_id: canaries[4] } } }],
  route: { rules: [{ outbound: canaries[0], domain: "private.example" }] },
  dns: { servers: [{ server: "dns.private.example" }] }
});
const after = JSON.stringify({ ...JSON.parse(before), inbounds: [{ type: "tun", tag: "tun-secret", stack: "gvisor", mtu: 1400, auto_route: true }] });

const sanitized = sanitizeConfigForIssue(after);
for (const canary of canaries) assert.equal(sanitized.includes(canary), false, `leaked ${canary}`);
assert.match(sanitized, /"mtu": 1400/);
assert.match(sanitized, /"id": "inbound-1"/);

const diff = buildUnifiedConfigDiff(before, after);
assert.match(diff, /^--- config\.before\.json\n\+\+\+ config\.after\.json\n@@ /);
assert.match(diff, /^\+\s+"mtu": 1400/m);
for (const canary of canaries) assert.equal(diff.includes(canary), false, `diff leaked ${canary}`);
assert.ok(Buffer.byteLength(diff) < 2048, "diff is not compact");
assert.ok(Buffer.byteLength(diff) < MAX_CONFIG_ISSUE_DIFF_BYTES);
assert.equal(buildUnifiedConfigDiff(before, before), "");

for (const [section, mutate] of [
  ["outbounds", (config) => { config.outbounds[0].server = "changed-node.example.invalid"; }],
  ["dns", (config) => { config.dns.servers[0].server = "changed-dns.example.invalid"; }],
  ["route", (config) => { config.route.rules[0].domain = "changed-private.example"; }]
]) {
  const changed = JSON.parse(before);
  mutate(changed);
  const sameCountDiff = buildUnifiedConfigDiff(before, JSON.stringify(changed));
  assert.notEqual(sameCountDiff, "", `${section} same-count edit was missed`);
  assert.match(sameCountDiff, new RegExp(`[-+]    "${section}": "(?:before|after)"`));
  assert.equal(sameCountDiff.includes("changed-"), false, `${section} raw value leaked`);
  for (const canary of canaries) assert.equal(sameCountDiff.includes(canary), false, `${section} diff leaked ${canary}`);
}

assert.throws(() => sanitizeConfigForIssue("not-json"));
console.log("config issue draft tests passed");
