import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.locale", "zh-CN");
  });
  await page.goto("/", { waitUntil: "networkidle" });
  await expect(page.locator(".mn-control")).toBeVisible();
});

test("the brand stays readable beside touch-sized toolbar controls", async ({ page }) => {
  const brand = page.locator(".mn-brand-copy h1");
  expect(await brand.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true);
  for (const label of [/外观主题/, "快速跳转", "打开系统工具"]) {
    const bounds = await page.getByRole("button", { name: label, exact: typeof label === "string" }).boundingBox();
    expect(bounds.width).toBeGreaterThanOrEqual(44);
    expect(bounds.height).toBeGreaterThanOrEqual(44);
  }
  await page.getByRole("button", { name: "打开系统工具", exact: true }).click();
  const refresh = page.getByRole("dialog", { name: "系统工具", exact: true })
    .getByRole("button", { name: "刷新面板", exact: true });
  const bounds = await refresh.boundingBox();
  expect(bounds.width).toBeGreaterThanOrEqual(44);
  expect(bounds.height).toBeGreaterThanOrEqual(44);
});

test("opening another page starts at its heading after a long page", async ({ page }) => {
  await page.evaluate(() => window.scrollTo(0, 600));
  expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(100);
  const desktop = page.locator('.desktop-rail [data-tab="apps"]');
  if (await desktop.isVisible()) await desktop.click();
  else await page.locator('.mobile-nav [data-workspace="route"]').click();
  await expect(page.locator('.page-surface[data-page="apps"] h2')).toHaveText("应用名单");
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeLessThan(2);
  await expect(page.locator('.page-surface[data-page="apps"] h2')).toBeInViewport();
});

test("quick navigation opened from system tools restores its visible trigger", async ({ page }) => {
  const trigger = page.getByRole("button", { name: "打开系统工具", exact: true });
  await trigger.click();
  await page.getByRole("dialog", { name: "系统工具", exact: true })
    .getByRole("button", { name: "快速跳转", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "快速跳转", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(trigger).toBeFocused();
});

test("onboarding opened through quick navigation keeps the original focus target", async ({ page }) => {
  const trigger = page.getByRole("button", { name: "打开系统工具", exact: true });
  await trigger.click();
  await page.getByRole("dialog", { name: "系统工具", exact: true })
    .getByRole("button", { name: "快速跳转", exact: true }).click();
  const search = page.getByRole("combobox", { name: "搜索页面和操作" });
  await search.fill("新手引导");
  await search.press("Enter");
  const onboarding = page.getByRole("dialog", { name: "订阅链接", exact: true });
  await expect(onboarding).toBeVisible();
  await onboarding.getByRole("button", { name: "取消", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(trigger).toBeFocused();
});

test("application search is immediately reachable and route details remain available", async ({ page }) => {
  // A connected device adds the runtime status ribbon above the page.
  await page.addInitScript(() => {
    window.ksu = { spawn(_command, _args, _options, callbackName) {
      setTimeout(() => window[callbackName].emit("exit", 0), 0);
    } };
  });
  await page.goto("/#/apps", { waitUntil: "networkidle" });
  const search = page.getByPlaceholder("搜索已安装应用包名", { exact: true });
  await expect(search).toBeVisible();
  const dock = page.locator(".mobile-nav");
  if (page.viewportSize().width <= 430) {
    const searchBounds = await search.boundingBox();
    const dockBounds = await dock.boundingBox();
    expect(searchBounds.y + searchBounds.height).toBeLessThanOrEqual(dockBounds.y);
  }
  const details = page.locator("#app-route-guide-details");
  await expect(details).toBeHidden();
  await page.getByRole("button", { name: "查看详细差异", exact: true }).click();
  await expect(details.locator("article")).toHaveCount(3);
  await expect(details.getByRole("button", { name: "重新解析 App UID", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "收起详细差异", exact: true }).click();
  await expect(details).toBeHidden();
});

test("the empty terminal leaves its input and execute button above the phone dock", async ({ page }) => {
  test.skip(page.viewportSize().width > 430, "Portrait phone layout");
  await page.evaluate(() => { location.hash = "/terminal"; });
  const input = page.getByRole("textbox", { name: "命令", exact: true });
  for (const withDeviceStatus of [false, true]) {
    if (withDeviceStatus) {
      // Device status adds a row above the page that preview mode does not show.
      await page.addInitScript(() => {
        window.ksu = { spawn(_command, _args, _options, callbackName) {
          setTimeout(() => window[callbackName].emit("exit", 0), 0);
        } };
      });
      await page.reload({ waitUntil: "networkidle" });
    }
    await expect(input).toBeVisible();
    const dock = await page.locator(".mobile-nav").boundingBox();
    for (const control of [input, page.getByRole("button", { name: "执行", exact: true })]) {
      const bounds = await control.boundingBox();
      expect(bounds.y + bounds.height, `device status: ${withDeviceStatus}`).toBeLessThanOrEqual(dock.y);
      expect(bounds.height).toBeGreaterThanOrEqual(48);
    }
  }
});
