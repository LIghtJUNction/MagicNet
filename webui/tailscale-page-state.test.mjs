import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import ts from './node_modules/typescript/lib/typescript.js';
import { computed, ref } from 'vue';

const code = readFileSync(new URL('./src/components/pages/TailscalePage.vue', import.meta.url), 'utf8')
  .match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1]
  .replace(/^import[\s\S]*?;\s*$/gm, '');
const compiled = ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const configured = { configured: true, hostname: 'phone', controlUrl: 'https://controlplane.tailscale.com', tag: 'tailscale' };
function deferred() { let resolve; return { promise: new Promise(r => { resolve = r; }), resolve: v => resolve(v) }; }
const tick = () => new Promise(r => setImmediate(r));
function page(options = {}) {
  const calls = [], lifecycle = {}, timers = new Map(), listeners = new Map(); let next = 0;
  const document = { hidden: false, addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: name => listeners.delete(name) };
  const state = { hasKsu: true, busy: false, config: { dirty: false } };
  const hooks = Object.fromEntries(['onMounted','onActivated','onDeactivated','onUnmounted'].map(name => [name, fn => { lifecycle[name] = fn; }]));
  const dependencies = {
    computed, ref, watch: () => {}, ...hooks, document,
    setTimeout: fn => { timers.set(++next, fn); return next; }, clearTimeout: id => timers.delete(id),
    t: key => key, generateQrSvgPath: () => null,
    useMagicNet: () => ({ state, shellQuote: s => s, stagePrivatePayload: () => {}, removePrivatePayload: () => {},
      runPrivateCli: async command => { calls.push(command); return options.read ? options.read(command) : { ok: true, stdout: JSON.stringify({ online: true, state: 'Running', authUrl: '' }) }; },
      openExternal: async url => { calls.push('open:' + url); }, refreshStatus: async () => { calls.push('refresh'); },
    }),
    inspectTailscale: () => configured,
    parseTailscaleLogin: text => JSON.parse(text),
    saveTailscale: async () => { calls.push('save'); return options.save ? options.save() : { saved: true, stage: 'done', snapshot: configured }; },
    removeTailscale: async () => { calls.push('remove'); return { saved: true, stage: 'done', snapshot: { ...configured, configured: false } }; },
    TailscaleSetupError: class extends Error {},
  };
  const make = new Function(...Object.keys(dependencies), compiled + '\nreturn {read,submit,disconnectTailscale,retryRestart,snapshot,hostname,edited,authKey,isOnline,loading,saving,confirmRemove,restartPending,startLoginPolling};');
  return { ...make(...Object.values(dependencies)), calls, lifecycle, document, listeners, timers, state };
}

test('existing browser login performs a read, not a config write or core restart', async () => {
  const p = page(); p.snapshot.value = configured;
  await p.submit('browser'); await tick();
  assert.deepEqual(p.calls, ['api tailscale-status tailscale']);
  assert.equal(p.isOnline.value, true);
});
test('deactivated configuration response cannot replace the current page snapshot', async () => {
  const pending = deferred(), p = page({ read: () => pending.promise });
  p.authKey.value = 'private'; const work = p.read(); p.lifecycle.onDeactivated();
  pending.resolve({ ok: true, stdout: '{}' }); await work;
  assert.equal(p.snapshot.value, null); assert.equal(p.loading.value, false); assert.equal(p.authKey.value, '');
  assert.equal(p.calls.length, 1); assert.equal(p.timers.size, 0);
});
test('a background login response cannot publish online state or open a browser', async () => {
  const pending = deferred(), p = page({ read: () => pending.promise });
  p.snapshot.value = configured; p.lifecycle.onMounted(); // read starts separately; settle only after suspension
  p.startLoginPolling(true); p.lifecycle.onDeactivated();
  pending.resolve({ ok: true, stdout: JSON.stringify({ online: true, state: 'Running', authUrl: 'https://login.tailscale.com/a/private' }) });
  await tick();
  assert.equal(p.isOnline.value, null); assert.equal(p.timers.size, 0); assert.ok(!p.calls.some(c => c.startsWith('open:')));
});
test('hidden pages do not start root polling and unmount removes the visibility listener', async () => {
  const p = page(); p.lifecycle.onMounted(); await tick();
  p.document.hidden = true; p.listeners.get('visibilitychange')();
  const count = p.calls.length; p.startLoginPolling(true); await tick();
  assert.equal(p.calls.length, count); assert.equal(p.isOnline.value, null);
  assert.equal(p.timers.size, 0); p.lifecycle.onUnmounted(); assert.equal(p.listeners.size, 0);
});
test('a save completing after navigation does not restart polling or open authorization', async () => {
  const pending = deferred(), p = page({ save: () => pending.promise });
  p.snapshot.value = { ...configured, configured: false }; const work = p.submit('browser');
  p.lifecycle.onDeactivated(); pending.resolve({ saved: true, stage: 'done', snapshot: configured }); await work;
  assert.deepEqual(p.calls, ['save']); assert.equal(p.snapshot.value, null); assert.equal(p.saving.value, false);
});
test('removal requires explicit confirmation and retries are limited to failed restarts', async () => {
  const p = page(); p.snapshot.value = configured;
  await p.disconnectTailscale(); await p.retryRestart(); assert.deepEqual(p.calls, []);
  p.confirmRemove.value = true; await p.disconnectTailscale();
  assert.deepEqual(p.calls, ['remove','refresh']); assert.equal(p.snapshot.value.configured, false); assert.equal(p.confirmRemove.value, false);
});
test('a failed status read produces unknown, never stale online success', async () => {
  const p = page({ read: () => ({ ok: false, stdout: '' }) }); p.snapshot.value = configured; p.isOnline.value = true;
  p.startLoginPolling(false); await tick(); assert.equal(p.isOnline.value, null);
});
