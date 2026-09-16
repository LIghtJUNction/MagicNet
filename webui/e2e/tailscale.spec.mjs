import { expect, test } from "@playwright/test";

const authKey = ["tskey", "auth", "browser-fixture-not-real"].join("-");
async function mount(page, failure = "") {
  await page.addInitScript(({ failure, authKey }) => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    const config = { outbounds: [{ type: "direct", tag: "direct" }], route: { final: "direct" } };
    window.__tailscale = { config, payload: "", saves: 0, restarts: 0, removals: 0, failure, loginState: failure === "browser" ? "NeedsLogin" : "Running", loginOpened: false };
    window.ksu = {
      spawn(command, _args, _options, callbackName) {
        setTimeout(() => {
          const callback = window[callbackName];
          const fixture = window.__tailscale;
          let output = "";
          let errno = 0;
          if (command.includes("config-editor get sing-box")) output = JSON.stringify(fixture.config);
          else if (command.includes("api tailscale-status")) output = JSON.stringify({state:fixture.loginState,online:fixture.loginState === "Running",auth_url:fixture.loginState === "Running" ? "" : "https://login.tailscale.com/a/fixtureAuth"});
          else if (command.includes("am start") && command.includes("login.tailscale.com/a/fixtureAuth")) fixture.loginOpened = true;
          else if (command.includes("webui payload create tmp")) {
            const basename = command.match(/tailscale-[0-9]+-[a-z0-9]+\.json/)?.[0];
            fixture.payload = "";
            output = `/data/adb/modules/MagicNet/.tmp/webui-payload/${basename}`;
          } else if (command.includes("webui payload append tmp")) {
            const chunks = command.match(/[a-zA-Z0-9+/]{32,}={0,2}/g);
            fixture.payload += new TextDecoder().decode(Uint8Array.from(atob(chunks.at(-1)), (char) => char.charCodeAt(0)));
          } else if (command.includes("webui payload remove tmp")) fixture.removals += 1;
          else if (command.includes("config-editor save-file sing-box")) {
            fixture.saves += 1;
            if (fixture.failure === "validation") { errno = 1; output = `private validator detail ${authKey}`; }
            else {
              fixture.config = JSON.parse(fixture.payload);
              fixture.config.endpoints.forEach((endpoint) => { delete endpoint.auth_key; });
              output = "[info] Saved and validated sing-box config";
            }
          } else if (command.includes("service restart sing-box")) {
            fixture.restarts += 1;
            if (fixture.failure === "restart") errno = 1;
          }
          if (output) callback.stdout.emit("data", output);
          callback.emit("exit", errno);
        }, command.includes("config-editor save-file") ? 120 : 0);
      },
    };
  }, { failure, authKey });
  await page.goto("/#/tailscale", { waitUntil: "networkidle" });
  await expect(page.getByLabel("设备名称", { exact: true })).toBeEnabled();
}

async function fill(page) {
  await page.getByLabel("设备名称", { exact: true }).fill("my-phone");
  await page.getByLabel("Auth key", { exact: true }).fill(authKey);
}
async function expectNoSecret(page) {
  await expect(page.getByLabel("Auth key", { exact: true })).toHaveValue("");
  const displayed = await page.evaluate(async () => {
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    return [state.output, state.notice, state.lastCommand, JSON.stringify(state.operationCapture), JSON.stringify(localStorage), JSON.stringify(sessionStorage), document.body.innerText].join("\n");
  });
  expect(displayed).not.toContain(authKey);
}

test("connects without JSON editing, prevents duplicate submission and keeps secrets private", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await mount(page);
  await fill(page);
  await page.locator(".tailscale-page form").evaluate((form) => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  await expect(page.getByRole("status").filter({ hasText: "配置已保存，核心已重启" })).toBeVisible();
  expect(await page.evaluate(() => ({ saves: window.__tailscale.saves, restarts: window.__tailscale.restarts, removals: window.__tailscale.removals }))).toEqual({ saves: 1, restarts: 1, removals: 1 });
  expect(await page.evaluate(() => window.__tailscale.config.endpoints[0].hostname)).toBe("my-phone");
  await expectNoSecret(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1)).toBe(false);
  expect(errors).toEqual([]);
});

test("browser login opens the core authorization URL and confirms Running without a key", async ({page}) => {
  await mount(page, "browser");
  await page.getByRole('button', {name:'登录 Tailscale 并自动配置',exact:true}).click();
  await expect.poll(() => page.evaluate(() => window.__tailscale.loginOpened)).toBe(true);
  expect(await page.evaluate(() => window.__tailscale.config.endpoints[0].auth_key)).toBeUndefined();
  await expect(page.getByText('等待 Tailscale 登录授权，请在浏览器完成后返回。',{exact:true})).toBeVisible();
  expect(await page.locator('body').innerText()).not.toContain('fixtureAuth');
  await page.evaluate(() => { window.__tailscale.loginState = 'Running'; });
  await expect(page.getByText('Tailscale 已登录，正由 sing-box 连接。配置已自动生效。',{exact:true})).toBeVisible();
  expect(await page.evaluate(() => window.__tailscale.restarts)).toBe(1);
});

test("validation failure does not restart or expose validator output", async ({ page }) => {
  await mount(page, "validation");
  await fill(page);
  await page.getByRole("button", { name: "接入并重启", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "配置保存未确认" })).toBeVisible();
  expect(await page.evaluate(() => window.__tailscale.restarts)).toBe(0);
  expect(await page.evaluate(() => window.__tailscale.removals)).toBe(1);
  await expectNoSecret(page);
});

test("restart failure can be retried without another key or config save", async ({ page }) => {
  await mount(page, "restart");
  await fill(page);
  await page.getByRole("button", { name: "接入并重启", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "配置已保存，但核心重启失败" })).toBeVisible();
  await page.evaluate(() => { window.__tailscale.failure = ""; });
  await page.getByRole("button", { name: "重试重启核心", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "配置已保存，核心已重启" })).toBeVisible();
  expect(await page.evaluate(() => ({ saves: window.__tailscale.saves, restarts: window.__tailscale.restarts }))).toEqual({ saves: 1, restarts: 2 });
  await expectNoSecret(page);
});

test("leaving the cached page clears only the key, not the device-name draft", async ({ page }) => {
  await mount(page);
  await fill(page);
  await page.evaluate(() => { window.location.hash = "/output"; });
  await expect(page.locator(".page-surface")).toHaveAttribute("data-page", "output");
  await page.evaluate(() => { window.location.hash = "/tailscale"; });
  await expect(page.getByLabel("设备名称", { exact: true })).toHaveValue("my-phone");
  await expectNoSecret(page);
});

test("unsaved JSON editor work blocks the form instead of being discarded", async ({ page }) => {
  await mount(page);
  await page.evaluate(async () => {
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    state.config.text = '{"myDraft":true}';
    state.config.dirty = true;
  });
  await expect(page.getByRole("button", { name: "接入并重启", exact: true })).toBeDisabled();
  await expect(page.getByRole("alert").filter({ hasText: "配置编辑器还有未保存" })).toBeVisible();
  expect(await page.evaluate(() => window.__tailscale.saves)).toBe(0);
});
