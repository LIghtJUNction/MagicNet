import { test, expect } from "@playwright/test";

test("pending commands keep navigation responsive and execute in order", async ({ page }) => {
  // This models the native callback protocol; it does not execute Android commands.
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.theme", "light");
    window.__commandBridge = { started: [], callbacks: {}, results: {}, execCalls: 0 };
    window.ksu = {
      exec() {
        window.__commandBridge.execCalls += 1;
        throw new Error("Synchronous exec must never be used");
      },
      spawn(command, _args, _options, callback) {
        const id = command.match(/magicnet-e2e-(first|second)/)?.[1];
        if (id) {
          window.__commandBridge.started.push(id);
          window.__commandBridge.callbacks[id] = callback;
        } else {
          // Allow ordinary App status reads to complete without a device fixture.
          setTimeout(() => window[callback].emit("exit", 0), 0);
        }
      },
    };
  });
  await page.goto("/", { waitUntil: "networkidle" });
  await expect(page.locator(".mn-control")).toBeVisible();
  await expect.poll(() => page.evaluate(async () => {
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    return state.queueDepth === 0 && !state.busy;
  })).toBe(true);

  const start = (id) => page.evaluate(async (id) => {
    const { runShell } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    void runShell(`printf magicnet-e2e-${id}`, `测试命令 ${id}`).then((result) => {
      window.__commandBridge.results[id] = result;
    });
  }, id);
  const finish = (id, stdout, stderr, errno) => page.evaluate(({ id, stdout, stderr, errno }) => {
    const callback = window[window.__commandBridge.callbacks[id]];
    for (const line of stdout) callback.stdout.emit("data", line);
    for (const line of stderr) callback.stderr.emit("data", line);
    callback.emit("exit", errno);
  }, { id, stdout, stderr, errno });

  await start("first");
  await expect.poll(() => page.evaluate(() => window.__commandBridge.started)).toEqual(["first"]);
  await start("second");
  await expect.poll(() => page.evaluate(async () => {
    return (await import("/src/composables/useMagicNet.ts")).useMagicNet().state.queueDepth;
  })).toBe(2);

  // Both actions must complete while the first native exit callback is withheld.
  await page.getByRole("button", { name: /外观主题/ }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  const desktopOutput = page.locator('.desktop-rail [data-tab="output"]');
  if (await desktopOutput.isVisible()) {
    await desktopOutput.click();
  } else {
    await page.locator('[data-workspace="diagnose"]:visible').click();
    await page.locator('.mn-section-tabs [data-tab="output"]:visible').click();
  }
  await expect(page.getByRole("heading", { name: "最近输出", exact: true })).toBeVisible();
  expect(await page.evaluate(() => ({
    started: window.__commandBridge.started,
    results: window.__commandBridge.results,
  }))).toEqual({ started: ["first"], results: {} });

  await finish("first", ["first stdout", "", "中文输出"], ["first stderr"], 0);
  await expect.poll(() => page.evaluate(() => window.__commandBridge.started))
    .toEqual(["first", "second"]);
  await finish("second", ["second stdout", "last line"], ["second stderr"], 7);
  await expect.poll(() => page.evaluate(() => window.__commandBridge.results)).toEqual({
    first: "first stdout\n\n中文输出\nfirst stderr",
    second: "[error] errno=7\nsecond stdout\nlast line\nsecond stderr",
  });
  await expect.poll(() => page.evaluate(async () => {
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    return { phase: state.phase, busy: state.busy, depth: state.queueDepth };
  })).toEqual({ phase: "error", busy: false, depth: 0 });
  await expect(page.locator(".page-surface pre").last())
    .toContainText("[error] errno=7\nsecond stdout\nlast line\nsecond stderr");
  expect(await page.evaluate(() => window.__commandBridge.execCalls)).toBe(0);
});
