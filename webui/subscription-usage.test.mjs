import assert from "node:assert/strict";
import { test } from "node:test";
import { parseSubs, subscriptionDefaults } from "./src/composables/parsers.ts";
import { buildSubscriptionUsageOverview, parseSubscriptionSourceUsage } from "./src/composables/subscriptionUsage.ts";

const now = 1788600000;
const gib = 1024 ** 3;
const source = {
  id: "a".repeat(64), index: 1, hostname: "provider.example", state: "fresh",
  upload_bytes: gib, download_bytes: 2 * gib, total_bytes: 10 * gib,
  expire_epoch: now + 10 * 86400, updated_epoch: now - 60,
};
const list = "sing-box.1=https://different.example/private?token=do-not-display";
function stateFor(sources, previous = subscriptionDefaults) {
  return parseSubs(list, `source_mode=url\nsource_usage_json=${JSON.stringify(sources)}`, previous);
}
function rowFor(overrides = {}) {
  return buildSubscriptionUsageOverview(stateFor([{ ...source, ...overrides }]), now)[0];
}

test("provider counters produce usage, remaining quota and expiry", () => {
  const row = rowFor();
  assert.equal(row.usedBytes, 3 * gib);
  assert.equal(row.remainingBytes, 7 * gib);
  assert.equal(row.progressPercent, 30);
  assert.equal(row.usedLabel, "3 GiB");
  assert.equal(row.totalLabel, "10 GiB");
  assert.equal(row.daysRemaining, 10);
  assert.equal(row.expiryHint, "剩余 10 天");
  assert.equal(row.expired, false);
  assert.notEqual(row.updatedLabel, "尚未获取");
});

test("a concurrently changed URL list cannot relabel provider usage", () => {
  const row = rowFor();
  assert.equal(row.hostname, source.hostname);
  assert.equal(row.id, source.id);
  assert.equal(JSON.stringify(row).includes("different.example"), false);
  assert.equal(JSON.stringify(row).includes("do-not-display"), false);
});

test("missing or malformed metadata clears previous values and uses private unknown rows", () => {
  const previous = stateFor([source]);
  for (const payload of ["", "source_usage_json={", "source_usage_json=null", "source_usage_json={}"]) {
    const parsed = parseSubs(list, payload, previous);
    assert.deepEqual(parsed.sourceUsage, []);
    const row = buildSubscriptionUsageOverview(parsed, now)[0];
    assert.equal(row.hostname, "different.example");
    assert.equal(row.usedBytes, null);
    assert.equal(row.remainingBytes, null);
    assert.equal(row.progressPercent, null);
    assert.equal(row.expiryLabel, "未提供到期时间");
    assert.equal(JSON.stringify(row).includes("private"), false);
    assert.equal(JSON.stringify(row).includes("do-not-display"), false);
  }
});

test("zero quota and expiry are unspecified while zero usage is valid", () => {
  const row = rowFor({ upload_bytes: 0, download_bytes: 0, total_bytes: 0, expire_epoch: 0, updated_epoch: 0 });
  assert.equal(row.usedBytes, 0);
  assert.equal(row.usedLabel, "0 B");
  assert.equal(row.totalLabel, "未提供额度");
  assert.equal(row.remainingBytes, null);
  assert.equal(row.progressPercent, null);
  assert.equal(row.expired, false);
  assert.equal(row.daysRemaining, null);
  assert.equal(row.updatedLabel, "尚未获取");
  assert.equal(JSON.stringify(row).includes("无限"), false);
});

test("partial, unsafe and invalid counters cannot fabricate a remaining allowance", () => {
  for (const download_bytes of [undefined, null, "2", -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
    const row = rowFor({ download_bytes });
    assert.equal(row.usedBytes, null);
    assert.equal(row.remainingBytes, null);
    assert.equal(row.progressPercent, null);
    assert.equal(row.totalBytes, source.total_bytes);
  }
  assert.equal(rowFor({ upload_bytes: Number.MAX_SAFE_INTEGER, download_bytes: 1 }).usedBytes, null);
  assert.equal(rowFor({ total_bytes: Number.MAX_SAFE_INTEGER + 1 }).totalBytes, null);
  assert.equal(rowFor({ expire_epoch: 8640000000000000 }).daysRemaining, null);
});

test("overage, expiration and cached metadata remain explicit", () => {
  const row = rowFor({ state: "cached", total_bytes: gib, expire_epoch: now - 1 });
  assert.equal(row.stateLabel, "上次用量");
  assert.equal(row.remainingBytes, 0);
  assert.equal(row.progressPercent, 100);
  assert.equal(row.expired, true);
  assert.equal(row.daysRemaining, 0);
  assert.equal(row.expiryHint, "已到期");
  assert.equal(row.tone, "danger");
  assert.equal(rowFor({ expire_epoch: now + 60 }).expiryHint, "24 小时内到期");
  assert.equal(rowFor({ expire_epoch: now + 60 }).tone, "warning");
});

test("invalid identities, duplicated records and hostile hostnames are rejected", () => {
  assert.deepEqual(parseSubscriptionSourceUsage(JSON.stringify([source, source])), []);
  assert.deepEqual(parseSubscriptionSourceUsage(JSON.stringify([{ ...source, id: "https://private.example/?token=secret" }])), []);
  assert.deepEqual(parseSubscriptionSourceUsage(JSON.stringify([{ ...source, index: 0 }])), []);
  for (const hostname of ["https://private.example/token", "user:password@example.org", "example.org/?secret", "example.org\nsecret"]) {
    assert.equal(rowFor({ hostname }).hostname, "");
  }
  const unknown = rowFor({ state: "unrecognized" });
  assert.equal(unknown.state, "unknown");
  assert.equal(unknown.usedBytes, null);
  assert.equal(unknown.totalBytes, null);
});

test("local imports never inherit remote provider usage", () => {
  const parsed = parseSubs(list, `source_mode=local\nsource_usage_json=${JSON.stringify([source])}`, stateFor([source]));
  assert.deepEqual(parsed.sourceUsage, []);
  assert.deepEqual(buildSubscriptionUsageOverview(parsed, now), []);
});
