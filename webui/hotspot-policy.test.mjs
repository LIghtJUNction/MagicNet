import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const control = readFileSync(
  new URL("./src/components/pages/ControlPage.vue", import.meta.url),
  "utf8",
);
const routes = readFileSync(
  new URL("../src/MagicNet/lib/magicnet/routes.sh", import.meta.url),
  "utf8",
);
const core = readFileSync(
  new URL("../src/MagicNet/lib/magicnet/core.sh", import.meta.url),
  "utf8",
);
const webuiApi = readFileSync(
  new URL("../crates/magicnet-cli/src/webui_api.rs", import.meta.url),
  "utf8",
);

assert.match(control, /type="checkbox"/);
assert.match(control, /允许热点使用代理/);
assert.match(control, /hotspot \$\{enabled \? "enable" : "disable"\}/);
assert.match(control, /proxy<\/code> 代理组/);
assert.match(control, /不勾选时统一走\s*<code>direct<\/code>/);
assert.match(control, /type HotspotPolicyPhase = "loading" \| "ready" \| "error"/);
assert.match(control, /hotspotPolicyPhase\.value = "loading"/);
assert.match(control, /hotspotPolicyPhase\.value = "error"/);
assert.match(control, /hotspotPolicyPhase !== 'ready'/);
assert.match(control, /aria-busy="hotspotPolicyPhase === 'loading'"/);
assert.match(control, /role="alert"/);
assert.match(control, /MagicNet 没读到当前热点设置/);
assert.match(control, /设备设置没变/);
assert.match(control, /重新读取/);

const hotspotRefresh = control.slice(
  control.indexOf("async function refreshHotspotPolicy"),
  control.indexOf("async function retryHotspotPolicy"),
);
assert.doesNotMatch(hotspotRefresh, /state\.(?:phase|notice)\s*=/);
assert.match(hotspotRefresh, /state\.output =/);

assert.match(routes, /magicnet_hotspot_source_cidrs/);
assert.match(routes, /magicnet_hotspot_source_cidrs_json/);
assert.match(routes, /magicnet_hotspot_active_networks/);
assert.doesNotMatch(routes, /\["10\.0\.0\.0\/8", "172\.16\.0\.0\/12", "192\.168\.0\.0\/16"\]/);
assert.match(routes, /"outbound": "hotspot"/);
assert.match(routes, /"outbounds": \["direct", "proxy"\]/);
assert.match(routes, /ip rule add priority/);
assert.match(routes, /lookup 2022/);
assert.match(routes, /magicnet_hotspot_discover_interfaces/);
assert.match(routes, /magicnet_hotspot_route_cleanup/);
assert.match(routes, /settings put global tether_offload_disabled 1/);
assert.match(routes, /magicnet_hotspot_offload_restore/);
assert.match(routes, /register_uninstall_cmd/);
assert.match(control, /关闭 Android 热点硬件加速/);
assert.match(webuiApi, /"replay"[\s\S]*sync_persisted_hotspot_offload/);
assert.match(webuiApi, /"reconcile"[\s\S]*refresh_hotspot_policy_if_stale/);
assert.match(webuiApi, /"disable"[\s\S]*refresh_hotspot_policy_if_stale/);
assert.match(webuiApi, /rollback_hotspot_enable/);
const startSingBox = core.slice(
  core.indexOf("magicnet_start_singbox_unlocked()"),
  core.indexOf("magicnet_with_start_config_lock()"),
);
assert.match(startSingBox, /magicnet_singbox_apply_hotspot_policy/);
assert.ok(
  startSingBox.indexOf("magicnet_singbox_apply_hotspot_policy") <
    startSingBox.indexOf("singbox_start"),
  "hotspot policy must be materialized before sing-box snapshots the config",
);

console.log("hotspot policy tests passed");
