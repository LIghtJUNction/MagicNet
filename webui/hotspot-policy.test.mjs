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
const network = readFileSync(
  new URL("../src/MagicNet/lib/magicnet/network.sh", import.meta.url),
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

for (const source of [
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
]) {
  assert.match(routes, new RegExp(source.replaceAll(".", String.raw`\.`)));
}
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
assert.match(
  network,
  /magicnet_after_kernel_start_deferred_unlocked\(\)[\s\S]*magicnet_singbox_apply_hotspot_policy/,
);

console.log("hotspot policy tests passed");
