import assert from "node:assert/strict";

globalThis.window = globalThis;

const { SerialExecQueue } = await import("./src/composables/execQueue.ts");

const queue = new SerialExecQueue();
let secondStarted = false;

const first = queue.enqueue(
  () => new Promise((resolve) => setTimeout(() => resolve("first"), 60)),
  10,
  "first",
);
await assert.rejects(first, /first/);

const second = queue.enqueue(async () => {
  secondStarted = true;
  return "second";
}, 100, "second");

await new Promise((resolve) => setTimeout(resolve, 20));
assert.equal(secondStarted, false, "a timed-out command must remain serialized until its process settles");
assert.equal(await second, "second");

console.log("exec queue tests passed");
