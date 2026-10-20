import { expect, test } from "@playwright/test";
import { subscriptionData } from "../machine-fixtures.mjs";

// Exercise the real command queue and subscription parser through the native
// callback protocol. No device commands or network subscriptions are executed.
async function mount(page, schedule = {}) {
  await page.addInitScript((data) => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    window.__settings = { data, held: [], writes: [], holdWrites: true, failReads: false };
    window.ksu = { spawn(command, _args, _options, callbackName) {
      const write = command.match(/sub (user-agent|filter|schedule) (set ([A-Za-z0-9+/=]+)|clear)/);
      const respond = () => {
        const fixture = window.__settings;
        const callback = window[callbackName];
        if (write) {
          fixture.writes.push(write[0]);
          const value = write[3] ?? "";
          if (write[1] === "schedule") {
            fixture.data.schedule = { interval_hours: value, enabled: value !== "off", owner: value === "off" ? "none" : "active", running: value !== "off", owner_valid: true };
          } else {
            const decoded = new TextDecoder().decode(Uint8Array.from(atob(value), (c) => c.charCodeAt(0)));
            if (write[1] === "user-agent") fixture.data.configuration.user_agent = decoded;
            else fixture.data.configuration.filters = decoded.trim().split("\n").filter(Boolean);
          }
        } else if (command.includes("--json sub inspect")) {
          if (fixture.failReads) { callback.emit("exit", 1); return; }
          callback.stdout.emit("data", JSON.stringify({ schema: 1, ok: true, command: "sub.inspect", data: fixture.data }));
        }
        callback.emit("exit", 0);
      };
      if (write && window.__settings.holdWrites) window.__settings.held.push(respond);
      else setTimeout(respond, 0);
    } };
  }, subscriptionData({
    source: { mode: "remote_url", configured_count: 0 },
    configuration: { sing_box_urls: [], user_agent: "", filters: [] },
    schedule: { interval_hours: "off", enabled: false, owner: "none", running: false, owner_valid: true, ...schedule },
  }));
  await page.goto("/#/subs", { waitUntil: "networkidle" });
  await page.getByText("订阅设置", { exact: true }).click();
  await expect(page.getByLabel("更新频率", { exact: true })).toBeVisible();
}

async function releaseWrite(page, saveButton) {
  await expect.poll(() => page.evaluate(() => window.__settings.held.length)).toBe(1);
  await page.evaluate(() => {
    window.__settings.holdWrites = false;
    window.__settings.held.splice(0).forEach((respond) => respond());
  });
  await expect(saveButton).not.toHaveAttribute("aria-busy", "true");
}

async function refresh(page) {
  await page.evaluate(async () => {
    await (await import("/src/composables/useMagicNet.ts")).useMagicNet().refreshSubs(true);
  });
}

test("User-Agent edits made during a save survive later device reads", async ({ page }) => {
  await mount(page);
  const input = page.getByLabel("自定义值", { exact: true });
  const save = page.getByRole("button", { name: "保存 User-Agent", exact: true });
  await input.fill("agent-b");
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.held.length)).toBe(1);
  await input.fill("agent-c");
  await releaseWrite(page, save);
  expect(await page.evaluate(() => window.__settings.data.configuration.user_agent)).toBe("agent-b");
  await page.evaluate(() => { window.__settings.data.configuration.user_agent = "agent-device"; });
  await refresh(page);
  await expect(input).toHaveValue("agent-c");
  await expect(save).toBeEnabled();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.data.configuration.user_agent)).toBe("agent-c");
  await expect(save).toBeDisabled();
});

test("filter edits made during a save survive the next subscription refresh", async ({ page }) => {
  await mount(page);
  const add = page.getByRole("button", { name: "添加过滤关键词", exact: true });
  const input = page.getByLabel("自定义节点过滤关键词", { exact: true });
  const save = page.getByRole("button", { name: "保存过滤词", exact: true });
  await input.fill("first");
  await add.click();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.held.length)).toBe(1);
  await input.fill("later");
  await add.click();
  await releaseWrite(page, save);
  expect(await page.evaluate(() => window.__settings.data.configuration.filters)).toEqual(["first"]);
  await refresh(page);
  await expect(page.getByRole("button", { name: "移除过滤词 later", exact: true })).toBeVisible();
  await expect(save).toBeEnabled();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.data.configuration.filters)).toEqual(["first", "later"]);
  await expect(save).toBeDisabled();
});

test("schedule edits made during a save survive later device reads", async ({ page }) => {
  await mount(page);
  const input = page.getByLabel("更新频率", { exact: true });
  const save = page.getByRole("button", { name: "保存更新设置", exact: true });
  await input.selectOption("24");
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.held.length)).toBe(1);
  await input.selectOption("48");
  await releaseWrite(page, save);
  expect(await page.evaluate(() => window.__settings.data.schedule.interval_hours)).toBe("24");
  await page.evaluate(() => { window.__settings.data.schedule.interval_hours = "12"; });
  await refresh(page);
  await expect(input).toHaveValue("48");
  await expect(save).toBeEnabled();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__settings.data.schedule.interval_hours)).toBe("48");
  await expect(save).toBeDisabled();
});

test("an unhealthy automatic update can be restarted without changing its interval", async ({ page }) => {
  await mount(page, { interval_hours: "24", enabled: true, owner: "stale", running: false, owner_valid: false });
  await expect(page.getByText("自动更新暂未正常启动，请重新保存设置。", { exact: true })).toBeVisible();
  const save = page.getByRole("button", { name: "保存更新设置", exact: true });
  await expect(save).toBeEnabled();
  await save.click();
  await releaseWrite(page, save);
  expect(await page.evaluate(() => window.__settings.writes)).toEqual(["sub schedule set 24"]);
  await expect(page.getByText("自动更新已开启", { exact: true })).toBeVisible();
  await expect(save).toBeDisabled();
});

for (const owner of ["unknown", "pending"]) {
  test(`a schedule with ${owner} status cannot be restarted from an unchanged interval`, async ({ page }) => {
    await mount(page, { interval_hours: "24", enabled: true, owner, running: null, owner_valid: owner === "unknown" ? null : false });
    const input = page.getByLabel("更新频率", { exact: true });
    const save = page.getByRole("button", { name: "保存更新设置", exact: true });
    await expect(input).toHaveValue("24");
    await expect(save).toBeDisabled();
    await expect(page.getByText("自动更新状态未确认，请重新读取订阅状态。", { exact: true })).toBeVisible();
    expect(await page.evaluate(() => window.__settings.writes)).toEqual([]);
    await page.evaluate(() => { Object.assign(window.__settings.data.schedule, { owner: "none", running: false, owner_valid: false }); });
    await refresh(page);
    await expect(save).toBeEnabled();
  });
}

test("a failed status read does not enable a restart using the old interval", async ({ page }) => {
  await mount(page, { interval_hours: "24", enabled: true, owner: "active", running: true, owner_valid: true });
  const save = page.getByRole("button", { name: "保存更新设置", exact: true });
  await expect(page.getByLabel("更新频率", { exact: true })).toHaveValue("24");
  await expect(save).toBeDisabled();
  await page.evaluate(() => { window.__settings.failReads = true; });
  await refresh(page);
  await expect(save).toBeDisabled();
  await expect(page.getByText("自动更新状态未确认，请重新读取订阅状态。", { exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.__settings.writes)).toEqual([]);
  await page.evaluate(() => {
    window.__settings.failReads = false;
    window.__settings.data.schedule.interval_hours = "48";
  });
  await refresh(page);
  await expect(page.getByLabel("更新频率", { exact: true })).toHaveValue("48");
  await expect(save).toBeDisabled();
});
