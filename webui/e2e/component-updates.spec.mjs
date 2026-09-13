import { expect, test } from '@playwright/test';

async function mount(page, phase = 'available') {
  await page.addInitScript(({ phase }) => {
    localStorage.setItem('magicnet.webui.onboarding.v1', 'dismissed');
    window.__updates = { commands: [], failSave: false, snapshot: {
      settings: { enabled: false, interval_hours: 24, wifi_only: true, auto_install: true },
      phase, error: phase === 'error' ? 'GitHub metadata HTTP 503' : '',
      last_check: 1789322400, next_check: 1789408800, failures: phase === 'error' ? 1 : 0,
      ...(phase === 'error' ? {} : { plan: {
        version: 'v1.4.9', current: 'v1.4.8', needed: phase === 'available', pending: phase === 'pending-reboot',
        package: 'core', download_bytes: 4096, saved_bytes: 60000000,
        components: [{ id: 'bin-sing-box', sha256: 'a'.repeat(64), source: 'installed', bytes: 0 },
          { id: 'bin-jq', sha256: 'b'.repeat(64), source: 'download', bytes: 2048 }],
      } }),
    } };
    window.ksu = { spawn(command, _args, _options, callbackName) {
      setTimeout(() => {
        const f = window.__updates;
        const cb = window[callbackName];
        f.commands.push(command);
        let output = '', errno = 0;
        if (command.includes('update status')) output = JSON.stringify(f.snapshot);
        else if (command.includes('update configure')) {
          if (f.failSave) errno = 1;
          else f.snapshot.settings = { enabled: command.includes('--enabled=true'),
            interval_hours: Number(command.match(/--interval-hours=(\d+)/)?.[1]),
            wifi_only: command.includes('--wifi-only=true'), auto_install: command.includes('--auto-install=true') };
        }
        if (output) cb.stdout.emit('data', output);
        cb.emit('exit', errno);
      }, command.includes('update configure') ? 80 : 0);
    } };
  }, { phase });
  await page.goto('/#/webui', { waitUntil: 'networkidle' });
  return page.getByTestId('component-updates');
}

test('component plan and saved schedule are accessible without horizontal overflow', async ({ page }) => {
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  const card = await mount(page);
  await expect(card.getByRole('status')).toHaveText('有可用更新');
  await card.locator('summary').click();
  await expect(card.getByText('复用已安装', { exact: true })).toBeVisible();
  await expect(card.getByText('4.0 KiB', { exact: true })).toBeVisible();
  await card.getByLabel('定时自动更新', { exact: true }).check();
  await card.getByLabel('检查间隔（小时）', { exact: true }).fill('6');
  await card.getByRole('button', { name: '保存自动更新设置', exact: true }).click();
  await expect(card.getByRole('button', { name: '保存自动更新设置', exact: true })).toBeDisabled();
  const config = await page.evaluate(() => window.__updates.snapshot.settings);
  expect(config).toEqual({ enabled: true, interval_hours: 6, wifi_only: true, auto_install: true });
  expect(await page.evaluate(() => window.__updates.commands.filter(c => c.includes('update configure')).length)).toBe(1);
  expect(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1)).toBe(false);
  expect(errors).toEqual([]);
});

test('offline errors remain readable and failed saves preserve unsaved settings', async ({ page }) => {
  const card = await mount(page, 'error');
  await expect(card.getByRole('alert')).toContainText('GitHub metadata HTTP 503');
  await expect(card.getByRole('button', { name: '检查组件更新', exact: true })).toBeEnabled();
  await expect(card.getByRole('button', { name: '安装组件更新', exact: true })).toHaveCount(0);
  await page.evaluate(() => { window.__updates.failSave = true; });
  await card.getByLabel('检查间隔（小时）', { exact: true }).fill('12');
  await card.getByRole('button', { name: '保存自动更新设置', exact: true }).click();
  await expect(card.getByRole('alert')).toContainText('自动更新设置未保存');
  await expect(card.getByLabel('检查间隔（小时）', { exact: true })).toHaveValue('12');
  await expect(card.getByRole('button', { name: '保存自动更新设置', exact: true })).toBeEnabled();
});

test('pending restart hides install and page reactivation preserves drafts', async ({ page }) => {
  const card = await mount(page, 'pending-reboot');
  await expect(card.getByRole('status')).toHaveText('已暂存，重启后生效');
  await expect(card.getByRole('button', { name: '安装组件更新', exact: true })).toHaveCount(0);
  await card.getByLabel('检查间隔（小时）', { exact: true }).fill('9');
  await page.evaluate(() => { window.location.hash = '/output'; });
  await expect(page.locator('.page-surface')).toHaveAttribute('data-page', 'output');
  await page.evaluate(() => { window.location.hash = '/webui'; });
  await expect(card.getByLabel('检查间隔（小时）', { exact: true })).toHaveValue('9');
  await expect(card.getByRole('status')).toHaveText('已暂存，重启后生效');
});
