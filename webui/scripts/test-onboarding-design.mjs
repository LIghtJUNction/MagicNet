import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const child = spawn('python3', [path.join(root, 'scripts/onboarding-browser-fixture.py')], {
  cwd: root, stdio: ['pipe', 'pipe', 'inherit'],
});
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
async function receive() {
  let timer;
  try {
    const line = await Promise.race([
      lines.next(),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('fixture timeout')), 20000); }),
    ]);
    assert.equal(line.done, false, 'fixture exited');
    const data = JSON.parse(line.value);
    assert.equal(data.error, undefined, data.error);
    return data;
  } finally { clearTimeout(timer); }
}
async function rpc(op) { child.stdin.write(JSON.stringify({ op }) + '\n'); return receive(); }
let browser;
const errors = [];
try {
  const fixture = await receive();
  browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH });
  for (const [width, height] of [[320, 568], [390, 852], [768, 1024], [1440, 900]]) {
    for (const colorScheme of ['light', 'dark']) {
      const context = await browser.newContext({ locale: 'zh-CN', colorScheme, reducedMotion: 'reduce', viewport: { width, height } });
      await context.route('https://api.github.com/repos/LIghtJUNction/MagicNet', route => route.fulfill({ json: { stargazers_count: 1234 } }));
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
      await page.goto(`${fixture.origin}/#${fixture.token}`);
      await page.waitForFunction(() => !document.getElementById('save').disabled);
      assert.equal(await page.locator('.artwork img').evaluate(image => image.complete && image.naturalWidth === 512), true, 'bundled illustration missing');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      assert.equal(await page.locator('main h1:visible').count(), 1);
      assert.equal(await page.locator('main p:visible').count(), 1, 'only the subscription editing hint is shown');
      assert.ok((await page.locator('#subscription-help').textContent()).trim());
      assert.equal(await page.locator('#status').textContent(), '');
      assert.equal(await page.locator('#telegram').getAttribute('href'), 'https://t.me/magicnet_group');
      assert.equal(await page.locator('#discord').getAttribute('href'), 'https://discord.gg/asRwgK9FpA');
      for (const element of await page.locator('a, button, textarea, select').all()) {
        if (!await element.isVisible()) continue;
        const box = await element.boundingBox();
        assert.ok(box.height >= 44, 'touch target smaller than 44px');
      }
      for (const element of await page.locator('[data-i18n-label]').all()) {
        assert.ok(await element.getAttribute('aria-label'));
        assert.notEqual(await element.getAttribute('aria-label'), 'undefined');
      }
      await context.close();
    }
  }
  const context = await browser.newContext({ locale: 'zh-CN' });
  await context.route('https://api.github.com/repos/LIghtJUNction/MagicNet', route => route.fulfill({ json: { stargazers_count: 1234 } }));
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/#${fixture.token}`);
  await page.waitForFunction(() => !document.getElementById('save').disabled);
  const value = 'https://feed.example.test/subscription';
  await page.locator('#subscription').fill(value);
  for (const [selector, destination] of [['#telegram', 'https://t.me/magicnet_group'], ['#discord', 'https://discord.gg/asRwgK9FpA']]) {
    let clicked = false;
    await context.route(destination + '**', async route => {
      clicked = true;
      assert.equal(route.request().headers().referer, undefined, 'invite leaked a referrer');
      await route.fulfill({ status: 200, contentType: 'text/html', body: '<title>Invite fixture</title>' });
    });
    const popupPromise = page.waitForEvent('popup');
    await page.locator(selector).click();
    const popup = await popupPromise;
    await popup.waitForLoadState();
    assert.ok(clicked, 'join button did not navigate');
    assert.ok(popup.url().startsWith(destination));
    assert.equal(await popup.evaluate(() => window.opener === null), true);
    assert.equal(await page.locator('#subscription').inputValue(), value);
    assert.equal((await rpc('state')).value, null, 'community link submitted the form');
    await popup.close();
  }
  await page.locator('#save').click();
  await page.locator('#completion').waitFor({ state: 'visible' });
  const saved = await rpc('wait');
  assert.equal(saved.exit, 0);
  assert.equal(saved.value, value + '\n');
  assert.equal(await page.locator('#title').isVisible(), false);
  assert.equal(await page.locator('#completion-note').textContent(), '安装器已确认：一切就绪。');
  assert.equal(await page.locator('#completion-title').evaluate(node => node === document.activeElement), true);
  assert.equal(await page.locator('#telegram').isVisible(), true);
  assert.equal(await page.locator('#discord').isVisible(), true);
  await context.close();
  assert.deepEqual(errors, [], 'page emitted JavaScript or CSP errors');
  console.log('Design contracts passed: eight layouts, illustration, minimal copy, accessible targets, both invite clicks and saved state.');
} finally {
  if (browser) await browser.close();
  child.stdin.end(JSON.stringify({ op: 'close' }) + '\n');
  const timer = setTimeout(() => child.kill('SIGTERM'), 15000);
  await new Promise(resolve => { if (child.exitCode !== null) resolve(); else child.once('exit', resolve); });
  clearTimeout(timer);
}
