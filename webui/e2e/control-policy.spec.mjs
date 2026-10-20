import { expect, test } from "@playwright/test";

// Exercise the real components and CLI bridge protocol. No Android commands
// leave this browser fixture; unknown commands always fail.
async function mountPolicy(page, component, options = {}) {
  await page.route("**/e2e/control-policy-fixture.html", (route) => route.fulfill({
    contentType: "text/html",
    body: '<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width, initial-scale=1"><body><main id="policy-fixture" style="padding:16px"></main></body></html>',
  }));
  await page.goto("/e2e/control-policy-fixture.html");
  await page.evaluate(async ({ component, options }) => {
    const fixture = window.__policyFixture = {
      readFailure: false, writeFailure: false, holdWifi: false, releaseWifi: null,
      writes: [], reads: 0,
      configured: { ipv6_mode: "prefer_ipv6", mtu: 1450, udp_timeout: "10m" },
      ...options,
    };
    window.ksu = {
      spawn(command, _args, _options, callbackName) {
        const finish = () => {
          const callback = window[callbackName];
          let output = "fixture.unsupported_command";
          let errno = 1;
          if (command.includes("--json network status")) {
            fixture.reads++;
            if (!fixture.readFailure) {
              output = JSON.stringify({ schema: 1, ok: true, command: "network.status", data: {
                configured: fixture.configured,
                effective: { ...fixture.configured, stack: "mixed" },
              } });
              errno = 0;
            }
          } else if (command.includes("--json wifi inspect")) {
            if (!fixture.readFailure) {
              output = JSON.stringify({ schema: 1, ok: true, command: "wifi.inspect", data: {
                policy: { enabled: false, mode: "blacklist", interval_seconds: 10, supervisor: "stopped" },
                network: { connected: false, matched: false, desired_mode: "rule", ssid: "", bssid: "" },
                configuration: { ssids: [], bssids: [] }, current_mode: "unavailable",
              } });
              errno = 0;
            }
          } else if (/network set |wifi add-(?:ssid|bssid) /.test(command)) {
            fixture.writes.push(command);
            errno = fixture.writeFailure ? 1 : 0;
            output = fixture.writeFailure ? "fixture.write_failed" : "fixture.saved";
            const update = command.match(/network set (\w+) (\d+) (\w+)/);
            if (update && !errno) fixture.configured = {
              ipv6_mode: update[1], mtu: Number(update[2]), udp_timeout: update[3],
            };
          }
          callback.stdout.emit("data", output);
          callback.emit("exit", errno);
        };
        if (fixture.holdWifi && command.includes("wifi add-")) fixture.releaseWifi = finish;
        else setTimeout(finish, 0);
      },
    };
    const { createApp } = await import("/e2e/vue-fixture.mjs");
    await import("/src/styles.css");
    const { setLocale } = await import("/src/i18n/index.ts");
    setLocale("zh-CN");
    const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
    state.hasKsu = true;
    const { default: Component } = await import(`/src/components/pages/${component}.vue`);
    createApp(Component).mount("#policy-fixture");
  }, { component, options });
}

test("Wi-Fi add failures retain the input and a successful retry clears it", async ({ page }) => {
  await mountPolicy(page, "ControlPage", { writeFailure: true });
  await page.locator("summary").filter({ hasText: "Wi-Fi 自动切换" }).click();
  const input = page.getByRole("textbox", { name: "Wi-Fi SSID", exact: true });
  await input.fill("Cafe fixture");
  await page.getByRole("button", { name: "SSID", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__policyFixture.writes.length)).toBe(1);
  await expect(input).toHaveValue("Cafe fixture");
  await page.evaluate(() => { window.__policyFixture.writeFailure = false; window.__policyFixture.readFailure = true; });
  await page.getByRole("button", { name: "SSID", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__policyFixture.writes.length)).toBe(2);
  await expect(page.getByRole("button", { name: "SSID", exact: true })).toBeEnabled();
  await expect(input).toHaveValue("Cafe fixture");
  await page.evaluate(() => { window.__policyFixture.readFailure = false; });
  await page.getByRole("button", { name: "SSID", exact: true }).click();
  await expect(input).toHaveValue("");
  expect(await page.evaluate(() => window.__policyFixture.writes.length)).toBe(3);
});

test("Wi-Fi completion and duplicate Enter do not erase a newer draft", async ({ page }) => {
  await mountPolicy(page, "ControlPage", { holdWifi: true });
  await page.locator("summary").filter({ hasText: "Wi-Fi 自动切换" }).click();
  const input = page.getByRole("textbox", { name: "Wi-Fi BSSID", exact: true });
  await input.fill("00:11:22:33:44:55");
  await page.getByRole("button", { name: "BSSID", exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof window.__policyFixture.releaseWifi)).toBe("function");
  await input.fill("00:11:22:33:44:66");
  await input.press("Enter");
  await expect(input).toHaveValue("00:11:22:33:44:66");
  await page.evaluate(() => window.__policyFixture.releaseWifi());
  await expect(page.getByRole("button", { name: "BSSID", exact: true })).toBeEnabled();
  await expect(input).toHaveValue("00:11:22:33:44:66");
  expect(await page.evaluate(() => window.__policyFixture.writes.length)).toBe(1);
});

test("network settings require a successful read and keep supported custom MTU values", async ({ page }) => {
  await mountPolicy(page, "NetworkPolicyCard", { readFailure: true });
  const save = page.getByRole("button", { name: "保存并应用", exact: true });
  await expect.poll(() => page.evaluate(() => window.__policyFixture.reads)).toBe(1);
  await expect(save).toBeDisabled();
  await expect(page.getByRole("alert")).toContainText("读取 UDP / IPv6 策略失败");
  expect(await page.evaluate(() => window.__policyFixture.writes)).toEqual([]);
  await page.evaluate(() => { window.__policyFixture.readFailure = false; });
  await page.getByRole("button", { name: "刷新", exact: true }).click();
  await expect(page.getByRole("combobox", { name: "TUN MTU", exact: true })).toHaveValue("1450");
  await expect(save).toBeEnabled();
  await page.getByRole("combobox", { name: "IPv6 策略", exact: true }).selectOption("ipv4_only");
  await expect(save).toBeEnabled();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__policyFixture.writes.length)).toBe(1);
  await expect(save).toBeEnabled();
  expect(await page.evaluate(() => window.__policyFixture.configured))
    .toEqual({ ipv6_mode: "ipv4_only", mtu: 1450, udp_timeout: "10m" });
});

test("network reads and failed writes preserve pending edits until a confirmed save", async ({ page }) => {
  await mountPolicy(page, "NetworkPolicyCard");
  const mode = page.getByRole("combobox", { name: "IPv6 策略", exact: true });
  const save = page.getByRole("button", { name: "保存并应用", exact: true });
  const refresh = page.getByRole("button", { name: "刷新", exact: true });
  await expect(mode).toHaveValue("prefer_ipv6");
  await mode.selectOption("ipv4_only");
  await page.evaluate(() => { window.__policyFixture.configured.mtu = 1400; });
  await refresh.click();
  await expect(refresh).toBeEnabled();
  await expect(mode).toHaveValue("ipv4_only");
  await expect(page.getByRole("combobox", { name: "TUN MTU", exact: true })).toHaveValue("1450");
  await page.evaluate(() => { window.__policyFixture.readFailure = true; });
  await refresh.click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(save).toBeDisabled();
  await expect(mode).toHaveValue("ipv4_only");
  await page.evaluate(() => { window.__policyFixture.readFailure = false; window.__policyFixture.writeFailure = true; });
  await refresh.click();
  await expect(save).toBeEnabled();
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__policyFixture.writes.length)).toBe(1);
  await expect(mode).toHaveValue("ipv4_only");
  await expect(save).toBeEnabled();
  await page.evaluate(() => { window.__policyFixture.writeFailure = false; });
  await save.click();
  await expect.poll(() => page.evaluate(() => window.__policyFixture.writes.length)).toBe(2);
  await expect(save).toBeEnabled();
  await expect(page.getByText("有未保存的更改", { exact: true })).toHaveCount(0);
});
