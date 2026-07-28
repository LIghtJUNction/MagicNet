import assert from "node:assert/strict";
import { parseSubs, subscriptionDefaults } from "./src/composables/parsers.ts";

const list = [
  "sing-box.1=https://first.example.invalid/path?token=secret",
  "sing-box.2=https://second.example.invalid/sub",
  "sing-box=https://first.example.invalid/path?token=secret",
  "user-agent=sing-box/1.12.0 (Android)",
  "filter.1=免费",
  "filter.2=HK",
].join("\n");
const status = [
  "configured_count=2",
  "update_running=1",
  "update_lock_owner=active",
  "last_phase=commit",
  "last_result=success",
  "last_attempt_epoch=1784420000",
  "last_success_epoch=1784420001",
  "last_configured_count=2",
  "last_source_count=2",
  "last_imported_count=41",
  "last_skipped_count=3",
  "last_generation_id=1784420000-123",
  "last_reason=none",
  "cache_count=2",
  "cache_provenance_count=2",
  "cache_source=url_sha256_identity",
  "schedule_interval_hours=24",
  "schedule_enabled=1",
  "schedule_running=1",
  "schedule_owner=active",
  "subscription_refresh_event_count=9",
  "subscription_refresh_error_count=1",
].join("\n");

const parsed = parseSubs(list, status, subscriptionDefaults);
assert.equal(parsed.singBoxUrls.length, 2);
assert.equal(parsed.userAgent, "sing-box/1.12.0 (Android)");
assert.deepEqual(parsed.filters, ["免费", "HK"]);
assert.equal(parsed.configuredCount, 2);
assert.equal(parsed.updateRunning, true);
assert.equal(parsed.lastPhase, "commit");
assert.equal(parsed.lastResult, "success");
assert.equal(parsed.lastImportedCount, 41);
assert.equal(parsed.lastGenerationId, "1784420000-123");
assert.equal(parsed.cacheSource, "url_sha256_identity");
assert.equal(parsed.scheduleIntervalHours, "24");
assert.equal(parsed.scheduleEnabled, true);
assert.equal(parsed.scheduleRunning, true);
assert.equal(parsed.scheduleOwner, "active");
assert.equal(parsed.scheduleOwnerValid, true);
assert.equal(parsed.refreshEventCount, 9);
assert.equal(parsed.refreshErrorCount, 1);

const inconsistent = parseSubs("sing-box=", "schedule_interval_hours=12\nschedule_enabled=1\nschedule_running=0\nschedule_owner=stale", parsed);
assert.equal(inconsistent.scheduleOwnerValid, false);
assert.equal(inconsistent.configuredCount, 0);

console.log("subscription state tests passed");
