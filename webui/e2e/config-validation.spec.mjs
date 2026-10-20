import { expect, test } from "@playwright/test";

for (const action of ["edit", "format"]) {
  test(`a saved configuration loses its old validation result after ${action}`, async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    });
    await page.goto("/#/config", { waitUntil: "networkidle" });
    const editor = page.locator(".json-editor__textarea");
    await expect(editor).toBeVisible();
    // Seed a prior device result. This test checks what the user sees after
    // changing that draft, not whether an Android core accepts a configuration.
    await page.evaluate(async () => {
      const { state } = (await import("/src/composables/useMagicNet.ts")).useMagicNet();
      Object.assign(state.config, {
        text: '{"log":{"level":"info"}}', dirty: false,
        status: "校验通过，已保存",
        validation: { status: "ok", summary: "配置已通过校验并保存。", checkedAt: "12:00:00" },
      });
    });
    const validation = page.locator(".config-editor-workspace > details");
    await expect(validation.locator("summary")).toHaveText("校验与结构通过");
    if (action === "edit") {
      await editor.fill('{"log":{"level":"debug"}}');
    } else {
      await page.getByLabel("更多配置操作", { exact: true }).click();
      await page.getByRole("button", { name: "格式化", exact: true }).click();
    }
    await expect(validation.locator("summary")).toHaveText("校验与结构未校验");
    await validation.locator("summary").click();
    await expect(validation.getByText("当前修改尚未校验。", { exact: true })).toBeVisible();
    await expect(page.locator(".config-file-bar")).toContainText("未保存");
    await expect(page.locator(".config-file-bar")).not.toContainText("已保存");
  });
}
