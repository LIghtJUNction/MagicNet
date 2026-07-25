/**
 * Structural contract for the anthropic-art restyle + lag fixes.
 * Drives the shipped source entry points (App shell, styles, public asset,
 * page/tone sources) rather than re-implementing loaders or hard-coding
 * expected class strings alone.
 */
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "./node_modules/typescript/lib/typescript.js";

const root = dirname(fileURLToPath(import.meta.url));
const src = join(root, "src");
const pagesDir = join(src, "components", "pages");
const appPath = join(src, "App.vue");
const stylesPath = join(src, "styles.css");
const publicAsset = join(root, "public", "magicnet-network-card.svg");
const distDir = join(root, "dist");

function read(path) {
  assert.ok(existsSync(path), `missing shipped file: ${path}`);
  return readFileSync(path, "utf8");
}

function listPageSources() {
  assert.ok(existsSync(pagesDir), `missing pages dir: ${pagesDir}`);
  return readdirSync(pagesDir)
    .filter((name) => name.endsWith(".vue") || name.endsWith(".ts"))
    .map((name) => join(pagesDir, name));
}

async function loadShippedModule(relativeFromWebui, importRewrites = []) {
  const sourcePath = join(root, relativeFromWebui);
  let source = read(sourcePath);
  for (const [pattern, replacement] of importRewrites) {
    source = source.replace(pattern, replacement);
  }
  // Drop type-only imports so transpile+import stays pure JS
  source = source.replace(/^import type .*;\n/gm, "");
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      verbatimModuleSyntax: true,
    },
  }).outputText;
  const dir = await mkdtemp(join(tmpdir(), "magicnet-webui-tone-"));
  const modulePath = join(dir, "module.mjs");
  await writeFile(modulePath, output, "utf8");
  try {
    return {
      mod: await import(pathToFileURL(modulePath).href),
      cleanup: () => rm(dir, { recursive: true, force: true }),
    };
  } catch (error) {
    await rm(dir, { recursive: true, force: true });
    throw error;
  }
}

// --- anthropic-art tokens on real styles entry ---
const styles = read(stylesPath);
for (const token of ["#BCD1CA", "#CBCADB", "#E3DACC", "#FAF9F5", "#141413"]) {
  assert.match(styles, new RegExp(token, "i"), `styles.css must declare palette token ${token}`);
}
assert.match(styles, /--mn-ivory|--mn-cactus|--mn-carrier/, "styles.css must expose mn design tokens");
assert.doesNotMatch(
  styles,
  /radial-gradient\([^)]*52,\s*211,\s*153/,
  "styles.css must not use the old emerald multi-radial body stack",
);
assert.doesNotMatch(
  styles,
  /repeating-linear-gradient/,
  "styles.css must not use repeating-line noise overlay as default body paint",
);
assert.doesNotMatch(styles, /page-arrive|@keyframes page-arrive/, "page-arrive enter animation must be removed from default CSS");
assert.match(styles, /background:\s*var\(--mn-ivory\)/, "body/html must use flat ivory field");

// --- illustration asset present and anthropic-art form grammar ---
const svg = read(publicAsset);
assert.match(svg, /#BCD1CA/i, "illustration must use cactus full-frame field");
assert.match(svg, /#FAF9F5/i, "illustration must include ivory carrier");
assert.match(svg, /#141413/i, "illustration must use near-black linework");

// --- App shell: lazy pages, no full remount key, branding asset ---
const app = read(appPath);
assert.match(app, /defineAsyncComponent/, "App.vue must lazy-load pages via defineAsyncComponent");
assert.match(app, /import\("@\/components\/pages\/ControlPage\.vue"\)/, "App.vue must dynamic-import ControlPage");
assert.match(app, /import\("@\/components\/pages\/ConfigPage\.vue"\)/, "App.vue must dynamic-import ConfigPage");
assert.match(app, /import\("@\/components\/pages\/AppsPage\.vue"\)/, "App.vue must dynamic-import AppsPage");
assert.match(app, /import\("@\/components\/pages\/OutputPage\.vue"\)/, "App.vue must dynamic-import OutputPage");
assert.doesNotMatch(
  app,
  /import\s+ControlPage\s+from\s+["']@\/components\/pages\/ControlPage\.vue["']/,
  "ControlPage must not be a static top-level import on the critical path",
);
assert.doesNotMatch(app, /:key=["']activeTab["']/, "tab switches must not remount via :key=activeTab");
assert.doesNotMatch(app, /class=["'][^"']*page-enter/, "active page surface must not use page-enter remount animation class");
assert.match(app, /magicnet-network-card\.svg/, "shell must reference the illustration asset");
assert.match(app, /控制|配置|应用|黑名单|诊断/, "primary nav labels must remain");
assert.match(app, /订阅|排行|工具|面板|输出/, "advanced nav labels must remain");
assert.match(app, /createIssue|refreshAll|openExternal/, "header actions must remain wired");
assert.doesNotMatch(app, /backdrop-blur/, "shell chrome must not default to heavy backdrop-blur");

// --- contrast regressions on light ivory canvas (page + tone sources) ---
// Pale dark-theme ink (*-50 near-white, *-100 pale) and zinc-800 chips fail on ivory/oat/carrier.
const forbiddenContrast = [
  /text-amber-50\b/,
  /text-lime-50\b/,
  /text-sky-50\b/,
  /text-red-50\b/,
  /text-rose-50\b/,
  /text-emerald-50\b/,
  /text-cyan-50\b/,
  /text-zinc-50\b/,
  /text-lime-100\b/,
  /text-sky-100\b/,
  /text-red-100\b/,
  /text-rose-100\b/,
  /text-amber-100\b/,
  /text-emerald-100\b/,
  /text-cyan-100\b/,
  /bg-zinc-800\b/,
];
const uiPrimitives = [
  join(src, "components", "ui", "Badge.vue"),
  join(src, "components", "ui", "Button.vue"),
  join(src, "components", "ui", "Card.vue"),
  join(src, "components", "ui", "Input.vue"),
  join(src, "components", "ui", "PageHeader.vue"),
  join(src, "components", "ui", "Textarea.vue"),
];
const contrastTargets = [appPath, stylesPath, ...listPageSources(), ...uiPrimitives];
for (const path of contrastTargets) {
  const body = read(path);
  for (const pattern of forbiddenContrast) {
    assert.doesNotMatch(
      body,
      pattern,
      `${path} still contains light-on-light / dark-on-dark class ${pattern}`,
    );
  }
}

// Drive shipped tone helpers (real entry points) — not reimplemented expectations.
{
  const { mod, cleanup } = await loadShippedModule("src/components/pages/dnsTestSummary.ts");
  try {
    const okTone = mod.dnsStatusTone("ok");
    assert.equal(typeof okTone, "string");
    assert.match(okTone, /--mn-success|var\(--mn-success\)/, "dnsStatusTone(ok) must use readable success ink");
    assert.doesNotMatch(okTone, /text-lime-100/, "dnsStatusTone(ok) must not return dark-theme pale lime ink");
    assert.match(okTone, /--mn-cactus|cactus/, "dnsStatusTone(ok) should use cactus success surface family");
  } finally {
    await cleanup();
  }
}

{
  const { mod, cleanup } = await loadShippedModule("src/components/pages/nodeSwitchPlan.ts");
  try {
    const switchTone = mod.nodeSwitchPlanTone("switch");
    const keepTone = mod.nodeSwitchPlanTone("keep");
    assert.doesNotMatch(switchTone, /text-lime-100|text-sky-100/);
    assert.doesNotMatch(keepTone, /text-lime-100|text-sky-100/);
    assert.match(switchTone, /--mn-success|var\(--mn-success\)/);
    assert.match(keepTone, /--mn-info|var\(--mn-info\)/);
  } finally {
    await cleanup();
  }
}

// --- production dist when built: multi-chunk code split ---
if (existsSync(distDir)) {
  const assetsDir = join(distDir, "assets");
  assert.ok(existsSync(assetsDir), "dist/assets must exist after build");
  const jsChunks = readdirSync(assetsDir).filter((name) => name.endsWith(".js"));
  assert.ok(jsChunks.length > 1, `expected multiple JS chunks for code-split, got ${jsChunks.length}: ${jsChunks.join(", ")}`);
  const indexHtml = read(join(distDir, "index.html"));
  assert.match(indexHtml, /MagicNet/, "built index must keep MagicNet branding");
  assert.match(indexHtml, /assets\//, "built index must reference assets/");
  assert.ok(
    existsSync(join(distDir, "magicnet-network-card.svg")),
    "built dist must include magicnet-network-card.svg from public/",
  );
}

console.log("frontend-refactor-contract: ok");
