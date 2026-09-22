import { expect, test } from "@playwright/test";
import { subscriptionSnapshot } from "../machine-fixtures.mjs";

const pages = ["control", "subs", "tailscale", "apps", "block", "chain", "config", "webui", "health", "terminal", "output", "tools", "about"];
for (const theme of ["light", "dark"]) {
  test(`every shipped page has a usable layout: ${theme}`, async ({ page }, info) => {
    // Native responses are display fixtures, not Android/KernelSU acceptance.
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(({ theme, subscription }) => {
      localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
      localStorage.setItem("magicnet.webui.theme", theme);
      window.ksu = { spawn(command, _args, _options, callbackName) {
        setTimeout(() => {
          const callback = window[callbackName];
          let output = "";
          if (command.includes("config-editor get sing-box")) output = JSON.stringify({ outbounds: [{ type: "direct", tag: "direct" }], route: { final: "direct" } });
          else if (command.includes("--json sub inspect")) output = subscription;
          if (output) callback.stdout.emit("data", output);
          callback.emit("exit", 0);
        }, 0);
      } };
    }, { theme, subscription: subscriptionSnapshot() });
    await page.goto("/", { waitUntil: "networkidle" });
    for (const id of pages) {
      await page.evaluate((id) => { location.hash = "/" + id; }, id);
      const surface = page.locator(`.page-surface[data-page="${id}"]`);
      await expect(surface).toBeVisible();
      await expect(surface.locator("h2").first()).toBeVisible();
      await page.evaluate(async () => {
        await document.fonts.ready;
        if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
        window.scrollTo({ top: 0, behavior: "instant" });
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1), id).toBe(true);
      await page.screenshot({ path: info.outputPath(`${theme}-${id}.png`), fullPage: true, timeout: 20_000 });
    }
    expect(errors).toEqual([]);
  });
}

test("advanced tools retain their native disclosure and keyboard access", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed"));
  await page.goto("/#/tools", { waitUntil: "networkidle" });
  const sections = page.locator(".tools-sections > details");
  await expect(sections).toHaveCount(7);
  await expect(page.locator(".tools-sections > details[open]")).toHaveCount(0);
  for (const section of await sections.all()) {
    const summary = section.locator(":scope > summary");
    await summary.focus();
    await summary.press("Enter");
    await expect(section).toHaveAttribute("open", "");
    await expect(section.locator(".mn-section-disclosure__body")).toBeVisible();
    await summary.press("Enter");
    await expect(section).not.toHaveAttribute("open", "");
  }
});
