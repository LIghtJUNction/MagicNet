import assert from "node:assert/strict";
import { test } from "node:test";
import { matchingProxyGroups, matchingProxyGroupNodes, proxyDisplayName, proxyNameLabel } from "./src/components/pages/proxyGroupView.ts";
import { setLocale } from "./src/i18n/index.ts";

const groups = Array.from({ length: 12 }, (_, index) => ({
  name: `Group ${index + 1}`,
  type: "Selector",
  now: "Node 24",
  proxies: Array.from({ length: 24 }, (_, node) => `Node ${node + 1}`),
}));

test("search finds groups and nodes beyond the initial display limits", () => {
  assert.equal(matchingProxyGroups(groups, "group 12")[0].name, "Group 12");
  assert.equal(matchingProxyGroups(groups, "node 23").length, 12);
  assert.deepEqual(matchingProxyGroupNodes(groups[0], "node 23"), ["Node 23"]);
  assert.equal(matchingProxyGroupNodes(groups[11], "group 12").length, 24);
  assert.deepEqual(matchingProxyGroups(groups, "missing node"), []);
});

test("the active node stays in the initial view without removing other choices", () => {
  const nodes = matchingProxyGroupNodes(groups[0], "");
  assert.equal(nodes[0], "Node 24");
  assert.equal(nodes.length, 24);
  assert.equal(new Set(nodes).size, 24);
  assert.deepEqual(new Set(nodes), new Set(groups[0].proxies));
  assert.equal(nodes.slice(0, 9).includes("Node 24"), true);
  assert.equal(matchingProxyGroupNodes(groups[0], "group 1")[0], "Node 24");
  assert.equal(matchingProxyGroupNodes(groups[0], "node 24")[0], "Node 24");
  assert.equal(matchingProxyGroupNodes({ ...groups[0], now: "Unknown" }, "")[0], "Node 1");
});

test("built-in names translate at render time while custom names remain unchanged", () => {
  try {
    setLocale("zh-CN");
    assert.equal(proxyNameLabel("proxy"), "代理");
    assert.equal(proxyNameLabel("direct"), "直连");
    assert.equal(proxyNameLabel("block"), "拦截");
    assert.equal(proxyNameLabel("proxy-auto"), "自动测速");
    assert.equal(proxyDisplayName("cn-direct"), "国内流量 (cn-direct)");
    for (const name of ["My private proxy", "__proto__", "constructor", "toString"]) {
      assert.equal(proxyDisplayName(name), name);
    }
    setLocale("en");
    assert.equal(proxyDisplayName("proxy"), "Proxy (proxy)");
    setLocale("ru");
    assert.equal(proxyDisplayName("direct"), "Напрямую (direct)");
  } finally { setLocale("zh-CN"); }
});

test("translated searches return the original groups and node tags for API calls", () => {
  const snapshot = [
    { name: "google-proxy", type: "Selector", now: "proxy", proxies: ["proxy", "direct", "private-node"] },
    { name: "custom", type: "Selector", now: "private-node", proxies: ["block", "private-node"] },
  ];
  const before = structuredClone(snapshot);
  assert.strictEqual(matchingProxyGroups(snapshot, "Google 服务")[0], snapshot[0]);
  assert.strictEqual(matchingProxyGroups(snapshot, "google-proxy")[0], snapshot[0]);
  assert.deepEqual(matchingProxyGroupNodes(snapshot[0], "直连"), ["direct"]);
  assert.deepEqual(matchingProxyGroupNodes(snapshot[1], "拦截"), ["block"]);
  assert.deepEqual(matchingProxyGroupNodes(snapshot[0], "Google 服务"), snapshot[0].proxies);
  assert.deepEqual(snapshot, before);
});
