import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  appPolicyModeSummary,
  appPolicyRouteDefinitions,
} from "./src/components/pages/appPolicyRouteModel.ts";
import { buildAppPolicyChangePlan } from "./src/components/pages/appPolicyChangePlan.ts";

const guide = readFileSync(
  new URL("./src/components/pages/AppPolicyRouteGuide.vue", import.meta.url),
  "utf8",
);
const page = readFileSync(
  new URL("./src/components/pages/AppsPage.vue", import.meta.url),
  "utf8",
);

assert.deepEqual(appPolicyRouteDefinitions.map((route) => route.id), ["proxy", "direct", "bypass"]);
assert.match(appPolicyRouteDefinitions.find((route) => route.id === "direct")?.traffic ?? "", /仍进入当前 MagicNet 数据面/);
assert.match(appPolicyRouteDefinitions.find((route) => route.id === "bypass")?.dns ?? "", /netd DNS 仍可能被捕获/);
assert.match(appPolicyModeSummary("blacklist"), /未列出应用进入 MagicNet/);
assert.match(appPolicyModeSummary("whitelist"), /未列出应用绕过 MagicNet 数据面/);
assert.match(appPolicyModeSummary("whitelist"), /TUN 模式下 DNS 仍可能被捕获/);

const base = {
  mode: "blacklist",
  proxy: [],
  direct: [],
  bypass: [],
  installedPackages: new Set(["com.example.app"]),
};
const bypassPlan = buildAppPolicyChangePlan(base, {
  type: "add",
  target: "bypass",
  packages: ["com.example.app"],
});
assert.equal(bypassPlan.routePreview.before, "MagicNet 一般路由规则");
assert.equal(bypassPlan.routePreview.after, "Bypass：系统网络／外部 VPN");
assert.match(bypassPlan.routePreview.activation, /自动解析 UID/);

// Removing explicit Bypass in whitelist mode changes the DNS boundary even
// though the app's traffic still stays outside the dataplane.
const whitelist = { ...base, mode: "whitelist" };
const removeBypassPlan = buildAppPolicyChangePlan(
  { ...whitelist, bypass: ["com.example.app"] },
  { type: "remove", target: "bypass", packages: ["com.example.app"] },
);
assert.equal(removeBypassPlan.routePreview.before, "Bypass：系统网络／外部 VPN");
assert.equal(removeBypassPlan.routePreview.after, "白名单未列入：系统网络／外部 VPN");
assert.match(removeBypassPlan.routePreview.traffic, /绕过当前 MagicNet 数据面/);
assert.match(removeBypassPlan.routePreview.dns, /TUN 模式下 DNS 仍可能被 MagicNet 捕获/);
assert.doesNotMatch(removeBypassPlan.routePreview.dns, /具体 App UID 会绕过/);
assert.equal(removeBypassPlan.items.find((item) => item.label === "路由变化")?.value, "1 个");

const addWhitelistBypassPlan = buildAppPolicyChangePlan(whitelist, {
  type: "add", target: "bypass", packages: ["com.example.app"],
});
assert.equal(addWhitelistBypassPlan.routePreview.before, removeBypassPlan.routePreview.after);
assert.equal(addWhitelistBypassPlan.routePreview.after, removeBypassPlan.routePreview.before);
assert.match(addWhitelistBypassPlan.routePreview.dns, /具体 App UID 会绕过/);
assert.match(addWhitelistBypassPlan.routePreview.dns, /netd DNS 仍可能被捕获/);

const whitelistModePlan = buildAppPolicyChangePlan(base, { type: "mode", mode: "whitelist" });
assert.equal(whitelistModePlan.routePreview.before, "MagicNet 一般路由规则");
assert.equal(whitelistModePlan.routePreview.after, removeBypassPlan.routePreview.after);
assert.equal(whitelistModePlan.routePreview.dns, removeBypassPlan.routePreview.dns);

for (const target of ["proxy", "direct"]) {
  const removeSelectedPlan = buildAppPolicyChangePlan(
    { ...whitelist, [target]: ["com.example.app"] },
    { type: "remove", target, packages: ["com.example.app"] },
  );
  assert.equal(removeSelectedPlan.routePreview.after, removeBypassPlan.routePreview.after);
  assert.equal(removeSelectedPlan.routePreview.dns, removeBypassPlan.routePreview.dns);
}

const reapplyPlan = buildAppPolicyChangePlan(base, { type: "reapply" });
assert.equal(reapplyPlan.routePreview.after, "相同名单，重新绑定当前 UID");
assert.match(reapplyPlan.warnings.join(" "), /应用重装/);

assert.match(guide, /aria-expanded="expanded"/);
assert.match(guide, /重新解析 App UID/);
assert.match(page, /@reapply="requestReapplyAppPolicy"/);
assert.match(page, /pendingAppAction\.plan\.routePreview\.dns/);

console.log("app policy route guide tests passed");
