import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const apps = readFileSync(new URL("./src/components/pages/AppsPage.vue", import.meta.url), "utf8");

assert.match(app, /desktop-rail[\s\S]*whitespace-nowrap/, "desktop navigation labels must stay on one line");
assert.match(app, /mobile-nav[\s\S]*whitespace-nowrap/, "mobile navigation labels must stay on one line");
assert.match(apps, /min-h-12 whitespace-nowrap[\s\S]*全局接管/);
assert.match(apps, /min-h-12 whitespace-nowrap[\s\S]*仅名单接管/);

console.log("UI layout regression tests passed");
