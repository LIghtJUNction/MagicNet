import { expect, test } from "@playwright/test";
import { subscriptionData } from "../machine-fixtures.mjs";

async function mount(page, failClear = false) {
  await page.addInitScript(({ data, failClear }) => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    window.__sources = { data, failClear, clears: 0, launches: 0, payload: "", operation: "", local: false, held: [], holdLaunch: false, failLaunch: false };
    window.ksu = { spawn(command, _args, _options, callbackName) {
      const respond = () => {
        const fixture = window.__sources;
        const callback = window[callbackName];
        let output = "", status = 0;
        if (command.includes("--json sub inspect")) output = JSON.stringify({ schema: 1, ok: true, command: "sub.inspect", data: fixture.data });
        else if (command.includes("sub clear")) {
          fixture.clears++;
          if (fixture.failClear) status = 1;
          else {
            fixture.data.configuration.sing_box_urls = [];
            fixture.data.source = { mode: "remote_url", configured_count: 0 };
            // Keep old usage deliberately: the UI must not resurrect this row.
          }
        } else if (command.includes("webui payload create subscription")) {
          fixture.payload = "";
          const basename = command.match(/magicnet-(?:webui|local)-[a-z0-9-]+\.(?:txt|list|b64)/)?.[0];
          output = `/data/adb/modules/MagicNet/.tmp/webui-subscription/${basename}`;
        } else if (command.includes("webui payload append subscription")) {
          // Decode the quoted payload argument, including short URL chunks.
          const innerCommand = command.replaceAll("'\\''", "'");
          const chunk = innerCommand.match(/webui payload append subscription '[^']+' '([A-Za-z0-9+/]+={0,2})'/)?.[1];
          if (!chunk) { callback.emit("exit", 1); return; }
          fixture.payload += new TextDecoder().decode(Uint8Array.from(atob(chunk), (c) => c.charCodeAt(0)));
        } else if (command.includes("[accepted] id=")) {
          fixture.operation = command.match(/\[accepted\] id=([a-z0-9-]+)/)[1];
          fixture.launches++;
          fixture.local = command.includes("apply-subscription-source");
          if (!fixture.failLaunch) {
            fixture.data.configuration.sing_box_urls = fixture.local ? [] : fixture.payload.trim().split("\n");
            fixture.data.source = { mode: fixture.local ? "local_file" : "remote_url", configured_count: fixture.local ? 1 : fixture.data.configuration.sing_box_urls.length };
            fixture.data.last = { ...fixture.data.last, attempt_epoch: 2, success_epoch: 2, generation_id: `new-generation-${fixture.launches}`, imported_count: 1 };
            fixture.data.source_usage = [];
          }
          output = `[accepted] id=${fixture.operation}`;
        } else if (command.includes("[task log] id=")) output = `[launch] id=${fixture.operation} label=fixture\n[exit] id=${fixture.operation} status=${fixture.failLaunch ? 1 : 0}`;
        if (output) callback.stdout.emit("data", output);
        callback.emit("exit", status);
      };
      if (window.__sources.holdLaunch && command.includes("[accepted] id=")) window.__sources.held.push(respond);
      else setTimeout(respond, 20);
    } };
  }, { data: subscriptionData({ source_usage: [{ id: "a".repeat(64), index: 1, hostname: "provider.example", state: "cached", upload_bytes: 1, download_bytes: 2, total_bytes: 100, expire_epoch: null, updated_epoch: 1700000000 }] }), failClear });
  await page.goto("/#/subs", { waitUntil: "networkidle" });
  await expect(page.getByRole("button", { name: "管理来源", exact: true })).toBeEnabled();
}

test("removing every source needs confirmation and does not restore stale provider cards", async ({ page }, info) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await page.getByLabel("订阅链接，每行一个", { exact: true }).fill("");
  await page.getByRole("button", { name: "移除所有来源", exact: true }).click();
  expect(await page.evaluate(() => window.__sources.clears)).toBe(0);
  await page.getByRole("button", { name: "确认移除", exact: true }).click();
  await expect(page.getByText("来源已移除。当前核心配置保持不变。", { exact: true })).toBeVisible();
  await expect(page.locator(".usage-source")).toHaveCount(0);
  await expect(page.getByLabel("订阅链接，每行一个", { exact: true })).toHaveValue("");
  await page.evaluate(() => { location.hash = "/output"; });
  await expect(page.locator('.page-surface[data-page="output"]')).toBeVisible();
  await page.evaluate(() => { location.hash = "/subs"; });
  await expect(page.getByText("添加第一个订阅", { exact: true })).toBeVisible();
  await expect(page.locator(".usage-source")).toHaveCount(0);
  expect(await page.evaluate(() => window.__sources.launches)).toBe(0);
  await page.screenshot({ path: info.outputPath("subscription-removed.png"), fullPage: true });
});

test("a rejected clear keeps sources and shows a retryable failure", async ({ page }) => {
  await mount(page, true);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await page.getByLabel("订阅链接，每行一个", { exact: true }).fill("");
  await page.getByRole("button", { name: "移除所有来源", exact: true }).click();
  await page.getByRole("button", { name: "确认移除", exact: true }).click();
  await expect(page.getByText("来源未移除，请重新读取状态后重试。", { exact: true })).toBeVisible();
  await expect(page.locator(".usage-source")).toHaveCount(1);
  expect(await page.evaluate(() => window.__sources.data.configuration.sing_box_urls.length)).toBe(1);
});

test("a Clash file import completes instead of leaving a permanent pending state", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await page.locator('input[type="file"]').setInputFiles({ name: "fixture.yaml", mimeType: "application/yaml", buffer: Buffer.from('proxies:\n  - {name: test, type: trojan, server: test.invalid, port: 443, password: fixture}\n') });
  await expect.poll(() => page.evaluate(() => window.__sources.launches)).toBe(1);
  await expect(page.getByText("本地订阅文件", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "更新订阅", exact: true })).toBeEnabled({ timeout: 10_000 });
  await expect.poll(() => page.evaluate(async () => (await import('/src/composables/useMagicNet.ts')).useMagicNet().state.backgroundTask.status)).toBe("done");
});

test("replacing a URL updates the persisted source and completes its task", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await page.getByLabel("订阅链接，每行一个", { exact: true }).fill("https://new-provider.example/subscription");
  await page.getByRole("button", { name: "保存并应用", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__sources.launches)).toBe(1);
  await expect.poll(() => page.evaluate(async () => (await import('/src/composables/useMagicNet.ts')).useMagicNet().state.backgroundTask.status)).toBe("done");
  expect(await page.evaluate(() => window.__sources.data.configuration.sing_box_urls)).toEqual(["https://new-provider.example/subscription"]);
  await expect(page.getByRole("heading", { name: "provider.example", exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "new-provider.example", exact: true })).toBeVisible();
});

async function finish(page, status = "done") {
  await expect.poll(() => page.evaluate(async () => (await import('/src/composables/useMagicNet.ts')).useMagicNet().state.backgroundTask.status)).toBe(status);
}
async function holdLaunch(page) {
  await page.evaluate(() => { window.__sources.holdLaunch = true; });
}
async function releaseLaunch(page) {
  await expect.poll(() => page.evaluate(() => window.__sources.held.length)).toBe(1);
  await page.evaluate(() => { window.__sources.holdLaunch = false; window.__sources.held.splice(0).forEach((respond) => respond()); });
}

test("editing after requesting clear invalidates the old confirmation", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  const editor = page.getByLabel("订阅链接，每行一个", { exact: true });
  await editor.fill("");
  await page.getByRole("button", { name: "移除所有来源", exact: true }).click();
  await expect(page.getByRole("button", { name: "确认移除", exact: true })).toBeVisible();
  await editor.fill("https://later.invalid/sub");
  await expect(page.getByRole("button", { name: "确认移除", exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => window.__sources.clears)).toBe(0);
});

test("apply B then edit C keeps C unsaved when the device accepts B", async ({ page }, info) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  const editor = page.getByLabel("订阅链接，每行一个", { exact: true });
  await editor.fill("https://b.invalid/sub");
  await holdLaunch(page);
  await page.getByRole("button", { name: "保存并应用", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__sources.held.length)).toBe(1);
  await editor.fill("https://c.invalid/sub");
  await releaseLaunch(page);
  await finish(page);
  expect(await page.evaluate(() => window.__sources.data.configuration.sing_box_urls)).toEqual(["https://b.invalid/sub"]);
  await expect(editor).toHaveValue("https://c.invalid/sub");
  await expect(page.getByText("有未保存的更改", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "保存并应用", exact: true })).toBeEnabled();
  await page.screenshot({ path: info.outputPath("subscription-newer-draft.png"), fullPage: true });
});

test("a failed apply retains the old source and edited draft for retry", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  const editor = page.getByLabel("订阅链接，每行一个", { exact: true });
  await editor.fill("https://b.invalid/sub");
  await page.evaluate(() => { window.__sources.failLaunch = true; });
  await page.getByRole("button", { name: "保存并应用", exact: true }).click();
  await finish(page, "error");
  await expect(editor).toHaveValue("https://b.invalid/sub");
  await expect(page.getByRole("heading", { name: "provider.example", exact: true })).toBeVisible();
  await page.evaluate(() => { window.__sources.failLaunch = false; });
  await page.getByRole("button", { name: "保存并应用", exact: true }).click();
  await finish(page);
  expect(await page.evaluate(() => window.__sources.data.configuration.sing_box_urls)).toEqual(["https://b.invalid/sub"]);
});

test("source list supports add remove reorder replace clear and re-add", async ({ page }) => {
  await mount(page);
  const editor = page.getByLabel("订阅链接，每行一个", { exact: true });
  const lists = [
    ["https://a.invalid/sub", "https://b.invalid/sub"],
    ["https://b.invalid/sub", "https://a.invalid/sub"],
    ["https://b.invalid/sub"],
    ["https://c.invalid/sub"],
  ];
  for (const list of lists) {
    await page.getByRole("button", { name: "管理来源", exact: true }).click();
    await editor.fill(list.join("\n"));
    const oldLaunches = await page.evaluate(() => window.__sources.launches);
    await page.getByRole("button", { name: "保存并应用", exact: true }).click();
    await expect.poll(() => page.evaluate(() => window.__sources.launches)).toBe(oldLaunches + 1);
    await finish(page);
    expect(await page.evaluate(() => window.__sources.data.configuration.sing_box_urls)).toEqual(list);
    await expect(page.locator(".usage-source")).toHaveCount(list.length);
  }
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await editor.fill("");
  await page.getByRole("button", { name: "移除所有来源", exact: true }).click();
  await page.getByRole("button", { name: "确认移除", exact: true }).click();
  await expect(page.getByText("添加第一个订阅", { exact: true })).toBeVisible();
  await editor.fill("https://d.invalid/sub");
  await page.getByRole("button", { name: "添加并启用", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__sources.launches)).toBe(5);
  await finish(page);
  await expect(page.locator(".usage-source")).toHaveCount(1);
});

test("local import does not overwrite edits made while it is downloading", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await holdLaunch(page);
  await page.locator('input[type="file"]').setInputFiles({ name: "fixture.yaml", mimeType: "application/yaml", buffer: Buffer.from('proxies: [{name: test, type: trojan, server: test.invalid, port: 443, password: fixture}]\n') });
  await expect.poll(() => page.evaluate(() => window.__sources.held.length)).toBe(1);
  const editor = page.getByLabel("订阅链接，每行一个", { exact: true });
  await editor.fill("https://later.invalid/sub");
  await releaseLaunch(page);
  await finish(page);
  await expect(editor).toHaveValue("https://later.invalid/sub");
  await expect(page.getByText("本地订阅文件", { exact: true })).toBeVisible();
});

test("over-limit input cannot silently remove a source", async ({ page }) => {
  await mount(page);
  await page.getByRole("button", { name: "管理来源", exact: true }).click();
  await page.getByLabel("订阅链接，每行一个", { exact: true }).fill(Array.from({ length: 6 }, (_, i) => `https://${i}.invalid/sub`).join("\n"));
  await expect(page.getByRole("button", { name: "保存并应用", exact: true })).toBeDisabled();
  expect(await page.evaluate(() => window.__sources.launches)).toBe(0);
});
