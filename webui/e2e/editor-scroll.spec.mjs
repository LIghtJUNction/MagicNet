import { expect, test } from "@playwright/test";

async function expectAlignedLayers(page) {
  await expect.poll(() => page.locator(".json-editor__textarea").evaluate((editor) => {
    const highlight = editor.previousElementSibling;
    return Math.max(Math.abs(highlight.scrollLeft - editor.scrollLeft), Math.abs(highlight.scrollTop - editor.scrollTop));
  }), { message: "The visible JSON must follow the caret's horizontal and vertical scrolling." }).toBeLessThanOrEqual(1);
}

test("long JSON input and formatting keep syntax highlighting aligned with the caret", async ({ page }, info) => {
  await page.addInitScript(() => localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed"));
  await page.goto("/#/config", { waitUntil: "networkidle" });
  const editor = page.locator(".json-editor__textarea");
  const status = page.locator(".json-editor__toolbar [role=status]");
  const draft = JSON.stringify({ description: "abcdefghij".repeat(24), values: Array.from({ length: 30 }, (_, index) => index) });
  await editor.pressSequentially(draft);
  await expect(editor).toHaveValue(draft);
  await expect(status).toHaveText("语法正确");
  await expect(page.locator(".json-editor__highlight")).toHaveText(draft);
  // Real keyboard input scrolls to the end before the debounced highlight has
  // grown. The eventual painted text must catch up without another scroll event.
  expect(await editor.evaluate(node => node.scrollLeft)).toBeGreaterThan(0);
  await expectAlignedLayers(page);
  await page.locator(".json-editor").screenshot({ path: info.outputPath("long-json-input.png") });

  await page.getByLabel("更多配置操作", { exact: true }).click();
  await page.getByRole("button", { name: "格式化", exact: true }).click();
  const formatted = `${JSON.stringify(JSON.parse(draft), null, 2)}\n`;
  await expect(editor).toHaveValue(formatted);
  await expect(status).toHaveText("语法正确");
  await expect(page.locator(".json-editor__highlight")).toHaveText(formatted);
  await expectAlignedLayers(page);

  await page.keyboard.press("Escape");
  await editor.press("Control+End");
  expect(await editor.evaluate(node => node.scrollTop)).toBeGreaterThan(0);
  await expectAlignedLayers(page);
  await page.locator(".json-editor").screenshot({ path: info.outputPath("formatted-json-end.png") });
});
