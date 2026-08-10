import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "./node_modules/typescript/lib/typescript.js";

function transpile(source) {
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      verbatimModuleSyntax: true,
    },
  }).outputText;
}

const dir = await mkdtemp(join(tmpdir(), "magicnet-dns-summary-"));
try {
  const dnsCard = readFileSync(new URL("./src/components/pages/DnsToolsCard.vue", import.meta.url), "utf8");
  assert.match(dnsCard, /dnsTestOutput\.value = await runCli\(/);
  assert.doesNotMatch(dnsCard, /state\.output\s*=\s*dnsTestOutput\.value/);

  const tone = readFileSync(new URL("./src/lib/statusTone.ts", import.meta.url), "utf8");
  await writeFile(join(dir, "statusTone.mjs"), transpile(tone), "utf8");
  const source = readFileSync(new URL("./src/components/pages/dnsTestSummary.ts", import.meta.url), "utf8")
    .replace(/from\s+["']@\/lib\/statusTone["']/g, 'from "./statusTone.mjs"');
  await writeFile(join(dir, "dnsTestSummary.mjs"), transpile(source), "utf8");
  const summary = await import(pathToFileURL(join(dir, "dnsTestSummary.mjs")).href);

  const httpError = summary.parseDnsTestSummary(
    "domain=https://www.gstatic.com/\nhttp_code=404\nremote_ip=203.0.113.10\ntime_total=0.42\n",
  );
  assert.equal(httpError.httpStatus, 404);
  assert.equal(httpError.issueCount, 0);
  assert.equal(httpError.status, "warn");
  assert.match(httpError.summary, /DNS\/网络链路可达/);
  assert.match(summary.formatDnsTestReport(httpError, "default", "bootstrap", "", "default", "raw"), /http_code=404/);

  const proxied = summary.parseDnsTestSummary(
    "domain=https://chatgpt.com/\nprobe_path=magicnet-mixed\nhttp_code=200\nproxy_ip=127.0.0.1\ntime_total=0.31\n",
  );
  assert.equal(proxied.status, "ok");
  assert.equal(proxied.probePath, "magicnet-mixed");
  assert.equal(proxied.proxyIp, "127.0.0.1");
  assert.equal(proxied.remoteIp, "");
  assert.match(proxied.summary, /MagicNet 混合入口/);
  const proxiedReport = summary.formatDnsTestReport(proxied, "default", "bootstrap", "", "default", "raw");
  assert.match(proxiedReport, /probe_path=magicnet-mixed/);
  assert.match(proxiedReport, /proxy_ip=127\.0\.0\.1/);
  assert.match(proxiedReport, /remote_ip=none/);

  const transportError = summary.parseDnsTestSummary(
    "domain=https://example.invalid/\nhttp_code=000\nremote_ip=\ntime_total=6.00\ncurl: (6) Could not resolve host\n",
  );
  assert.equal(transportError.httpStatus, null);
  assert.equal(transportError.status, "fail");
  assert.equal(transportError.issueCount, 1);

  for (const invalidCode of ["000", "099", "600", "999"]) {
    const invalid = summary.parseDnsTestSummary(
      `domain=https://example.invalid/\nhttp_code=${invalidCode}\nremote_ip=\ntime_total=6.00\n`,
    );
    assert.equal(invalid.httpStatus, null, `${invalidCode} is not an HTTP status`);
  }
} finally {
  await rm(dir, { recursive: true, force: true });
}

console.log("dns test summary tests passed");
