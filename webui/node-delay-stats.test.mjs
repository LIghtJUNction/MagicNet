import assert from "node:assert/strict";
import { buildNodeDelayStats } from "./src/composables/nodeDelayParsers.ts";

function entry(node, delayMillis) {
  const quality =
    delayMillis === null ? "failed" : delayMillis <= 120 ? "fast" : delayMillis <= 250 ? "normal" : "slow";
  return { node, summary: delayMillis === null ? "timeout" : `${delayMillis}ms`, delayMillis, quality };
}

// Deliberately UNSORTED input: fastest/slowest must be derived from the actual
// delays, not from the first/last array positions.
const unsorted = [entry("mid", 180), entry("slow", 400), entry("fast", 40), entry("dead", null)];

const stats = buildNodeDelayStats(unsorted);
assert.equal(stats.fastest?.node, "fast", "fastest must be the lowest-delay node");
assert.equal(stats.slowest?.node, "slow", "slowest must be the highest-delay node");
assert.equal(stats.tested, 4);
assert.equal(stats.usable, 3);
assert.equal(stats.failed, 1);

// Empty and all-failed inputs stay well-defined.
assert.equal(buildNodeDelayStats([]).fastest, null);
assert.equal(buildNodeDelayStats([entry("dead", null)]).slowest, null);

console.log("node delay stats tests passed");
