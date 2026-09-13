import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { parseUpdateSnapshot, updateSettingsArgs, updateBytes } from './src/components/pages/componentUpdates.ts';
const settings = { enabled: false, interval_hours: 24, wifi_only: true, auto_install: true };
const value = () => ({ settings: { ...settings }, phase: 'idle', last_check: 0, next_check: 0, failures: 0 });
test('accepts disabled scheduler and authentic component plans', () => {
  const v = value(); v.phase = 'available'; v.plan = { version: 'v1.4.9', current: 'v1.4.8', pending: false, needed: true, package: 'core', download_bytes: 4096, saved_bytes: 60000000, components: [{ id: 'bin-jq', sha256: 'a'.repeat(64), source: 'download', bytes: 1024 }] };
  assert.equal(parseUpdateSnapshot(JSON.stringify(v)).plan.components[0].id, 'bin-jq');
});
test('invalid or missing status cannot be treated as success', () => {
  for (const v of [{}, { ...value(), phase: 'made-up-success' }, { ...value(), failures: -1 }, { ...value(), settings: { ...settings, enabled: 'true' } }]) assert.throws(() => parseUpdateSnapshot(JSON.stringify(v)));
  assert.throws(() => parseUpdateSnapshot('[error] unavailable'));
});
test('schedule validation prevents command injection', () => {
  assert.match(updateSettingsArgs(settings), /^update configure --enabled=false --interval-hours=24 /);
  for (const interval_hours of [0, 169, 1.5, NaN, '1; reboot']) assert.throws(() => updateSettingsArgs({ ...settings, interval_hours }));
});
test('formats byte estimates without hiding zero-download plans', () => {
  assert.equal(updateBytes(0), '0 B'); assert.equal(updateBytes(1024), '1.0 KiB'); assert.equal(updateBytes(1048576), '1.00 MiB'); assert.equal(updateBytes(-1), '—');
});
test('updates are reachable and background operations use existing task tracking', () => {
  const page = readFileSync(new URL('./src/components/pages/WebuiPage.vue', import.meta.url), 'utf8');
  const card = readFileSync(new URL('./src/components/pages/ComponentUpdatesCard.vue', import.meta.url), 'utf8');
  assert.match(page, /<ComponentUpdatesCard/);
  assert.match(card, /startBackgroundCli\(apply \? 'update apply' : 'update check'/);
  assert.match(card, /onDeactivated\(stop\)/); assert.match(card, /onUnmounted\(stop\)/);
  assert.match(card, /!dirty.value && !saving.value/);
  assert.doesNotMatch(card, /window.location.reload|reboot\(\)/);
});
