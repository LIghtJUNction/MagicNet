import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { machineFailureText, parseMachineDns, parseMachineNetwork } from "./src/composables/machineStatus.ts";

// Run the actual composable refresh functions, not a copied refresh algorithm.
const source = ts.createSourceFile("useMagicNet.ts", readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true);
const names = ["startForegroundCommand", "canUpdateRefreshUi", "markQuietFailure", "refreshDns", "refreshNetwork"];
const functions = source.statements.filter((node) => ts.isFunctionDeclaration(node) && names.includes(node.name?.text));
assert.equal(functions.length, names.length);
const utilities = ts.createSourceFile("utils.ts", readFileSync(new URL("./src/utils.ts", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true);
const execFailed = utilities.statements.find((node) => ts.isFunctionDeclaration(node) && node.name?.text === "execFailed").getText(utilities).replace(/^export /, "");
const code = ts.transpileModule(execFailed + "\n" + functions.map((node) => node.getText(source)).join("\n"), { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
const dnsResponse = JSON.stringify({ schema: 1, ok: true, command: "dns.status", data: { profile: "default", primary: "bootstrap-local-dns", secondary: null, transport: "default" } });
const networkResponse = JSON.stringify({ schema: 1, ok: true, command: "network.status", data: {
  configured: { ipv6_mode: "prefer_ipv4", mtu: 1400, udp_timeout: "5m" },
  effective: { ipv6_mode: "unavailable", stack: "unavailable", mtu: null, udp_timeout: "unavailable" },
} });
function fixture() {
  let token = 1, resolve;
  const pending = new Promise((done) => { resolve = done; });
  const calls = [];
  const state = { dns: { profile: "cloudflare-doh", primary: "old", secondary: "old", transport: "doh" }, phase: "done", notice: "newer action", output: "newer output", busy: false };
  const context = vm.createContext({
    state, machineFailureText, parseMachineDns, parseMachineNetwork,
    t: (text, values = {}) => text.replace(/\{(\w+)\}/g, (_, key) => values[key] ?? key),
    foregroundUiGate: { current: () => token, owns: (value) => value === token },
    runCli: (args, _label, quiet) => { if (!quiet) token++; calls.push(args); return pending; },
  });
  vm.runInContext(code, context);
  return { context, state, calls, resolve, supersede: () => ++token };
}

test("global DNS refresh uses one machine request and clears a nullable secondary", async () => {
  const { context, state, calls, resolve } = fixture();
  const refresh = context.refreshDns(); resolve(dnsResponse);
  assert.equal(await refresh, true);
  assert.equal(state.dns.profile, "default"); assert.equal(state.dns.secondary, "");
  assert.deepEqual(calls, ["--json dns status"]);
});

test("malformed and unsupported DNS responses fail visibly without changing last data", async () => {
  for (const response of ["profile=default\nprimary=old", '{"schema":1,"ok":true,"command":"dns.status","data":{}}',
    '{"schema":1,"ok":false,"command":"machine.error","error":{"code":"machine.unsupported_command"}}']) {
    const { context, state, calls, resolve } = fixture(); const old = state.dns;
    const refresh = context.refreshDns(true); resolve(response);
    assert.equal(await refresh, false); assert.equal(state.dns, old);
    assert.equal(state.phase, "error"); assert.match(state.output, /machine\.(invalid_response|unsupported_command)/);
    assert.deepEqual(calls, ["--json dns status"]);
  }
});

test("stale DNS successes and protocol failures cannot overwrite a newer action", async () => {
  for (const response of [dnsResponse, "malformed", "[error] errno=1"] ) {
    const { context, state, resolve, supersede } = fixture(); const before = structuredClone(state);
    const refresh = context.refreshDns(true); supersede(); resolve(response); await refresh;
    assert.deepEqual(state, before);
  }
});

test("refresh-all's inherited token can publish DNS while its own busy flag is set", async () => {
  const { context, state, resolve } = fixture(); state.busy = true;
  const refresh = context.refreshDns(true, 1); resolve(dnsResponse);
  assert.equal(await refresh, true); assert.equal(state.dns.profile, "default");
});

test("network reads reject stale completions and malformed replies without legacy retries", async () => {
  const { context, calls, resolve, supersede } = fixture();
  const refresh = context.refreshNetwork(true); supersede(); resolve(networkResponse);
  assert.equal(await refresh, null); assert.deepEqual(calls, ["--json network status"]);
  const invalid = fixture(); const failed = invalid.context.refreshNetwork(); invalid.resolve("ipv6_mode=prefer_ipv4");
  assert.equal(await failed, null); assert.equal(invalid.state.phase, "error");
  assert.deepEqual(invalid.calls, ["--json network status"]);
});

test("network refresh preserves configured/effective separation", async () => {
  const { context, resolve } = fixture(); const refresh = context.refreshNetwork(); resolve(networkResponse);
  const result = await refresh;
  assert.equal(result.configured.mtu, 1400); assert.equal(result.effective.mtu, null);
});
