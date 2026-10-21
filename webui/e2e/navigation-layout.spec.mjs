import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.theme", "light");
  });
  await page.goto("/#/about", { waitUntil: "networkidle" });
  await expect(page.locator('.page-surface[data-page="about"] h2').first()).toBeVisible();
});

test("the phone toolbar keeps the full app name and reachable actions", async ({ page }) => {
  const title = page.locator(".mn-brand-copy h1");
  expect(await title.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
  await expect(page.getByRole("button", { name: "快速跳转", exact: true })).toBeInViewport();
  await page.getByRole("button", { name: "打开系统工具", exact: true }).click();
  const sheet = page.getByRole("dialog", { name: "系统工具", exact: true });
  await expect(sheet).toBeVisible();
  await expect(sheet.getByRole("button", { name: "刷新面板", exact: true })).toBeInViewport();
});

test("changing pages after scrolling opens the destination at its heading", async ({ page }) => {
  const navigate = async (tab) => {
    const desktop = page.locator(`.desktop-rail [data-tab="${tab}"]`);
    if (await desktop.isVisible()) await desktop.click();
    else await page.locator(`.mn-section-tabs [data-tab="${tab}"]`).click();
    await expect(page.locator(`.page-surface[data-page="${tab}"] h2`).first()).toBeVisible();
  };
  // Cache both long pages first; an empty lazy-loading shell can hide this bug.
  await navigate("control");
  await navigate("about");
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(100);

  await navigate("control");
  await expect(page.locator('.page-surface[data-page="control"] h2').first()).toBeInViewport({ ratio: 1 });
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
});

test("a direct link keeps the selected section label fully visible", async ({ page }) => {
  // A hash-only navigation would exercise the normal setTab path instead of mounting a deep link.
  await page.goto("about:blank");
  await page.goto("/#/webui", { waitUntil: "networkidle" });
  await expect(page.locator('.page-surface[data-page="webui"] h2').first()).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  const sections = page.locator(".mn-section-tabs");
  if (await sections.isVisible()) {
    await expect.poll(async () => sections.evaluate((track) => {
      const selected = track.querySelector('[aria-current="page"]');
      if (!selected) return false;
      const label = selected.getBoundingClientRect();
      const visible = track.getBoundingClientRect();
      return label.left >= visible.left && label.right <= visible.right;
    })).toBe(true);
  } else {
    await expect(page.locator('.desktop-rail [data-tab="webui"][aria-current="page"]')).toBeInViewport({ ratio: 1 });
  }
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  await page.keyboard.press("Tab");
  await expect(page.locator(".mn-skip-link")).toBeFocused();
});
