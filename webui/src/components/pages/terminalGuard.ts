const SHELL_META = /[;&|`$()<>\\\n\r]/;

export function stripCliPrefix(command: string): string {
  return command.replace(/^(?:cli|magicnet-cli)\s+/i, "");
}

export const TERMINAL_SHELL_META_MESSAGE =
  "终端只接受 magicnet-cli 参数，不能包含 shell 元字符。";

export function assertCliOnlyArgs(args: string): string {
  const trimmed = args.trim();
  if (!trimmed) {
    throw new Error("empty command");
  }
  if (SHELL_META.test(trimmed)) {
    throw new Error(TERMINAL_SHELL_META_MESSAGE);
  }
  return trimmed;
}
