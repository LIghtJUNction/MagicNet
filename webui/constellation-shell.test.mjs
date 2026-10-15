import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { isPaletteShortcut, rankPaletteEntries, scorePaletteEntry } from "./src/components/commandPalette.ts";
import { buildConstellation } from "./src/components/pages/constellationPath.ts";
import { parseMachineHotspot, parseMachineRuntime } from "./src/composables/machineStatus.ts";
import { runtimeDefaults } from "./src/composables/parsers.ts";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const envelope = (command, data) => JSON.stringify({ schema: 1, ok: true, command, data });

const entries = [
  { id: "tab:control", label: "概览", group: "运行", hint: "服务状态、代理模式与热点", keywords: ["overview", "tun"] },
  { id: "tab:subs", label: "订阅", group: "配置", hint: "来源、用量与自动更新", keywords: ["subscription", "nodes"] },
  { id: "tab:terminal", label: "终端", group: "诊断", keywords: ["terminal", "cli"] },
  { id: "action:theme", label: "切换外观", group: "操作", keywords: ["theme", "dark"] },
];

test("palette keeps navigation order for an empty query and ranks direct label hits first", () => {
  assert.deepEqual(rankPaletteEntries(entries, "").map((entry) => entry.id), entries.map((entry) => entry.id));
  assert.equal(rankPaletteEntries(entries, "订阅")[0].id, "tab:subs");
  assert.equal(rankPaletteEntries(entries, "  SUB ")[0].id, "tab:subs");
  assert.equal(rankPaletteEntries(entries, "dark")[0].id, "action:theme");
  assert.deepEqual(rankPaletteEntries(entries, "zzzz-no-match"), []);
});

test("palette matches the active-locale translation as well as the source label", () => {
  const english = { 概览: "Overview", 订阅: "Subscriptions", 终端: "Terminal" };
  const translate = (source) => english[source] ?? source;
  assert.equal(rankPaletteEntries(entries, "overv", translate)[0].id, "tab:control");
  assert.ok(scorePaletteEntry(entries[2], "trm", translate) > 0, "ordered subsequence still matches");
  assert.ok(scorePaletteEntry(entries[1], "订阅", translate) > scorePaletteEntry(entries[1], "更新", translate));
});

test("palette shortcut never steals a slash typed into a field", () => {
  const key = (event) => ({ ctrlKey: false, metaKey: false, altKey: false, target: { tagName: "BODY" }, ...event });
  assert.equal(isPaletteShortcut(key({ key: "k", ctrlKey: true })), true);
  assert.equal(isPaletteShortcut(key({ key: "K", metaKey: true })), true);
  assert.equal(isPaletteShortcut(key({ key: "/" })), true);
  for (const tagName of ["INPUT", "TEXTAREA", "SELECT"]) {
    assert.equal(isPaletteShortcut(key({ key: "/", target: { tagName } })), false);
  }
  assert.equal(isPaletteShortcut(key({ key: "/", target: { tagName: "DIV", isContentEditable: true } })), false);
  assert.equal(isPaletteShortcut(key({ key: "k", ctrlKey: true, altKey: true })), false);
  assert.equal(isPaletteShortcut(key({ key: "k" })), false);
});

const ready = {
  ...runtimeDefaults,
  singBoxState: "sing-box",
  singBox: "4127",
  singBoxRssKib: 48230,
  serviceReady: true,
  transparentDataplaneReady: true,
  transparentMode: "tun",
  transparentEffectiveMode: "tun",
};

test("constellation only flows when every star is backed by evidence", () => {
  const flowing = buildConstellation(ready, true);
  assert.equal(flowing.summary, "flowing");
  assert.deepEqual(flowing.edges, ["flowing", "flowing", "flowing"]);
  assert.equal(flowing.stars[1].detail, "magicnet0");
  assert.match(flowing.stars[2].detail, /^PID 4127 · 47 MiB$/);

  // Unknown dataplane evidence is never drawn as captured traffic.
  const unproven = buildConstellation({ ...ready, transparentDataplaneReady: null, serviceReady: null }, true);
  assert.notEqual(unproven.summary, "flowing");
  assert.equal(unproven.stars[1].state, "unknown");
  assert.equal(unproven.edges[0], "unknown");
  assert.equal(unproven.stars[3].state, "unknown");

  // API not ready breaks only the exit link.
  const partial = buildConstellation({ ...ready, serviceReady: false }, true);
  assert.deepEqual(partial.edges, ["flowing", "flowing", "idle"]);
  assert.equal(partial.summary, "partial");

  const stopped = buildConstellation({ ...runtimeDefaults, singBoxState: "stopped", singBox: "stopped", serviceReady: false, transparentMode: "tun" }, true);
  assert.equal(stopped.summary, "stopped");
  assert.ok(stopped.stars.every((star) => star.state === "off"));

  const preview = buildConstellation(ready, false);
  assert.equal(preview.summary, "unknown");
  assert.ok(preview.stars.every((star) => star.state === "unknown"));
});

test("eBPF dataplane is described by attachments, never by magicnet0", () => {
  const ebpf = buildConstellation({ ...ready, transparentMode: "ebpf", transparentEffectiveMode: "hybrid", transparentLocalCgroup: "attached" }, true);
  assert.equal(ebpf.stars[1].label, "eBPF");
  assert.equal(ebpf.stars[1].detail, "local + shared");
  assert.doesNotMatch(JSON.stringify(ebpf), /magicnet0/);
});

test("runtime parser keeps dataplane evidence separate and never carries a stale true", () => {
  const status = (core, dataplaneReady) => envelope("service.status", {
    core: { sing_box: core },
    transparent: { configured_mode: "tun", effective_type: "tun", effective_mode: "tun", capability: "not_required", local_cgroup: "inactive", shared_tc: "inactive", shared_interface_count: 0, transition: "stable", has_recent_error: false, dataplane_ready: dataplaneReady },
    supervisors: { fswatch: "stopped" }, api: { url: "", webui: "" }, readiness: { overall: core.running === true && dataplaneReady === true ? true : core.running ? null : false },
  });
  const running = { process_state: "running", running: true, pid_summary: "10", rss_kib: 1024 };
  assert.equal(parseMachineRuntime(status(running, true)).transparentDataplaneReady, true);
  assert.equal(parseMachineRuntime(status(running, null)).transparentDataplaneReady, null);
  const stopped = { process_state: "stopped", running: false, pid_summary: "stopped", rss_kib: null };
  assert.equal(parseMachineRuntime(status(stopped, true)).transparentDataplaneReady, null);
  assert.equal(parseMachineRuntime(status(stopped, false)).transparentDataplaneReady, false);
});

test("hotspot machine status is strictly validated and privacy-minimal", () => {
  const data = (configured = {}, effective = {}) => ({
    configured: { enabled: true, outbound: "proxy", transparent_mode: "tun", ...configured },
    effective: { route_state: "waiting", offload_owned: true, tun_rule_count: 0, ...effective },
  });
  assert.deepEqual(parseMachineHotspot(envelope("hotspot.status", data())), {
    enabled: true, transparentMode: "tun", routeState: "waiting", offloadOwned: true, tunRuleCount: 0,
  });
  assert.equal(parseMachineHotspot(envelope("hotspot.status", data({ enabled: null, outbound: "unknown" }))).enabled, null);
  for (const bad of [
    data({ enabled: true, outbound: "direct" }),
    data({ outbound: "node-name" }),
    data({ transparent_mode: "auto" }),
    data({}, { route_state: "ready" }),
    data({}, { tun_rule_count: -1 }),
    data({}, { offload_owned: "1" }),
  ]) assert.equal(parseMachineHotspot(envelope("hotspot.status", bad)), null);
  assert.equal(parseMachineHotspot(envelope("wifi.inspect", data())), null);
  assert.equal(parseMachineHotspot("enabled=1\nroute_status=ready"), null, "human text is no longer parsed");
});

test("overview reads hotspot state through the machine interface", () => {
  const control = read("./src/components/pages/ControlPage.vue");
  assert.match(control, /runCli\("--json hotspot status"/);
  assert.match(control, /parseMachineHotspot\(output\)/);
  assert.doesNotMatch(control, /route_status=\(/);
  assert.match(control, /<ConstellationPath :runtime="state\.runtime" :has-device="state\.hasKsu" \/>/);
});

test("shell exposes the quick-jump palette with dialog semantics", () => {
  const app = read("./src/App.vue");
  const palette = read("./src/components/CommandPalette.vue");
  assert.match(app, /<CommandPalette v-if="showPalette" :items="paletteItems" @close="closePalette" \/>/);
  assert.match(app, /document\.addEventListener\("keydown", handlePaletteShortcut\)/);
  assert.match(app, /document\.removeEventListener\("keydown", handlePaletteShortcut\)/);
  assert.match(app, /restoreFocusAfterUpdate\(trigger\)/);
  assert.match(palette, /role="dialog"[\s\S]*aria-modal="true"/);
  assert.match(palette, /role="combobox"[\s\S]*aria-activedescendant/);
  assert.match(palette, /role="listbox"/);
  assert.match(palette, /trapFocusWithin\(event, dialog\.value\)/);
  // Palette actions never run device mutations directly.
  assert.doesNotMatch(app, /id: "action:[^"]+"[^\n]*(?:runCli|startBackgroundCli|service (?:start|stop))/);
});
