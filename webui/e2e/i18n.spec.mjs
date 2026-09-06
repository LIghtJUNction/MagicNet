import { test, expect } from '@playwright/test';

const tabs = ['control', 'about', 'apps', 'block', 'chain', 'subs', 'config', 'webui', 'health', 'tools', 'output'];
async function changeLanguage(page, language) {
  const header = page.locator('.mn-language-header select');
  if (await header.isVisible()) {
    await header.selectOption(language);
  } else {
    await page.locator('.mn-more-action').click();
    await page.locator('.mn-utility-sheet select').selectOption(language);
    await page.keyboard.press('Escape');
  }
  await expect(page.locator('html')).toHaveAttribute('lang', language);
}

for (const [browserLocale, language, overview] of [
  ['en-US', 'en', 'Overview'],
  ['ru-RU', 'ru', 'Обзор'],
]) {
  test.describe(browserLocale, () => {
    test.use({ locale: browserLocale });
    test('detects language and translates every page without changing raw data', async ({ page }) => {
      const errors = [];
      page.on('pageerror', (error) => errors.push(error.message));
      await page.goto('/');
      await expect(page.locator('html')).toHaveAttribute('lang', language);
      await expect(page.locator('.mn-section-tabs [data-tab="control"]')).toHaveText(overview);
      for (const tab of tabs) {
        await page.evaluate((tab) => { window.location.hash = `/${tab}`; }, tab);
        await expect(page.locator('.page-surface')).toHaveAttribute('data-page', tab);
        await expect(page.locator('.page-surface h2').first()).toBeVisible();
        await page.evaluate(() => {
          document.querySelectorAll('.page-surface details:not(.config-action-menu)').forEach((node) => { node.open = true; });
        });
        const untranslated = await page.locator('.page-surface').evaluate((root) => {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const found = [];
          while (walker.nextNode()) {
            const element = walker.currentNode.parentElement;
            if (!element?.checkVisibility() || element.closest('pre, code, textarea, input, .json-editor')) continue;
            const text = walker.currentNode.textContent.trim();
            // Node-name filters are literal matching values.
            if (element.closest('[data-filter-value]')) continue;
            if (/\p{Script=Han}/u.test(text)) found.push(text);
          }
          return found;
        });
        expect(untranslated, `${language}: ${tab}`).toEqual([]);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1);
        expect(overflow, `${language}: ${tab} horizontal overflow`).toBe(false);
      }
      await page.evaluate(async () => {
        const { useMagicNet } = await import('/src/composables/useMagicNet.ts');
        useMagicNet().state.output = '原始日志: server=Москва.example；用户自定义';
      });
      await expect(page.locator('.page-surface pre').last()).toHaveText('原始日志: server=Москва.example；用户自定义');
      await changeLanguage(page, language === 'en' ? 'ru' : 'en');
      await expect(page.locator('.page-surface pre').last()).toHaveText('原始日志: server=Москва.example；用户自定义');
      expect(errors).toEqual([]);
    });
  });
}

test('manual language survives reload and keeps an unsaved editor draft', async ({ page }) => {
  await page.goto('/#/config');
  const editor = page.locator('.json-editor textarea');
  await expect(editor).toBeVisible();
  await editor.fill('{"tag":"用户自定义 Москва"}');
  await changeLanguage(page, 'ru');
  await expect(editor).toHaveValue('{"tag":"用户自定义 Москва"}');
  await expect(page.locator('.page-surface h2').first()).toHaveText('Файл конфигурации');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('lang', 'ru');
  await changeLanguage(page, 'en');
  await expect(page.locator('.page-surface h2').first()).toHaveText('Configuration file');
  await changeLanguage(page, 'zh-CN');
  await expect(page.locator('.page-surface h2').first()).toHaveText('配置文件');
});
