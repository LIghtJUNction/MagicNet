import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import postcss from "postcss";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const css = read("./src/console.css");
const header = read("./src/components/ui/PageHeader.vue");

test("page heading and both action slots share a wrapping header", () => {
  assert.match(header, /<div class="mn-page-header">/);
  assert.match(header, /<slot name="actions">\s*<slot \/>/);
  assert.match(css, /\.mn-page-header\s*\{[^}]*display: flex;[^}]*flex-wrap: wrap;/);
});

test("console refinements load after the existing theme with narrowly scoped overrides", () => {
  assert.match(read("./src/main.ts"), /import "\.\/styles\.css";\s*import "\.\/console\.css";/);
  assert.doesNotMatch(css, /@import|url\(/);
  const important = [];
  postcss.parse(css).walkDecls((decl) => {
    if (!decl.important) return;
    important.push(`${decl.parent.selector}: ${decl.prop}`);
  });
  // Existing nav rules and Tailwind !p-* utilities require these exact overrides.
  // Other pages and properties must not accumulate priority escapes.
  assert.deepEqual(important, [
    ".mobile-nav button.mn-nav-active: border-color",
    ".mobile-nav button.mn-nav-active: border-top-color",
    ".mobile-nav button.mn-nav-active: background",
    ".mobile-nav button.mn-nav-active: border-top-color",
    '.page-surface[data-page="control"] > .grid > .grid > .magic-card: padding',
  ]);
});

test("mobile status details wrap and high-contrast tabs retain selection", () => {
  assert.match(css, /\.mn-runtime-brief > p\s*\{[^}]*grid-row: 2;[^}]*white-space: normal;/);
  assert.match(css, /@media \(forced-colors: active\)[\s\S]*border-bottom-color: Highlight;/);
});

test("card actions stay inside their card when text is enlarged", () => {
  assert.match(read("./src/components/ui/CardHeading.vue"), /flex max-w-full shrink-0 flex-wrap/);
});
