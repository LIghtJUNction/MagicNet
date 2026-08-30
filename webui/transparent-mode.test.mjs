import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  invalidateTransparentRuntime,
  normalizeTransparentMode,
  parseRuntime,
  runtimeDefaults,
} from "./src/composables/parsers.ts";
import { setTransparentModeAction } from "./src/components/pages/controlDangerActions.ts";

const controlSource = readFileSync(new URL("./src/components/pages/ControlPage.vue", import.meta.url), "utf8");
const appSource = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const runtimeSource = readFileSync(new URL("./src/composables/useMagicNet.ts", import.meta.url), "utf8");
const runtimeInsightSource = readFileSync(
  new URL("./src/components/pages/controlRuntimeInsight.ts", import.meta.url),
  "utf8",
);

test("transparent mode parser accepts only explicit tun or ebpf", () => {
  assert.equal(normalizeTransparentMode("tun"), "tun");
  assert.equal(normalizeTransparentMode(" eBPF "), "ebpf");
  for (const invalid of ["auto", "hybrid", "proxy", "external", "tproxy", "redirect"]) {
    assert.equal(normalizeTransparentMode(invalid), null);
  }
});

test("runtime parser keeps configured and effective dataplane facts separate", () => {
  const runtime = parseRuntime(`
MagicNet
  Transparent: ebpf
mode=ebpf
configured_mode=ebpf
effective_mode=hybrid
capability=ok
local_cgroup=attached
shared_tc=attached
shared_interfaces=wlan2,usb0
recent_error=none
transition=idle
`, runtimeDefaults);

  assert.equal(runtime.transparentMode, "ebpf");
  assert.equal(runtime.transparentEffectiveMode, "hybrid");
  assert.equal(runtime.transparentCapability, "ok");
  assert.equal(runtime.transparentLocalCgroup, "attached");
  assert.equal(runtime.transparentSharedTc, "attached");
  assert.deepEqual(runtime.transparentSharedInterfaces, ["wlan2", "usb0"]);
  assert.equal(runtime.transparentRecentError, "");
  assert.equal(runtime.transparentTransition, "stable");
  assert.equal(
    parseRuntime("transition=candidate-starting\n", runtimeDefaults).transparentTransition,
    "pending",
  );
});

test("runtime parser invalidates missing or malformed transparent status", () => {
  const previous = parseRuntime("mode=ebpf\neffective_mode=local\nlocal_cgroup=attached\n", runtimeDefaults);
  assert.equal(parseRuntime("mode=proxy\n", previous).transparentMode, "unknown");

  const invalidated = invalidateTransparentRuntime(previous);
  assert.equal(invalidated.transparentMode, "unknown");
  assert.equal(invalidated.transparentEffectiveMode, "unknown");
  assert.equal(invalidated.transparentLocalCgroup, "unknown");
  assert.deepEqual(invalidated.transparentSharedInterfaces, []);
});

test("runtime parser exposes local pending and rollback without guessing attachment", () => {
  const runtime = parseRuntime(`
mode=ebpf
configured_mode=ebpf
effective_mode=local
capability=failed
local_cgroup=unknown
shared_tc=pending
shared_interfaces=none
recent_error=transition to ebpf failed at start
transition=rollback
`, runtimeDefaults);

  assert.equal(runtime.transparentEffectiveMode, "local");
  assert.equal(runtime.transparentSharedTc, "pending");
  assert.deepEqual(runtime.transparentSharedInterfaces, []);
  assert.equal(runtime.transparentTransition, "rollback");
  assert.match(runtime.transparentRecentError, /failed at start/);
});

test("mode actions invoke only the strict backend command", () => {
  assert.deepEqual(setTransparentModeAction("ebpf", "tun"), {
    key: "transparent-set-ebpf",
    args: "transparent set ebpf",
    label: "切换为 eBPF",
    message: "确认从 TUN 切换为 eBPF？MagicNet 会停止当前数据面，验证并启动目标模式；失败时将尝试恢复 TUN。",
    background: false,
  });
  assert.equal(setTransparentModeAction("tun", "ebpf").args, "transparent set tun");
});

test("control page reuses confirmation and renders non-optimistic state facts", () => {
  assert.match(controlSource, /requestDangerAction\(\s*setTransparentModeAction/);
  assert.match(controlSource, /state\.runtime\.transparentEffectiveMode/);
  assert.match(controlSource, /state\.runtime\.transparentSharedTc/);
  assert.match(controlSource, /role="alert"/);
  assert.match(controlSource, /无法读取透明代理状态/);
  assert.match(runtimeSource, /transparentFailed/);
  assert.match(runtimeSource, /invalidateTransparentRuntime/);
  assert.match(appSource, /STATUS UNAVAILABLE/);
  assert.match(runtimeInsightSource, /透明代理状态不可用/);
  assert.doesNotMatch(controlSource, /transparent set auto/);
});
