import assert from "node:assert/strict";
import test from "node:test";
import {
  assertCliOnlyArgs,
  stripCliPrefix,
  TERMINAL_SHELL_META_MESSAGE,
} from "./src/components/pages/terminalGuard.ts";

test("strips a cli prefix and keeps ordinary magicnet-cli arguments", () => {
  assert.equal(stripCliPrefix("cli health"), "health");
  assert.equal(stripCliPrefix("magicnet-cli service status"), "service status");
  assert.equal(assertCliOnlyArgs("service status sing-box"), "service status sing-box");
  assert.equal(assertCliOnlyArgs("dns test example.com"), "dns test example.com");
});

test("rejects shell metacharacters before the su -c boundary", () => {
  for (const args of [
    "health; id",
    "health && id",
    "health | tee /sdcard/out",
    "health `id`",
    "health $(id)",
    "health > /sdcard/out",
    "health < /sdcard/in",
    "health\nid",
  ]) {
    assert.throws(() => assertCliOnlyArgs(args), (error) => {
      assert.equal(error.message, TERMINAL_SHELL_META_MESSAGE);
      return true;
    }, args);
  }
});
