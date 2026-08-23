/**
 * Structural contract for the mobile-first Phosphor Grid refactor + lag fixes.
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
const logoAsset = join(root, "..", "icon.png");
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
    const toneSrc = read(join(src, "lib", "statusTone.ts")).replace(
      /^import type .*;\n/gm,
      "",
    );
    await writeFile(join(dir, "statusTone.mjs"), transpile(toneSrc), "utf8");
    source = source.replace(
      /from\s+["']@\/lib\/statusTone["']/g,
      'from "./statusTone.mjs"',
    );
  }
  if (/@\/lib\/fnv32/.test(source)) {
    const hashSrc = read(join(src, "lib", "fnv32.ts")).replace(
      /^import type .*;\n/gm,
      "",
    );
    await writeFile(join(dir, "fnv32.mjs"), transpile(hashSrc), "utf8");
    source = source.replace(
      /from\s+["']@\/lib\/fnv32["']/g,
      'from "./fnv32.mjs"',
    );
  }
  // Bundle @/composables/nodeDelayParsers the same way for modules that share
  // the fastest/slowest-entry helpers.
  if (/@\/composables\/nodeDelayParsers/.test(source)) {
    const parsersSrc = read(
      join(src, "composables", "nodeDelayParsers.ts"),
    ).replace(/^import type .*;\n/gm, "");
    await writeFile(
      join(dir, "nodeDelayParsers.mjs"),
      transpile(parsersSrc),
      "utf8",
    );
    source = source.replace(
      /import\s*\{([^}]*)\}\s*from\s*["']@\/composables\/nodeDelayParsers["']/g,
      (_whole, names) => {
        const valueNames = names
          .split(",")
          .map((name) => name.trim())
          .filter((name) => name && !name.startsWith("type "))
          .join(", ");
        return valueNames
          ? `import { ${valueNames} } from "./nodeDelayParsers.mjs"`
          : `import "./nodeDelayParsers.mjs"`;
      },
    );
  }
  // Other @/ paths must be rewritten explicitly by callers; fail loudly otherwise.
  assert.doesNotMatch(
    source,
    /from\s+["']@\//,
    `${relativeFromWebui} still has unresolved @/ imports after rewrite`,
  );

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

// --- Phosphor Grid tokens on the real styles entry ---
const styles = read(stylesPath);
for (const token of ["#B7F34A", "#050706", "#E6F7C8", "#F2F5EB", "#121711"]) {
  assert.match(
    styles,
    new RegExp(token, "i"),
    `styles.css must declare palette token ${token}`,
  );
}
assert.match(
  styles,
  /--mn-ivory|--mn-cactus|--mn-carrier/,
  "styles.css must expose mn design tokens",
);
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
assert.doesNotMatch(
  styles,
  /page-arrive|@keyframes page-arrive/,
  "page-arrive enter animation must be removed from default CSS",
);
assert.match(
  styles,
  /background:\s*var\(--mn-ivory\)/,
  "body/html must use flat ivory field",
);

// --- shared logo asset: valid square PNG, large enough for module stores + WebUI ---
assert.ok(existsSync(logoAsset), `missing shipped logo: ${logoAsset}`);
const logo = readFileSync(logoAsset);
assert.deepEqual(
  [...logo.subarray(0, 8)],
  [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  "icon.png must be a PNG",
);
assert.equal(
  logo.readUInt32BE(16),
  logo.readUInt32BE(20),
  "icon.png must be square",
);
assert.ok(logo.readUInt32BE(16) >= 512, "icon.png must be at least 512px");

// --- App shell: lazy pages, no full remount key, branding asset ---
const app = read(appPath);
assert.match(
  app,
  /defineAsyncComponent/,
  "App.vue must lazy-load pages via defineAsyncComponent",
);
assert.match(
  app,
  /import\("@\/components\/pages\/ControlPage\.vue"\)/,
  "App.vue must dynamic-import ControlPage",
);
assert.match(
  app,
  /import\("@\/components\/pages\/ConfigPage\.vue"\)/,
  "App.vue must dynamic-import ConfigPage",
);
assert.match(
  app,
  /import\("@\/components\/pages\/AppsPage\.vue"\)/,
  "App.vue must dynamic-import AppsPage",
);
assert.match(
  app,
  /import\("@\/components\/pages\/OutputPage\.vue"\)/,
  "App.vue must dynamic-import OutputPage",
);
assert.doesNotMatch(
  app,
  /import\s+ControlPage\s+from\s+["']@\/components\/pages\/ControlPage\.vue["']/,
  "ControlPage must not be a static top-level import on the critical path",
);
assert.doesNotMatch(
  app,
  /:key=["']activeTab["']/,
  "tab switches must not remount via :key=activeTab",
);
assert.doesNotMatch(
  app,
  /class=["'][^"']*page-enter/,
  "active page surface must not use page-enter remount animation class",
);
assert.match(
  app,
  /MAGICNET_LOGO_URL/,
  "shell must reference the shared MagicNet logo",
);
assert.match(
  app,
  /运行|路由|配置|诊断/,
  "four primary workspace labels must remain",
);
assert.match(
  app,
  /应用|黑名单|链式代理|订阅|工具|面板|输出/,
  "all local page labels must remain reachable",
);
assert.match(
  app,
  /createIssue|refreshAll|openExternal/,
  "header actions must remain wired",
);
const header = app.slice(
  app.indexOf("<header"),
  app.indexOf("</header>") + "</header>".length,
);
function headerButton(action) {
  const actionIndex = header.indexOf(`@click="${action}"`);
  assert.notEqual(actionIndex, -1, `missing header action: ${action}`);
  const buttonStart = header.lastIndexOf("<Button", actionIndex);
  const buttonEnd = header.indexOf(">", buttonStart);
  assert.ok(
    buttonStart >= 0 && buttonEnd > buttonStart,
    `invalid header action: ${action}`,
  );
  return header.slice(buttonStart, buttonEnd + 1);
}
assert.doesNotMatch(
  headerButton("cycleTheme"),
  /mn-desktop-action/,
  "theme must remain visible on mobile",
);
assert.doesNotMatch(
  headerButton("refreshAll"),
  /mn-desktop-action/,
  "refresh must remain visible on mobile",
);
assert.match(
  headerButton("openExternal(REPO, 'GitHub')"),
  /mn-desktop-action/,
  "GitHub belongs to desktop chrome and the mobile utility sheet",
);
assert.match(
  headerButton("createIssue"),
  /mn-desktop-action/,
  "feedback must move to the utility sheet on mobile",
);
assert.match(
  app,
  /openUtilityMenu[\s\S]*反馈问题[\s\S]*悄悄话/,
  "mobile utility sheet must expose feedback and whisper actions",
);
assert.match(
  app,
  /useTheme|cycleTheme/,
  "shell must wire light/dark theme toggle",
);
assert.match(
  app,
  /KeepAlive/,
  "shell must KeepAlive tab pages so form state survives switches",
);
assert.doesNotMatch(
  app,
  /backdrop-blur/,
  "shell chrome must not default to heavy backdrop-blur",
);
const pageHeader = read(join(src, "components", "ui", "PageHeader.vue"));
assert.match(
  pageHeader,
  /<div class="contents">/,
  "PageHeader actions must participate in the owning page grid",
);
const controlPage = read(join(pagesDir, "ControlPage.vue"));
assert.doesNotMatch(
  controlPage,
  /AI 自动推广系统|PROMOTION_URL|Megaphone/,
  "control page must not ship the promotion card",
);
assert.doesNotMatch(
  controlPage,
  /external-tun|Hybrid|modeActionKey/,
  "control page must expose only TUN mode",
);
assert.match(controlPage, /const singBoxStatus = computed/);
assert.match(controlPage, /tone: "neutral"/);
assert.match(
  controlPage,
  /label: !rawState \|\| rawState === "unknown" \? "状态未知" : rawState/,
);
assert.doesNotMatch(
  controlPage,
  /singBoxState === 'stopped' \? 'warning' : 'success'/,
  "unknown sing-box state must not inherit success tone",
);
assert.match(controlPage, /data-danger-cancel/);
assert.match(controlPage, /prefers-reduced-motion: reduce/);
assert.match(controlPage, /\[data-danger-cancel\]/);
assert.match(controlPage, /restoreDangerActionFocus\(\)/);
const focusManagement = read(join(src, "lib", "focus.ts"));
assert.match(focusManagement, /element\.isConnected/);

// --- Light/dark theme system ---
const themePath = join(src, "composables", "useTheme.ts");
const themeSrc = read(themePath);
assert.match(
  themeSrc,
  /export function useTheme|export function bootstrapTheme/,
  "useTheme composable must exist",
);
assert.match(
  themeSrc,
  /magicnet\.webui\.theme/,
  "theme preference must persist to localStorage",
);
assert.match(
  styles,
  /html\[data-theme=["']light["']\]/,
  "styles must define light theme tokens",
);
assert.match(
  styles,
  /html\[data-theme=["']dark["']\]/,
  "styles must define dark theme tokens",
);
assert.match(
  styles,
  /--mn-on-accent/,
  "styles must define on-accent text for filled controls",
);
assert.match(
  styles,
  /--mn-page-actions-desktop-top:\s*1rem/,
  "desktop page actions must align to the flat workspace surface",
);
assert.match(
  styles,
  /\.mn-page-actions\s*\{[^}]*position:\s*static/,
  "page actions must stay in normal flow on compact screens",
);
assert.match(
  styles,
  /@media \(min-width: 1024px\)[\s\S]*?\.mn-page-actions\s*\{[^}]*position:\s*sticky;[^}]*top:\s*var\(--mn-page-actions-desktop-top\)[\s\S]*?\.page-surface\s*\{[^}]*overflow:\s*visible/,
  "desktop page actions must stick without clipping the page surface",
);
const mainTs = read(join(src, "main.ts"));
assert.match(
  mainTs,
  /bootstrapTheme/,
  "main.ts must bootstrap theme before mount",
);
assert.match(
  mainTs,
  /installMagicNetFavicon/,
  "main.ts must install the shared logo as favicon",
);
const indexHtml = read(join(root, "index.html"));
assert.match(
  indexHtml,
  /color-scheme|data-theme|magicnet\.webui\.theme/,
  "index.html must prevent theme flash",
);
assert.match(
  indexHtml,
  /id="magicnet-favicon"[^>]*type="image\/png"/,
  "index.html must expose the favicon target",
);

// --- Theme root: design tokens + shared statusTone helper (primary guarantee) ---
const statusTonePath = join(src, "lib", "statusTone.ts");
const statusToneSrc = read(statusTonePath);
assert.match(
  statusToneSrc,
  /export function statusToneClasses/,
  "statusTone.ts must export statusToneClasses",
);
assert.match(
  statusToneSrc,
  /mn-tone-ok|mn-tone-warn|mn-tone-danger/,
  "statusTone maps must use CSS mn-tone-* classes",
);
assert.match(
  styles,
  /\.mn-tone-ok|\.mn-tone-warn|\.mn-tone-danger/,
  "styles.css must define mn-tone surfaces",
);
assert.match(
  styles,
  /--mn-success|--mn-warning|--mn-danger|--mn-info/,
  "styles must define semantic ink tokens",
);

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
      assert.match(
        styles,
        new RegExp(`\\.${cls}\\s*(?:,|\\{)`),
        `styles.css missing .${cls}`,
      );
    }
  } finally {
    await cleanup();
  }
}

// Real plan/status helpers must delegate to statusToneClasses (token path, not ad-hoc strings).
{
  const { mod, cleanup } = await loadShippedModule(
    "src/components/pages/dnsTestSummary.ts",
  );
  try {
    const okTone = mod.dnsStatusTone("ok");
    assert.equal(
      okTone,
      "mn-tone-ok",
      "dnsStatusTone(ok) must return shared mn-tone-ok",
    );
    assert.equal(mod.dnsStatusTone("fail"), "mn-tone-danger");
  } finally {
    await cleanup();
  }
}

{
  const { mod, cleanup } = await loadShippedModule(
    "src/components/pages/nodeSwitchPlan.ts",
  );
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
    assert.doesNotMatch(
      body,
      pattern,
      `${path} residual pale/dark class ${pattern}`,
    );
  }
}

// --- production dist when built: multi-chunk code split ---
if (existsSync(distDir)) {
  const assetsDir = join(distDir, "assets");
  assert.ok(existsSync(assetsDir), "dist/assets must exist after build");
  const jsChunks = readdirSync(assetsDir).filter((name) =>
    name.endsWith(".js"),
  );
  assert.ok(
    jsChunks.length > 1,
    `expected multiple JS chunks for code-split, got ${jsChunks.length}: ${jsChunks.join(", ")}`,
  );
  const indexHtml = read(join(distDir, "index.html"));
  assert.match(
    indexHtml,
    /MagicNet/,
    "built index must keep MagicNet branding",
  );
  assert.match(indexHtml, /assets\//, "built index must reference assets/");
  const pngAssets = readdirSync(assetsDir).filter((name) =>
    name.endsWith(".png"),
  );
  assert.ok(
    pngAssets.length >= 1,
    "built dist must include the shared MagicNet PNG logo",
  );
}

console.log("frontend-refactor-contract: ok");
