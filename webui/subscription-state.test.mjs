import assert from "node:assert/strict";
import test from "node:test";
import { parseMachineSubscription } from "./src/composables/machineStatus.ts";
import { envelope, subscriptionData, subscriptionSnapshot } from "./machine-fixtures.mjs";

test("machine subscription inspector preserves configuration, lifecycle, ownership and counters", () => {
  const data = subscriptionData({
    source: {mode: "remote_url", configured_count: 2},
    update: {owner: "active", running: true, transaction_pending: false},
    configuration: {sing_box_urls: ["https://first.example.invalid/path?token=secret", "https://second.example.invalid/sub"],
      user_agent: "sing-box/1.12.0 (Android)", filters: ["免费", "HK"]},
    cache: {entries: 4, source_entries: 2, provenance_entries: 2, identity: "url_sha256_identity"},
    schedule: {interval_hours: "24", enabled: true, owner: "active", running: true, owner_valid: true},
    refresh: {event_count: 9, error_count: 1},
  });
  data.last = {...data.last, imported_count: 41, generation_id: "1784420000-123"};
  const parsed = parseMachineSubscription(envelope("sub.inspect", data));
  assert.equal(parsed.singBoxUrls.length, 2);
  assert.equal(parsed.userAgent, "sing-box/1.12.0 (Android)");
  assert.deepEqual(parsed.filters, ["免费", "HK"]);
  assert.equal(parsed.configuredCount, 2);
  assert.equal(parsed.sourceMode, "url");
  assert.equal(parsed.updateRunning, true);
  assert.equal(parsed.lastPhase, "commit");
  assert.equal(parsed.lastResult, "success");
  assert.equal(parsed.lastImportedCount, 41);
  assert.equal(parsed.lastGenerationId, "1784420000-123");
  assert.equal(parsed.cacheCount, 2);
  assert.equal(parsed.cacheProvenanceCount, 2);
  assert.equal(parsed.cacheSource, "url_sha256_identity");
  assert.equal(parsed.scheduleIntervalHours, "24");
  assert.equal(parsed.scheduleEnabled, true);
  assert.equal(parsed.scheduleRunning, true);
  assert.equal(parsed.scheduleOwner, "active");
  assert.equal(parsed.scheduleOwnerValid, true);
  assert.equal(parsed.refreshEventCount, 9);
  assert.equal(parsed.refreshErrorCount, 1);
});

test("stale owners and interrupted transactions stay distinct from running", () => {
  const data = subscriptionData({update: {owner: "stale", running: false, transaction_pending: true},
    schedule: {interval_hours: "12", enabled: true, owner: "stale", running: false, owner_valid: false}});
  data.last.result = "interrupted";
  const parsed = parseMachineSubscription(envelope("sub.inspect", data));
  assert.equal(parsed.updateRunning, false);
  assert.equal(parsed.updateLockOwner, "stale");
  assert.equal(parsed.lastResult, "interrupted");
  assert.equal(parsed.scheduleOwnerValid, false);
  for (const owner of ["unknown", "pending"]) {
    const value = parseMachineSubscription(subscriptionSnapshot({update: {owner, running: null, transaction_pending: false}}));
    assert.equal(value.updateRunning, false);
    assert.equal(value.updateLockOwner, owner);
  }
});

test("local source precedence clears old remote usage without erasing editor settings", () => {
  const parsed = parseMachineSubscription(subscriptionSnapshot({source: {mode: "local_file", configured_count: 1}, source_usage: [{stale: true}]}));
  assert.equal(parsed.sourceMode, "local");
  assert.equal(parsed.configuredCount, 1);
  assert.deepEqual(parsed.sourceUsage, []);
  assert.equal(parsed.singBoxUrls.length, 1);
});

test("malformed private snapshots and contradictory status fields fail closed", () => {
  for (const data of [subscriptionData({last:{}}), subscriptionData({source_usage:{}}),
    subscriptionData({update:{owner:"active",running:false,transaction_pending:false}}),
    subscriptionData({source:{mode:"remote_url",configured_count:5}}),
    subscriptionData({schedule:{interval_hours:"24",enabled:false,owner:"none",running:false,owner_valid:true}}),
    subscriptionData({configuration:{sing_box_urls:["secret\nurl"],user_agent:"",filters:[]}}),
    subscriptionData({refresh:{event_count:-1,error_count:0}})]) {
    assert.equal(parseMachineSubscription(envelope("sub.inspect",data)), null);
  }
  for (const text of ["last_result=success", subscriptionSnapshot().replace('"schema":1','"schema":2'),
    "[error] errno=1\n"+subscriptionSnapshot(), envelope("sub.status",subscriptionData())]) {
    assert.equal(parseMachineSubscription(text), null);
  }
});
