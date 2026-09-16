import assert from "node:assert/strict";
import test from "node:test";
import { decodeMachineData, machineErrorCode, machineFailureText, parseMachineDns, parseMachineNetwork, parseMachineRuntime } from "./src/composables/machineStatus.ts";

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

const runtime = {
  core: { sing_box: {process_state:"running",running:true,pid_summary:"123",rss_kib:131072} },
  supervisors:{fswatch:"456"}, api:{url:"http://127.0.0.1:9090",webui:"http://127.0.0.1:9090/ui"},
  readiness:{overall:true}, transparent:{configured_mode:"tun",effective_type:"tun",effective_mode:"tun",
    capability:"not_required",local_cgroup:"inactive",shared_tc:"inactive",shared_interface_count:0,
    transition:"idle",has_recent_error:false,dataplane_ready:true},
};
const parseRuntime = (data) => parseMachineRuntime(envelope("service.status", data));

test("service snapshot preserves measured memory, process and readiness independently", () => {
  const value=parseRuntime(runtime);
  assert.equal(value.singBoxState,"sing-box");
  assert.equal(value.singBoxRssKib,131072);
  assert.equal(value.serviceReady,true);
  const notReady=parseRuntime({...runtime,readiness:{overall:false}});
  assert.equal(notReady.singBoxState,"sing-box");
  assert.equal(notReady.serviceReady,false);
});

test("service snapshot does not conflate unknown with stopped or healthy", () => {
  const data={...runtime,core:{sing_box:{process_state:"unknown",running:null,pid_summary:"unknown",rss_kib:null}},readiness:{overall:null}};
  const value=parseRuntime(data);
  assert.equal(value.singBoxState,"unknown");
  assert.equal(value.serviceReady,null);
  assert.equal(value.singBoxRssKib,null);
  assert.equal(parseRuntime({...data,readiness:{overall:true}}),null);
});

test("service snapshot rejects contradictory process, malformed memory and private errors", () => {
  for (const change of [{running:false},{pid_summary:"0"},{pid_summary:""},{pid_summary:"unknown"},
    {pid_summary:"123,"},{pid_summary:"9999999999999999"},{rss_kib:-1},{rss_kib:1.5},{rss_kib:"131072"}]) {
    assert.equal(parseRuntime({...runtime,core:{sing_box:{...runtime.core.sing_box,...change}}}),null);
  }
  assert.equal(parseMachineRuntime("[error] errno=1\n"+envelope("service.status",runtime)),null);
  assert.equal(parseMachineRuntime(envelope("transparent.status",runtime)),null);
});

test("eBPF snapshot keeps configured and effective modes separate without fake interface names", () => {
  const value=parseRuntime({...runtime,transparent:{...runtime.transparent,configured_mode:"tun",
    effective_type:"ebpf",effective_mode:"shared",capability:"ok",local_cgroup:"inactive",
    shared_tc:"attached",shared_interface_count:2,transition:"rolling-back",has_recent_error:true}});
  assert.equal(value.transparentMode,"tun");
  assert.equal(value.transparentEffectiveMode,"shared");
  assert.equal(value.transparentSharedInterfaceCount,2);
  assert.deepEqual(value.transparentSharedInterfaces,[]);
  assert.equal(value.transparentTransition,"rollback");
  assert.equal(value.transparentRecentError,"recorded");
});

test("missing or malformed service snapshots cannot preserve a stale running indication", () => {
  for (const change of [{core:null},{transparent:{}},{api:null},{readiness:{}},
    {transparent:{...runtime.transparent,shared_interface_count:-1}},
    {transparent:{...runtime.transparent,has_recent_error:"false"}}]) {
    assert.equal(parseRuntime({...runtime,...change}),null);
  }
});
