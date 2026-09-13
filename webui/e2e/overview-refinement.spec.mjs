import { test, expect } from "@playwright/test";

async function fit(page) {
  expect(
    await page.evaluate(
      () =>
        document.documentElement.scrollWidth <=
        document.documentElement.clientWidth + 1,
    ),
  ).toBe(true);
  for (const button of await page
    .locator(".page-surface button:visible")
    .all()) {
    const box = await button.boundingBox();
    expect(box.height).toBeGreaterThanOrEqual(44);
  }
}

for (const theme of ["light", "dark"]) {
  test(`runtime and subscription hierarchy: ${theme}`, async ({
    page,
  }, info) => {
    await page.addInitScript((theme) => {
      localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
      localStorage.setItem("magicnet.webui.theme", theme);
    }, theme);
    await page.goto("/", { waitUntil: "networkidle" });
    await expect(page.locator(".mn-control")).toBeVisible();
    await page.evaluate(async () => {
      // Display fixture only: no root bridge is installed and no commands run.
      const { state } = (
        await import("/src/composables/useMagicNet.ts")
      ).useMagicNet();
      Object.assign(state, { hasKsu: true, busy: false, phase: "idle" });
      Object.assign(state.runtime, {
        singBoxState: "sing-box",
        singBox: "123",
        singBoxRssKib: 131072,
      });
      Object.assign(state.subscriptions, {
        configuredCount: 1,
        singBoxUrls: ["https://provider.example/subscription"],
        lastResult: "success",
        lastImportedCount: 24,
        sourceUsage: [
          {
            id: "preview",
            index: 1,
            hostname: "provider.example",
            state: "cached",
            uploadBytes: 1073741824,
            downloadBytes: 2147483648,
            totalBytes: 107374182400,
            expireEpoch: null,
            updatedEpoch: 1700000000,
          },
        ],
      });
    });
    await expect(page.locator(".mn-control-memory")).toContainText("128.0");
    await expect(page.locator(".mn-control-memory")).toContainText("MiB");
    await fit(page);
    await page.screenshot({
      path: info.outputPath(`${theme}-runtime.png`),
      fullPage: true,
    });
    await page.evaluate(async () => {
      const { state } = (
        await import("/src/composables/useMagicNet.ts")
      ).useMagicNet();
      state.runtime.singBoxRssKib = null;
    });
    await expect(page.locator(".mn-control-memory")).toContainText("暂不可用");
    await page.evaluate(async () => {
      const { state } = (
        await import("/src/composables/useMagicNet.ts")
      ).useMagicNet();
      state.runtime.singBoxState = "stopped";
    });
    await expect(page.locator(".mn-control-memory")).toHaveCount(0);
    const desktop = page.locator('.desktop-rail [data-tab="subs"]');
    if (await desktop.isVisible()) await desktop.click();
    else await page.locator('[data-workspace="configure"]:visible').click();
    await expect(page.locator(".subscriptions-page")).toBeVisible();
    await expect(page.locator(".update-outcome")).toHaveText("更新成功");
    await expect(page.locator(".source-state")).toHaveText("上次用量");
    await fit(page);
    await page.screenshot({
      path: info.outputPath(`${theme}-subscriptions.png`),
      fullPage: true,
    });
    await page.getByRole("button", { name: "管理来源", exact: true }).click();
    await expect(page.locator(".source-textarea")).toBeFocused();
    await page.getByRole("button", { name: "取消", exact: true }).click();
    await expect(page.locator(".source-textarea")).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "管理来源", exact: true }),
    ).toBeFocused();
    await page.evaluate(async () => {
      const { state } = (
        await import("/src/composables/useMagicNet.ts")
      ).useMagicNet();
      state.subscriptions.updateRunning = true;
    });
    await expect(page.locator(".update-outcome")).toHaveText("更新中");
    await expect(
      page.getByRole("button", { name: "更新订阅", exact: true }),
    ).toBeDisabled();
    await page.evaluate(async () => {
      const { state } = (
        await import("/src/composables/useMagicNet.ts")
      ).useMagicNet();
      state.subscriptions.updateRunning = false;
      state.subscriptions.lastResult = "failed";
      state.subscriptions.sourceUsage[0].totalBytes = null;
    });
    await expect(page.locator(".update-outcome")).toHaveText("更新未完成");
    await expect(page.locator(".subscription-feedback")).toContainText(
      "当前仍保留原有配置",
    );
    await expect(page.locator(".remaining-quota")).toHaveAttribute(
      "data-unavailable",
      "true",
    );
    await fit(page);
  });
}
