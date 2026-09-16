from pathlib import Path
import subprocess

BASE = 'ff3b5f07a53da92696eb8c33e833de9b1dca5434'
PRS = {263: '9d1c50bfa7e325298c50a93ea6e9bcb9d614a999', 285: 'ea4add937ec9ec9acdacddb10911d98a4889d8d6', 286: 'b1dfe6cbc2d739151b9d50bf28c0acc348376383'}

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def replace(path, old, new):
    file = Path(path)
    source = file.read_text()
    assert source.count(old) == 1, (path, source.count(old), old[:100])
    file.write_text(source.replace(old, new))

for number, sha in PRS.items():
    run('git', 'fetch', 'origin', f'pull/{number}/head')
    fetched = subprocess.check_output(['git', 'rev-parse', 'FETCH_HEAD'], text=True).strip()
    assert fetched == sha, (number, fetched, sha)
for number, flags in [(286, []), (263, ['--exclude=scripts/test-host.sh']), (285, ['--include=crates/magicnet-cli/src/state.rs', '--include=crates/magicnet-cli/src/wifi.rs', '--include=crates/magicnet-cli/src/service.rs'])]:
    diff = subprocess.check_output(['git', 'diff', f'{BASE}...{PRS[number]}'])
    run('git', 'apply', *flags, input=diff)

replace('scripts/test-host.sh', 'check bash scripts/test-singbox-readiness.sh\n', 'check bash scripts/test-api-endpoint.sh\ncheck bash scripts/test-singbox-readiness.sh\n')
replace('scripts/package-smoke.sh', "    'lib/magicnet/primitives.sh' \\\n", "    'lib/magicnet/primitives.sh' \\\n    'lib/magicnet/api.sh' \\\n")

Path('webui/src/lib/qrcode.ts').write_text('''import qrcode from "qrcode-generator";

// Keep authentication URLs on the device. No remote QR service is involved.
qrcode.stringToBytes = (text: string) => Array.from(new TextEncoder().encode(text));

export function generateQrMatrix(text: string): { matrix: boolean[][]; size: number } {
  if (!text) throw new RangeError("QR data must not be empty");
  const code = qrcode(0, "M");
  code.addData(text, "Byte");
  try {
    code.make();
  } catch {
    // Never truncate the URL, or include private input in error messages.
    throw new RangeError("QR data exceeds supported capacity");
  }
  const size = code.getModuleCount();
  const matrix = Array.from({ length: size }, (_, y) =>
    Array.from({ length: size }, (_, x) => code.isDark(y, x)),
  );
  return { matrix, size };
}

export function generateQrSvgPath(text: string): { path: string; size: number } {
  const { matrix, size } = generateQrMatrix(text);
  const parts: string[] = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (matrix[y][x]) parts.push(`M${x} ${y}h1v1h-1z`);
    }
  }
  return { path: parts.join(""), size };
}
''')
Path('webui/qrcode.test.mjs').write_text('''import assert from "node:assert/strict";
import test from "node:test";
import jsQR from "jsqr";
import { generateQrMatrix, generateQrSvgPath } from "./src/lib/qrcode.ts";

function decode(matrix) {
  const scale = 4;
  const quiet = 4;
  const width = (matrix.length + quiet * 2) * scale;
  const pixels = new Uint8ClampedArray(width * width * 4).fill(255);
  for (let y = 0; y < matrix.length; y++) {
    for (let x = 0; x < matrix.length; x++) {
      if (!matrix[y][x]) continue;
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const offset = (((y + quiet) * scale + dy) * width + (x + quiet) * scale + dx) * 4;
          pixels.fill(0, offset, offset + 3);
        }
      }
    }
  }
  return jsQR(pixels, width, width, { inversionAttempts: "dontInvert" });
}

for (const [name, text] of [
  ["plain text", "hello"],
  ["Tailscale login", "https://login.tailscale.com/a/fixtureAuth"],
  ["UTF-8", "连接 MagicNet — 日本語 🌐"],
  ["version information", "a".repeat(180)],
  ["large payload", "a".repeat(500)],
]) {
  test(`independent decoder round-trips ${name} without truncation`, () => {
    const { matrix, size } = generateQrMatrix(text);
    assert.equal(matrix.length, size);
    assert.ok(matrix.every(row => row.length === size));
    assert.equal(decode(matrix)?.data, text);
    if (text.length >= 180) assert.ok(size >= 45, "exercise version >= 7");
    const svg = generateQrSvgPath(text);
    assert.equal(svg.size, size);
    const modules = [...svg.path.matchAll(/M(\\d+) (\\d+)h1v1h-1z/g)];
    assert.equal(modules.length, matrix.flat().filter(Boolean).length);
    const rendered = Array.from({ length: size }, () => Array(size).fill(false));
    for (const [, x, y] of modules) rendered[Number(y)][Number(x)] = true;
    assert.deepEqual(rendered, matrix);
  });
}

test("empty and over-capacity input fail without leaking private input", () => {
  assert.throws(() => generateQrMatrix(""), RangeError);
  const privateInput = "https://login.tailscale.com/a/" + "secret".repeat(500);
  assert.throws(() => generateQrSvgPath(privateInput), error =>
    error instanceof RangeError && !error.message.includes("secret"));
});
''')

setup = 'webui/src/components/pages/tailscaleSetup.ts'
replace(setup, '''export function removeTailscaleEndpoint(text: string): string {
  const config = parseConfig(text);
  const endpoints = (config.endpoints ?? []) as JsonObject[];
  config.endpoints = endpoints.filter((item) => item.type !== "tailscale");''', '''export function removeTailscaleEndpoint(text: string, baseline: TailscaleSnapshot): string {
  const config = parseConfig(text);
  const endpoint = endpointOf(config);
  if (!endpoint || revision(endpoint) !== baseline.endpointRevision) throw new TailscaleSetupError("conflict");
  const endpoints = (config.endpoints ?? []) as JsonObject[];
  config.endpoints = endpoints.filter((item) => item !== endpoint);''')
replace(setup, '''export async function saveTailscale(
  client: TailscaleClient,
  draft: TailscaleDraft,
  baseline: TailscaleSnapshot,
): Promise<SaveResult> {''', '''async function updateTailscale(
  client: TailscaleClient,
  transform: (text: string) => string,
): Promise<SaveResult> {''')
replace(setup, 'const candidate = buildTailscaleConfig(current.stdout, draft, baseline);', 'const candidate = transform(current.stdout);')
file = Path(setup)
source = file.read_text()
start = source.index('export async function removeTailscale(client: TailscaleClient): Promise<SaveResult> {')
file.write_text(source[:start] + '''export function saveTailscale(client: TailscaleClient, draft: TailscaleDraft, baseline: TailscaleSnapshot): Promise<SaveResult> {
  return updateTailscale(client, (text) => buildTailscaleConfig(text, draft, baseline));
}

export function removeTailscale(client: TailscaleClient, baseline: TailscaleSnapshot): Promise<SaveResult> {
  return updateTailscale(client, (text) => removeTailscaleEndpoint(text, baseline));
}
''')
page = 'webui/src/components/pages/TailscalePage.vue'
replace(page, 'type SaveResult, type SetupErrorCode, type TailscaleSnapshot,', 'type SaveResult, type SetupErrorCode, type TailscaleSnapshot, type TailscaleClient,')
replace(page, '  loginUrl.value = "";\n}\n', '  loginUrl.value = "";\n  loginMessage.value = "";\n  isOnline.value = false;\n}\n')
replace(page, ':viewBox="`0 0 ${qrInfo.size} ${qrInfo.size}`"', ':viewBox="`-4 -4 ${qrInfo.size + 8} ${qrInfo.size + 8}`"')
replace(page, 'async function submit(mode: "key" | "browser" = "key"): Promise<void> {', '''function privateClient(label: string): TailscaleClient {
  return {
    run: (args) => runPrivateCli(args, label, args.startsWith("config-editor save-file")
      ? "config-editor save-file sing-box [private-payload]" : `${args} [private-output]`),
    stage: (text) => stagePrivatePayload("tmp", `tailscale-${Date.now()}-${Math.random().toString(36).slice(2, 10)}.json`, text, t("Tailscale 私密配置")),
    remove: (name) => removePrivatePayload("tmp", name, t("Tailscale 私密配置")),
    quote: shellQuote,
    canSave: () => !state.config.dirty,
  };
}

function applySavedSnapshot(result: SaveResult): void {
  if (!result.saved || !result.snapshot) return;
  snapshot.value = result.snapshot;
  hostname.value = result.snapshot.hostname;
  edited.value = false;
  if (!state.config.dirty) {
    state.config.text = "";
    state.config.status = t("Tailscale 已更新，请重新加载配置。");
    state.config.validation = { status: "idle", summary: state.config.status, checkedAt: "" };
  }
}

async function submit(mode: "key" | "browser" = "key"): Promise<void> {''')
file = Path(page)
s = file.read_text()
start = s.index('    const result = await saveTailscale({')
end = s.index('    message.value = resultMessage(result);', start)
s = s[:start] + '''    const result = await saveTailscale(privateClient(t("配置 Tailscale")), draft, snapshot.value);
    applySavedSnapshot(result);
''' + s[end:]
start = s.index('async function disconnectTailscale(): Promise<void> {')
end = s.index('\nasync function retryRestart()', start)
s = s[:start] + '''async function disconnectTailscale(): Promise<void> {
  if (saveDisabled.value || !snapshot.value?.configured) return;
  saving.value = true;
  hasError.value = false;
  message.value = t("正在移除 Tailscale 节点并重启核心…");
  authKey.value = "";
  stopLoginPolling();
  try {
    const result = await removeTailscale(privateClient(t("移除 Tailscale")), snapshot.value);
    // Reading here would be skipped by the saving lock. The transaction's
    // confirmed snapshot is authoritative even when the restart fails.
    applySavedSnapshot(result);
    message.value = result.stage === "done"
      ? t("Tailscale 节点已移除，核心已重启。") : resultMessage(result);
    hasError.value = result.stage !== "done";
    if (result.stage === "done" || result.stage === "restart") await refreshStatus(undefined, false);
  } finally { saving.value = false; }
}
''' + s[end:]
file.write_text(s)
replace(page, ':disabled="locked"\n            @click="disconnectTailscale"', ':disabled="saveDisabled"\n            @click="disconnectTailscale"')

tests = 'webui/tailscale-setup.test.mjs'
replace(tests, 'saveTailscale, parseTailscaleLogin,', 'saveTailscale, removeTailscale, removeTailscaleEndpoint, parseTailscaleLogin,')
replace(tests, 'reads > 1 && options.conflict ? `${original()} ` : original()', 'reads > 1 && options.conflict ? `${options.source ?? original()} ` : (options.source ?? original())')
with Path(tests).open('a') as f:
    f.write('''

test("removal targets the inspected endpoint and preserves unrelated config", () => {
  const source = JSON.stringify(fixture());
  const result = JSON.parse(removeTailscaleEndpoint(source, inspectTailscale(source)));
  assert.equal(result.endpoints.some(endpoint => endpoint.type === "tailscale"), false);
  assert.deepEqual(result.route, fixture().route);
  const changed = fixture();
  changed.endpoints[0].hostname = "changed-elsewhere";
  code(() => removeTailscaleEndpoint(JSON.stringify(changed), inspectTailscale(source)), "conflict");
  changed.endpoints.push({ type: "tailscale", tag: "second" });
  code(() => removeTailscaleEndpoint(JSON.stringify(changed), inspectTailscale(source)), "multiple");
});

for (const [option, expected] of Object.entries({
  success: "done", dirty: "conflict", readFailure: "read", stageFailure: "stage",
  conflict: "conflict", validationFailure: "validate", missingReceipt: "validate",
  cleanupFailure: "cleanup", cleanupThrow: "cleanup", restartFailure: "restart", restartThrow: "restart",
})) {
  test(`removal ${option} reports the actual transaction stage`, async () => {
    const source = JSON.stringify(fixture());
    const transport = client({ source, [option]: true });
    const result = await removeTailscale(transport, inspectTailscale(source));
    assert.equal(result.stage, expected);
    const saved = ["done", "cleanup", "restart"].includes(expected);
    assert.equal(result.saved, saved);
    if (saved) assert.equal(result.snapshot.configured, false);
    assert.equal(transport.calls.includes("service restart sing-box"), ["done", "restart"].includes(expected));
    assert.equal(JSON.stringify(result).includes(key), false);
    if (["done", "restart"].includes(expected)) {
      assert.ok(transport.calls.indexOf("remove tailscale.json") < transport.calls.indexOf("service restart sing-box"));
    }
  });
}
''')

run('git', 'diff', '--check')
