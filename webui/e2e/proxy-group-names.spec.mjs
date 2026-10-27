import { expect, test } from "@playwright/test";

test("prototype-named groups survive refresh, latency updates and raw-tag selection", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/e2e/proxy-group-names-fixture.html", (route) => route.fulfill({
    contentType: "text/html",
    body: '<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width, initial-scale=1"><body><main id="proxy-fixture" style="padding:16px"></main></body></html>',
  }));
  await page.goto("/e2e/proxy-group-names-fixture.html");
  await page.evaluate(async () => {
    window.__proxyCommands = [];
    window.__proxyReads = 0;
    const names = ["constructor", "__proto__", "toString", "hasOwnProperty"];
    const choices = new Map(names.map((name) => [name, "proxy"]));
    const { shellQuote } = await import("/src/utils.ts");
    const { CLI } = await import("/src/constants.ts");
    window.__expectedSelection = `su -M -c ${shellQuote(`${CLI} api select ${shellQuote("constructor")} ${shellQuote("direct")}`)}`;
    window.ksu = {
      spawn(command, _args, _options, callbackName) {
        setTimeout(() => {
          const callback = window[callbackName];
          let output = "fixture.unsupported_command";
          let errno = 1;
          if (command.includes("api proxies")) {
            window.__proxyReads += 1;
            output = JSON.stringify({ proxies: Object.fromEntries(names.map((name) => [
              name, { type: "Selector", now: choices.get(name), all: ["proxy", "direct"] },
            ])) });
            errno = 0;
          } else if (command.includes("node test-all")) {
            output = "proxy=150ms\ndirect=20ms";
            errno = 0;
          } else if (command === window.__expectedSelection) {
            window.__proxyCommands.push(command);
            choices.set("constructor", "direct");
            output = "fixture.selected";
            errno = 0;
          }
          callback.stdout.emit("data", output);
          callback.emit("exit", errno);
        }, 0);
      },
    };
    const { createApp } = await import("/e2e/vue-fixture.mjs");
    await import("/src/styles.css");
    const { setLocale } = await import("/src/i18n/index.ts");
    setLocale("zh-CN");
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    state.hasKsu = true;
    const { default: Component } = await import("/src/components/pages/ProxyGroupsPage.vue");
    createApp(Component).mount("#proxy-fixture");
  });

  const groups = page.locator(".proxy-group");
  const group = (name) => groups.filter({ has: page.getByRole("heading", { name, exact: true }) });
  await expect(groups).toHaveCount(4);
  await page.getByRole("button", { name: "刷新", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__proxyReads)).toBe(2);
  await expect(groups).toHaveCount(4);
  for (const name of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
    await expect(group(name).getByRole("heading", { name, exact: true })).toBeVisible();
  }

  await group("constructor").getByRole("button", { name: "测速本组", exact: true }).click();
  await expect(group("constructor").getByRole("button", { name: "使用最快", exact: true })).toBeEnabled();
  await expect(groups).toHaveCount(4);
  await expect(group("__proto__").getByRole("button", { name: "使用最快", exact: true })).toBeDisabled();
  await group("__proto__").getByRole("button", { name: "测速本组", exact: true }).click();
  await expect(group("__proto__").getByRole("button", { name: "使用最快", exact: true })).toBeEnabled();
  await expect(group("constructor").getByRole("button", { name: "使用最快", exact: true })).toBeEnabled();

  await group("constructor").getByRole("button", { name: "使用最快", exact: true }).click();
  await page.getByRole("button", { name: "确认切换", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__proxyCommands)).toEqual([
    await page.evaluate(() => window.__expectedSelection),
  ]);
  await expect(group("constructor").getByRole("button", { name: /^直连 \(direct\) 已选择/ })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "刷新", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__proxyReads)).toBe(4);
  await expect(groups).toHaveCount(4);
  await expect(group("constructor").getByRole("button", { name: "使用最快", exact: true })).toBeDisabled();
  expect(errors).toEqual([]);
});
