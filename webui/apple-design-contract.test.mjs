import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");

const styles = read("./src/styles.css");
const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");
const card = read("./src/components/ui/Card.vue");
const pageHeader = read("./src/components/ui/PageHeader.vue");

// Materials communicate hierarchy and retain solid fallbacks.
assert.match(styles, /--mn-material:/, "material surface token must exist");
assert.match(
  styles,
  /backdrop-filter:\s*blur\(/,
  "functional chrome must use a translucent material",
);
assert.match(
  styles,
  /@media\s*\(prefers-reduced-transparency:\s*reduce\)/,
  "translucency must have a solid accessibility fallback",
);
assert.match(
  styles,
  /@media\s*\(prefers-contrast:\s*more\)/,
  "materials must adapt to increased contrast",
);
assert.match(app, /mn-topbar mn-chrome/, "top actions must share one material layer");
assert.match(
  app,
  /ref="advancedDialog"[^>]*mn-chrome-raised/,
  "modal navigation must use the heavier raised material",
);

// Platform typography and optical hierarchy.
assert.match(
  styles,
  /font-family:\s*\n?\s*-apple-system,\s*BlinkMacSystemFont/,
  "platform system typography must be preferred",
);
assert.match(styles, /font-optical-sizing:\s*auto/, "optical sizing must be enabled");
assert.match(
  pageHeader,
  /tracking-\[-0\.04em\]/,
  "display text must use size-appropriate tighter tracking",
);

// Press feedback starts immediately and visual motion remains interruptible.
assert.match(button, /active:scale-\[0\.97\]/, "buttons need direct press feedback");
assert.match(button, /active:duration-75/, "press feedback must not wait on a long transition");
assert.match(
  styles,
  /--mn-motion-spring:\s*cubic-bezier/,
  "shared spring-like response curve must exist",
);
assert.match(
  styles,
  /transform-origin:\s*bottom center/,
  "mobile sheet motion must remain anchored to its trigger region",
);
assert.match(
  styles,
  /@media\s*\(prefers-reduced-motion:\s*reduce\)/,
  "motion must have a reduced-motion equivalent",
);

// Controls keep touch targets, location context, and familiar grouping.
assert.match(button, /min-h-11/, "button touch targets must remain at least 44px");
assert.match(card, /rounded-\[1\.25rem\]/, "cards must use the shared large-radius language");
assert.match(app, /:aria-current="activeTab === item\.key \? 'page'/, "navigation must expose the current location");
assert.match(app, /mobile-nav mn-chrome/, "mobile navigation must stay a floating functional layer");

console.log("apple design contract tests passed");
