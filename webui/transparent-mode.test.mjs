import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  normalizeTransparentMode,
} from "./src/composables/parsers.ts";
import { setTransparentModeAction } from "./src/components/pages/controlDangerActions.ts";

const controlSource = readFileSync(
  new URL("./src/components/pages/ControlPage.vue", import.meta.url),
  "utf8",
);
const appSource = readFileSync(
  new URL("./src/App.vue", import.meta.url),
  "utf8",
);
const runtimeSource = readFileSync(
  new URL("./src/composables/useMagicNet.ts", import.meta.url),
  "utf8",
);
const runtimeInsightSource = readFileSync(
  new URL("./src/components/pages/controlRuntimeInsight.ts", import.meta.url),
  "utf8",
);

test("transparent mode parser accepts only explicit tun or ebpf", () => {
  assert.equal(normalizeTransparentMode("tun"), "tun");
  assert.equal(normalizeTransparentMode(" eBPF "), "ebpf");
  for (const invalid of [
    "auto",
    "hybrid",
    "proxy",
    "external",
    "tproxy",
    "redirect",
  ]) {
    assert.equal(normalizeTransparentMode(invalid), null);
  }
});

test("mode actions invoke only the strict backend command", () => {
  assert.deepEqual(setTransparentModeAction("ebpf", "tun"), {
    key: "transparent-set-ebpf",
    args: "transparent set ebpf",
    label: "切换为 eBPF",
    message:
      "确认从 TUN 切换为 eBPF？MagicNet 会停止当前数据面，验证并启动目标模式；失败时将尝试恢复 TUN。",
    background: false,
  });
  assert.equal(
    setTransparentModeAction("tun", "ebpf").args,
    "transparent set tun",
  );
});

test("mode confirmation does not guess TUN when the current mode is unknown", () => {
  for (const target of ["tun", "ebpf"]) {
    const action = setTransparentModeAction(target, "unknown");
    assert.equal(action.args, `transparent set ${target}`);
    assert.match(action.message, /当前透明代理状态未知/);
    assert.match(action.message, /恢复原配置/);
    assert.doesNotMatch(action.message, /确认从 TUN|恢复 TUN/);
  }
});

test("control page reuses confirmation and renders non-optimistic state facts", () => {
  assert.match(
    controlSource,
    /requestDangerAction\(\s*setTransparentModeAction/,
  );
  assert.match(controlSource, /state\.runtime\.transparentEffectiveMode/);
  assert.match(controlSource, /state\.runtime\.transparentSharedTc/);
  assert.match(controlSource, /role="alert"/);
  assert.match(controlSource, /无法读取透明代理状态/);
  assert.match(runtimeSource, /--json service status/);
  assert.match(runtimeSource, /state\.runtime = snapshot \?\? \{ \.\.\.runtimeDefaults \}/);
  assert.doesNotMatch(runtimeSource, /"transparent status"/);
  assert.match(appSource, /transparentRouteData/);
  assert.match(runtimeInsightSource, /透明代理状态不可用/);
  assert.doesNotMatch(controlSource, /transparent set auto/);
});
