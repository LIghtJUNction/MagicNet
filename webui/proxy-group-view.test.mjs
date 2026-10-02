import assert from "node:assert/strict";
import { test } from "node:test";
import { matchingProxyGroups, matchingProxyGroupNodes } from "./src/components/pages/proxyGroupView.ts";

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
