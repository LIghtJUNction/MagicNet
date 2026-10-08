import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { MODULE_DIR } from "./src/constants.ts";
import {
  backgroundAccepted,
  backgroundLaunchCommand,
  backgroundTaskBlocksLaunch,
  parseBackgroundCompletion,
} from "./src/composables/backgroundTasks.ts";

for (const [mode, status] of [["success", 0], ["failure", 7], ["terminate", 143]]) {
  test(`background ${mode} records exactly one completion and permits the next task`, (t) => {
    const directory = mkdtempSync(`${tmpdir()}/magicnet-background-lifecycle-`);
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    writeFileSync(`${directory}/cli`, `#!/bin/sh
case "$1" in
  success) exit 0 ;;
  failure) exit 7 ;;
  terminate)
    kill -TERM "$PPID"
    printf '[device-finished]\\n'
    exit 0
    ;;
esac
exit 99
`, { mode: 0o755 });

    // Wait for the actual detached child, not a timer or a simulated log.
    // Repeat failures and interruptions as well as the normal completion path.
    for (let iteration = 0; iteration < 20; iteration += 1) {
      const id = `${mode}-${iteration}`;
      const log = `${directory}/task with spaces.log`;
      const command = backgroundLaunchCommand(mode, "refresh '订阅'", log, id)
        .replaceAll(MODULE_DIR, directory);
      const result = spawnSync("/bin/sh", ["-c", `${command}; wait "$_magicnet_background_pid"`], {
        encoding: "utf8", timeout: 5000,
      });
      assert.ifError(result.error);
      assert.equal(result.status, status, result.stderr);
      assert.equal(backgroundAccepted(result.stdout, id), true);
      const output = readFileSync(log, "utf8");
      assert.deepEqual(output.match(/^\[exit\].*$/gm), [`[exit] id=${id} status=${status}`]);
      if (mode === "terminate") {
        assert.match(output, /\[device-finished\]\n\[exit\]/);
      }
      const completion = parseBackgroundCompletion(output, id);
      assert.equal(completion, status === 0 ? "done" : "error");
      assert.equal(backgroundTaskBlocksLaunch({ status: completion }), false);
    }
  });
}
