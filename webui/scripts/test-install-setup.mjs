import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.MAGICNET_PLAYWRIGHT_MODULE || '@playwright/test');
const here = path.dirname(fileURLToPath(import.meta.url));
const assets = path.resolve(here, '../../src/MagicNet/lib/magicnet/setup');
const screenshots = process.env.MAGICNET_SETUP_SCREENSHOTS;
const token = 'a'.repeat(48);
const received = [];
let reply = null;
const types = { 'index.html': 'text/html', 'app.js': 'text/javascript', 'style.css': 'text/css' };
const server = http.createServer(async (req, res) => {
  if (req.url.startsWith('/cgi-bin/api/')) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    received.push({ body: Buffer.concat(chunks).toString(), headers: req.headers, path: req.url });
    res.writeHead(reply?.status || 200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    res.end(reply?.text || (req.url.endsWith('/skip') ? 'skipped\n' : 'saved\n'));
    return;
  }
  const name = req.url === '/' ? 'index.html' : req.url.slice(1);
  if (!Object.hasOwn(types, name)) { res.writeHead(404); res.end(); return; }
  try {
    res.writeHead(200, { 'Content-Type': types[name] });
    res.end(await fs.readFile(path.join(assets, name)));
  } catch { res.writeHead(500); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({
  headless: true,
  ...(process.env.MAGICNET_CHROMIUM ? { executablePath: process.env.MAGICNET_CHROMIUM } : {}),
});
// Some hermetic render environments prohibit all navigation. This optional
// DOM fixture exercises the same assets with an in-memory XHR transport;
// normal CI uses the HTTP fixture above and retains the production CSP.
const domFixture = process.env.MAGICNET_SETUP_DOM_FIXTURE === '1';
let fixtureNetworkFailure = false;
async function load(page, url = `${origin}/#${token}`) {
  if (!domFixture) return page.goto(url);
  const css = await fs.readFile(path.join(assets, 'style.css'), 'utf8');
  const js = await fs.readFile(path.join(assets, 'app.js'), 'utf8');
  let html = await fs.readFile(path.join(assets, 'index.html'), 'utf8');
  html = html.replace("style-src 'self'", "style-src 'self' 'nonce-fixture'")
    .replace("script-src 'self'", "script-src 'self' 'nonce-fixture'")
    .replace('<link rel="stylesheet" href="style.css">', `<style nonce="fixture">${css}</style>`)
    .replace('<script src="app.js" defer></script>', '');
  if (!page.__fixtureBound) {
    await page.exposeFunction('__formFixture', async request => {
      if (fixtureNetworkFailure) return { failure: true };
      received.push(request);
      return { status: reply?.status || 200, text: reply?.text || (request.path.endsWith('/skip') ? 'skipped' : 'saved') };
    });
    page.__fixtureBound = true;
  }
  await page.setContent(html);
  await page.evaluate(({ hash, js }) => {
    history.replaceState(null, '', 'about:blank' + hash);
    window.XMLHttpRequest = class {
      headers = {};
      open(method, path) { this.path = path; }
      setRequestHeader(key, value) { this.headers[key.toLowerCase()] = value; }
      send(body) {
        window.__formFixture({ path: this.path, headers: this.headers, body }).then(response => {
          if (response.failure) { this.onerror(); return; }
          this.status = response.status; this.responseText = response.text; this.onload();
        });
      }
    };
    const script = document.createElement('script');
    script.nonce = 'fixture'; script.textContent = js; document.head.appendChild(script);
  }, { hash: new URL(url).hash, js });
}
let checked = 0;
try {
  if (screenshots) await fs.mkdir(screenshots, { recursive: true });
  for (const locale of ['zh-CN', 'en-US', 'ru-RU', 'ja-JP', 'ko-KR']) {
    for (const colorScheme of ['light', 'dark']) {
      const context = await browser.newContext({ locale, colorScheme, reducedMotion: 'reduce', viewport: { width: 393, height: 852 } });
      const page = await context.newPage();
      const errors = [], remote = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('request', request => { if (!request.url().startsWith(origin)) remote.push(request.url()); });
      await load(page);
      await page.locator('#url').waitFor();
      assert.equal(await page.locator('html').getAttribute('lang'), locale === 'zh-CN' ? locale : locale.split('-')[0]);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `overflow ${locale}/${colorScheme}`);
      assert.equal(await page.locator('.point').evaluate(node => getComputedStyle(node).animationName), 'none');
      assert.deepEqual(remote, [], 'page loaded remote assets without consent');
      assert.deepEqual(errors, []);
      for (const link of await page.locator('a').all()) {
        assert.equal(await link.getAttribute('target'), '_blank');
        assert.equal(await link.getAttribute('rel'), 'noopener noreferrer');
        assert.match(await link.getAttribute('href'), /^https:\/\//);
      }
      if (screenshots && locale === 'zh-CN') await page.screenshot({ path: path.join(screenshots, `mobile-${colorScheme}.png`), fullPage: true });
      // Theme follows the OS preference live, rather than only at page load.
      const before = await page.locator('html').evaluate(node => getComputedStyle(node).backgroundColor);
      await page.emulateMedia({ colorScheme: colorScheme === 'light' ? 'dark' : 'light' });
      const after = await page.locator('html').evaluate(node => getComputedStyle(node).backgroundColor);
      assert.notEqual(before, after);
      await context.close();
      checked++;
    }
  }
  for (const width of [320, 1440]) {
    const context = await browser.newContext({ locale: 'zh-CN', viewport: { width, height: 960 }, colorScheme: 'light', reducedMotion: 'reduce' });
    const page = await context.newPage();
    await load(page);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    if (screenshots && width === 1440) await page.screenshot({ path: path.join(screenshots, 'desktop-light.png'), fullPage: true });
    await context.close();
    checked++;
  }
  const context = await browser.newContext({ locale: 'zh-CN', viewport: { width: 393, height: 852 }, colorScheme: 'dark' });
  const page = await context.newPage();
  await load(page);
  await page.locator('#url').fill('not-a-url');
  await page.locator('#save').click();
  assert.equal(received.length, 0);
  assert.equal(await page.locator('#status').getAttribute('data-error'), 'true');
  const value = "https://example.invalid/sub?key=a%2Bb+c&value=$('literal');x#测试";
  await page.locator('#url').fill(value);
  await page.locator('#url').press('Enter');
  await page.locator('#finish').waitFor({ state: 'visible' });
  assert.equal(received.at(-1).body, value);
  assert.equal(received.at(-1).headers['x-setup-token'], token);
  assert.equal(received.at(-1).path, '/cgi-bin/api/save');
  assert.equal(await page.locator('#url').inputValue(), '');
  assert.equal(await page.locator('#title').textContent(), '链接已保存。');
  await page.locator('#language').selectOption('en');
  assert.equal(await page.locator('#title').textContent(), 'Your link is saved.');
  await page.locator('#language').selectOption('zh');
  if (screenshots) await page.screenshot({ path: path.join(screenshots, 'saved-dark.png'), fullPage: true });
  checked++;

  await load(page);
  await page.locator('#skip').click();
  await page.locator('#finish').waitFor({ state: 'visible' });
  assert.equal(received.at(-1).path, '/cgi-bin/api/skip');
  assert.equal(received.at(-1).body, '');
  assert.equal(await page.locator('#title').textContent(), '下次再连接。');
  checked++;

  await load(page, origin);
  assert.equal(await page.locator('#save').isDisabled(), true);
  assert.equal(await page.locator('#status').getAttribute('data-error'), 'true');
  checked++;

  reply = { status: 403, text: 'forbidden' };
  await load(page);
  await page.locator('#url').fill('https://example.invalid/sub');
  await page.locator('#save').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.equal(await page.locator('#save').isDisabled(), true);
  assert.equal(await page.locator('#finish').isVisible(), false);
  checked++;

  reply = null;
  await load(page);
  fixtureNetworkFailure = true;
  if (!domFixture) await page.route('**/cgi-bin/api/save', route => route.abort());
  await page.locator('#url').fill('https://example.invalid/sub');
  await page.locator('#save').click();
  await page.waitForFunction(() => document.getElementById('status').dataset.error === 'true');
  assert.match(await page.locator('#status').textContent(), /无法确认/);
  assert.equal(await page.locator('#finish').isVisible(), false, 'network failure must not claim success');
  checked++;
  await context.close();
  console.log(`Installer page: ${checked} browser scenarios passed (${domFixture ? 'offline DOM fixture' : 'HTTP fixture'}).`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
