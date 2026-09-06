import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";

globalThis.window = globalThis;

const { SerialExecQueue } = await import("./src/composables/execQueue.ts");

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function useClock(t) {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 });
}

test("a command that never settles cannot leave queued callers waiting forever", async (t) => {
  useClock(t);
  const queue = new SerialExecQueue();
  const first = queue.enqueue(() => new Promise(() => {}), 10, "first");
  const firstRejected = assert.rejects(first, { name: "ExecTimeoutError" });
  let waitingStarts = 0;
  const enqueueWaiting = () => assert.rejects(queue.enqueue(async () => {
    waitingStarts += 1;
  }, 20, "waiting"), /waiting/);
  const waiting = Array.from({ length: 25 }, enqueueWaiting);
  await setImmediate();
  assert.equal(queue.depth, 26);

  t.mock.timers.tick(10);
  await firstRejected;
  assert.equal(queue.depth, 26, "the underlying active command still occupies the slot");
  t.mock.timers.tick(10);
  await Promise.all(waiting);
  assert.equal(queue.depth, 1, "expired entries must be removed even if the active promise never settles");

  const retry = enqueueWaiting();
  t.mock.timers.tick(20);
  await retry;
  assert.equal(queue.depth, 1);
  assert.equal(waitingStarts, 0);
});

for (const outcome of ["resolve", "reject"]) {
  test(`late active ${outcome} resumes the queue without starting expired commands`, async (t) => {
    useClock(t);
    const depths = [];
    const queue = new SerialExecQueue((depth) => depths.push(depth));
    const operation = deferred();
    const started = [];
    const first = queue.enqueue(() => {
      started.push("first");
      return operation.promise;
    }, 10, "first");
    const firstRejected = assert.rejects(first, /first/);
    const expired = queue.enqueue(async () => { started.push("expired"); }, 20, "expired");
    const expiredRejected = assert.rejects(expired, /expired/);
    const survivor = queue.enqueue(async () => {
      started.push("survivor");
      return "done";
    }, 100, "survivor");
    await setImmediate();

    t.mock.timers.tick(10);
    await firstRejected;
    t.mock.timers.tick(10);
    await expiredRejected;
    assert.deepEqual(started, ["first"], "caller timeout must not release the execution slot");
    assert.equal(queue.depth, 2);

    operation[outcome](outcome === "reject" ? new Error("late failure") : "late result");
    assert.equal(await survivor, "done");
    await setImmediate();
    assert.deepEqual(started, ["first", "survivor"]);
    assert.equal(queue.depth, 0);
    assert.deepEqual(depths, [1, 2, 3, 2, 1, 0]);
  });
}

test("the timeout budget includes queue wait and is not reset on execution", async (t) => {
  useClock(t);
  const queue = new SerialExecQueue();
  const firstOperation = deferred();
  const secondOperation = deferred();
  const first = queue.enqueue(() => firstOperation.promise, 100, "first");
  const second = queue.enqueue(() => secondOperation.promise, 50, "second");
  const secondRejected = assert.rejects(second, /second/);
  await setImmediate();
  t.mock.timers.tick(30);
  firstOperation.resolve("done");
  await first;
  await setImmediate();
  assert.equal(queue.depth, 1);

  t.mock.timers.tick(20);
  await secondRejected;
  assert.equal(queue.depth, 1, "a started command retains its slot after its caller times out");
  secondOperation.resolve("late");
  await setImmediate();
  assert.equal(queue.depth, 0);
});

test("expired commands are skipped even before their delayed timer fires", async (t) => {
  useClock(t);
  const queue = new SerialExecQueue();
  const operation = deferred();
  const first = queue.enqueue(() => operation.promise, 100, "first");
  let expiredStarted = false;
  const expired = queue.enqueue(async () => { expiredStarted = true; }, 20, "expired");
  const expiredRejected = assert.rejects(expired, /expired/);
  const survivor = queue.enqueue(async () => "survivor", 100, "survivor");
  await setImmediate();

  t.mock.timers.setTime(30); // Advance the clock without running timeout callbacks.
  operation.resolve("done");
  await first;
  await expiredRejected;
  assert.equal(await survivor, "survivor");
  await setImmediate();
  assert.equal(expiredStarted, false);
  assert.equal(queue.depth, 0);
});

test("synchronous throws and asynchronous failures release the slot for the next command", async () => {
  const queue = new SerialExecQueue();
  const syncError = new Error("synchronous failure");
  const asyncError = new Error("asynchronous failure");
  const sync = queue.enqueue(() => { throw syncError; }, 1000, "sync");
  const async = queue.enqueue(async () => { throw asyncError; }, 1000, "async");
  const success = queue.enqueue(async () => "success", 1000, "success");
  await Promise.all([assert.rejects(sync, syncError), assert.rejects(async, asyncError)]);
  assert.equal(await success, "success");
  await setImmediate();
  assert.equal(queue.depth, 0);
});
