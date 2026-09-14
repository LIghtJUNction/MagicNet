export type MachineEnvelope<T extends Record<string, unknown>> = {
  schema: 1;
  ok: true;
  command: string;
  data: T;
};

type MachineErrorEnvelope = {
  schema: 1;
  ok: false;
  command: string;
  error?: {
    code?: unknown;
    message?: unknown;
  };
};

function jsonObjects(text: string): unknown[] {
  const candidates = [text.trim(), ...text.split(/\r?\n/).map((line) => line.trim())]
    .filter((value, index, values) => value.startsWith("{") && values.indexOf(value) === index);
  const parsed: unknown[] = [];
  for (const candidate of candidates) {
    try {
      parsed.push(JSON.parse(candidate));
    } catch {
      // Device execution layers may append stderr or diagnostic lines. Only a
      // complete JSON object is eligible for the machine protocol.
    }
  }
  return parsed;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function decodeMachineData<T extends Record<string, unknown>>(
  text: string,
  expectedCommand: string,
): T | null {
  for (const value of jsonObjects(text)) {
    if (!isRecord(value)) continue;
    if (value.schema !== 1 || value.ok !== true || value.command !== expectedCommand)
      continue;
    if (!isRecord(value.data)) continue;
    return value.data as T;
  }
  return null;
}

export function machineErrorCode(text: string): string {
  for (const value of jsonObjects(text)) {
    if (!isRecord(value)) continue;
    if (value.schema !== 1 || value.ok !== false) continue;
    const envelope = value as MachineErrorEnvelope;
    const code = envelope.error?.code;
    if (typeof code === "string") return code;
  }
  return "";
}

export function machineInterfaceUnavailable(text: string): boolean {
  const code = machineErrorCode(text);
  if (code === "machine.unsupported_command") return true;
  return /unknown command[^\n]*--json|unknown command:\s*--json/i.test(text);
}
