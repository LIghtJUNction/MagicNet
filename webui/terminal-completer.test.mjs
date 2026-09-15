import assert from "node:assert/strict";
import test from "node:test";
import {
  getCompletions,
  applyTabCompletion,
  CLI_COMMAND_TREE,
} from "./src/components/pages/terminalCompleter.ts";

test("provides top-level suggestions and ghost text for empty or partial input", () => {
  const empty = getCompletions("");
  assert.ok(empty.suggestions.length > 10);
  assert.ok(empty.suggestions.some((s) => s.display === "service"));
  assert.ok(empty.suggestions.some((s) => s.display === "health"));
  assert.ok(empty.suggestions.some((s) => s.display === "transparent"));

  const ser = getCompletions("ser");
  assert.ok(ser.suggestions.length >= 1);
  assert.equal(ser.suggestions[0].display, "service");
  assert.equal(ser.ghostText, "vice");

  const tabResult = applyTabCompletion("ser");
  assert.equal(tabResult.completed, "service");
  assert.equal(tabResult.changed, true);
});

test("supports nested subcommands and handles 'cli ' prefix transparently", () => {
  const serviceSub = getCompletions("service ");
  assert.ok(serviceSub.suggestions.some((s) => s.display === "status"));
  assert.ok(serviceSub.suggestions.some((s) => s.display === "restart"));

  const cliServiceSub = getCompletions("cli service r");
  assert.ok(cliServiceSub.suggestions.some((s) => s.display === "restart"));
  assert.equal(cliServiceSub.ghostText, "estart");

  const tabService = applyTabCompletion("cli service r");
  assert.equal(tabService.completed, "cli service restart");

  const transparentSet = getCompletions("transparent set ");
  assert.ok(transparentSet.suggestions.some((s) => s.display === "tun"));
  assert.ok(transparentSet.suggestions.some((s) => s.display === "ebpf"));
});

test("incorporates command history for autocompletion and ghost text", () => {
  const history = ["dns set cloudflare-doh", "node test-all"];
  const res = getCompletions("dns set c", history);
  assert.ok(res.suggestions.some((s) => s.command.includes("cloudflare-doh")));
  assert.equal(res.ghostText, "loudflare-doh");
});
