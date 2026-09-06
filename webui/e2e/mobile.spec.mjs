import { test, expect } from "@playwright/test";

const pages = [
  ["run", "control", null],
  ["run", "about", "流量路径"],
  ["route", "apps", "应用名单"],
  ["route", "block", "拦截规则"],
  ["route", "chain", "链式代理"],
  ["configure", "subs", "订阅"],
  ["configure", "config", "配置文件"],
  ["configure", "webui", "面板配置"],
  ["diagnose", "health", "诊断"],
  ["diagnose", "output", "最近输出"],
  ["diagnose", "tools", "工具"],
];

async function settle(page) {
  await expect
    .poll(() =>
      page.evaluate(async () => {
        const { useMagicNet } = await import("/src/composables/useMagicNet.ts");
        const { state } = useMagicNet();
        return (
          state.queueDepth === 0 &&
          !["accepted", "queued", "running"].includes(state.phase)
        );
      }),
    )
    .toBe(true);
}

async function navigate(page, workspace, tab, heading) {
  const desktopPage = page.locator(`.desktop-rail [data-tab="${tab}"]`);
  if (await desktopPage.isVisible()) {
    await desktopPage.click();
  } else {
    await page.locator(`[data-workspace="${workspace}"]:visible`).click();
    await page.locator(`.mn-section-tabs [data-tab="${tab}"]:visible`).click();
  }
  if (heading)
    await expect(page.locator(".page-surface h2").first()).toHaveText(heading);
  else await expect(page.locator(".mn-control")).toBeVisible();
  await settle(page);
}

async function seedView(page, overrides = {}) {
  // The bridge is absent when the module initializes, so no root commands can
  // execute. Only display state is supplied; this is not a device/network test.
  await page.evaluate(async (overrides) => {
    const { useMagicNet } = await import("/src/composables/useMagicNet.ts");
    const { state } = useMagicNet();
    Object.assign(state, {
      hasKsu: true,
      phase: "idle",
      busy: false,
      task: "",
      notice: "",
      output: "Fixture: no device commands were executed.",
      packages: [
        "com.example.reader",
        "com.example.browser",
        "com.example.notes",
      ].map((packageName) => ({ packageName })),
    });
    Object.assign(state.runtime, {
      singBoxState: "sing-box",
      singBox: "running",
      fswatch: "running",
      transparentMode: "tun",
      transparentEffectiveMode: "tun",
      transparentCapability: "available",
      transparentLocalCgroup: "not-required",
      transparentSharedTc: "not-required",
      transparentSharedInterfaces: [],
      transparentRecentError: "",
      transparentTransition: "idle",
      ...overrides,
    });
  }, overrides);
}

async function expectNoHorizontalOverflow(page) {
  const overflow = await page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    const outside = [
      ...document.querySelectorAll(
        "button, input:not([type=hidden]), textarea, select, summary",
      ),
    ]
      .filter((element) => {
        if (element.closest(".mn-section-tabs")) return false; // intentionally scrollable tabs
        if (
          !element.checkVisibility({
            visibilityProperty: true,
            contentVisibilityAuto: true,
          })
        )
          return false;
        const rect = element.getBoundingClientRect();
        return (
          rect.width > 0 &&
          rect.height > 0 &&
          (rect.left < -1 || rect.right > width + 1)
        );
      })
      .map((element) => ({
        tag: element.tagName,
        text: element.textContent?.trim().slice(0, 50),
        label: element.getAttribute("aria-label"),
      }));
    return { page: document.documentElement.scrollWidth > width + 1, outside };
  });
  expect(overflow).toEqual({ page: false, outside: [] });
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    localStorage.setItem("magicnet.webui.theme", "light");
  });
  await page.goto("/", { waitUntil: "networkidle" });
  await expect(page.locator(".mn-control")).toBeVisible();
  await settle(page);
});

test("a fresh browser opens the overview instead of an unusable setup flow", async ({
  page,
}) => {
  await page.evaluate(() =>
    localStorage.removeItem("magicnet.webui.onboarding.v1"),
  );
  // beforeEach's init script belongs to the original page, not this fresh one.
  const fresh = await page.context().newPage();
  try {
    await fresh.goto("/", { waitUntil: "networkidle" });
    await expect(
      fresh.getByRole("heading", { name: "未连接设备" }),
    ).toBeVisible();
    await expect(fresh.getByRole("dialog")).toHaveCount(0);
  } finally {
    await fresh.close();
  }
});

test("all eleven pages fit in both themes", async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  for (const theme of ["light", "dark"]) {
    if (theme === "dark")
      await page.getByRole("button", { name: /外观主题/ }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    for (const [workspace, tab, heading] of pages) {
      await test.step(`${theme}: ${tab}`, async () => {
        await navigate(page, workspace, tab, heading);
        await seedView(page);
        await expectNoHorizontalOverflow(page);
        await page.screenshot({
          path: testInfo.outputPath(`${theme}-${tab}.png`),
          fullPage: false,
        });
        await page.evaluate(() => {
          document
            .querySelectorAll(".page-surface details:not(.config-action-menu)")
            .forEach((detail) => {
              detail.dataset.previousOpen = String(detail.open);
              detail.open = true;
            });
        });
        try {
          await settle(page);
          await seedView(page);
          await expectNoHorizontalOverflow(page);
        } finally {
          await page.evaluate(() => {
            document
              .querySelectorAll("details[data-previous-open]")
              .forEach((detail) => {
                detail.open = detail.dataset.previousOpen === "true";
                delete detail.dataset.previousOpen;
              });
          });
        }
      });
    }
  }
  expect(errors).toEqual([]);
});

test("mode changes use a focus-trapped confirmation, never optimistic state", async ({
  page,
}) => {
  await seedView(page);
  const target = page.getByRole("button", { name: "eBPF", exact: true });
  await target.click();
  const dialog = page.getByRole("alertdialog", { name: "确认控制操作" });
  await expect(dialog).toBeVisible();
  await expect(
    dialog.getByRole("button", { name: "取消", exact: true }),
  ).toBeFocused();
  await expect(
    page.getByRole("button", { name: "TUN", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await expect(target).toHaveAttribute("aria-pressed", "false");
  await expect(page.locator("body")).toHaveCSS("overflow", "hidden");
  await expectNoHorizontalOverflow(page);
  await page.keyboard.press("Shift+Tab");
  await expect(
    dialog.getByRole("button", { name: "继续执行", exact: true }),
  ).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(
    dialog.getByRole("button", { name: "取消", exact: true }),
  ).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await expect(target).toBeFocused();
  await expect(page.locator("body")).not.toHaveCSS("overflow", "hidden");
});

test("device unavailable, stopped, unknown, and failed states remain distinct", async ({
  page,
}) => {
  await expect(page.getByRole("heading", { name: "未连接设备" })).toBeVisible();
  await expect(
    page.getByRole("button", { name: "启动服务", exact: true }),
  ).toBeDisabled();
  await seedView(page, { singBoxState: "stopped" });
  await expect(
    page.getByRole("heading", { name: "已停止", exact: true }),
  ).toBeVisible();
  await seedView(page, {
    singBoxState: "unknown",
    transparentMode: "unknown",
    transparentEffectiveMode: "unknown",
  });
  await expect(
    page.getByRole("heading", { name: "状态未知", exact: true }),
  ).toBeVisible();
  await seedView(page, {
    transparentRecentError: "Fixture: capability check failed",
  });
  await expect(
    page.getByRole("alert").filter({ hasText: "capability check failed" }),
  ).toBeVisible();
  await seedView(page, { singBoxState: "stopped", transparentRecentError: "" });
  await page.evaluate(async () => {
    const { useMagicNet } = await import("/src/composables/useMagicNet.ts");
    useMagicNet().state.output =
      "No cached sing-box nodes found; run cli sub update sing-box";
  });
  await expect(
    page.getByRole("button", { name: "更新订阅并重建节点" }),
  ).toBeVisible();
});

test("native editor preserves drafts and blocks empty or invalid saves", async ({
  page,
}) => {
  await navigate(page, "configure", "config", "配置文件");
  await seedView(page);
  const field = page.locator(".json-editor__textarea");
  const save = page.getByRole("button", {
    name: "校验并保存配置",
    exact: true,
  });
  await expect(save).toBeDisabled();
  const draft = '{\n  "log": { "level": "info" }\n}';
  await field.fill(draft);
  await expect(field).toHaveAttribute("aria-invalid", "false");
  await expect(save).toBeEnabled();
  await navigate(page, "run", "control", null);
  await navigate(page, "configure", "config", "配置文件");
  await expect(field).toHaveValue(draft);
  await field.fill('{ "log": ');
  await expect(field).toHaveAttribute("aria-invalid", "true");
  await expect(page.locator("#json-editor-error")).toBeVisible();
  await expect(save).toBeDisabled();
  await expectNoHorizontalOverflow(page);
});

test("toolbar menus fit the page when opened", async ({ page }) => {
  for (const [workspace, tab, heading] of [pages[2], pages[6], pages[8]]) {
    await navigate(page, workspace, tab, heading);
    const menu = page.locator(".mn-page-actions .config-action-menu");
    await menu.locator("summary").click();
    await expect(menu).toHaveAttribute("open", "");
    await expectNoHorizontalOverflow(page);
    await page.keyboard.press("Escape");
    await expect(menu).not.toHaveAttribute("open", "");
    await expect(menu.locator("summary")).toBeFocused();
    await menu.locator("summary").click();
    await page.locator(".page-surface h2").first().click();
    await expect(menu).not.toHaveAttribute("open", "");
  }
});

test("utility sheet and support are reachable without occupying the overview", async ({
  page,
}) => {
  const trigger = page.getByRole("button", { name: "打开系统工具" });
  await expect(page.getByText("支持项目", { exact: true })).toBeHidden();
  await trigger.click();
  const dialog = page.getByRole("dialog", { name: "系统工具" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText("支持项目", { exact: true })).toBeVisible();
  await expectNoHorizontalOverflow(page);
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await expect(trigger).toBeFocused();
});

test("keyboard gives the field space and restores navigation after editing", async ({
  page,
}) => {
  test.skip(
    page.viewportSize().width >= 980,
    "Desktop uses the side rail, not mobile keyboard navigation.",
  );
  await navigate(page, "configure", "subs", "订阅");
  const field = page.getByRole("textbox", {
    name: "sing-box 订阅 URL，每行一个",
  });
  const original = page.viewportSize();
  await field.fill("https://example.invalid/subscription");
  await page.setViewportSize({
    width: original.width,
    height: Math.max(240, original.height - 280),
  });
  await expect(page.locator(".mobile-nav")).toBeHidden();
  await expect(field).toBeFocused();
  await expectNoHorizontalOverflow(page);
  const bounds = await field.boundingBox();
  expect(bounds.y).toBeGreaterThanOrEqual(0);
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(
    page.viewportSize().height + 1,
  );
  await page.setViewportSize(original);
  await field.blur();
  await expect(page.locator(".mobile-nav")).toBeVisible();
  await navigate(page, "run", "control", null);
  await navigate(page, "configure", "subs", "订阅");
  await expect(field).toHaveValue("https://example.invalid/subscription");
});

test("expanded controls and enlarged text keep actions reachable", async ({
  page,
}) => {
  await seedView(page);
  await page.evaluate(() => {
    document.documentElement.style.fontSize = "200%";
    document.querySelectorAll(".mn-control details").forEach((detail) => {
      detail.open = true;
    });
  });
  await expectNoHorizontalOverflow(page);
  const brand = await page.locator(".mn-brand-copy h1").boundingBox();
  const actions = await page.locator(".mn-global-actions").boundingBox();
  expect(brand.x + brand.width).toBeLessThanOrEqual(actions.x + 1);
  await expect(
    page.getByRole("button", { name: "应用配置", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "应用配置", exact: true }).click();
  await expect(page.getByRole("alertdialog")).toBeVisible();
  await expectNoHorizontalOverflow(page);
});
