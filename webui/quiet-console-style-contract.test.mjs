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

void test("quiet console uses neutral surfaces and blue action emphasis", () => {
  assert.match(styles, /--mn-ivory:\s*#0b0d12/i);
  assert.match(styles, /--mn-surface-raised:\s*#151a23/i);
  assert.match(styles, /--mn-primary:\s*#60a5fa/i);
  assert.match(styles, /--mn-radius-lg:\s*10px/i);
  assert.match(styles, /--mn-shadow-card:\s*0 1px 2px/i);
  assert.doesNotMatch(
    styles,
    /linear-gradient|radial-gradient|backdrop-filter:\s*blur/i,
  );
});

void test("shell is outcome-led rather than terminal-themed", () => {
  assert.match(app, /class="mn-runtime-brief"/);
  assert.match(app, />网络控制</);
  assert.match(app, /查看状态并控制服务。/);
  assert.match(app, /检查问题并运行维护工具。/);
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

void test("durable design baseline names the approved world", () => {
  assert.match(design, /name:\s*"MagicNet Quiet Console"/);
  assert.match(design, /primary:\s*"#60A5FA"/i);
  assert.match(design, /Signature Mechanism:\s*Precision Editor Rail/);
  assert.doesNotMatch(design, /Phosphor Grid|Live Route Stack/);
});
