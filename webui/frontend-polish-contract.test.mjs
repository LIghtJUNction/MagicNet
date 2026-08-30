import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (relativePath) =>
  readFileSync(new URL(relativePath, import.meta.url), "utf8");

const app = read("./src/App.vue");
const button = read("./src/components/ui/Button.vue");
const editor = read("./src/components/ConfigCodeEditor.vue");
const configPage = read("./src/components/pages/ConfigPage.vue");
const controlPage = read("./src/components/pages/ControlPage.vue");
const visibilityTask = read("./src/composables/useVisibilityTask.ts");
const styles = read("./src/styles.css");
const deferredPanels = [
  "./src/components/pages/ConnectionsPanel.vue",
  "./src/components/pages/ProxyGroupsPanel.vue",
  "./src/components/pages/NodeDelayPanel.vue",
].map(read);
const radiusSurfaces = [
  "./src/components/OnboardingDialog.vue",
  "./src/components/OpenSourceSupportNote.vue",
  "./src/components/pages/ControlPage.vue",
  "./src/components/pages/ProxyChainPage.vue",
]
  .map(read)
  .join("\n");

assert.match(button, /:aria-busy="loading \? 'true' : undefined"/);
assert.match(button, /absolute inset-0 grid place-items-center/);
assert.match(button, /loading \? 'opacity-0' : 'opacity-100'/);

assert.match(editor, /ANALYSIS_DELAY_MS = 180/);
assert.match(editor, /MAX_HIGHLIGHT_CHARACTERS/);
assert.match(editor, /JSON_NUMBER_PATTERN\.lastIndex = index/);
assert.match(editor, /JSON_WORD_PATTERN\.lastIndex = index/);
assert.doesNotMatch(editor, /text\.slice\(index\)\.match/);
assert.match(editor, /Array\.from\(\{ length: lineCount\.value \}/);
assert.doesNotMatch(editor, /v-for="line in lineCount"/);
assert.match(configPage, /analyzedConfigText/);
assert.match(configPage, /configAnalysisPending/);
assert.match(controlPage, /aria-label="Wi-Fi SSID"/);
assert.match(controlPage, /aria-label="Wi-Fi BSSID"/);

assert.match(visibilityTask, /globalThis\.IntersectionObserver/);
assert.match(
  visibilityTask,
  /rootMargin: options\.rootMargin \?\? "320px 0px"/,
);
for (const panel of deferredPanels) {
  assert.match(panel, /useVisibilityTask/);
  assert.match(panel, /ref="visibilityTarget" class="mn-deferred-region"/);
  assert.doesNotMatch(panel, /onMounted\(\(\) => \{\s*void refresh/);
}

assert.match(
  app,
  /if \(tab !== activeTab\.value\) \{[\s\S]*warmActiveTab\(tab\);[\s\S]*\}\s*void nextTick/,
);
assert.match(app, /@pointerenter="prefetchTab\(item\.key\)"/);
assert.match(styles, /scrollbar-gutter:\s*stable/);
assert.match(styles, /content-visibility:\s*auto/);
assert.match(styles, /\.mn-workspace-header\s*\{[\s\S]*position:\s*sticky/);
assert.doesNotMatch(styles, /\[class\*="(?:rounded-|shadow-|backdrop-blur)/);
assert.doesNotMatch(
  radiusSurfaces,
  /rounded-\[(?:0\.[0-9]+|1(?:\.[0-9]+)?)rem\]/,
);

console.log("frontend polish contract tests passed");
