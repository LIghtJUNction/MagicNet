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

function luminance(hex) {
  const rgb=hex.match(/[0-9a-f]{2}/gi).map(v=>parseInt(v,16)/255).map(v=>v<=0.04045?v/12.92:((v+0.055)/1.055)**2.4);
  return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
}
function contrast(a,b) {const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
void test("network instrument palette keeps readable text and controls in both themes", () => {
  for(const theme of ["light","dark"]) {
    const block=styles.split(`html[data-theme="${theme}"] {`)[1].split("\n}")[0];
    const token=name=>block.match(new RegExp(`--mn-${name}:\\s*(#[0-9a-f]{6})`,"i"))[1];
    assert.ok(contrast(token("ink"),token("ivory"))>=4.5,"body text contrast");
    assert.ok(contrast(token("on-accent"),token("primary"))>=4.5,"primary control contrast");
  }
  assert.doesNotMatch(styles, /@font-face|fonts\.googleapis/);
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
  assert.match(design, /name:\s*"MagicNet Fieldnotes"/);
  assert.match(design, /primary:\s*"#12675D"/i);
  assert.match(design, /移动端优先/);
  assert.match(design, /Signature Mechanism:\s*Live Constellation Path/);
  assert.match(design, /Precision Editor Rail/);
  assert.doesNotMatch(design, /Phosphor Grid|Live Route Stack/);
});
