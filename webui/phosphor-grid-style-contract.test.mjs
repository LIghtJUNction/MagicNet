import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");

const styles = read("./src/styles.css");
const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");
const index = read("./index.html");

for (const [token, value] of [
  ["ivory", "#f2f5eb"],
  ["ink", "#121711"],
  ["cactus", "#2d660d"],
  ["focus", "#b7f34a"],
]) {
  assert.match(
    styles,
    new RegExp(`--mn-${token}:\\s*${value}`, "i"),
    `phosphor-grid token ${token} must include ${value}`,
  );
}

assert.match(styles, /html\[data-theme="dark"\][\s\S]*--mn-cactus:\s*#b7f34a/i);
assert.match(
  styles,
  /--font-sans:[^;]*Noto Sans CJK SC/,
  "body typography must keep a Chinese-capable sans fallback",
);
assert.match(styles, /--font-mono:[^;]*ui-monospace/);
assert.match(styles, /body\s*\{[\s\S]*font-family:\s*var\(--font-sans\)/);
assert.match(styles, /code,[\s\S]*font-family:\s*var\(--font-mono\)/);
assert.match(
  app,
  /class="mn-route-stack"/,
  "the first viewport must expose the live route stack",
);
assert.match(
  app,
  /ANDROID ROOT[\s\S]*magicnet0[\s\S]*sing-box[\s\S]*POLICY \/ OUTBOUND/,
);
assert.match(app, /role="status" aria-live="polite" aria-atomic="true"/);
assert.match(
  button,
  /bg-\[var\(--mn-cactus\)\]\s+text-\[var\(--mn-on-accent\)\]/,
);
assert.match(
  index,
  /<body>\s*<!-- DIRECTION_CONTRACT:/,
  "direction contract must be the body's first child",
);

assert.doesNotMatch(
  styles,
  /linear-gradient\(/,
  "the shell must not use decorative gradients",
);
assert.doesNotMatch(
  styles,
  /repeating-linear-gradient/,
  "the terminal field must not fake scan lines",
);
assert.doesNotMatch(
  styles,
  /backdrop-filter:\s*blur\(/,
  "the new world must not retain glass blur",
);
assert.doesNotMatch(
  app,
  /巨型连接|速度仪表盘/,
  "the shell must not present a generic VPN hero",
);

console.log("phosphor grid style contract tests passed");
