from pathlib import Path
r=Path('webui')
p=r/'src/composables/machineStatus.ts'
p.write_text('''import type { DnsState } from "@/types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function parseEnvelope(stdout: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(stdout);
    return isRecord(value) && value.schema === 1 ? value : null;
  } catch {
    return null;
  }
}

/** Parse stdout only: stderr is a separate execution channel, not a framing protocol. */
export function decodeMachineData<T extends Record<string, unknown>>(
  stdout: string,
  expectedCommand: string,
): T | null {
  const value = parseEnvelope(stdout);
  return value?.ok === true && value.command === expectedCommand && isRecord(value.data)
    ? value.data as T
    : null;
}

export function machineErrorCode(stdout: string, expectedCommand: string): string {
  const value = parseEnvelope(stdout);
  if (!value || value.ok !== false || !isRecord(value.error)) return "";
  // Dispatcher errors use machine.error because an unsupported request has no command result.
  if (value.command !== expectedCommand && value.command !== "machine.error") return "";
  return typeof value.error.code === "string" ? value.error.code : "";
}

export function decodeDnsStatus(stdout: string): DnsState | null {
  const data = decodeMachineData(stdout, "dns.status");
  if (!data || typeof data.profile !== "string"
    || !["default", "cloudflare-doh", "cloudflare-dot", "cloudflare-udp"].includes(data.profile)
    || typeof data.primary !== "string"
    || (data.secondary !== null && typeof data.secondary !== "string")
    || typeof data.transport !== "string") return null;
  return {
    profile: data.profile as DnsState["profile"],
    primary: data.primary,
    secondary: data.secondary ?? "",
    transport: data.transport,
  };
}

export type NetworkStatus = {
  configured: { ipv6_mode: string; mtu: number; udp_timeout: string };
  effective: { ipv6_mode: string; stack: string; mtu: number | null; udp_timeout: string };
};

export function decodeNetworkStatus(stdout: string): NetworkStatus | null {
  const data = decodeMachineData(stdout, "network.status");
  if (!data || !isRecord(data.configured) || !isRecord(data.effective)) return null;
  const { configured, effective } = data;
  if (typeof configured.ipv6_mode !== "string"
    || !["ipv4_only", "prefer_ipv4", "prefer_ipv6"].includes(configured.ipv6_mode)
    || typeof configured.mtu !== "number" || !Number.isInteger(configured.mtu)
    || configured.mtu < 1280 || configured.mtu > 1500
    || typeof configured.udp_timeout !== "string"
    || !["1m", "3m", "5m", "10m", "15m", "30m"].includes(configured.udp_timeout)
    || typeof effective.ipv6_mode !== "string" || typeof effective.stack !== "string"
    || (effective.mtu !== null && (typeof effective.mtu !== "number" || !Number.isInteger(effective.mtu)))
    || typeof effective.udp_timeout !== "string") return null;
  return data as NetworkStatus;
}
''')
p=r/'src/composables/useMagicNet.ts';s=p.read_text().replace('  parseDns,\n','')
s=s.replace('import { ForegroundUiGate }', 'import { decodeDnsStatus, decodeNetworkStatus, machineErrorCode, type NetworkStatus } from "@/composables/machineStatus";\nimport { ForegroundUiGate }',1)
a=s.index('async function refreshDns(');b=s.index('\nasync function refreshWarp(',a)
s=s[:a]+'''async function refreshMachineStatus<T>(
  args: string,
  label: string,
  decode: (stdout: string) => T | null,
  apply: (data: T) => void,
  quiet = false,
  foregroundTokenOrPreview?: number | string,
): Promise<boolean> {
  const inheritedToken = typeof foregroundTokenOrPreview === "number"
    ? foregroundTokenOrPreview : undefined;
  const preview = typeof foregroundTokenOrPreview === "string"
    ? foregroundTokenOrPreview : "";
  const before = foregroundUiGate.current();
  const command = `${CLI} --json ${args}`;
  const pending = quiet && preview
    ? runTrackedQuietShellOutcome(command, label, preview)
    : runShellOutcome(command, label, quiet, preview);
  const after = foregroundUiGate.current();
  const token = after !== before ? after : (inheritedToken ?? before);
  const allowBusy = foregroundTokenOrPreview !== undefined;
  const outcome = await pending;
  const data = outcome.ok ? decode(outcome.stdout) : null;
  if (data === null) {
    if (canUpdateRefreshUi(token, allowBusy)) {
      const commandName = args.replaceAll(" ", ".");
      const code = machineErrorCode(outcome.stdout, commandName)
        || (outcome.ok ? "machine.invalid_response" : "machine.exec_failed");
      state.phase = "error";
      state.notice = t("{p0}失败", { p0: t(label) });
      state.output = JSON.stringify({
        schema: 1, ok: false, command: commandName,
        error: { code, message: state.notice },
      });
    }
    return false;
  }
  if (canUpdateRefreshUi(token, allowBusy)) apply(data);
  return true;
}

async function refreshDns(
  quiet = false,
  foregroundTokenOrPreview?: number | string,
): Promise<boolean> {
  return refreshMachineStatus(
    "dns status", "读取 DNS", decodeDnsStatus,
    (data) => { state.dns = data; }, quiet, foregroundTokenOrPreview,
  );
}

async function refreshNetworkStatus(
  apply: (data: NetworkStatus) => void,
  quiet = false,
): Promise<boolean> {
  return refreshMachineStatus(
    "network status", "读取 UDP / IPv6 策略", decodeNetworkStatus, apply, quiet,
  );
}
''' + s[b:]
s=s.replace('    refreshDns,\n', '    refreshDns,\n    refreshNetworkStatus,\n')
p.write_text(s)
p=r/'src/composables/parsers.ts';s=p.read_text();a=s.index('export function parseDns(');b=s.index('export function parseWarp(',a);p.write_text(s[:a]+s[b:])
p=r/'src/components/pages/DnsToolsCard.vue';s=p.read_text();a=s.index('import {\n  decodeMachineData,');b=s.index('import { useActionLock',a);s=s[:a]+s[b:]
s=s.replace('refreshDns: refreshLegacyDns','refreshDns: refreshDnsStatus')
a=s.index('const dnsProfiles = [');b=s.index('const dnsSummary',a);s=s[:a]+s[b:]
a=s.index('function applyMachineDnsStatus(');b=s.index('async function runSetDnsProfile(',a);s=s[:a]+s[b:];p.write_text(s)
p=r/'src/components/pages/NetworkPolicyCard.vue';s=p.read_text();a=s.index('import {\n  decodeMachineData,');b=s.index('import { useActionLock',a);s=s[:a]+s[b:]
s=s.replace('const { state, runCli }', 'const { state, runCli, refreshNetworkStatus }')
a=s.index('const ipv6Modes = [');b=s.index('const modeHint',a);s=s[:a]+s[b:]
a=s.index('function asRecord(');b=s.index('async function applyPolicy(',a)
s=s[:a]+'''async function refreshStatus(silent = false): Promise<void> {
  await refreshNetworkStatus(({ configured, effective }) => {
    ipv6Mode.value = configured.ipv6_mode;
    mtu.value = String(configured.mtu);
    udpTimeout.value = configured.udp_timeout;
    effectiveMode.value = effective.ipv6_mode;
    effectiveStack.value = effective.stack;
    effectiveMtu.value = effective.mtu === null ? "unavailable" : String(effective.mtu);
    effectiveUdpTimeout.value = effective.udp_timeout;
  }, silent);
}

'''+s[b:];p.write_text(s)
p=r/'src/composables/issueReporter.ts';s=p.read_text()
for cmd in ['dns status','network status','transparent status','sub status']:
 s=s.replace(f'runCli("{cmd}"',f'runCli("--json {cmd}"')
p.write_text(s)
p=r/'issue-reporter-dialog.test.mjs';s=p.read_text()
for cmd in ['dns status','network status','transparent status','sub status']:
 s=s.replace(f'runCli\\("{cmd}"',f'runCli\\("--json {cmd}"').replace(f'"{cmd}"',f'"--json {cmd}"')
p.write_text(s)
p=r/'foreground-state-ownership.test.mjs';s=p.read_text().replace('  "refreshDns",\n','')
s+='''\nconst machine = functionSource("refreshMachineStatus");
assert.match(machine, /const before = foregroundUiGate\\.current\\(\\)/);
assert.match(machine, /canUpdateRefreshUi\\(token, allowBusy\\)/);
for (const name of ["refreshDns", "refreshNetworkStatus"]) {
  assert.match(functionSource(name), /refreshMachineStatus\\(/);
}
''';p.write_text(s)
