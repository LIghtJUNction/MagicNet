import assert from "node:assert/strict";

const { ForegroundUiGate } = await import("./src/composables/foregroundUiGate.ts");

const gate = new ForegroundUiGate();
assert.equal(gate.current(), 0, "a new gate must have no foreground owner");
const first = gate.begin();
assert.equal(gate.owns(first), true);
assert.equal(gate.current(), first, "the current token must be observable for quiet readers");

const second = gate.begin();
assert.equal(gate.owns(first), false, "an older command must lose shared UI ownership");
assert.equal(gate.owns(second), true, "the latest command must own shared UI status");

console.log("foreground UI gate tests passed");
