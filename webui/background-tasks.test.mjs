import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import {
  backgroundAccepted,
  backgroundLaunchCommand,
  backgroundLogCommand,
  backgroundTaskBlocksLaunch,
  backgroundLogPath,
  createBackgroundOperationId,
  isActiveSubscriptionBackgroundTask,
  parseBackgroundCompletion,
  reconcileSubscriptionCompletion,
  subscriptionLifecycleRunning,
} from "./src/composables/backgroundTasks.ts";
import { CLI, MODULE_DIR } from "./src/constants.ts";

const useMagicNetSource = readFileSync(
  new URL("./src/composables/useMagicNet.ts", import.meta.url),
  "utf8",
);
const controlRuntimeSource = readFileSync(
  new URL("./src/components/pages/controlRuntimeInsight.ts", import.meta.url),
  "utf8",
);
const controlPageSource = readFileSync(
  new URL("./src/components/pages/ControlPage.vue", import.meta.url),
  "utf8",
);
assert.match(
  useMagicNetSource,
  /async function startBackgroundCli[\s\S]*?const operationSequence = trackRedactedOperation\(\s*previewOverride \|\| redactedCliPreview\(displayArgs\),\s*label,\s*\);/,
);
assert.match(
  useMagicNetSource,
  /function followBackgroundLogs\([\s\S]*?operationSequence: number,[\s\S]*?publishTrackedOperation\(\s*operationSequence,/,
);
assert.match(
  useMagicNetSource,
  /function followBackgroundLogs[\s\S]*?refreshSubs\(true(?:,|\))/,
);
assert.match(
  useMagicNetSource,
  /async function startBackgroundCli[\s\S]*?const operationId = createBackgroundOperationId\(\);[\s\S]*?refreshSubs\(true\)/,
);
assert.match(
  useMagicNetSource,
  /const ownsForegroundUi = \(\): boolean => foregroundUiGate\.owns\(foregroundToken\);[\s\S]*?if \(!ownsForegroundUi\(\)\)[\s\S]*?followBackgroundLogs/,
);
assert.match(
  useMagicNetSource,
  /backgroundTaskBlocksLaunch\(state\.backgroundTask\)[\s\S]*?仍在后台运行或等待对账/,
);
assert.match(
  controlRuntimeSource,
  /\["running", "timeout"\]\.includes\(backgroundStatus\)/,
);
assert.match(
  controlPageSource,
  /controlRuntimeBusy\(state\.phase, state\.queueDepth, state\.backgroundTask\.status\)/,
);

const firstId = createBackgroundOperationId(1000);
const secondId = createBackgroundOperationId(1000);
assert.notEqual(firstId, secondId);
assert.notEqual(
  backgroundLogPath("refresh", firstId),
  backgroundLogPath("refresh", secondId),
  "same-label operations must not reuse logs",
);
assert.equal(
  parseBackgroundCompletion(
    "[info] running\nError: retryable upstream text\nfailed once",
    firstId,
  ),
  "running",
);
assert.equal(
  parseBackgroundCompletion(
    "[error] human output only\nno exit marker yet",
    firstId,
  ),
  "running",
);
assert.equal(
  parseBackgroundCompletion(
    `[launch] id=${firstId} label=refresh\n[exit] id=${firstId} status=0\n`,
    firstId,
  ),
  "done",
);
assert.equal(
  parseBackgroundCompletion(
    `[launch] id=${firstId} label=refresh\n[exit] id=${firstId} status=7\n`,
    firstId,
  ),
  "error",
);
assert.equal(
  parseBackgroundCompletion(`[exit] id=${firstId} status=0\n`, firstId),
  "running",
  "exit without matching launch must be ignored",
);
assert.equal(
  parseBackgroundCompletion(`[exit] id=${firstId} status=0\n`, secondId),
  "running",
  "old same-label exit marker must be ignored",
);
assert.equal(backgroundAccepted(`[accepted] id=${firstId}`, firstId), true);
assert.equal(backgroundAccepted(`[accepted] id=${firstId}`, secondId), false);

for (const status of ["done", "error", "timeout"]) {
  assert.equal(
    isActiveSubscriptionBackgroundTask({ status, args: "sub update-all" }),
    false,
  );
}
assert.equal(
  isActiveSubscriptionBackgroundTask({
    status: "running",
    args: "sub update-all",
  }),
  true,
);
assert.equal(
  isActiveSubscriptionBackgroundTask({
    status: "running",
    args: "service restart",
  }),
  false,
);
assert.equal(
  subscriptionLifecycleRunning(
    { status: "done", args: "sub update-all" },
    true,
  ),
  true,
  "device update_running must win over stale done task",
);
assert.equal(
  subscriptionLifecycleRunning(
    { status: "error", args: "sub update-all" },
    false,
  ),
  false,
);
assert.equal(backgroundTaskBlocksLaunch({ status: "idle" }), false);
assert.equal(backgroundTaskBlocksLaunch({ status: "done" }), false);
assert.equal(backgroundTaskBlocksLaunch({ status: "error" }), false);
assert.equal(backgroundTaskBlocksLaunch({ status: "running" }), true);
assert.equal(
  backgroundTaskBlocksLaunch({ status: "timeout" }),
  true,
  "an unverified timeout must block another mutating background task",
);

const command = backgroundLaunchCommand(
  "sub update-all",
  "refresh",
  "/module/.log/task.log",
  firstId,
  "rm -f '/module/.state/payload.b64'",
);
for (const token of [
  "trap",
  "setsid",
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
])
  assert.ok(command.includes(token), `background launch missing ${token}`);
const statusIndex = command.indexOf("status=$?");
const clearTrapIndex = command.indexOf("trap - EXIT HUP INT TERM", statusIndex);
const cleanupInvokeIndex = command.indexOf("cleanup; echo", clearTrapIndex);
const exitMarkerIndex = command.indexOf(
  `[exit] id=${firstId} status=$status`,
  cleanupInvokeIndex,
);
assert.ok(
  statusIndex < clearTrapIndex &&
    clearTrapIndex < cleanupInvokeIndex &&
    cleanupInvokeIndex < exitMarkerIndex,
  "cleanup must run after CLI status capture and before exit marker",
);

// The launch command must not claim acceptance when its log directory cannot
// be prepared. Execute the generated shell rather than relying on string
// shape alone so a storage/permission failure cannot become a false success.
const launchFixture = mkdtempSync(`${tmpdir()}/magicnet-background-`);
try {
  writeFileSync(`${launchFixture}/.log`, "not-a-directory");
  const setupFailureCommand = backgroundLaunchCommand(
    "true",
    "刷新",
    `${launchFixture}/task.log`,
    firstId,
  )
    .replaceAll(MODULE_DIR, launchFixture)
    .replaceAll(CLI, "/bin/true");
  const setupFailure = spawnSync("/bin/sh", ["-c", setupFailureCommand], {
    encoding: "utf8",
  });
  const setupOutput = `${setupFailure.stdout || ""}\n${setupFailure.stderr || ""}`;
  assert.notEqual(
    setupFailure.status,
    0,
    "background setup failure must fail the launch command",
  );
  assert.equal(
    setupOutput.includes(`[accepted] id=${firstId}`),
    false,
    "background setup failure must not emit accepted",
  );
} finally {
  rmSync(launchFixture, { recursive: true, force: true });
}

// Completion markers can be older than the last 80 lines of a verbose CLI
// log. The reader must retain matching markers so reconciliation still sees a
// completed operation instead of timing out forever.
const longLogFixture = mkdtempSync(`${tmpdir()}/magicnet-background-log-`);
try {
  const longLog = `${longLogFixture}/task.log`;
  const filler = Array.from(
    { length: 100 },
    (_, index) => `diagnostic-${index}`,
  );
  writeFileSync(
    longLog,
    [
      `[launch] id=${firstId} label=refresh`,
      ...filler,
      `[exit] id=${firstId} status=0`,
    ].join("\n"),
  );
  const logRead = spawnSync(
    "/bin/sh",
    ["-c", backgroundLogCommand(longLog, "sub update-all", firstId)],
    {
      encoding: "utf8",
    },
  );
  assert.equal(logRead.status, 0);
  assert.equal(
    parseBackgroundCompletion(logRead.stdout || "", firstId),
    "done",
    "long logs must retain launch/exit markers",
  );
} finally {
  rmSync(longLogFixture, { recursive: true, force: true });
}

const lifecycleBaseline = {
  subscriptionBaselineKnown: true,
  subscriptionBaselineAttemptEpoch: 100,
  subscriptionBaselineGenerationId: "generation-old",
  subscriptionBaselineResult: "success",
};
assert.equal(
  reconcileSubscriptionCompletion(
    { ...lifecycleBaseline, subscriptionBaselineKnown: false },
    {
      lastAttemptEpoch: 101,
      lastGenerationId: "generation-new",
      lastResult: "success",
    },
  ),
  "running",
  "an unverified baseline must fail closed",
);
assert.equal(
  reconcileSubscriptionCompletion(lifecycleBaseline, {
    lastAttemptEpoch: 100,
    lastGenerationId: "generation-old",
    lastResult: "success",
  }),
  "running",
  "old lifecycle success must not complete a new operation",
);
assert.equal(
  reconcileSubscriptionCompletion(lifecycleBaseline, {
    lastAttemptEpoch: 101,
    lastGenerationId: "generation-new",
    lastResult: "success",
  }),
  "done",
);
assert.equal(
  reconcileSubscriptionCompletion(lifecycleBaseline, {
    lastAttemptEpoch: 101,
    lastGenerationId: "generation-new",
    lastResult: "failed",
  }),
  "error",
);

console.log("background task tests passed");
