import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const apps = readFileSync(new URL("./src/components/pages/AppsPage.vue", import.meta.url), "utf8");
const styles = readFileSync(new URL("./src/styles.css", import.meta.url), "utf8");

assert.match(app, /desktop-rail[\s\S]*whitespace-nowrap/, "desktop navigation labels must stay on one line");
assert.match(app, /mobile-nav[\s\S]*whitespace-nowrap/, "mobile navigation labels must stay on one line");
assert.match(app, /mobile-nav[\s\S]*max-w-full truncate leading-none/, "mobile navigation labels must clip instead of wrapping");
assert.match(app, /desktop-rail[\s\S]*min-w-0 truncate/, "desktop navigation labels must not force rail overflow");
assert.match(apps, /min-h-12 whitespace-nowrap[\s\S]*全局接管/);
assert.match(apps, /min-h-12 whitespace-nowrap[\s\S]*仅名单接管/);
assert.doesNotMatch(
  styles,
  /button,\s*input,\s*select,\s*textarea\s*\{\s*font:\s*inherit;/,
  "an unlayered font shorthand must not override responsive button text sizes",
);

console.log("UI layout regression tests passed");
