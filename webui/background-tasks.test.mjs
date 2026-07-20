import assert from "node:assert/strict";
import {
  backgroundAccepted,
  backgroundLaunchCommand,
  backgroundLogPath,
  createBackgroundOperationId,
  isActiveSubscriptionBackgroundTask,
  parseBackgroundCompletion,
  reconcileSubscriptionCompletion,
  subscriptionLifecycleRunning,
} from "./src/composables/backgroundTasks.ts";

const firstId = createBackgroundOperationId(1000);
const secondId = createBackgroundOperationId(1000);
assert.notEqual(firstId, secondId);
assert.notEqual(backgroundLogPath("refresh", firstId), backgroundLogPath("refresh", secondId), "same-label operations must not reuse logs");
assert.equal(parseBackgroundCompletion("[info] running\nError: retryable upstream text\nfailed once", firstId), "running");
assert.equal(parseBackgroundCompletion("[error] human output only\nno exit marker yet", firstId), "running");
assert.equal(parseBackgroundCompletion(`[launch] id=${firstId} label=refresh\n[exit] id=${firstId} status=0\n`, firstId), "done");
assert.equal(parseBackgroundCompletion(`[launch] id=${firstId} label=refresh\n[exit] id=${firstId} status=7\n`, firstId), "error");
assert.equal(parseBackgroundCompletion(`[exit] id=${firstId} status=0\n`, firstId), "running", "exit without matching launch must be ignored");
assert.equal(parseBackgroundCompletion(`[exit] id=${firstId} status=0\n`, secondId), "running", "old same-label exit marker must be ignored");
assert.equal(backgroundAccepted(`[accepted] id=${firstId}`, firstId), true);
assert.equal(backgroundAccepted(`[accepted] id=${firstId}`, secondId), false);

for (const status of ["done", "error", "timeout"]) {
  assert.equal(isActiveSubscriptionBackgroundTask({ status, args: "sub update-all" }), false);
}
assert.equal(isActiveSubscriptionBackgroundTask({ status: "running", args: "sub update-all" }), true);
assert.equal(isActiveSubscriptionBackgroundTask({ status: "running", args: "service restart" }), false);
assert.equal(subscriptionLifecycleRunning({ status: "done", args: "sub update-all" }, true), true, "device update_running must win over stale done task");
assert.equal(subscriptionLifecycleRunning({ status: "error", args: "sub update-all" }, false), false);

const command = backgroundLaunchCommand(
  "sub update-all",
  "refresh",
  "/module/.log/task.log",
  firstId,
  "rm -f '/module/.state/payload.b64'",
);
for (const token of [
  "trap",
  "EXIT",
  "HUP",
  "INT",
  "TERM",
  "background cleanup failed",
  "status=$?",
  "trap - EXIT HUP INT TERM",
  "rm -f",
  `[accepted] id=${firstId}`,
  `[launch] id=${firstId}`,
  `[exit] id=${firstId} status=$status`,
  "exit $status",
]) assert.ok(command.includes(token), `background launch missing ${token}`);
const statusIndex = command.indexOf("status=$?");
const clearTrapIndex = command.indexOf("trap - EXIT HUP INT TERM", statusIndex);
const cleanupInvokeIndex = command.indexOf("cleanup; echo", clearTrapIndex);
const exitMarkerIndex = command.indexOf(`[exit] id=${firstId} status=$status`, cleanupInvokeIndex);
assert.ok(statusIndex < clearTrapIndex && clearTrapIndex < cleanupInvokeIndex && cleanupInvokeIndex < exitMarkerIndex, "cleanup must run after CLI status capture and before exit marker");

const lifecycleBaseline = {
  subscriptionBaselineKnown: true,
  subscriptionBaselineAttemptEpoch: 100,
  subscriptionBaselineGenerationId: "generation-old",
  subscriptionBaselineResult: "success",
};
assert.equal(reconcileSubscriptionCompletion({ ...lifecycleBaseline, subscriptionBaselineKnown: false }, {
  lastAttemptEpoch: 101,
  lastGenerationId: "generation-new",
  lastResult: "success",
}), "running", "an unverified baseline must fail closed");
assert.equal(reconcileSubscriptionCompletion(lifecycleBaseline, {
  lastAttemptEpoch: 100,
  lastGenerationId: "generation-old",
  lastResult: "success",
}), "running", "old lifecycle success must not complete a new operation");
assert.equal(reconcileSubscriptionCompletion(lifecycleBaseline, {
  lastAttemptEpoch: 101,
  lastGenerationId: "generation-new",
  lastResult: "success",
}), "done");
assert.equal(reconcileSubscriptionCompletion(lifecycleBaseline, {
  lastAttemptEpoch: 101,
  lastGenerationId: "generation-new",
  lastResult: "failed",
}), "error");

console.log("background task tests passed");
