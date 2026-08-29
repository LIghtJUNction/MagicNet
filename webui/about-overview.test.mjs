import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "./node_modules/typescript/lib/typescript.js";

function transpile(source) {
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      verbatimModuleSyntax: true,
    },
  }).outputText;
}

const aboutPage = readFileSync(new URL("./src/components/pages/AboutPage.vue", import.meta.url), "utf8");
const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const overviewSource = readFileSync(
  new URL("./src/components/pages/aboutOverview.ts", import.meta.url),
  "utf8",
);

const dir = await mkdtemp(join(tmpdir(), "magicnet-about-overview-"));
try {
  await writeFile(join(dir, "aboutOverview.mjs"), transpile(overviewSource), "utf8");
  const overview = await import(pathToFileURL(join(dir, "aboutOverview.mjs")).href);

  const facts = overview.dataPlaneFacts();
  const steps = overview.firstRunSteps();
  const checks = overview.successChecks();
  const pathNodes = overview.pathFlowNodes();
  const report = overview.formatAboutOverview();

  assert.equal(overview.DATAPLANE_IFACE, "magicnet0");
  assert.equal(facts.length, 3);
  assert.equal(steps.length, 3);
  assert.equal(checks.length, 3);
  assert.equal(pathNodes.length, 4);
  assert.equal(pathNodes.map((item) => item.code).join("|"), "ROOT|TUN|CORE|OUT");
  assert.ok(facts.every((item) => item.code && item.title && item.detail));
  assert.match(report, /dataplane=sing-box TUN/);
  assert.match(report, /iface=magicnet0/);
  assert.match(report, /cli health/);
  assert.match(report, /cli transparent status/);
  assert.doesNotMatch(report, /\bTProxy\b/);
  assert.doesNotMatch(report, /\beBPF\b/);
  assert.doesNotMatch(report, /ALLOW_MULTI/);
  assert.doesNotMatch(report, /cli ebpf status/);
  assert.doesNotMatch(report, /\bauto\b/);
  assert.equal(
    checks.map((item) => item.command).join(" | "),
    "cli health | cli transparent status | magicnet0",
  );
} finally {
  await rm(dir, { recursive: true, force: true });
}

assert.match(aboutPage, /路径速览/);
assert.match(aboutPage, /goto-tab/);
assert.match(aboutPage, /DATAPLANE_IFACE/);
assert.match(aboutPage, /mn-path-flow/);
assert.match(aboutPage, /InsightChip/);
assert.doesNotMatch(aboutPage, /TProxy|eBPF|ALLOW_MULTI|cli ebpf status/);

assert.match(app, /type TabKey =[\s\S]*"about"/);
assert.match(app, /import\("@\/components\/pages\/AboutPage\.vue"\)/);
assert.match(app, /key: "about", label: "路径速览"/);
assert.match(app, /@goto-tab="setTab"/);
assert.match(app, /<KeepAlive :max="11">/);

const controlPage = readFileSync(
  new URL("./src/components/pages/ControlPage.vue", import.meta.url),
  "utf8",
);
assert.match(controlPage, /goto-tab',\s*'about'|goto-tab",\s*"about"/);
assert.match(controlPage, /路径速览/);

console.log("about overview tests passed");
