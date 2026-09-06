import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import postcss from "postcss";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const css = read("./src/styles.css");
const header = read("./src/components/ui/PageHeader.vue");

test("page heading and both action slots share a wrapping header", () => {
  assert.match(header, /<div class="mn-page-header">/);
  assert.match(header, /<slot name="actions">\s*<slot \/>/);
  assert.match(css, /\.mn-page-header\s*\{[^}]*display: flex;[^}]*flex-wrap: wrap;/);
});

test("the shared theme has one entry and scoped utility priority", () => {
  const main = read("./src/main.ts");
  assert.match(main, /import "\.\/styles\.css";/);
  assert.doesNotMatch(main, /console\.css/);
  const important = [];
  postcss.parse(css).walkDecls((decl) => {
    if (!decl.important) return;
    important.push(`${decl.parent.selector}: ${decl.prop}`);
  });
  // Normal-flow sections need no utility override; only reduced-motion guarantees do.
  assert.deepEqual(important, [
    "*,\n  *::before,\n  *::after: scroll-behavior",
    "*,\n  *::before,\n  *::after: animation-duration",
    "*,\n  *::before,\n  *::after: animation-iteration-count",
    "*,\n  *::before,\n  *::after: transition-duration",
  ]);
});

test("mobile status details wrap and high-contrast tabs retain selection", () => {
  assert.match(css, /\.mn-runtime-brief > p\s*\{[^}]*overflow-wrap: anywhere;[^}]*white-space: normal;/);
  assert.match(css, /@media \(forced-colors: active\)[\s\S]*border-bottom-color: Highlight;/);
});

test("card actions stay inside their card when text is enlarged", () => {
  assert.match(read("./src/components/ui/CardHeading.vue"), /flex max-w-full shrink-0 flex-wrap/);
});
