import assert from "node:assert/strict";
import { parseWifiPolicy } from "./src/composables/parsers.ts";

const parsed = parseWifiPolicy(`
enabled=1
policy_mode=blacklist
interval_seconds=5
supervisor=123
connected=1
ssid=Home WiFi
bssid=aa:bb:cc:dd:ee:ff
matched=1
desired_mode=direct
current_mode=direct
ssid entries:
Home WiFi
Office
bssid entries:
aa:bb:cc:dd:ee:ff
`);

assert.equal(parsed.enabled, true);
assert.equal(parsed.policyMode, "blacklist");
assert.equal(parsed.connected, true);
assert.equal(parsed.ssid, "Home WiFi");
assert.equal(parsed.matched, true);
assert.equal(parsed.currentMode, "direct");
assert.deepEqual(parsed.ssids, ["Home WiFi", "Office"]);
assert.deepEqual(parsed.bssids, ["aa:bb:cc:dd:ee:ff"]);

const fallback = parseWifiPolicy("current_mode=unexpected\ninterval_seconds=1\n");
assert.equal(fallback.currentMode, "unavailable");
assert.equal(fallback.intervalSeconds, 5);

console.log("Wi-Fi policy parser tests passed");
