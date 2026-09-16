import { expect, test } from "@playwright/test";

const legacyKey = "magicnet.terminal.history.v1";
const legacyValue = JSON.stringify(["old-private-command"]);
async function mount(page, clearFails = false) {
  await page.addInitScript(({ legacyKey, legacyValue, clearFails }) => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem(legacyKey, legacyValue);
    window.__terminalCommands = [];
    window.ksu = {
      spawn(command, _args, _options, callbackName) {
        window.__terminalCommands.push(command);
        const isTestCommand = command.includes("terminal-fixture");
        const isLegacyClear = command.includes("rm -f") && command.includes("terminal_history.txt");
        setTimeout(() => {
          const callback = window[callbackName];
          if (isTestCommand) callback.stdout.emit("data", "terminal-fixture-result");
          callback.emit("exit", isLegacyClear && clearFails ? 1 : 0);
        }, isTestCommand ? 200 : 0);
      },
    };
  }, { legacyKey, legacyValue, clearFails });
  await page.goto("/#/terminal", { waitUntil: "networkidle" });
  await expect(page.locator(".terminal-page input")).toBeEnabled();
}

test("terminal admits a rapid command once, avoids persistence and clears cached-page history", async ({ page }) => {
  await mount(page);
  const input = page.locator(".terminal-page input");
  await input.fill("help terminal-fixture");
  await input.evaluate(element => {
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  await expect(page.locator(".terminal-page pre")).toHaveText("terminal-fixture-result");
  const result = await page.evaluate(key => ({
    runs: window.__terminalCommands.filter(command => command.includes("terminal-fixture")).length,
    disk: window.__terminalCommands.filter(command => command.includes("terminal_history.txt")),
    stored: localStorage.getItem(key),
  }), legacyKey);
  expect(result).toEqual({ runs: 1, disk: [], stored: legacyValue });
  await page.evaluate(() => { location.hash = "/health"; });
  await expect(page.locator(".terminal-page")).not.toBeVisible();
  await page.evaluate(() => { location.hash = "/terminal"; });
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue("");
  await expect(page.locator(".terminal-page pre")).toHaveCount(0);
  await input.press("ArrowUp");
  await expect(input).toHaveValue("");
});

test("explicit legacy clear stays available with empty history and reports a native failure", async ({ page }) => {
  await mount(page, true);
  await page.locator(".terminal-page").getByRole("button", { name: "清空历史", exact: true }).click();
  await expect(page.locator(".terminal-page [role=alert]")).toContainText("旧历史记录未完全清除");
  expect(await page.evaluate(key => localStorage.getItem(key), legacyKey)).toBeNull();
  const calls = await page.evaluate(() => window.__terminalCommands.filter(command => command.includes("terminal_history.txt")));
  expect(calls).toHaveLength(1);
  expect(calls[0]).toContain("rm -f");
});
