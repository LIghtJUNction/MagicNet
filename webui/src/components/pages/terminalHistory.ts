/**
 * Terminal command history manager.
 * Persists command history to `/data/adb/modules/MagicNet/.config/terminal_history.txt`
 * and keeps localStorage in sync as an instant fallback.
 */

export const TERMINAL_HISTORY_FILE = "/data/adb/modules/MagicNet/.config/terminal_history.txt";
export const TERMINAL_HISTORY_STORAGE_KEY = "magicnet.terminal.history.v1";
export const MAX_HISTORY_LENGTH = 300;

export async function loadTerminalHistory(
  runShell?: (cmd: string, label: string, quiet?: boolean) => Promise<string>,
): Promise<string[]> {
  const localHistory = readLocalStorageHistory();

  if (!runShell) {
    return localHistory;
  }

  try {
    const fileContent = await runShell(
      `cat ${TERMINAL_HISTORY_FILE} 2>/dev/null`,
      "读取终端历史记录",
      true,
    );
    const lines = fileContent
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);

    if (lines.length > 0) {
      // Merge unique lines while preserving order
      const combined = Array.from(new Set([...localHistory, ...lines])).slice(
        -MAX_HISTORY_LENGTH,
      );
      writeLocalStorageHistory(combined);
      return combined;
    }
  } catch {
    /* fallback to local storage */
  }

  return localHistory;
}

export function readLocalStorageHistory(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(TERMINAL_HISTORY_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return parsed.map(String).filter((cmd) => cmd.trim().length > 0);
    }
  } catch {
    /* ignore parse error */
  }
  return [];
}

export function writeLocalStorageHistory(history: readonly string[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(
      TERMINAL_HISTORY_STORAGE_KEY,
      JSON.stringify(history.slice(-MAX_HISTORY_LENGTH)),
    );
  } catch {
    /* ignore quota error */
  }
}

export async function appendTerminalHistory(
  command: string,
  currentHistory: string[],
  runShell?: (cmd: string, label: string, quiet?: boolean) => Promise<string>,
  quote?: (str: string) => string,
): Promise<string[]> {
  const trimmed = command.trim();
  if (!trimmed) return currentHistory;

  // Don't duplicate immediately adjacent command
  if (currentHistory.length > 0 && currentHistory[currentHistory.length - 1] === trimmed) {
    return currentHistory;
  }

  const nextHistory = [...currentHistory, trimmed].slice(-MAX_HISTORY_LENGTH);
  writeLocalStorageHistory(nextHistory);

  if (runShell && quote) {
    try {
      const escaped = quote(trimmed);
      await runShell(
        `mkdir -p /data/adb/modules/MagicNet/.config && printf '%s\\n' ${escaped} >> ${TERMINAL_HISTORY_FILE}`,
        "记录终端历史",
        true,
      );
    } catch {
      /* ignore background file append failures */
    }
  }

  return nextHistory;
}

export async function clearTerminalHistory(
  runShell?: (cmd: string, label: string, quiet?: boolean) => Promise<string>,
): Promise<void> {
  if (typeof window !== "undefined") {
    try {
      window.localStorage.removeItem(TERMINAL_HISTORY_STORAGE_KEY);
    } catch {
      /* ignore */
    }
  }

  if (runShell) {
    try {
      await runShell(
        `rm -f ${TERMINAL_HISTORY_FILE}`,
        "清除终端历史记录",
        true,
      );
    } catch {
      /* ignore */
    }
  }
}
