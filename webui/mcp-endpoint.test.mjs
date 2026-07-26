import assert from "node:assert/strict";
import {
  formatMcpHostPort,
  formatMcpUrl,
  isMcpIpLiteral,
  isValidMcpPort,
  mcpDefaults,
  parseMcp,
} from "./src/composables/parsers.ts";

for (const bind of ["127.0.0.1", "0.0.0.0", "::1", "2001:db8::1", "::ffff:192.0.2.1"]) {
  assert.equal(isMcpIpLiteral(bind), true, `${bind} must be accepted as an IP literal`);
}
for (const bind of ["localhost", "example.com", "127.0.0.1$(reboot)", "[::1]", "2001:::1", ""]) {
  assert.equal(isMcpIpLiteral(bind), false, `${bind || "empty bind"} must be rejected`);
}

assert.equal(isValidMcpPort("1"), true);
assert.equal(isValidMcpPort("65535"), true);
assert.equal(isValidMcpPort("0"), false);
assert.equal(isValidMcpPort("65536"), false);
assert.equal(isValidMcpPort("8766; reboot"), false);

assert.equal(formatMcpHostPort("127.0.0.1", "8766"), "127.0.0.1:8766");
assert.equal(formatMcpHostPort("::1", "8766"), "[::1]:8766");
assert.equal(formatMcpUrl("2001:db8::1", "8766"), "http://[2001:db8::1]:8766/mcp");

const parsed = parseMcp(
  "enabled=1\nbind=::1\nport=8766\npid=42\nurl=http://::1:8766/mcp\n",
  { ...mcpDefaults },
);
assert.equal(parsed.url, "http://[::1]:8766/mcp");

console.log("MCP endpoint contract tests passed");
