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

const root = new URL("./src/", import.meta.url);
const dir = await mkdtemp(join(tmpdir(), "magicnet-runtime-log-"));
try {
  const tone = readFileSync(new URL("./lib/statusTone.ts", root), "utf8");
  const drafts = readFileSync(new URL("./composables/issueDrafts.ts", root), "utf8");
  const source = readFileSync(new URL("./components/pages/runtimeLogInsights.ts", root), "utf8")
    .replace(/from\s+["']@\/lib\/statusTone["']/g, 'from "./statusTone.mjs"')
    .replace(/from\s+["']@\/composables\/issueDrafts["']/g, 'from "./issueDrafts.mjs"');
  await Promise.all([
    writeFile(join(dir, "statusTone.mjs"), transpile(tone), "utf8"),
    writeFile(join(dir, "issueDrafts.mjs"), transpile(drafts), "utf8"),
    writeFile(join(dir, "runtimeLogInsights.mjs"), transpile(source), "utf8"),
  ]);
  const insights = await import(pathToFileURL(join(dir, "runtimeLogInsights.mjs")).href);
  const issue = "ERROR connection from 192.0.2.7:443 to https://private.example.invalid/path?token=secret";
  const report = insights.formatRuntimeLogIssueReport({
    target: "sing-box",
    lines: [issue],
    issueLines: [issue],
    warningCount: 0,
    errorCount: 1,
    otherIssueCount: 0,
  });
  assert.doesNotMatch(report, /192\.0\.2\.7|private\.example\.invalid|token=secret/);
  assert.match(report, /\[filtered-ip\]/);
  assert.match(report, /\[filtered-url\]/);
  const insight = insights.buildRuntimeLogInsight([issue], 0, 1, [issue]);
  assert.doesNotMatch(insight.lastIssue, /192\.0\.2\.7|private\.example\.invalid/);
} finally {
  await rm(dir, { recursive: true, force: true });
}

console.log("runtime log insight tests passed");
