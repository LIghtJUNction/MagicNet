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
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('fixture response timeout')), 20000); }),
    ]);
    assert.equal(line.done, false, 'fixture exited unexpectedly');
    const value = JSON.parse(line.value);
    assert.equal(value.error, undefined, value.error);
    return value;
  } finally { clearTimeout(timer); }
}
async function rpc(op) { child.stdin.write(JSON.stringify({ op }) + '\n'); return receive(); }
let fixture;
let browser;
let checked = 0;
const errors = [];
const remote = [];
const repositoryPrompts = [];
async function observe(page) {
  page.on('dialog', async dialog => { repositoryPrompts.push(dialog.message()); await dialog.dismiss(); });
  await page.route('https://api.github.com/repos/LIghtJUNction/MagicNet', route => {
    assert.equal(route.request().headers()['x-setup-token'], undefined);
    assert.equal(route.request().headers().referer, undefined);
    return route.fulfill({ json: { stargazers_count: 1234 } });
  });
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => {
    if (!request.url().startsWith(fixture.origin + '/') && request.url() !== 'https://api.github.com/repos/LIghtJUNction/MagicNet') remote.push(request.url());
  });
}
async function load(page, suffix = `/#${fixture.token}`, ready = true) {
  await page.goto('about:blank');
  await page.goto(fixture.origin + suffix);
  if (ready) await page.waitForFunction(() => !document.getElementById('save').disabled);
}
async function reset(page) { fixture = await rpc('reset'); await load(page); }
try {
  fixture = await receive();
  browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH });
  for (const [locale, expected] of [['zh-CN', 'zh'], ['zh-TW', 'zh-TW'], ['en-US', 'en'], ['ru-RU', 'ru'], ['ja-JP', 'ja'], ['ko-KR', 'ko']]) {
    for (const width of [320, 390, 1440]) {
      for (const colorScheme of ['light', 'dark']) {
        const context = await browser.newContext({ locale, colorScheme, reducedMotion: 'reduce', viewport: { width, height: 900 } });
        const page = await context.newPage();
        await observe(page);
        await load(page);
        assert.equal(await page.locator('html').getAttribute('lang'), expected);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${locale}/${width}/${colorScheme} overflows`);
        assert.equal(await page.locator('.orbit-d').evaluate(node => getComputedStyle(node).animationName), 'none');
        for (const element of await page.locator('[data-i18n]').all()) {
          assert.ok((await element.textContent()).trim(), `${locale}: empty translation`);
          assert.notEqual(await element.textContent(), 'undefined');
        }
        for (const link of await page.locator('a').all()) {
          assert.equal(await link.getAttribute('target'), '_blank');
          assert.equal(await link.getAttribute('rel'), 'noopener noreferrer');
          assert.match(await link.getAttribute('href'), /^https:\/\//);
          assert.equal((await link.getAttribute('href')).includes(fixture.token), false);
        }
        const before = await page.locator('html').evaluate(node => getComputedStyle(node).backgroundColor);
        await page.emulateMedia({ colorScheme: colorScheme === 'light' ? 'dark' : 'light' });
        const after = await page.locator('html').evaluate(node => getComputedStyle(node).backgroundColor);
        assert.notEqual(before, after, 'theme did not follow media preference');
        await context.close();
        checked++;
      }
    }
  }
  assert.deepEqual(errors, [], 'unexpected JavaScript errors');
  assert.deepEqual(remote, [], 'remote assets loaded without user navigation');
  const context = await browser.newContext({ locale: 'zh-CN', viewport: { width: 390, height: 852 }, colorScheme: 'dark' });
  const page = await context.newPage();
  await observe(page);
  await load(page, `/?lang=zh-TW#${fixture.token}`);
  assert.equal(await page.locator('html').getAttribute('lang'), 'zh-TW');
  await page.locator('#language').selectOption('en');
  assert.equal(await page.locator('html').getAttribute('lang'), 'en');
  checked++;

  await load(page);
  await page.waitForFunction(() => document.getElementById('star-count').textContent.replace(/\D/g, '') === '1234');
  const starURL = 'https://api.github.com/repos/LIghtJUNction/MagicNet';
  const failStars = route => route.abort();
  await page.route(starURL, failStars);
  await load(page);
  assert.equal(await page.locator('#star-count').textContent(), '—');
  await page.unroute(starURL, failStars);
  await page.locator('#subscription').fill('not-a-url');
  await page.locator('#save').click();
  assert.equal(await page.locator('#status').getAttribute('data-error'), 'true');
  assert.equal((await rpc('state')).value, null);
  checked++;

  const value = "https://feed.example.test/sub?token=a+b%2F&quote='&semi=;&x=$(id)";
  let releaseReceipt;
  let receiptRequested;
  const holdReceipt = new Promise(resolve => { releaseReceipt = resolve; });
  const requestedReceipt = new Promise(resolve => { receiptRequested = resolve; });
  await page.route('**/cgi-bin/setup/status', async route => {
    receiptRequested();
    await holdReceipt;
    await route.continue();
  });
  await page.locator('#subscription').fill(value);
  await page.locator('#save').click();
  await Promise.race([requestedReceipt, new Promise((_, reject) => setTimeout(() => reject(new Error('installer receipt was not requested')), 3000))]);
  assert.equal(await page.locator('#completion').isVisible(), false, 'a write acknowledgement is not installer readiness');
  assert.equal(repositoryPrompts.length, 0);
  releaseReceipt();
  await page.locator('#completion').waitFor({ state: 'visible' });
  await page.unroute('**/cgi-bin/setup/status');
  assert.equal(await page.locator('#subscription').inputValue(), '');
  assert.equal(new URL(page.url()).hash, '');
  assert.equal(await page.locator('#completion-title').textContent(), '链接已收好。');
  const saved = await rpc('wait');
  assert.equal(saved.value, value + '\n');
  assert.equal(saved.mode, 0o600);
  assert.equal(saved.exit, 0);
  assert.ok(repositoryPrompts.includes('是否跳转至源代码仓库？'));
  await page.locator('#language').selectOption('zh-TW');
  assert.equal(await page.locator('#completion-title').textContent(), '連結已收好。');
  checked++;

  await reset(page);
  await page.locator('#skip').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.equal(await page.locator('#completion').isVisible(), false);
  const promptCount = repositoryPrompts.length;
  await page.locator('#cancel').click();
  await page.locator('#completion').waitFor({ state: 'visible' });
  const skipped = await rpc('wait');
  assert.equal(skipped.value, null);
  assert.equal(skipped.exit, 4);
  assert.equal(repositoryPrompts.length, promptCount);
  checked++;

  fixture = await rpc('upgrade');
  await load(page);
  assert.equal(await page.locator('#subscription').inputValue(), 'https://existing.example.test/sub');
  const replacement = 'https://replacement.example.test/sub\nhttps://added.example.test/sub';
  await page.locator('#subscription').fill(replacement);
  await page.locator('#save').click();
  await page.locator('#completion').waitFor({ state: 'visible' });
  assert.equal((await rpc('wait')).value, replacement + '\n');
  checked++;

  fixture = await rpc('reset');
  await load(page, '/', false);
  assert.equal(await page.locator('#save').isDisabled(), true);
  assert.equal(await page.locator('#status').getAttribute('data-error'), 'true');
  checked++;

  await load(page, '/#' + 'f'.repeat(48), false);
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.equal(await page.locator('#save').isDisabled(), true);
  assert.equal(await page.locator('#completion').isVisible(), false);
  checked++;

  await load(page);
  await rpc('existing');
  await page.locator('#subscription').fill(value);
  await page.locator('#save').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.equal(await page.locator('#save').isDisabled(), true);
  assert.equal((await rpc('state')).value, 'https://existing.example.test/sub\n');
  assert.equal(await page.locator('#completion').isVisible(), false);
  checked++;

  await reset(page);
  await page.route('**/cgi-bin/setup/save', route => route.abort());
  await page.locator('#subscription').fill(value);
  await page.locator('#save').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.match(await page.locator('#status').textContent(), /无法确认/);
  assert.equal(await page.locator('#completion').isVisible(), false);
  assert.equal((await rpc('state')).value, null);
  await page.unroute('**/cgi-bin/setup/save');
  checked++;

  // Losing an acknowledgement after the CGI commits is not proof of failure
  // or success in the browser. The installer, not the UI, owns the saved result.
  await reset(page);
  await page.route('**/cgi-bin/setup/save', async route => { await route.fetch(); await route.abort(); });
  await page.locator('#subscription').fill(value);
  await page.locator('#save').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.match(await page.locator('#status').textContent(), /无法确认/);
  assert.equal(await page.locator('#completion').isVisible(), false);
  const unconfirmed = await rpc('wait');
  assert.equal(unconfirmed.exit, 0);
  assert.equal(unconfirmed.value, value + '\n');
  checked++;
  await context.close();
  assert.deepEqual(errors, []);
  assert.deepEqual(remote, []);
  console.log(`Installer page: ${checked} scenarios passed against real BusyBox HTTP/CGI (two transport faults injected).`);
} finally {
  if (browser) await browser.close();
  child.stdin.end(JSON.stringify({ op: 'close' }) + '\n');
  const killTimer = setTimeout(() => child.kill('SIGTERM'), 15000);
  await new Promise(resolve => {
    if (child.exitCode !== null) resolve(); else child.once('exit', resolve);
  });
  clearTimeout(killTimer);
}
