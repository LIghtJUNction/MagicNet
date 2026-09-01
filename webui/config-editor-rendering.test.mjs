import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_HIGHLIGHT_CHARACTERS,
  MAX_HIGHLIGHT_LINES,
  shouldHighlightJson,
} from "./src/components/configEditorRendering.ts";

assert.equal(shouldHighlightJson('{"route":{"rules":[]}}'), true);
assert.equal(shouldHighlightJson("x".repeat(MAX_HIGHLIGHT_CHARACTERS + 1)), false);
assert.equal(shouldHighlightJson(Array.from({ length: MAX_HIGHLIGHT_LINES + 1 }, () => "{}").join("\n")), false);

test("large editor uses a scrollable plain-text fallback", async () => {
  const source = await (await import("node:fs/promises")).readFile(
    new URL("./src/components/ConfigCodeEditor.vue", import.meta.url),
    "utf8",
  );
  assert.match(source, /v-if="highlightEnabled"/);
  assert.match(source, /highlight\.value\.scrollTop = target\.scrollTop/);
  assert.match(source, /json-editor--plain/);
  assert.doesNotMatch(source, /will-change:\s*transform/);
  assert.doesNotMatch(source, /translate\(\$\{-scrollLeft/);
});
