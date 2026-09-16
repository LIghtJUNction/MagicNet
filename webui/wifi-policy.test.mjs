import assert from "node:assert/strict";
import test from "node:test";
import { parseMachineWifi } from "./src/composables/machineStatus.ts";
import { envelope, wifiSnapshot, wifiData } from "./machine-fixtures.mjs";

test("Wi-Fi machine inspector preserves editable lists and observed policy", () => {
  const parsed = parseMachineWifi(wifiSnapshot());
  assert.equal(parsed.observed, true);
  assert.equal(parsed.enabled, true);
  assert.equal(parsed.policyMode, "blacklist");
  assert.equal(parsed.connected, true);
  assert.equal(parsed.ssid, "Home WiFi");
  assert.equal(parsed.matched, true);
  assert.equal(parsed.currentMode, "direct");
  assert.deepEqual(parsed.ssids, ["Home WiFi", "Office"]);
  assert.deepEqual(parsed.bssids, ["aa:bb:cc:dd:ee:ff"]);
  const withEquals = parseMachineWifi(wifiSnapshot({configuration: {ssids: ["Guest=WiFi", "Normal"], bssids: ["aa:bb:cc:dd:ee:ff"]}}));
  assert.deepEqual(withEquals.ssids, ["Guest=WiFi", "Normal"]);
});

test("machine failures are not interpreted as a confirmed Wi-Fi disconnect", () => {
  for (const text of ["connected=0", envelope("wifi.status",wifiData()), "[error] errno=1\n"+wifiSnapshot(),
    wifiSnapshot({network:{}}),wifiSnapshot({current_mode:"unexpected"}),
    wifiSnapshot({policy:{...wifiData().policy,interval_seconds:1}}),
    wifiSnapshot({configuration:{ssids:[],bssids:["INVALID"]}})]) {
    assert.equal(parseMachineWifi(text), null);
  }
  const disconnected = parseMachineWifi(wifiSnapshot({network:{connected:false,matched:false,desired_mode:"rule",ssid:"",bssid:""}, current_mode:"unavailable"}));
  assert.equal(disconnected.observed, true);
  assert.equal(disconnected.connected, false);
});
