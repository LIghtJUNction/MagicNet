import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.theme", "light");
  });
  await page.goto("/", { waitUntil: "networkidle" });
  await expect(page.locator(".mn-control")).toBeVisible();
});

async function setTask(page, task) {
  // Display-only fixture: never install a bridge or execute root commands.
  await page.evaluate(async (task) => {
    const { useMagicNet } = await import("/src/composables/useMagicNet.ts");
    useMagicNet().state.task = task;
  }, task);
}

test("busy buttons keep their geometry, labels and disabled state", async ({ page }) => {
  const buttons = [
    ["刷新面板", "刷新面板", true],
    ["创建 GitHub Issue", "创建 GitHub issue", false],
  ];
  for (const [label, task, iconOnly] of buttons) {
    const button = page.getByRole("button", { name: label, exact: true });
    if (!(await button.isVisible())) continue; // Feedback lives in the desktop toolbar.
    const before = await button.boundingBox();
    const text = await button.innerText();
    await setTask(page, task);
    await expect(button).toHaveAttribute("aria-busy", "true");
    await expect(button).toBeDisabled();
    const during = await button.boundingBox();
    for (const key of ["x", "y", "width", "height"])
      expect(Math.abs(during[key] - before[key])).toBeLessThan(1);
    expect(await button.innerText()).toBe(text);
    await expect(button.locator(".mn-button__content")).toHaveCSS("opacity", iconOnly ? "0" : "1");
    if (!iconOnly) {
      expect(await button.evaluate((el) => getComputedStyle(el, "::after").animationName)).toBe("none");
    }
    await setTask(page, "");
    await expect(button).toBeEnabled();
    await expect(button.locator(".mn-button__content")).toHaveCSS("opacity", "1");
  }
});

test("navigation and disclosure focus remain distinct in both themes", async ({ page }, testInfo) => {
  for (const theme of ["light", "dark"]) {
    if (theme === "dark") await page.getByRole("button", { name: /外观主题/ }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    const mobile = await page.locator(".mobile-nav").isVisible();
    const active = page.locator(mobile ? ".mobile-nav .mn-nav-active" : ".desktop-rail .mn-nav-active");
    await expect(active).toHaveCount(1);
    const colors = await active.evaluate((el) => [getComputedStyle(el).backgroundColor, getComputedStyle(document.body).backgroundColor]);
    expect(colors[0]).not.toBe(colors[1]);
    const summary = page.locator(".mn-disclosure > summary").first();
    await page.keyboard.press("Tab");
    await summary.focus();
    await expect(summary).toBeFocused();
    await expect(summary).toHaveCSS("outline-style", "solid");
    await expect(summary).toHaveCSS("outline-width", "2px");
    await page.screenshot({ path: testInfo.outputPath(`paper-${theme}.png`), fullPage: false });
  }
});
