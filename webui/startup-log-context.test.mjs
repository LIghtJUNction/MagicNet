import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeRuntimeLogLines, formatRuntimeLogIssueReport } from './src/components/pages/runtimeLogInsights.ts';
const report = lines => formatRuntimeLogIssueReport({target:'webui',lines,...analyzeRuntimeLogLines(lines)});

test('startup issue export retains adjacent unlabelled causes in chronological order', () => {
  const text = report(['[info] checking config','inbound[0]','  missing field: interface_name','◬[warn] sing-box startup failed; see the preceding core or network error.❖','[error] MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel failed with status 1']);
  assert.match(text,/warnings=1\nerrors=1\nother_issues=0\nissues=2/);
  assert.match(text,/excerpt_lines=5/);
  assert.match(text,/inbound\[0\]\n  missing field: interface_name\n◬\[warn\]/);
});

test('whole-document redaction occurs before truncation and context selection', () => {
  const secret = 'invented-multiline-key-material';
  const text = report(['[error] TLS configuration','-----BEGIN PRIVATE KEY-----',secret,'-----END PRIVATE KEY-----','Startup step failed: stage=config-check exit=1']);
  assert.doesNotMatch(text,/invented-multiline|BEGIN PRIVATE|END PRIVATE/);
  assert.match(text,/stage=config-check/);
  const json = report(['[error] authentication','{ "password":','  "invented-quoted-password"','}','Startup step failed: stage=auth exit=1']);
  assert.doesNotMatch(json,/invented-quoted-password/);
});

test('context export is bounded and preserves latest errors rather than huge earlier lines', () => {
  const lines = Array.from({length:300},(_,i)=>`[error] failure ${i}: ${'x'.repeat(3000)}`);
  const text = report(lines);
  assert.ok(text.length < 17000);
  assert.match(text,/failure 299:/);
  assert.doesNotMatch(text,/failure 0:/);
  assert.match(text,/errors=300/);
});

test('copying full output uses the same multiline redaction before keyword filtering', async () => {
  const { sanitizeOutputText } = await import('./src/components/pages/outputDiagnostics.ts');
  const original = '[error] connection\n-----BEGIN PRIVATE KEY-----\ninvented-copy-secret\n-----END PRIVATE KEY-----\n{ "password": "invented-json-copy-secret" }';
  const safe = sanitizeOutputText(original);
  assert.doesNotMatch(safe,/invented-copy-secret|invented-json-copy-secret/);
  assert.equal(safe.split('\n').filter(line => line.includes('invented-copy-secret')).join('\n'),'');
});
