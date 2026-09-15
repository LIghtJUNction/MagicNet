import assert from "node:assert/strict";
import test from "node:test";
import {
  loadTerminalHistory,
  appendTerminalHistory,
  clearTerminalHistory,
  TERMINAL_HISTORY_STORAGE_KEY,
} from "./src/components/pages/terminalHistory.ts";

test("appends and loads terminal history safely", async () => {
  const mockCalls = [];
  const mockRunShell = async (cmd) => {
    mockCalls.push(cmd);
    if (cmd.includes("cat")) return "health\nservice status\n";
    return "";
  };

  const initial = await loadTerminalHistory(mockRunShell);
  assert.deepEqual(initial, ["health", "service status"]);

  const updated = await appendTerminalHistory(
    "node list",
    initial,
    mockRunShell,
    (s) => `'${s}'`,
  );
  assert.deepEqual(updated, ["health", "service status", "node list"]);
  assert.ok(mockCalls.some((c) => c.includes("printf '%s\\n' 'node list'")));

  // Duplicate immediately adjacent command is ignored
  const deduplicated = await appendTerminalHistory(
    "node list",
    updated,
    mockRunShell,
    (s) => `'${s}'`,
  );
  assert.equal(deduplicated.length, 3);
});
