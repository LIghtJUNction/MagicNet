import assert from "node:assert/strict";
import test from "node:test";
import { computed } from "vue";
import { useActionLock } from "./src/composables/useActionLock.ts";

test("action keys do not inherit properties from Object.prototype", async () => {
  const lock = useActionLock();
  for (const key of [
    "__proto__",
    "constructor",
    "toString",
    "hasOwnProperty",
  ]) {
    assert.equal(lock.isRunning(key), false, key);
    assert.equal(await lock.withAction(key, async () => key), key);
    assert.equal(lock.isRunning(key), false, key);
  }
});

test("an in-flight action is deduplicated without blocking other keys", async () => {
  const lock = useActionLock();
  const task = Promise.withResolvers();
  const running = computed(() => lock.isRunning("refresh"));
  assert.equal(running.value, false);
  const first = lock.withAction("refresh", () => task.promise);
  assert.equal(running.value, true);
  assert.equal(
    await lock.withAction("refresh", async () => assert.fail("duplicate ran")),
    undefined,
  );
  assert.equal(await lock.withAction("save", async () => "saved"), "saved");
  assert.equal(running.value, true);
  task.resolve("refreshed");
  assert.equal(await first, "refreshed");
  assert.equal(running.value, false);
  assert.equal(
    await lock.withAction("refresh", async () => "retried"),
    "retried",
  );
});

test("failed actions propagate the error and release the lock", async () => {
  const lock = useActionLock();
  const error = new Error("task failed");
  for (const task of [
    () => {
      throw error;
    },
    () => Promise.reject(error),
  ]) {
    await assert.rejects(
      lock.withAction("save", task),
      (actual) => actual === error,
    );
    assert.equal(lock.isRunning("save"), false);
    assert.equal(await lock.withAction("save", async () => "retry"), "retry");
  }
});

test("separate composable instances do not share locks", async () => {
  const first = useActionLock();
  const second = useActionLock();
  const task = Promise.withResolvers();
  const pending = first.withAction("save", () => task.promise);
  assert.equal(second.isRunning("save"), false);
  assert.equal(await second.withAction("save", async () => "saved"), "saved");
  task.resolve();
  await pending;
});
