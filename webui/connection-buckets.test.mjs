import assert from "node:assert/strict";
import test from "node:test";
import { connectionBuckets, parseConnectionSnapshot } from "./src/composables/parsers.ts";
import { buildConnectionInsights } from "./src/components/pages/connectionInsights.ts";

function connectionsFor(name) {
  return parseConnectionSnapshot(JSON.stringify({ connections: [
    { id: "one", metadata: { host: "example.test", processName: name }, rule: name, chains: [name], upload: 100, download: 200 },
    { id: "two", metadata: { host: "example.test", processName: name }, rule: name, chains: [name], upload: 50, download: 50 },
    { id: "three", metadata: { host: "example.test", processName: "ordinary" }, rule: "ordinary", chains: ["ordinary"], upload: 10, download: 10 },
  ] })).connections;
}

for (const name of ["__proto__", "constructor", "toString", "hasOwnProperty"]) {
  test(`connection summaries treat ${name} as an ordinary name`, () => {
    const prototypeBefore = Object.getOwnPropertyDescriptors(Object.prototype);
    const inheritedBefore = Object.getOwnPropertyDescriptors(({})[name]);
    const connections = connectionsFor(name);
    try {
      for (const kind of ["process", "rule", "chain"]) {
        const buckets = connectionBuckets(connections, kind);
        assert.deepEqual(buckets[0], { name, query: name, count: 2, bytes: 400 });
        assert.equal(buckets.length, 2);
      }
      const insights = buildConnectionInsights(connections, connections, "");
      for (const insight of insights.slice(2)) {
        assert.equal(insight.value, "400 B");
        assert.equal(insight.detail, `${name} · 2 条`);
      }
      assert.deepEqual(Object.getOwnPropertyDescriptors(Object.prototype), prototypeBefore);
      assert.deepEqual(Object.getOwnPropertyDescriptors(({})[name]), inheritedBefore);
    } finally {
      // Keep the regression isolated even when run against the buggy reducer.
      for (const target of [Object.prototype, ({})[name]]) {
        delete target.count;
        delete target.bytes;
      }
    }
  });
}

test("connection buckets retain descending totals and the top-four limit", () => {
  const connections = ["a", "b", "c", "d", "e"].flatMap(connectionsFor);
  const buckets = connectionBuckets(connections, "process");
  assert.equal(buckets.length, 4);
  assert.deepEqual(buckets.map(({ name }) => name), ["a", "b", "c", "d"]);
  assert.deepEqual(connectionBuckets([], "process"), []);
});
