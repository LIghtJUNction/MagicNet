import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import ts from "typescript";
import { t } from "./src/i18n/index.ts";
import { ForegroundUiGate } from "./src/composables/foregroundUiGate.ts";
import {
  decodeMachineData, decodeDnsStatus, decodeNetworkStatus, machineErrorCode,
} from "./src/composables/machineStatus.ts";

const dns = { profile: "cloudflare-doh", primary: "https://one.one.one.one/dns-query", secondary: null, transport: "https" };
const network = {
  configured: { ipv6_mode: "prefer_ipv4", mtu: 1400, udp_timeout: "5m" },
  effective: { ipv6_mode: "unavailable", stack: "unavailable", mtu: null, udp_timeout: "unavailable" },
};
const envelope = (command, data) => JSON.stringify({ schema: 1, ok: true, command, data });

test("machine decoding accepts exactly one schema-1 stdout document", () => {
  const text = envelope("dns.status", dns);
  assert.deepEqual(decodeMachineData(`\n ${text}\n`, "dns.status"), dns);
  for (const invalid of ["not json", text + "\n[warn] stderr", text + "\n" + text,
    envelope("network.status", dns), text.replace('"schema":1', '"schema":2'),
    envelope("dns.status", null), envelope("dns.status", []), text.replace('"ok":true', '"ok":1')]) {
    assert.equal(decodeDnsStatus(invalid), null, invalid);
  }
});

test("DNS and network shapes reject missing or untyped values and preserve unknown observations", () => {
  assert.deepEqual(decodeDnsStatus(envelope("dns.status", dns)), { ...dns, secondary: "" });
  assert.deepEqual(decodeNetworkStatus(envelope("network.status", network)), network);
  for (const patch of [{ profile: "invalid" }, { primary: 1 }, { secondary: undefined }, { transport: null }]) {
    assert.equal(decodeDnsStatus(envelope("dns.status", { ...dns, ...patch })), null);
  }
  for (const patch of [{ mtu: "1400" }, { mtu: 1279 }, { mtu: 1501 }, { mtu: 1400.5 }, { ipv6_mode: "auto" }, { udp_timeout: "forever" }]) {
    assert.equal(decodeNetworkStatus(envelope("network.status", { ...network, configured: { ...network.configured, ...patch } })), null);
  }
  assert.equal(decodeNetworkStatus(envelope("network.status", { ...network, effective: { ...network.effective, mtu: "unknown" } })), null);
});

test("error decoding is schema- and command-bound, never an instruction to use text fallback", () => {
  const error = (command, schema = 1) => JSON.stringify({ schema, ok: false, command,
    error: { code: "machine.unsupported_command", message: "unsupported" } });
  assert.equal(machineErrorCode(error("machine.error"), "dns.status"), "machine.unsupported_command");
  assert.equal(machineErrorCode(error("dns.status"), "dns.status"), "machine.unsupported_command");
  assert.equal(machineErrorCode(error("network.status"), "dns.status"), "");
  assert.equal(machineErrorCode(error("machine.error", 2), "dns.status"), "");
  assert.equal(machineErrorCode("unknown command: --json", "dns.status"), "");
});

// Run the production ownership/refresh functions, not a duplicate model.
const source = ts.createSourceFile("useMagicNet.ts", readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true);
const names = ["canUpdateRefreshUi", "refreshMachineStatus", "refreshDns", "refreshNetworkStatus"];
const functions = source.statements.filter((node) => ts.isFunctionDeclaration(node) && names.includes(node.name?.text))
  .map((node) => node.getText(source)).join("\n");
const code = ts.transpileModule(functions, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
function fixture() {
  const gate = new ForegroundUiGate();
  gate.begin();
  const state = { dns: { profile: "default", primary: "old", secondary: "", transport: "default" },
    busy: false, phase: "done", notice: "previous action", output: "previous output" };
  const calls = [];
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  function run(command, label, quiet) {
    calls.push(command);
    if (!quiet) gate.begin();
    return pending;
  }
  const context = vm.createContext({ t, state, foregroundUiGate: gate, CLI: "/module/cli", decodeDnsStatus, decodeNetworkStatus,
    machineErrorCode, runShellOutcome: run, runTrackedQuietShellOutcome: (command, label) => run(command, label, false) });
  vm.runInContext(code, context);
  return { context, state, calls, resolve, gate };
}
const outcome = (stdout, ok = true) => ({ ok, stdout, stderr: "[warn] harmless diagnostics", text: stdout + "\n[warn] harmless diagnostics" });

test("shared DNS refresh uses stdout only and executes no legacy status command", async () => {
  const { context, state, calls, resolve } = fixture();
  const refreshing = context.refreshDns(true);
  resolve(outcome(envelope("dns.status", dns)));
  assert.equal(await refreshing, true);
  assert.equal(state.dns.profile, "cloudflare-doh");
  assert.equal(state.phase, "done");
  assert.deepEqual(calls, ["/module/cli --json dns status"]);
});

for (const [name, response, expectedCode] of [
  ["malformed", outcome("profile=default"), "machine.invalid_response"],
  ["unsupported", outcome(JSON.stringify({ schema: 1, ok: false, command: "machine.error", error: { code: "machine.unsupported_command", message: "unsupported" } }), false), "machine.unsupported_command"],
  ["execution failure", outcome("", false), "machine.exec_failed"],
]) {
  test(`DNS ${name} failure is visible, preserves previous data and does not downgrade`, async () => {
    const { context, state, calls, resolve } = fixture();
    const previous = state.dns;
    const refreshing = context.refreshDns(true);
    resolve(response);
    assert.equal(await refreshing, false);
    assert.equal(state.dns, previous);
    assert.equal(state.phase, "error");
    assert.equal(JSON.parse(state.output).error.code, expectedCode);
    assert.equal(calls.length, 1);
  });
}

for (const valid of [true, false]) {
  test(`stale ${valid ? "valid" : "invalid"} DNS completion cannot overwrite newer foreground feedback`, async () => {
    const { context, state, resolve, gate } = fixture();
    const previous = state.dns;
    const refreshing = context.refreshDns(true);
    gate.begin();
    Object.assign(state, { busy: true, phase: "running", notice: "new action", output: "new output" });
    resolve(outcome(valid ? envelope("dns.status", dns) : "bad response"));
    await refreshing;
    assert.equal(state.dns, previous);
    assert.equal(state.phase, "running");
    assert.equal(state.notice, "new action");
    assert.equal(state.output, "new output");
  });
}

test("refresh-all inherited ownership permits a DNS observation while its own operation is busy", async () => {
  const { context, state, resolve, gate } = fixture();
  state.busy = true;
  const refreshing = context.refreshDns(true, gate.current());
  resolve(outcome(envelope("dns.status", dns)));
  assert.equal(await refreshing, true);
  assert.equal(state.dns.profile, dns.profile);
});

test("network commits are ownership guarded and keep configured and effective data separate", async () => {
  const { context, resolve, calls } = fixture();
  let applied;
  const refreshing = context.refreshNetworkStatus((data) => { applied = data; }, true);
  resolve(outcome(envelope("network.status", network)));
  await refreshing;
  assert.deepEqual(applied, network);
  assert.deepEqual(calls, ["/module/cli --json network status"]);
  const newer = fixture();
  let lateApplied = false;
  const stale = newer.context.refreshNetworkStatus(() => { lateApplied = true; }, true);
  newer.gate.begin();
  newer.resolve(outcome(envelope("network.status", network)));
  await stale;
  assert.equal(lateApplied, false);
});

test("DNS and network components have no human-status parser or unsupported fallback", () => {
  for (const file of ["NetworkPolicyCard.vue", "DnsToolsCard.vue"]) {
    const component = readFileSync(new URL(`./src/components/pages/${file}`, import.meta.url), "utf8");
    assert.doesNotMatch(component, /machineInterfaceUnavailable|parseLegacyStatus|refreshLegacyDns|decodeMachineData/);
    assert.doesNotMatch(component, /runCli\("(?:--json )?(?:dns|network) status"/);
  }
});
