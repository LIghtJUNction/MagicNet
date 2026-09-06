import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");

const styles = read("./src/styles.css");
const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");
const card = read("./src/components/ui/Card.vue");

assert.match(styles, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
assert.match(styles, /@media\s*\(prefers-contrast:\s*more\)/);
assert.match(styles, /@media\s*\(prefers-reduced-transparency:\s*reduce\)/);
assert.match(styles, /font-optical-sizing:\s*auto/);
assert.match(styles, /touch-action:\s*manipulation/);

assert.match(
  button,
  /active:translate-y-px/,
  "buttons need immediate physical press feedback",
);
assert.match(button, /duration-150/, "button feedback must stay short");
assert.match(
  button,
  /min-h-12/,
  "button targets must remain at least 48px tall",
);
assert.match(card, /magic-card/, "shared sections retain their semantic surface class");
assert.match(styles, /\.magic-card\s*\{[^}]*border-top: 1px solid var\(--mn-border\);[^}]*border-radius: 0;/,
  "top-level sections use a continuous layout with a visible divider");

assert.match(
  app,
  /type WorkspaceKey = "run" \| "route" \| "configure" \| "diagnose"/,
);
for (const label of ["运行", "路由", "配置", "诊断"]) {
  assert.match(
    app,
    new RegExp(`label: "${label}"`),
    `missing mobile workspace ${label}`,
  );
}
assert.match(
  app,
  /:aria-current="activeWorkspace\.key === workspace\.key \? 'page' : undefined"/,
);
assert.match(
  styles,
  /\.mobile-nav\s*\{[\s\S]*grid-template-columns:\s*repeat\(4,/,
);
assert.match(styles, /\.mobile-nav button\s*\{[\s\S]*min-height:\s*56px/);
assert.match(styles, /env\(safe-area-inset-bottom\)/);
assert.match(styles, /env\(safe-area-inset-top\)/);
assert.match(styles, /env\(safe-area-inset-left\)/);
assert.match(styles, /env\(safe-area-inset-right\)/);
assert.match(app, /v-show="!keyboardOpen" class="mobile-nav"/);
assert.match(
  styles,
  /\.mobile-nav button span\s*\{[\s\S]*white-space:\s*normal/,
);

console.log("mobile interaction contract tests passed");
