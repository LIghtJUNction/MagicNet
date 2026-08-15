import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "./node_modules/typescript/lib/typescript.js";

const source = readFileSync(new URL("./src/components/pages/proxyChainPlan.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ES2022,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: true,
  },
}).outputText;
const dir = await mkdtemp(join(tmpdir(), "magicnet-proxy-chain-"));
await writeFile(join(dir, "proxyChainPlan.mjs"), compiled, "utf8");

try {
  const mod = await import(pathToFileURL(join(dir, "proxyChainPlan.mjs")).href);
  const status = mod.parseProxyChainStatus([
    "enabled=true",
    "mode=auto",
    "upstream=relay-jp",
    "exit=exit-us",
    "runtime=available",
    "runtime.proxy=chain",
    "runtime.chain=chain-auto",
    "runtime.chain-hop1=relay-jp",
    "runtime.chain-exit=magicnet-chain-exit::exit-us",
  ].join("\n"));
  assert.deepEqual(status, {
    enabled: true,
    mode: "auto",
    upstream: "relay-jp",
    exit: "exit-us",
    runtime: {
      available: true,
      proxy: "chain",
      chain: "chain-auto",
      hop1: "relay-jp",
      exit: "magicnet-chain-exit::exit-us",
    },
  });

  assert.deepEqual(mod.parseProxyNodeList("relay-jp\nrelay-jp\n[error] ignored\nexit-us\n"), ["relay-jp", "exit-us"]);
  assert.deepEqual(mod.mergeProxyChainNodes(["relay-jp"], "missing-exit", "relay-jp"), ["relay-jp", "missing-exit"]);

  const current = mod.createProxyChainStatus();
  current.enabled = false;
  current.upstream = "relay-jp";
  current.exit = "exit-us";
  const enablePlan = mod.buildProxyChainPlan(current, {
    enabled: true,
    mode: "auto",
    upstream: "relay-jp",
    exit: "exit-us",
  });
  assert.deepEqual(enablePlan.actions.map((action) => action.kind), ["mode", "enable"]);

  const disablePlan = mod.buildProxyChainPlan({
    ...current,
    enabled: true,
    mode: "manual",
  }, {
    enabled: false,
    mode: "auto",
    upstream: "",
    exit: "",
  });
  assert.deepEqual(disablePlan.actions.map((action) => action.kind), [
    "disable",
    "clear-upstream",
    "clear-exit",
    "mode",
  ]);

  const errors = mod.validateProxyChainDraft({
    enabled: true,
    mode: "manual",
    upstream: "same-node",
    exit: "same-node",
  }, ["same-node"]);
  assert.deepEqual(errors, ["中转节点和落地节点不能是同一个节点。"]);
  assert.deepEqual(mod.validateProxyChainDraft({
    enabled: false,
    mode: "manual",
    upstream: "stale-relay",
    exit: "stale-exit",
  }, ["fresh-node"]), []);
} finally {
  await rm(dir, { recursive: true, force: true });
}

console.log("proxy chain UI plan tests passed");
