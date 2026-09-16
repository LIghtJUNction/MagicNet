import { MODULE_DIR } from "../../constants.ts";
import { execFailed, shellQuote } from "../../utils.ts";

// Commands can contain subscription URLs or credentials. Keep new history only
// in this page's memory; the legacy locations are used solely by explicit clear.
export const TERMINAL_HISTORY_FILE = `${MODULE_DIR}/.config/terminal_history.txt`;
export const TERMINAL_HISTORY_STORAGE_KEY = "magicnet.terminal.history.v1";
export const MAX_HISTORY_LENGTH = 300;
export const MAX_HISTORY_COMMAND_LENGTH = 4096;
export const MAX_TERMINAL_ENTRIES = 50;

type RunShell = (cmd: string, label: string, quiet?: boolean) => Promise<string>;

export function appendTerminalHistory(command: string, currentHistory: readonly string[]): string[] {
  const history = currentHistory.slice(-MAX_HISTORY_LENGTH).filter(
    (entry) => entry.length > 0 && entry.length <= MAX_HISTORY_COMMAND_LENGTH,
  );
  const trimmed = command.trim();
  if (!trimmed || trimmed.length > MAX_HISTORY_COMMAND_LENGTH || history.at(-1) === trimmed) {
    return history;
  }
  return [...history, trimmed].slice(-MAX_HISTORY_LENGTH);
}

// Do not read or automatically delete a user's old history. An explicit clear
// attempts both legacy stores and reports partial failure without echoing data.
export async function clearTerminalHistory(runShell?: RunShell): Promise<boolean> {
  let cleared = true;
  if (typeof window !== "undefined") {
    try {
      window.localStorage.removeItem(TERMINAL_HISTORY_STORAGE_KEY);
    } catch {
      cleared = false;
    }
  }
  if (runShell) {
    try {
      const result = await runShell(
        `rm -f ${shellQuote(TERMINAL_HISTORY_FILE)}`,
        "清除终端历史记录",
        true,
      );
      if (execFailed(result)) cleared = false;
    } catch {
      cleared = false;
    }
  }
  return cleared;
}
