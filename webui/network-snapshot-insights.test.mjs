import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

const dir = await mkdtemp(join(tmpdir(), "magicnet-network-snapshot-"));
try {
  const source = await readFile(new URL("./src/components/pages/networkSnapshotInsights.ts", import.meta.url), "utf8");
  const tone = await readFile(new URL("./src/lib/statusTone.ts", import.meta.url), "utf8");
  await writeFile(join(dir, "statusTone.mjs"), transpile(tone), "utf8");
  await writeFile(
    join(dir, "networkSnapshotInsights.mjs"),
    transpile(source.replace(/from\s+["']@\/lib\/statusTone["']/g, 'from "./statusTone.mjs"')),
    "utf8",
  );
  const insights = await import(pathToFileURL(join(dir, "networkSnapshotInsights.mjs")).href);
  const tunInsight = (text) => insights
    .buildNetworkSnapshotInsights(text)
    .find((item) => item.label === "TUN 接口");

  assert.equal(tunInsight("2: Meta: <POINTOPOINT,UP> state UNKNOWN")?.value, "not detected");
  assert.equal(tunInsight("2: Meta: <POINTOPOINT,UP> state UNKNOWN")?.tone, "info");
  assert.equal(tunInsight("8: magicnet0: <POINTOPOINT,UP> state UNKNOWN")?.value, "detected");
  assert.equal(tunInsight("TUN interface is ready, but no device name")?.value, "not detected");
  console.log("network snapshot interface tests passed");
} finally {
  await rm(dir, { recursive: true, force: true });
}
