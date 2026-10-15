import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");
const styles = read("./src/styles.css");
const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");
const pageHeader = read("./src/components/ui/PageHeader.vue");
const design = read("./DESIGN.md");

void test("constellation palette derives from the logo and keeps one restrained accent", () => {
  assert.match(styles, /--mn-ivory:\s*#f7f2e8/i, "light canvas is the logo's cream paper");
  assert.match(styles, /--mn-ink:\s*#1f1b16/i, "light ink is the logo's line work");
  assert.match(styles, /--mn-primary:\s*#b9502b/i, "terracotta primary keeps white text above 4.5:1");
  assert.match(styles, /--mn-ivory:\s*#14120f/i, "dark canvas is a warm night sky");
  assert.match(styles, /--mn-primary:\s*#f08a5d/i);
  assert.match(styles, /--font-serif:/, "display type uses the system serif stack, no downloaded fonts");
  assert.doesNotMatch(styles, /@font-face|fonts\.googleapis/);
  assert.match(styles, /--mn-radius-lg:\s*20px/i);
  // The star field is static paint, removed for high contrast and forced colors.
  assert.match(styles, /--mn-sky-field:\s*none/);
  assert.match(styles, /@media \(prefers-contrast: more\)[\s\S]*--mn-sky-field: none/);
  assert.match(styles, /@media \(forced-colors: active\)\s*\{\s*body\s*\{\s*background-image: none/);
  assert.doesNotMatch(styles, /backdrop-filter:\s*blur/i, "WebView chrome avoids blur compositing");
  assert.doesNotMatch(styles, /@keyframes[^{]*\{[^}]*\b(?:body|html)\b/, "the page canvas never animates");
});

void test("shell is outcome-led rather than terminal-themed", () => {
  assert.match(app, /class="mn-runtime-brief"/);
  assert.doesNotMatch(app, /activeWorkspace\.description|>网络控制</);
  assert.match(app, /:aria-label="t\('全部页面'\)"/);
  assert.match(app, /mobileLabel: "订阅"/);
  assert.match(app, /useMobileKeyboard/);
  assert.match(app, /v-show="!keyboardOpen" class="mobile-nav"/);
  assert.doesNotMatch(
    app,
    />网络控制<|查看状态并控制服务。|检查问题并运行维护工具。/,
  );
  assert.doesNotMatch(
    app,
    /ROOT:\/\/MAGICNET|ROUTE_STACK|WORKSPACES|root@magicnet/,
  );
  assert.doesNotMatch(app, /workspace\.code|item\.code/);
  assert.match(app, /readTabFromLocation/);
  assert.match(app, /writeTabToLocation/);
  assert.match(
    app,
    /window\.addEventListener\("popstate", syncTabFromLocation\)/,
  );
});

void test("shared primitives preserve labels and reduce decorative copy", () => {
  assert.match(button, /v-if="loading"/);
  assert.doesNotMatch(button, /loading \? 'opacity-0'/);
  assert.doesNotMatch(pageHeader, /mn-page-kicker/);
  assert.match(pageHeader, /v-if="description"/);
});

void test("design baseline records the implemented mobile brief", () => {
  assert.match(design, /name:\s*"MagicNet Constellation"/);
  assert.match(design, /primary:\s*"#B9502B"/i);
  assert.match(design, /移动端优先/);
  assert.match(design, /Signature Mechanism:\s*Live Constellation Path/);
  assert.match(design, /Precision Editor Rail/);
  assert.doesNotMatch(design, /Phosphor Grid|Live Route Stack/);
});
