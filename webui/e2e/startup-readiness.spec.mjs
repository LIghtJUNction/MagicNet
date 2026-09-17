import { test, expect } from '@playwright/test';

async function setFixture(page, overrides = {}) {
  await page.evaluate(async overrides => {
    // Display-only fixture: no root bridge and no device/network mutation.
    const {state} = (await import('/src/composables/useMagicNet.ts')).useMagicNet();
    Object.assign(state, {hasKsu:true, busy:false, phase:'idle', queueDepth:0, task:'', notice:'', output:''});
    state.backgroundTask.status = 'idle';
    Object.assign(state.runtime, {singBoxState:'sing-box',singBox:'123',singBoxRssKib:98304,serviceReady:true,transparentMode:'tun',transparentEffectiveMode:'tun',transparentTransition:'stable',fswatch:'124'});
    Object.assign(state.runtime, overrides.runtime || {});
    Object.assign(state, overrides.state || {});
  }, overrides);
}
async function assertFits(page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)).toBe(true);
  for (const button of await page.locator('.mn-control button:visible').all()) {
    const box = await button.boundingBox();
    expect(box.height).toBeGreaterThanOrEqual(44);
    expect(box.width).toBeGreaterThanOrEqual(44);
  }
}
for (const theme of ['light','dark']) {
  test(`startup overview is truthful and usable: ${theme}`, async ({page}, info) => {
    await page.addInitScript(theme => {
      localStorage.setItem('magicnet.webui.onboarding.v1','dismissed');
      localStorage.setItem('magicnet.webui.theme',theme);
    },theme);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('/',{waitUntil:'networkidle'});
    await expect(page.locator('.mn-control')).toBeVisible();
    await expect(page.locator('.mn-control-power')).toBeDisabled();
    await setFixture(page);
    await expect(page.locator('.mn-control-hero')).toHaveAttribute('data-service-state','ready');
    await expect(page.locator('.mn-control-status h2')).toHaveText('运行中');
    await expect(page.locator('.mn-control-hero .mn-control-notice')).toHaveCount(0);
    await assertFits(page);
    await page.screenshot({path:info.outputPath(`${theme}-ready.png`),fullPage:true});
    await setFixture(page,{runtime:{serviceReady:null}});
    await expect(page.locator('.mn-control-status h2')).toHaveText('状态待确认');
    await expect(page.locator('.mn-control-eyebrow .mn-status-dot-ok')).toHaveCount(0);
    await expect(page.locator('.mn-control-hero .mn-control-notice')).toBeVisible();
    await setFixture(page,{runtime:{serviceReady:false}});
    await expect(page.locator('.mn-control-status h2')).toHaveText('服务未就绪');
    await expect(page.locator('.mn-control-eyebrow .mn-status-dot-ok')).toHaveCount(0);
    await setFixture(page,{runtime:{singBoxState:'stopped',serviceReady:false,transparentEffectiveMode:'unknown'},state:{phase:'error',output:'[warn] Startup step failed: stage=config-check exit=1\n[warn] sing-box startup failed; see the preceding core or network error.\n[error] MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel failed with status 1'}});
    await expect(page.locator('.mn-control-hero .mn-control-notice')).toHaveAttribute('role','alert');
    await expect(page.locator('.mn-control-hero .mn-control-notice h3')).toContainText('配置校验');
    await expect(page.locator('.mn-control-hero .mn-control-notice p')).toBeVisible();
    await assertFits(page);
    await page.screenshot({path:info.outputPath(`${theme}-failure.png`),fullPage:true});
    await page.locator('.mn-control-hero .mn-control-notice').getByRole('button',{name:'查看输出'}).click();
    await expect(page.locator('.page-surface pre').last()).toContainText('Startup step failed: stage=config-check');
    expect(errors).toEqual([]);
  });
}
