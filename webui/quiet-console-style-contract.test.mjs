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

void test("quiet console uses neutral surfaces and graphite action emphasis", () => {
  assert.match(styles, /--mn-ivory:\s*#171717/i);
  assert.match(styles, /--mn-surface-raised:\s*#1d1d1d/i);
  assert.match(styles, /--mn-primary:\s*#e8e8e8/i);
  assert.match(styles, /--mn-radius-lg:\s*10px/i);
  assert.match(styles, /--mn-shadow-card:\s*none/i);
  assert.doesNotMatch(
    styles,
    /linear-gradient|radial-gradient|backdrop-filter:\s*blur/i,
  );
});

void test("shell is outcome-led rather than terminal-themed", () => {
  assert.match(app, /class="mn-runtime-brief"/);
  assert.doesNotMatch(app, /activeWorkspace\.description|>网络控制</);
  assert.match(app, /aria-label="全部页面"/);
  assert.match(app, /mobileLabel: "订阅"/);
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

void test("durable design baseline records the current neutral direction", () => {
  assert.match(design, /name:\s*"MagicNet Quiet Console"/);
  assert.match(design, /primary:\s*"#E8E8E8"/i);
  assert.match(design, /Signature Mechanism:\s*Precision Editor Rail/);
  assert.doesNotMatch(design, /Phosphor Grid|Live Route Stack/);
});
