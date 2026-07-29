import assert from "node:assert/strict";
import { subscriptionUserAgentPresets } from "./src/components/pages/subscriptionUserAgent.ts";

assert.deepEqual(
  subscriptionUserAgentPresets.map(({ label }) => label),
  ["默认", "sing-box", "Mihomo", "Clash for Windows", "Shadowrocket", "v2rayNG"],
);
assert.equal(subscriptionUserAgentPresets[0].value, "");
assert.equal(
  new Set(subscriptionUserAgentPresets.map(({ value }) => value.toLocaleLowerCase())).size,
  subscriptionUserAgentPresets.length,
);
assert.ok(subscriptionUserAgentPresets.every(({ value }) => new TextEncoder().encode(value).length <= 256));

console.log("subscription User-Agent preset tests passed");
