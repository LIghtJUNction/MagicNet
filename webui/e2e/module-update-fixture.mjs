/**
 * Development-only native bridge fixture. All values are invented and public.
 * This function is self-contained so Playwright can serialize it as an init
 * script before the real application's native bridge discovery runs.
 */
export function installModuleUpdateFixture(options = {}) {
  const query = new URLSearchParams(window.location.search);
  const phase = options.phase ?? query.get('phase') ?? 'idle';
  const fault = options.fault ?? query.get('fault') ?? '';
  const unsupported = options.unsupported ?? query.get('unsupported') === '1';
  const requestedError = options.error ?? query.get('error') ?? 'module-update.network';
  const publicError = /^module-update\.[a-z][a-z0-9_.-]{0,63}$/.test(requestedError) ? requestedError : 'module-update.network';
  const fixtureKey = `magicnet.e2e.module-update.${phase}.${fault}.${unsupported}.${publicError}`;
  const activePhases = ['checking', 'downloading', 'verifying', 'installing'];
  const initialSnapshot = {
    installed: { version: 'v1.5.20', version_code: 10520 },
    latest: { version: phase === 'idle' ? null : 'v1.5.21', version_code: phase === 'idle' ? null : 10521 },
    update_available: phase === 'idle' ? null : phase === 'up_to_date' ? false : true,
    phase, manager: 'kernelsu', supported: true,
    busy: activePhases.includes(phase), reboot_required: phase === 'reboot_required',
    recovery_required: false, error_code: phase === 'failed' ? publicError : null,
    request_id: activePhases.includes(phase) || phase === 'reboot_required' ? 'fixture_request_01' : null,
  };
  if (phase === 'up_to_date') initialSnapshot.latest = { ...initialSnapshot.installed };
  let saved;
  try { saved = options.reset ? null : JSON.parse(sessionStorage.getItem(fixtureKey) || 'null'); } catch { saved = null; }
  const fixture = {
    snapshot: saved?.snapshot ?? initialSnapshot,
    commands: [], writes: saved?.writes ?? [], fault, unsupported,
    installDelayMs: options.installDelayMs ?? 120,
    reads: 0,
    // Synthetic negative-control detail; never a credential or a real device fact.
    rawDetail: 'fixture-internal-install-detail',
  };
  const persist = () => sessionStorage.setItem(fixtureKey, JSON.stringify({ snapshot: fixture.snapshot, writes: fixture.writes }));
  const envelope = (command, data) => JSON.stringify({ schema: 1, ok: true, command, data });
  fixture.set = (patch) => { Object.assign(fixture.snapshot, patch); persist(); };
  fixture.persist = persist;
  window.__moduleUpdateFixture = fixture;
  localStorage.setItem('magicnet.webui.onboarding.v1', 'dismissed');
  localStorage.setItem('magicnet.webui.locale', 'zh-CN');
  if (options.theme ?? query.get('theme')) localStorage.setItem('magicnet.webui.theme', options.theme ?? query.get('theme'));
  persist();
  window.ksu = {
    spawn(command, _args, _options, callbackName) {
      fixture.commands.push(command);
      const mutation = command.match(/--json module-update (check|install)\b/);
      if (mutation) fixture.writes.push({ action: mutation[1], command });
      window.setTimeout(() => {
        let output = '', stderr = '', errno = 0;
        if (command.includes('--json capabilities')) {
          output = envelope('machine.capabilities', {
            commands: fixture.unsupported ? ['service.status'] : ['service.status', 'module-update.status', 'module-update.check', 'module-update.install'],
            mutation_commands: fixture.unsupported ? [] : ['module-update.check', 'module-update.install'],
          });
        } else if (command.includes('--json module-update status')) {
          fixture.reads++;
          if (fixture.fault === 'malformed') output = '{"schema":1,"ok":true,"command":"module-update.status","data":{"phase":"available"}}';
          else if (fixture.fault === 'read') {
            errno = 1;
            output = JSON.stringify({ schema: 1, ok: false, command: 'module-update.status', error: { code: 'module-update.request_failed', message: fixture.rawDetail } });
          } else output = envelope('module-update.status', fixture.snapshot);
        } else if (mutation?.[1] === 'check') {
          const id = command.match(/--json module-update check ([A-Za-z0-9_-]+)/)?.[1];
          fixture.set({ latest: { version: 'v1.5.21', version_code: 10521 }, update_available: true, phase: 'available', busy: false, request_id: id, error_code: null });
          output = envelope('module-update.check', fixture.snapshot);
        } else if (mutation?.[1] === 'install') {
          const args = command.match(/--json module-update install (v[0-9.]+) (v[0-9.]+) ([A-Za-z0-9_-]+)/);
          if (fixture.fault === 'conflict') {
            errno = 1;
            output = JSON.stringify({ schema: 1, ok: false, command: 'module-update.install', error: { code: 'module-update.conflict', message: fixture.rawDetail } });
            stderr = fixture.rawDetail;
          } else if (!args || args[1] !== fixture.snapshot.installed.version || args[2] !== fixture.snapshot.latest.version) {
            errno = 1;
            output = JSON.stringify({ schema: 1, ok: false, command: 'module-update.install', error: { code: 'module-update.conflict', message: 'fixture-version-mismatch' } });
          } else {
            fixture.set({ phase: 'downloading', busy: true, request_id: args[3], error_code: null });
            output = envelope('module-update.install', fixture.snapshot);
          }
        } else if (command.includes('--json service status')) {
          output = envelope('service.status', {
            core: { sing_box: { process_state: 'running', pid_summary: '1234', running: true, rss_kib: 98304 } },
            transparent: { configured_mode: 'tun', effective_type: 'tun', effective_mode: 'tun', dataplane_ready: true, capability: 'not_required', local_cgroup: 'inactive', shared_tc: 'inactive', shared_interface_count: 0, transition: 'stable', has_recent_error: false },
            supervisors: { fswatch: '1235' }, api: { url: 'http://127.0.0.1:9090', webui: 'http://127.0.0.1:9090/ui/' }, readiness: { overall: true },
          });
        } else if (command.includes('hotspot status')) output = 'enabled=0\nroute_status=disabled\n';
        else if (command.includes('--json')) {
          errno = 1;
          output = JSON.stringify({ schema: 1, ok: false, command: 'machine.error', error: { code: 'machine.unsupported_command', message: 'fixture-read-unavailable' } });
        }
        persist();
        const callback = window[callbackName];
        if (!callback) return;
        if (output) callback.stdout.emit('data', output);
        if (stderr) callback.stderr.emit('data', stderr);
        callback.emit('exit', errno);
      }, mutation?.[1] === 'install' ? fixture.installDelayMs : 0);
    },
  };
  return fixture;
}

/** Use with a browser test context; all device calls terminate in the mock. */
export async function mountModuleUpdateFixture(page, options = {}) {
  await page.addInitScript(installModuleUpdateFixture, options);
  await page.goto('/#/control', { waitUntil: 'networkidle' });
}

/** Vite-only preview entry; it is never imported by the release bundle. */
export function moduleUpdatePreviewURL(baseURL, options = {}) {
  const url = new URL('/e2e/module-update-preview.html', baseURL);
  for (const [key, value] of Object.entries(options)) if (value !== undefined) url.searchParams.set(key, String(value));
  url.hash = '/control';
  return url.href;
}
