import assert from "node:assert/strict";
import test from "node:test";
import { connectionBuckets } from "./src/composables/parsers.ts";
import { buildConnectionInsights } from "./src/components/pages/connectionInsights.ts";

function target(overrides = {}) {
  return {
    id: "id",
    label: "example.com:443",
    source: "",
    network: "tcp",
    inbound: "tun",
    rule: "",
    rulePayload: "",
    chain: "",
    process: "",
    detail: "",
    upload: 0,
    download: 0,
    totalBytes: 0,
    ...overrides,
  };
}

test("connection buckets count prototype-named metadata as ordinary keys", () => {
  const connections = [
    target({ id: "1", process: "__proto__", totalBytes: 400 }),
    target({ id: "2", process: "constructor", totalBytes: 300 }),
    target({ id: "3", process: "toString", totalBytes: 200 }),
    target({ id: "4", process: "hasOwnProperty", totalBytes: 100 }),
    target({ id: "5", process: "chrome", totalBytes: 50 }),
  ];
  const buckets = connectionBuckets(connections, "process");
  assert.deepEqual(
    buckets.map((bucket) => [bucket.name, bucket.count, bucket.bytes]),
    [
      ["__proto__", 1, 400],
      ["constructor", 1, 300],
      ["toString", 1, 200],
      ["hasOwnProperty", 1, 100],
    ],
  );
  assert.equal(Object.hasOwn(Object.prototype, "count"), false);
  assert.equal(Object.prototype.toString.count, undefined);
});

test("connection insights keep prototype-named top traffic and the four-item limit", () => {
  const connections = [
    target({ id: "1", process: "__proto__", rule: "constructor", totalBytes: 800 }),
    target({ id: "2", process: "__proto__", rule: "toString", totalBytes: 200 }),
    target({ id: "3", process: "chrome", rule: "direct", totalBytes: 10 }),
  ];
  const insights = buildConnectionInsights(connections, connections, "");
  assert.equal(insights.length, 4);
  assert.match(insights[2].detail, /__proto__/);
  assert.match(insights[2].detail, /2/);
  assert.match(insights[3].detail, /constructor/);
  const buckets = connectionBuckets(
    [
      ...connections,
      target({ id: "4", process: "hasOwnProperty", totalBytes: 5 }),
      target({ id: "5", process: "valueOf", totalBytes: 4 }),
    ],
    "process",
  );
  assert.equal(buckets.length, 4);
  assert.equal(buckets[0].name, "__proto__");
  assert.equal(buckets[0].bytes, 1000);
  assert.deepEqual(
    buckets.map((bucket) => bucket.name),
    ["__proto__", "chrome", "hasOwnProperty", "valueOf"],
  );
});

test("empty connections yield no buckets or inherited object keys", () => {
  assert.deepEqual(connectionBuckets([], "process"), []);
  assert.deepEqual(connectionBuckets([], "rule"), []);
  assert.deepEqual(connectionBuckets([], "chain"), []);
});
