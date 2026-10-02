import { expect, test } from '@playwright/test';
import { mountModuleUpdateFixture } from './module-update-fixture.mjs';

const card = page => page.locator('.mn-module-update');
const install = page => card(page).getByRole('button', { name: /^安装更新至 / });
const writes = page => page.evaluate(() => window.__moduleUpdateFixture.writes);

async function assertNoInstall(page) {
  for (const button of await install(page).all()) await expect(button).toBeDisabled();
}

async function assertPrivateFailureAbsent(page) {
  const publicState = await page.evaluate(async () => {
    const { state } = (await import('/src/composables/useMagicNet.ts')).useMagicNet();
    return JSON.stringify([state.output, state.notice, state.lastCommand, state.operationCapture, localStorage, sessionStorage, document.body.innerText]);
  });
  expect(publicState).not.toContain('fixture-internal-install-detail');
}

test('negotiates capabilities, checks explicitly and binds one install to observed versions and request ID', async ({ page }) => {
  await mountModuleUpdateFixture(page);
  await expect(card(page).getByRole('button', { name: '检查更新', exact: true })).toBeEnabled();
  await expect(card(page)).toContainText('当前版本 v1.5.20');
  expect(await writes(page)).toEqual([]);
  const commands = await page.evaluate(() => window.__moduleUpdateFixture.commands);
  const discovery = commands.findIndex(command => command.includes('--json capabilities'));
  const status = commands.findIndex(command => command.includes('--json module-update status'));
  expect(discovery).toBeGreaterThanOrEqual(0);
  expect(status).toBeGreaterThan(discovery);
  await card(page).getByRole('button', { name: '检查更新', exact: true }).click();
  await expect(install(page)).toBeEnabled();
  await expect(install(page)).toHaveText('安装更新至 v1.5.21');
  const checkWrite = (await writes(page))[0];
  const checkId = checkWrite.command.match(/--json module-update check ([A-Za-z0-9_-]+)/)?.[1];
  expect(checkId).toMatch(/^webui_[A-Za-z0-9_-]{8,58}$/);
  expect(await page.evaluate(() => window.__moduleUpdateFixture.snapshot.request_id)).toBe(checkId);
  // Two events before the async native response verify the handler's own guard.
  await install(page).evaluate(button => { button.click(); button.click(); });
  await expect(card(page)).toHaveAttribute('data-phase', 'downloading');
  await expect(card(page)).toContainText('正在下载更新…');
  await assertNoInstall(page);
  const observedWrites = await writes(page);
  expect(observedWrites.map(write => write.action)).toEqual(['check', 'install']);
  const match = observedWrites[1].command.match(/--json module-update install (v[0-9.]+) (v[0-9.]+) ([A-Za-z0-9_-]+)/);
  expect(match?.slice(1, 3)).toEqual(['v1.5.20', 'v1.5.21']);
  expect(match?.[3]).toMatch(/^webui_[A-Za-z0-9_-]{8,58}$/);
  expect(await page.evaluate(() => window.__moduleUpdateFixture.snapshot.request_id)).toBe(match[3]);
  expect(await page.evaluate(() => window.__moduleUpdateFixture.commands.some(command => /(?:^|\s)reboot(?:\s|$)/.test(command)))).toBe(false);
});

test('background download survives page re-entry and full reload without another install', async ({ page }) => {
  await mountModuleUpdateFixture(page, { phase: 'available' });
  await expect(install(page)).toBeEnabled();
  await install(page).click();
  await expect(card(page)).toHaveAttribute('data-phase', 'downloading');
  await page.evaluate(() => { window.location.hash = '/output'; });
  await expect(page.locator('.page-surface')).toHaveAttribute('data-page', 'output');
  await page.evaluate(() => { window.location.hash = '/control'; });
  await expect(card(page)).toContainText('正在下载更新…');
  await assertNoInstall(page);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(card(page)).toContainText('正在下载更新…');
  await expect(card(page)).toContainText('当前版本 v1.5.20');
  await assertNoInstall(page);
  expect((await writes(page)).map(write => write.action)).toEqual(['install']);
});

test('observed staged install retains old running version and waits for manual reboot', async ({ page }) => {
  await mountModuleUpdateFixture(page, { phase: 'available' });
  await expect(install(page)).toBeEnabled();
  await install(page).click();
  await expect(card(page)).toHaveAttribute('data-phase', 'downloading');
  await page.evaluate(() => window.__moduleUpdateFixture.set({ phase: 'reboot_required', busy: false, reboot_required: true }));
  await expect(card(page)).toContainText('已安装，等待重启');
  await expect(card(page)).toContainText('当前版本 v1.5.20');
  await expect(card(page)).toContainText('v1.5.21 将在重启设备后生效。请在方便时手动重启。');
  await assertNoInstall(page);
  await expect(card(page).getByRole('button', { name: '检查更新', exact: true })).toHaveCount(0);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(card(page)).toContainText('已安装，等待重启');
  await assertNoInstall(page);
  expect((await writes(page)).map(write => write.action)).toEqual(['install']);
  expect(await page.evaluate(() => window.__moduleUpdateFixture.commands.some(command => /(?:^|\s)reboot(?:\s|$)/.test(command)))).toBe(false);
});

test('missing capabilities exposes no write controls and never reaches update mutations', async ({ page }) => {
  await mountModuleUpdateFixture(page, { unsupported: true });
  await expect(card(page)).toContainText('当前版本暂不支持内置更新');
  await assertNoInstall(page);
  await expect(card(page).getByRole('button', { name: '检查更新', exact: true })).toHaveCount(0);
  await card(page).getByRole('button', { name: '重新读取', exact: true }).click();
  await expect(card(page)).toContainText('当前版本暂不支持内置更新');
  expect(await writes(page)).toEqual([]);
  expect(await page.evaluate(() => window.__moduleUpdateFixture.commands.some(command => command.includes('--json module-update')))).toBe(false);
});

for (const fault of ['malformed', 'read']) {
  test(`${fault} initial status remains unknown and cannot install`, async ({ page }) => {
    await mountModuleUpdateFixture(page, { phase: 'available', fault });
    await expect(card(page)).toContainText('更新状态未确认');
    await expect(card(page)).toHaveAttribute('data-phase', 'unknown');
    await expect(card(page)).toContainText('无法确认更新状态，请重新读取后再试。');
    await assertNoInstall(page);
    expect(await writes(page)).toEqual([]);
    await assertPrivateFailureAbsent(page);
  });
  test(`${fault} after an available observation invalidates its install button`, async ({ page }) => {
    await mountModuleUpdateFixture(page, { phase: 'available' });
    await expect(install(page)).toBeEnabled();
    await page.evaluate(fault => { window.__moduleUpdateFixture.fault = fault; window.location.hash = '/output'; }, fault);
    await expect(page.locator('.page-surface')).toHaveAttribute('data-page', 'output');
    await page.evaluate(() => { window.location.hash = '/control'; });
    await expect(card(page)).toContainText('更新状态未确认');
    await expect(card(page)).toHaveAttribute('data-phase', 'unknown');
    await assertNoInstall(page);
    expect(await writes(page)).toEqual([]);
    await assertPrivateFailureAbsent(page);
  });
}

test('install conflicts show a localized error without publishing raw device failure', async ({ page }) => {
  await mountModuleUpdateFixture(page, { phase: 'available', fault: 'conflict' });
  await expect(install(page)).toBeEnabled();
  await install(page).click();
  await expect(card(page)).toContainText('版本信息已变化，请重新检查更新。');
  await expect(card(page)).not.toContainText('已安装');
  expect((await writes(page)).map(write => write.action)).toEqual(['install']);
  await assertPrivateFailureAbsent(page);
});

test('update controls fit the viewport and keep readable touch targets', async ({ page }, info) => {
  await mountModuleUpdateFixture(page, { phase: 'available' });
  await expect(install(page)).toBeEnabled();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)).toBe(true);
  for (const button of await card(page).getByRole('button').all()) {
    const box = await button.boundingBox();
    expect(box?.height).toBeGreaterThanOrEqual(44);
    expect(box?.width).toBeGreaterThanOrEqual(44);
  }
  await card(page).screenshot({ path: info.outputPath('module-update-available.png'), timeout: 20_000 });
});
