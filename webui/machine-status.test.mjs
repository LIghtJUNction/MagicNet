import assert from "node:assert/strict";
import test from "node:test";
import { decodeMachineData, machineErrorCode, machineFailureText, parseMachineDns, parseMachineNetwork } from "./src/composables/machineStatus.ts";

const envelope = (command, data) => JSON.stringify({ schema: 1, ok: true, command, data });
const dns = { profile: "default", primary: "bootstrap-local-dns", secondary: null, transport: "default" };
const network = {
  configured: { ipv6_mode: "prefer_ipv4", mtu: 1400, udp_timeout: "5m" },
  effective: { ipv6_mode: "ipv4_only", stack: "mixed", mtu: 1280, udp_timeout: "3m" },
};
const unsupported = JSON.stringify({ schema: 1, ok: false, command: "machine.error", error: { code: "machine.unsupported_command", message: "unsupported machine command" } });

test("machine decoder accepts exactly one response and bridge diagnostics", () => {
  const text = envelope("network.status", network);
  assert.deepEqual(decodeMachineData(text + "\n[warn] copied stderr", "network.status"), network);
  assert.deepEqual(decodeMachineData(JSON.stringify(JSON.parse(text), null, 2), "network.status"), network);
});

test("machine decoder rejects malformed, ambiguous or mismatched envelopes", () => {
  const good = envelope("dns.status", dns);
  for (const text of ["not json", good.replace('"schema":1', '"schema":2'), good + "\n" + good,
    unsupported + "\n" + good, good + "\n" + unsupported, '{"schema":\n' + good,
    "[error] errno=1\n" + good, good + "\ntrue", envelope("network.status", {}),
    envelope("dns.status", []), envelope("dns.status", null)]) {
    assert.equal(decodeMachineData(text, "dns.status"), null, text);
  }
});

test("unsupported machine commands stay errors rather than enabling legacy fallback", () => {
  assert.equal(machineErrorCode(unsupported), "machine.unsupported_command");
  assert.equal(machineErrorCode("[error] errno=1\n" + unsupported), "machine.unsupported_command");
  assert.equal(machineFailureText(unsupported), "[error] errno=-1\nmachine.unsupported_command");
  assert.equal(machineFailureText("unknown command --json private payload"), "[error] errno=-1\nmachine.invalid_response");
  assert.equal(machineErrorCode(unsupported.replace("machine.unsupported_command", "private token secret")), "");
});

test("DNS shape validation is shared and nullable secondary clears stale values", () => {
  assert.deepEqual(parseMachineDns(envelope("dns.status", dns)), { ...dns, secondary: "" });
  for (const invalid of [{}, { ...dns, profile: "unsupported" }, { ...dns, primary: null },
    { ...dns, secondary: false }, { ...dns, transport: "quic" }]) {
    assert.equal(parseMachineDns(envelope("dns.status", invalid)), null);
  }
  assert.equal(parseMachineDns(envelope("network.status", dns)), null);
});

test("network status preserves configured/effective differences and unknown values", () => {
  assert.deepEqual(parseMachineNetwork(envelope("network.status", network)), network);
  const unknown = { ...network, effective: { ipv6_mode: "unavailable", stack: "unavailable", mtu: null, udp_timeout: "unavailable" } };
  assert.deepEqual(parseMachineNetwork(envelope("network.status", unknown)), unknown);
});

test("network shape validation rejects partial, unsafe and out-of-policy values", () => {
  for (const configured of [{}, { ...network.configured, mtu: 1279 }, { ...network.configured, mtu: 1501 },
    { ...network.configured, mtu: 1400.5 }, { ...network.configured, mtu: "1400" },
    { ...network.configured, ipv6_mode: "auto" }, { ...network.configured, udp_timeout: "never" }]) {
    assert.equal(parseMachineNetwork(envelope("network.status", { ...network, configured })), null);
  }
  for (const mtu of [-1, 0, 1.5, "1400", Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal(parseMachineNetwork(envelope("network.status", { ...network, effective: { ...network.effective, mtu } })), null);
  }
  assert.equal(parseMachineNetwork(envelope("network.status", { configured: network.configured })), null);
});
