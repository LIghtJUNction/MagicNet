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

void test("mobile paper uses quiet surfaces and restrained action emphasis", () => {
  assert.match(styles, /--mn-ivory:\s*#fafaf7/i);
  assert.match(styles, /--mn-surface-raised:\s*#252823/i);
  assert.match(styles, /--mn-primary:\s*#30382f/i);
  assert.match(styles, /--mn-primary:\s*#dee3d4/i);
  assert.match(styles, /--mn-radius-lg:\s*16px/i);
  assert.match(styles, /--mn-shadow-card:\s*none/i);
  assert.match(
    styles,
    /\.magic-card\s*\{[^}]*border-radius:\s*0[^}]*background:\s*transparent/,
  );
  assert.doesNotMatch(
    styles,
    /linear-gradient|radial-gradient|backdrop-filter:\s*blur/i,
  );
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
  assert.match(design, /name:\s*"MagicNet Paper"/);
  assert.match(design, /primary:\s*"#30382F"/i);
  assert.match(design, /移动端优先/);
  assert.match(design, /Signature Mechanism:\s*Precision Editor Rail/);
  assert.doesNotMatch(design, /Phosphor Grid|Live Route Stack/);
});
