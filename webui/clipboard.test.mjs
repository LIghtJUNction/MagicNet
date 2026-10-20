import assert from "node:assert/strict";
import test from "node:test";
import { copyText, readClipboardText } from "./src/utils.ts";
import { useExternalLinks } from "./src/composables/useExternalLinks.ts";

test("clipboard results reflect whether the browser actually completes the operation", async (t) => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const install = (clipboard) => Object.defineProperty(globalThis, "navigator", {
    configurable: true, value: { clipboard },
  });
  t.after(() => {
    if (descriptor) Object.defineProperty(globalThis, "navigator", descriptor);
    else delete globalThis.navigator;
  });

  for (const clipboard of [undefined, {}]) {
    install(clipboard);
    assert.equal(await copyText("draft"), false, "missing clipboard support must not report a successful copy");
    assert.equal(await readClipboardText(), "");
  }

  install({
    async writeText() { throw new Error("permission denied"); },
    async readText() { throw new Error("permission denied"); },
  });
  assert.equal(await copyText("draft"), false);
  assert.equal(await readClipboardText(), "", "permission rejection must reach the page's manual-paste fallback");

  const state = { hasKsu: true, output: "", phase: "idle", notice: "", runtime: { api: "", singBoxState: "" } };
  const opened = [];
  const links = useExternalLinks(state, async (command) => { opened.push(command); return ""; }, async () => "");
  await links.openExternal("https://example.invalid/help");
  assert.equal(opened.length, 1, "clipboard failure must not block opening the link");
  assert.match(state.output, /剪贴板不可用/);
  assert.doesNotMatch(state.output, /已复制/);

  let copied;
  install({
    async writeText(value) { copied = value; },
    async readText() { return "pasted value"; },
  });
  assert.equal(await copyText("draft"), true);
  assert.equal(copied, "draft");
  assert.equal(await readClipboardText(), "pasted value");
});
