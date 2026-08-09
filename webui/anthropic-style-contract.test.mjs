import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");

const styles = read("./src/styles.css");
const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");

// The named light-theme accents must stay on the verified Anthropic palette.
for (const [token, value] of [
  ["clay", "#d97757"],
  ["olive", "#788c5d"],
  ["sky", "#6a9bcc"],
  ["coral", "#ebcece"],
]) {
  assert.match(
    styles,
    new RegExp(`--mn-${token}:\\s*${value}`, "i"),
    `light-theme ${token} must use the verified ${value} accent`,
  );
}

// Pale accents are surfaces. Small editorial labels use a dedicated contrast-safe ink.
assert.match(styles, /--mn-clay-ink:/, "clay labels need a separate high-contrast ink token");
assert.match(
  button,
  /bg-\[var\(--mn-clay\)\]\s+text-\[var\(--mn-on-accent\)\]/,
  "clay buttons must keep near-black marks instead of white text",
);

// The runtime summary is the page's single editorial field: accent, carrier, then ink.
assert.match(app, /runtime-cockpit mn-editorial-field/, "runtime summary must use the editorial accent field");
assert.match(app, /mn-editorial-carrier/, "runtime summary must include an ivory carrier");
assert.match(styles, /\.mn-editorial-field\s*\{[\s\S]*?background:\s*var\(--mn-cactus\)/);
assert.match(styles, /\.mn-editorial-carrier\s*\{[\s\S]*?background:\s*var\(--mn-ivory\)/);

// Structural separators stay flat and materially quiet.
assert.doesNotMatch(styles, /linear-gradient\(/, "shell chrome must not use decorative gradients");

console.log("anthropic style contract tests passed");
