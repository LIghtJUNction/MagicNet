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

function transpile(source) {
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      verbatimModuleSyntax: true,
    },
  }).outputText;
}

async function loadShippedModule(relativeFromWebui, importRewrites = []) {
  const sourcePath = join(root, relativeFromWebui);
  let source = read(sourcePath);
  for (const [pattern, replacement] of importRewrites) {
    source = source.replace(pattern, replacement);
  }
  // Drop type-only imports so transpile+import stays pure JS
  source = source.replace(/^import type .*;\n/gm, "");

  const dir = await mkdtemp(join(tmpdir(), "magicnet-webui-tone-"));
  // Bundle real @/lib/statusTone entry (token root) next to the module under test.
  if (/@\/lib\/statusTone/.test(source)) {
    const toneSrc = read(join(src, "lib", "statusTone.ts")).replace(/^import type .*;\n/gm, "");
    await writeFile(join(dir, "statusTone.mjs"), transpile(toneSrc), "utf8");
    source = source.replace(/from\s+["']@\/lib\/statusTone["']/g, 'from "./statusTone.mjs"');
  }
  // Other @/ paths must be rewritten explicitly by callers; fail loudly otherwise.
  assert.doesNotMatch(source, /from\s+["']@\//, `${relativeFromWebui} still has unresolved @/ imports after rewrite`);

  const modulePath = join(dir, "module.mjs");
  await writeFile(modulePath, transpile(source), "utf8");
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
const header = app.slice(app.indexOf("<header"), app.indexOf("</header>") + "</header>".length);
function headerButton(action) {
  const match = header.match(
    new RegExp(`<Button(?:(?!<\\/Button>)[\\s\\S])*?@click="${action}"(?:(?!<\\/Button>)[\\s\\S])*?<\\/Button>`),
  );
  assert.ok(match, `missing header action: ${action}`);
  return match[0].slice(0, match[0].indexOf(">") + 1);
}
assert.doesNotMatch(headerButton("cycleTheme"), /class="hidden /, "theme must remain visible on mobile");
assert.doesNotMatch(headerButton("refreshAll"), /class="hidden /, "refresh must remain visible on mobile");
assert.doesNotMatch(headerButton("openExternal\\(REPO, 'GitHub'\\)"), /class="hidden /, "GitHub must remain visible on mobile");
assert.match(headerButton("createIssue"), /class="hidden /, "feedback must move to More on mobile");
assert.match(
  headerButton("openExternal\\(AUTHOR_WHISPER_URL, '悄悄话'\\)"),
  /class="hidden /,
  "whisper must move to More on mobile",
);
assert.match(app, /反馈问题[\s\S]*悄悄话/, "mobile more sheet must expose feedback and whisper actions");
assert.match(app, /useTheme|cycleTheme/, "shell must wire light/dark theme toggle");
assert.match(app, /KeepAlive/, "shell must KeepAlive tab pages so form state survives switches");
assert.doesNotMatch(app, /backdrop-blur/, "shell chrome must not default to heavy backdrop-blur");
const controlPage = read(join(pagesDir, "ControlPage.vue"));
assert.doesNotMatch(controlPage, /AI 自动推广系统|PROMOTION_URL|Megaphone/, "control page must not ship the promotion card");
assert.doesNotMatch(controlPage, /external-tun|Hybrid|modeActionKey/, "control page must expose only TUN mode");

// --- Light/dark theme system ---
const themePath = join(src, "composables", "useTheme.ts");
const themeSrc = read(themePath);
assert.match(themeSrc, /export function useTheme|export function bootstrapTheme/, "useTheme composable must exist");
assert.match(themeSrc, /magicnet\.webui\.theme/, "theme preference must persist to localStorage");
assert.match(styles, /html\[data-theme=["']light["']\]/, "styles must define light theme tokens");
assert.match(styles, /html\[data-theme=["']dark["']\]/, "styles must define dark theme tokens");
assert.match(styles, /--mn-on-accent/, "styles must define on-accent text for filled controls");
assert.match(styles, /\.mn-page-actions/, "styles must define sticky page action bar");
const mainTs = read(join(src, "main.ts"));
assert.match(mainTs, /bootstrapTheme/, "main.ts must bootstrap theme before mount");
const indexHtml = read(join(root, "index.html"));
assert.match(indexHtml, /color-scheme|data-theme|magicnet\.webui\.theme/, "index.html must prevent theme flash");

// --- Theme root: design tokens + shared statusTone helper (primary guarantee) ---
const statusTonePath = join(src, "lib", "statusTone.ts");
const statusToneSrc = read(statusTonePath);
assert.match(statusToneSrc, /export function statusToneClasses/, "statusTone.ts must export statusToneClasses");
assert.match(statusToneSrc, /mn-tone-ok|mn-tone-warn|mn-tone-danger/, "statusTone maps must use CSS mn-tone-* classes");
assert.match(styles, /\.mn-tone-ok|\.mn-tone-warn|\.mn-tone-danger/, "styles.css must define mn-tone surfaces");
assert.match(styles, /--mn-success|--mn-warning|--mn-danger|--mn-info/, "styles must define semantic ink tokens");

// Drive shipped root: statusToneClasses itself (not a reimplementation).
{
  const { mod, cleanup } = await loadShippedModule("src/lib/statusTone.ts");
  try {
    const ok = mod.statusToneClasses("ok");
    const warn = mod.statusToneClasses("warning");
    const danger = mod.statusToneClasses("danger");
    const info = mod.statusToneClasses("info");
    assert.equal(ok, "mn-tone-ok");
    assert.equal(warn, "mn-tone-warn");
    assert.equal(danger, "mn-tone-danger");
    assert.equal(info, "mn-tone-info");
    // CSS definitions must exist for those class names
    for (const cls of [ok, warn, danger, info]) {
      assert.match(styles, new RegExp(`\\.${cls}\\s*\\{`), `styles.css missing .${cls}`);
    }
  } finally {
    await cleanup();
  }
}

// Real plan/status helpers must delegate to statusToneClasses (token path, not ad-hoc strings).
{
  const { mod, cleanup } = await loadShippedModule("src/components/pages/dnsTestSummary.ts");
  try {
    const okTone = mod.dnsStatusTone("ok");
    assert.equal(okTone, "mn-tone-ok", "dnsStatusTone(ok) must return shared mn-tone-ok");
    assert.equal(mod.dnsStatusTone("fail"), "mn-tone-danger");
  } finally {
    await cleanup();
  }
}

{
  const { mod, cleanup } = await loadShippedModule("src/components/pages/nodeSwitchPlan.ts");
  try {
    assert.equal(mod.nodeSwitchPlanTone("switch"), "mn-tone-ok");
    assert.equal(mod.nodeSwitchPlanTone("keep"), "mn-tone-info");
  } finally {
    await cleanup();
  }
}

// Secondary regression net only (not the primary design): ban residual pale dark-theme ink.
const forbiddenContrast = [
  /text-amber-50\b/,
  /text-lime-100\b/,
  /text-sky-100\b/,
  /bg-zinc-800\b/,
];
const uiPrimitives = [
  join(src, "components", "ui", "Badge.vue"),
  join(src, "components", "ui", "Button.vue"),
  join(src, "components", "ui", "Card.vue"),
];
for (const path of [appPath, ...listPageSources(), ...uiPrimitives]) {
  const body = read(path);
  for (const pattern of forbiddenContrast) {
    assert.doesNotMatch(body, pattern, `${path} residual pale/dark class ${pattern}`);
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
