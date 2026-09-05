import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import postcss from "postcss";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const styles = read("./src/styles.css");
const consoleStyles = read("./src/console.css");
const app = read("./src/App.vue");
const control = read("./src/components/pages/ControlPage.vue");

function themeTokens(theme) {
  const tokens = {};
  postcss.parse(consoleStyles).walkRules((rule) => {
    if (rule.parent.type !== "root") return;
    if (!rule.selector.includes(`html[data-theme="${theme}"]`)) return;
    rule.walkDecls((decl) => { tokens[decl.prop] = decl.value; });
  });
  return tokens;
}
function luminance(hex) {
  const values = hex.slice(1).match(/../g).map((c) => parseInt(c, 16) / 255);
  const [r, g, b] = values.map((v) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return r * 0.2126 + g * 0.7152 + b * 0.0722;
}
function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

for (const theme of ["light", "dark"]) {
  test(`${theme} theme keeps body, secondary text, links and primary controls readable`, () => {
    const tokens = themeTokens(theme);
    for (const [foreground, background] of [
      ["--mn-ink", "--mn-ivory"], ["--mn-ink-muted", "--mn-ivory"],
      ["--mn-primary-strong", "--mn-ivory"], ["--mn-on-accent", "--mn-primary"],
      ["--mn-control-text", "--mn-control-ink"],
    ]) {
      assert.ok(contrast(tokens[foreground], tokens[background]) >= 4.5, `${theme}: ${foreground} / ${background}`);
    }
  });
}

test("surfaces do not add decorative gradients, glow, or remote font dependencies", () => {
  assert.doesNotMatch(styles + consoleStyles, /linear-gradient|radial-gradient|backdrop-filter:\s*blur/i);
  assert.doesNotMatch(consoleStyles, /@import|url\(/);
  assert.doesNotMatch(consoleStyles, /nth-child/);
});

test("the home page has one leading state and three native settings disclosures", () => {
  assert.equal((control.match(/id="mn-runtime-title"/g) || []).length, 1);
  assert.equal((control.match(/<details class="mn-setting"/g) || []).length, 3);
  for (const key of ["transparent", "wifi", "hotspot"]) assert.match(control, new RegExp(`data-setting="${key}"`));
  assert.doesNotMatch(control, /<PageHeader|<Card\s/);
  assert.match(control, /pendingDangerAction/);
  assert.match(control, /requestTransparentMode\('tun'/);
  assert.match(control, /requestTransparentMode\('ebpf'/);
  assert.match(control, /state\.runtime\.transparentRecentError/);
});

test("shell retains device truth, original branding, history and all workspace access", () => {
  assert.match(app, /class="mn-runtime-brief"/);
  assert.match(app, /MAGICNET_LOGO_URL/);
  assert.match(app, /readTabFromLocation/);
  assert.match(app, /writeTabToLocation/);
  assert.match(app, /KeepAlive/);
  assert.match(app, /window\.addEventListener\("popstate", syncTabFromLocation\)/);
  assert.doesNotMatch(app, /ROOT:\/\/MAGICNET|ROUTE_STACK|root@magicnet/);
});

test("design proposal does not claim approval on the user's behalf", () => {
  const design = read("./DESIGN.md");
  assert.match(design, /status:\s*"proposal"/);
  assert.doesNotMatch(design, /approved_by:\s*"user"|status:\s*"approved"/);
});
