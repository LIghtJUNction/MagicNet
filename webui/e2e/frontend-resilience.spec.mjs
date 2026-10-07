import { expect, test } from "@playwright/test";

const tabs = ["control", "subs", "tailscale", "apps", "block", "chain", "webui", "health", "terminal", "output", "tools", "about"];

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.locale", "zh-CN");
  });
});

async function navigate(page, tab) {
  await page.evaluate((tab) => { location.hash = `/${tab}`; }, tab);
  await expect(page.locator(`.page-surface[data-page="${tab}"] h2`).first()).toBeVisible();
}

test("a configuration draft survives a visit to all thirteen pages", async ({ page }) => {
  await page.goto("/#/config");
  const draft = '{"outbounds": [], "route": {"final": "unsaved-draft"}}';
  await page.locator(".json-editor__textarea").fill(draft);
  for (const tab of tabs) await navigate(page, tab);
  await navigate(page, "config");
  await expect(page.locator(".json-editor__textarea")).toHaveValue(draft);
});

test("a failed page load stays local and preserves drafts on other pages", async ({ page }, info) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/src/components/pages/ProxyChainPage.vue*", (route) => route.abort("failed"));
  await page.goto("/#/config");
  await page.locator(".json-editor__textarea").fill('{"draft": true}');
  await navigate(page, "chain");
  await expect(page.getByRole("alert")).toContainText("页面未能加载");
  await expect(page.getByRole("button", { name: "重新加载此页" })).toBeEnabled();
  await page.screenshot({ path: info.outputPath("page-load-recovery.png"), fullPage: true });
  await navigate(page, "config");
  await expect(page.locator(".json-editor__textarea")).toHaveValue('{"draft": true}');
  expect(errors).toEqual([]);
});

test("retry replaces only a failed attempt and forwards page events", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  await page.evaluate(async () => {
    const { createApp, h } = await import("/e2e/vue-fixture.mjs");
    const { createRecoverablePage } = await import("/src/lib/recoverablePage.ts");
    const host = document.createElement("div");
    host.id = "retry-fixture";
    host.style.cssText = "padding:24px;margin-bottom:120px";
    document.body.append(host);
    window.__attempts = 0;
    window.__pageEvents = 0;
    const Page = createRecoverablePage(async () => {
      if (++window.__attempts === 1) throw new Error("private fixture detail");
      return { default: { emits: ["goto-tab"], setup: (_, { emit }) => () => h("button", { onClick: () => emit("goto-tab", "config") }, "Recovered page") } };
    });
    createApp({ render: () => h(Page, { "onGoto-tab": () => window.__pageEvents++ }) }).mount(host);
  });
  const fixture = page.locator("#retry-fixture");
  await expect(fixture.getByRole("alert")).toBeVisible();
  await expect(fixture).not.toContainText("private fixture detail");
  await fixture.getByRole("button", { name: "重新加载此页" }).click();
  await fixture.getByRole("button", { name: "Recovered page" }).click();
  expect(await page.evaluate(() => [window.__attempts, window.__pageEvents])).toEqual([2, 1]);
  await expect(page.locator(".mn-control")).toBeVisible();
});

test("slow page loads show a bounded error and remain retryable", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  await page.clock.install();
  await page.evaluate(async () => {
    const { createApp, h } = await import("/e2e/vue-fixture.mjs");
    const { createRecoverablePage } = await import("/src/lib/recoverablePage.ts");
    const host = document.createElement("div");
    host.id = "timeout-fixture";
    host.style.cssText = "padding:24px;margin-bottom:120px";
    document.body.append(host);
    let attempts = 0;
    const Page = createRecoverablePage(() => ++attempts === 1
      ? new Promise(() => {})
      : Promise.resolve({ default: { render: () => h("p", "Timeout recovered") } }));
    createApp(Page).mount(host);
  });
  await page.clock.fastForward(150);
  await expect(page.locator("#timeout-fixture [role=status]")).toBeVisible();
  await page.clock.fastForward(20_001);
  await expect(page.locator("#timeout-fixture [role=alert]")).toBeVisible();
  await page.locator("#timeout-fixture").getByRole("button").click();
  await expect(page.locator("#timeout-fixture")).toHaveText("Timeout recovered");
});

test("confirmation starts on Cancel, handles Escape, and restores the trigger", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  await page.evaluate(async () => {
    const { createApp, h, ref } = await import("/e2e/vue-fixture.mjs");
    const { default: ConfirmPanel } = await import("/src/components/ui/ConfirmPanel.vue");
    const host = document.createElement("div");
    host.id = "confirm-fixture";
    host.style.cssText = "padding:24px;margin-bottom:120px";
    document.body.append(host);
    window.__confirms = 0;
    window.__confirmationLoading = ref(false);
    createApp({ setup() {
      const open = ref(false);
      return () => h("div", [
        h("button", { id: "confirm-trigger", onClick: () => { open.value = true; } }, "Open confirmation"),
        open.value ? h(ConfirmPanel, {
          title: "Review changes", loading: window.__confirmationLoading.value,
          onCancel: () => { open.value = false; }, onConfirm: () => window.__confirms++,
        }, { default: () => h("input", { "aria-label": "Supporting value" }) }) : null,
      ]);
    } }).mount(host);
  });
  const fixture = page.locator("#confirm-fixture");
  await fixture.getByRole("button", { name: "Open confirmation" }).click();
  await expect(fixture.getByRole("button", { name: "取消", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.locator("#confirm-trigger")).toBeFocused();
  expect(await page.evaluate(() => window.__confirms)).toBe(0);
  await page.locator("#confirm-trigger").click();
  await page.evaluate(() => { window.__confirmationLoading.value = true; });
  await expect(fixture.getByRole("button", { name: "取消", exact: true })).toBeDisabled();
  await fixture.locator('[tabindex="-1"][aria-busy=true]').focus();
  await page.keyboard.press("Escape");
  await expect(fixture.getByRole("heading", { name: "Review changes" })).toBeVisible();
});

test("focus trap follows native summaries, disabled fields and radio groups", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  await page.evaluate(async () => {
    const { trapFocusWithin } = await import("/src/lib/focus.ts");
    const host = document.createElement("section");
    host.id = "focus-fixture";
    host.tabIndex = -1;
    host.innerHTML = `<h2 tabindex="-1">Test dialog</h2><details><summary>Options</summary><button>Hidden detail</button></details>
      <fieldset disabled><input aria-label="Disabled by fieldset"></fieldset><input type="hidden">
      <button tabindex="-1">Not in Tab order</button><button style="visibility:hidden">Invisible</button>
      <div inert><button>Inert</button></div><input type="radio" name="fixture-choice" aria-label="First">
      <input type="radio" name="fixture-choice" checked aria-label="Selected">`;
    host.addEventListener("keydown", (event) => trapFocusWithin(event, host));
    host.style.cssText = "padding:24px;margin-bottom:120px";
    document.body.append(host);
    host.focus();
  });
  const host = page.locator("#focus-fixture");
  await page.keyboard.press("Shift+Tab");
  await expect(host.getByRole("radio", { name: "Selected" })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(host.locator("summary")).toBeFocused();
  await host.locator("h2").focus();
  await page.keyboard.press("Shift+Tab");
  await expect(host.getByRole("radio", { name: "Selected" })).toBeFocused();
});

test("feedback keeps controls in the visible viewport and locks edits while sending", async ({ page }, info) => {
  await page.goto("/");
  await page.evaluate(async () => {
    const { useMagicNet } = await import("/src/composables/useMagicNet.ts");
    useMagicNet().state.issueReporter.open = true;
  });
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("button", { name: "取消创建 Issue" })).toBeFocused();
  await dialog.getByRole("radio").nth(1).check();
  await dialog.locator("#issue-summary").fill("测试反馈说明");
  await page.evaluate(() => {
    Object.defineProperty(visualViewport, "height", { configurable: true, value: 310 });
    Object.defineProperty(visualViewport, "offsetTop", { configurable: true, value: 70 });
    visualViewport.dispatchEvent(new Event("resize"));
  });
  await expect.poll(async () => {
    const box = await dialog.boundingBox();
    return box.y >= 70 && box.y + box.height <= 381;
  }).toBe(true);
  await page.screenshot({ path: info.outputPath("feedback-keyboard.png"), fullPage: false });
  await page.evaluate(async () => {
    (await import("/src/composables/useMagicNet.ts")).useMagicNet().state.task = "创建 GitHub issue";
  });
  await expect(dialog.locator("#issue-summary")).toBeDisabled();
  await expect(dialog.getByRole("button", { name: "取消创建 Issue" })).toBeDisabled();
  await dialog.focus();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
});

test("skip navigation preserves the route and titles follow the active language", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  await page.keyboard.press("Tab");
  await expect(page.locator(".mn-skip-link")).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("#mn-main")).toBeFocused();
  await expect(page).toHaveURL(/#\/control$/);
  await expect(page).toHaveTitle("概览 · MagicNet");
  await page.evaluate(async () => { (await import("/src/i18n/index.ts")).setLocale("en"); });
  await expect(page).toHaveTitle("Overview · MagicNet");
});


test("closing feedback restores the visible invoking control", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".mn-control")).toBeVisible();
  const desktop = page.getByRole("button", { name: "创建 GitHub Issue", exact: true });
  const trigger = await desktop.isVisible() ? desktop : page.locator(".mn-more-action");
  await trigger.click();
  if (!(await desktop.isVisible())) {
    await page.locator(".mn-utility-sheet").getByRole("button", { name: "反馈问题" }).click();
  }
  await expect(page.getByRole("dialog").getByRole("button", { name: "取消创建 Issue" })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(trigger).toBeFocused();
});
