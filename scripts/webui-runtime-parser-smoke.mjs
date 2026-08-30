#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import ts from "../webui/node_modules/typescript/lib/typescript.js";

const sourcePath = new URL("../webui/src/composables/parsers.ts", import.meta.url);
let source = await readFile(sourcePath, "utf8");
source = source
  .replace(
    /import\s*\{\s*MODULE_DIR\s*,\s*SING_BOX_UI\s*\}\s*from\s*["'](?:@\/constants|\.\.\/constants\.ts)["']\s*;/,
    'const MODULE_DIR = "/data/adb/modules/MagicNet"; const SING_BOX_UI = "zashboard";',
  )
  .replace(/^import type .* from ["'](?:@\/types|\.\.\/types\.ts)["'];\n/m, "");

const output = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: true,
  },
}).outputText;

const dir = await mkdtemp(join(tmpdir(), "magicnet-webui-parser-"));
try {
  const modulePath = join(dir, "parsers.mjs");
  await writeFile(modulePath, output, "utf8");
  const { normalizeTransparentMode, parseRuntime, runtimeDefaults } = await import(`file://${modulePath}`);

  assert.equal(normalizeTransparentMode("tun"), "tun");
  assert.equal(normalizeTransparentMode(" eBPF "), "ebpf");
  for (const legacy of ["proxy", "external", "external-tun", "hybrid", "auto", "tproxy"]) {
    assert.equal(normalizeTransparentMode(legacy), null);
  }

  const previous = { ...runtimeDefaults, transparentMode: "ebpf" };
  for (const legacy of ["proxy", "external", "hybrid", "invalid"]) {
    assert.equal(parseRuntime(`mode=${legacy}\n`, previous).transparentMode, "unknown");
  }
  assert.equal(parseRuntime("mode=tun\n", previous).transparentMode, "tun");
  assert.equal(parseRuntime("mode=ebpf\n", runtimeDefaults).transparentMode, "ebpf");
} finally {
  await rm(dir, { recursive: true, force: true });
}

console.log("webui runtime parser smoke passed");
