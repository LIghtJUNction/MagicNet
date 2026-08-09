import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "./node_modules/typescript/lib/typescript.js";

const source = readFileSync(new URL("./src/composables/operationCapture.ts", import.meta.url), "utf8");
const output = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: true,
  },
}).outputText;

const dir = await mkdtemp(join(tmpdir(), "magicnet-operation-capture-"));
try {
  const modulePath = join(dir, "operationCapture.mjs");
  await writeFile(modulePath, output, "utf8");
  const capture = await import(pathToFileURL(modulePath).href);
  const state = capture.emptyOperationCapture();

  const previous = capture.beginOperationCapture(
    state,
    "config-editor.get arguments=filtered",
    "local_dir=zashboard\nversion=v3.16.0",
  );
  const dns = capture.beginOperationCapture(
    state,
    "dns.test arguments=filtered",
    "DNS test running",
  );

  assert.equal(capture.updateOperationCapture(state, previous, {
    phase: "done",
    output: "local_dir=zashboard\nversion=v3.16.0",
  }), false);
  assert.equal(state.command, "dns.test arguments=filtered");
  assert.equal(state.output, "DNS test running");

  assert.equal(capture.updateOperationCapture(state, dns, {
    phase: "error",
    output: "curl: (6) Could not resolve host",
  }), true);
  assert.equal(state.phase, "error");
  assert.match(state.output, /Could not resolve host/);
} finally {
  await rm(dir, { recursive: true, force: true });
}

console.log("operation capture tests passed");
