import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_HIGHLIGHT_CHARACTERS,
  MAX_HIGHLIGHT_LINES,
  shouldHighlightJson,
} from "./src/components/configEditorRendering.ts";
import {
  lineColumnToPosition,
  lineRange,
  parseJsonSyntaxError,
  positionToLineColumn,
} from "./src/components/configEditorNavigation.ts";

void test("syntax highlighting remains bounded for large configs", () => {
  assert.equal(shouldHighlightJson('{"ok":true}'), true);
  assert.equal(
    shouldHighlightJson("x".repeat(MAX_HIGHLIGHT_CHARACTERS + 1)),
    false,
  );
  assert.equal(
    shouldHighlightJson(
      Array.from({ length: MAX_HIGHLIGHT_LINES + 1 }, () => "{}").join("\n"),
    ),
    false,
  );
});

void test("line navigation converts positions without crossing line bounds", () => {
  const text = '{\n  "dns": {},\n  "route": {}\n}';
  assert.deepEqual(positionToLineColumn(text, text.indexOf("route")), {
    line: 3,
    column: 4,
  });
  assert.equal(lineColumnToPosition(text, 3, 4), text.indexOf("route"));
  assert.deepEqual(lineRange(text, 2), {
    line: 2,
    column: 1,
    start: 2,
    end: 14,
  });
  assert.equal(lineColumnToPosition(text, 99, 99), text.length);
  assert.deepEqual(parseJsonSyntaxError('{\n  "dns": {},\n  "route":\n}'), {
    message: "这里需要一个值",
    line: 4,
    column: 1,
    position: 26,
  });
});

void test("editor exposes functional line and error navigation", async () => {
  const source = await (await import("node:fs/promises")).readFile(
    new URL("./src/components/ConfigCodeEditor.vue", import.meta.url),
    "utf8",
  );
  assert.match(
    source,
    /class="json-editor__gutter" aria-label="行号。点击可跳转到对应行"/,
  );
  assert.match(
    source,
    /:aria-current="line === currentLine \? 'location' : undefined"/,
  );
  assert.match(source, /@click="jumpToLine\(line\)"/);
  assert.match(source, /class="json-editor__error-jump"/);
  assert.match(
    source,
    /jumpToLine\(syntaxState\.error\.line, syntaxState\.error\.column\)/,
  );
  assert.match(source, /v-if="highlightEnabled"/);
  assert.match(source, /json-editor__plain-text/);
  assert.match(source, /ResizeObserver/);
});
