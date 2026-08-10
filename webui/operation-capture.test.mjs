import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "./node_modules/typescript/lib/typescript.js";

const source = await readFile(new URL("./src/composables/operationCapture.ts", import.meta.url), "utf8");
const output = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: true,
  },
}).outputText;

const moduleUrl = `data:text/javascript;base64,${Buffer.from(output).toString("base64")}`;
const capture = await import(moduleUrl);
const state = capture.emptyOperationCapture();

const first = capture.beginOperationCapture(state, "config-editor.get arguments=filtered", "loading");
const second = capture.beginOperationCapture(state, "dns.test arguments=filtered", "DNS test running");
assert.equal(capture.updateOperationCapture(state, first, { phase: "done", output: "stale" }), false);
assert.equal(state.command, "dns.test arguments=filtered");
assert.equal(state.output, "DNS test running");
assert.equal(capture.updateOperationCapture(state, second, { phase: "error", output: "probe failed" }), true);
assert.equal(state.phase, "error");
assert.equal(state.output, "probe failed");

const invalidated = capture.invalidateOperationCapture(state);
assert.equal(invalidated, second + 1);
assert.equal(state.command, "");
assert.equal(capture.updateOperationCapture(state, second, { phase: "done" }), false);

console.log("operation capture tests passed");
