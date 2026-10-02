import assert from "node:assert/strict";
import test from "node:test";
import { createModuleUpdateClient, moduleUpdateCapabilities, moduleUpdateCanInstall, parseModuleUpdate } from "./src/composables/moduleUpdate.ts";

const envelope = (command, data) => JSON.stringify({ schema: 1, ok: true, command, data });
const commands = ["module-update.status", "module-update.check", "module-update.install"];
const capabilities = envelope("machine.capabilities", { commands, mutation_commands: commands.slice(1) });
const data = {
  installed: { version: "v1.5.20", version_code: 10520 }, latest: { version: "v1.5.21", version_code: 10521 },
  update_available: true, phase: "available", manager: "kernelsu", supported: true, busy: false,
  reboot_required: false, recovery_required: false, error_code: null, request_id: "check_12345",
};
const status = (patch = {}, command = "module-update.status") => envelope(command, { ...data, ...patch });
const result = stdout => ({ ok: true, stdout });

test("capability negotiation requires read and explicit write capabilities", () => {
  assert.equal(moduleUpdateCapabilities(capabilities), true);
  for (const invalid of [envelope("machine.capabilities", { commands }), envelope("machine.capabilities", { commands: commands.slice(0, 2), mutation_commands: commands.slice(1) }),
    envelope("machine.capabilities", { commands, mutation_commands: ["module-update.check"] }), envelope("service.status", { commands, mutation_commands: commands.slice(1) })]) {
    assert.equal(moduleUpdateCapabilities(invalid), false);
  }
});

test("decoder preserves installed versus staged versions and unknown observations", () => {
  const staged = parseModuleUpdate(status({ phase: "reboot_required", reboot_required: true }));
  assert.equal(staged.installed.version, "v1.5.20");
  assert.equal(staged.latest.version, "v1.5.21");
  assert.equal(moduleUpdateCanInstall(staged), false);
  const unknown = parseModuleUpdate(status({ installed: { version: null, version_code: null }, update_available: null, manager: "unknown", supported: false, phase: "idle" }));
  assert.equal(unknown.installed.version, null);
  assert.equal(moduleUpdateCanInstall(unknown), false);
  assert.equal(moduleUpdateCanInstall(parseModuleUpdate(status())), true);
  for (const phase of ["checking", "downloading", "verifying", "installing"]) {
    assert.equal(moduleUpdateCanInstall(parseModuleUpdate(status({ phase, busy: false }))), false);
  }
});

test("decoder rejects private, malformed and contradictory public state", () => {
  for (const patch of [
    { installed: {} }, { latest: { version: "v1.5.21;reboot", version_code: 10521 } },
    { latest: { version: "https://private.example/token", version_code: 10521 } },
    { latest: { version: "v1.5.21", version_code: -1 } }, { latest: { version: "v1.5.21", version_code: "10521" } },
    { phase: "success" }, { manager: ["magisk"] }, { manager: ["unknown"] }, { manager: { toString: "magisk" } },
    { supported: "true" }, { busy: 0 }, { reboot_required: null }, { recovery_required: "false" },
    { error_code: "raw private device error" }, { request_id: "unsafe;reboot" },
    { phase: "reboot_required", reboot_required: false }, { manager: "unknown", supported: true },
    { latest: data.installed, update_available: true }, { installed: { version: null, version_code: null }, update_available: true },
  ]) assert.equal(parseModuleUpdate(status(patch)), null, JSON.stringify(patch));
  assert.equal(parseModuleUpdate(status({}, "module-update.install")), null);
  assert.equal(parseModuleUpdate(status() + "\n" + status()), null);
  assert.equal(parseModuleUpdate(status({ private_reason: "secret" })).private_reason, undefined);
});

test("unsupported modules cannot launch mutations or fall back to human commands", async () => {
  const writes = [];
  const client = createModuleUpdateClient(async args => { writes.push(args); return result(envelope("machine.capabilities", { commands: [], mutation_commands: [] })); });
  assert.equal(await client.discover(), false);
  await assert.rejects(client.check("webui_12345"), /unsupported_client/);
  await assert.rejects(client.install(parseModuleUpdate(status()), "webui_12345"), /unsupported_client/);
  assert.deepEqual(writes, ["--json capabilities"]);
});

test("install pins both observed versions and request id; accepted mutation is not running-version success", async () => {
  const seen = [];
  const client = createModuleUpdateClient(async args => {
    seen.push(args);
    return result(args === "--json capabilities" ? capabilities : status({ phase: "installing", busy: true, request_id: "webui_12345" }, "module-update.install"));
  });
  await client.discover();
  const accepted = await client.install(parseModuleUpdate(status()), "webui_12345");
  assert.deepEqual(seen, ["--json capabilities", "--json module-update install v1.5.20 v1.5.21 webui_12345"]);
  assert.equal(accepted.phase, "installing");
  assert.equal(accepted.installed.version, "v1.5.20");
  await assert.rejects(client.install({ ...data, installed: { version: "v1.5.20;reboot", version_code: 10520 } }, "webui_12345"), /invalid_request/);
  await assert.rejects(client.install(parseModuleUpdate(status()), "webui_12345;reboot"), /invalid_request/);
  assert.equal(seen.length, 2);
});

test("request identity, malformed output and raw exceptions cannot claim acceptance", async () => {
  const client = createModuleUpdateClient(async args => result(args === "--json capabilities" ? capabilities : status({ request_id: "another_1234" }, "module-update.check")));
  await client.discover();
  await assert.rejects(client.check("webui_12345"), /invalid_response/);
  const broken = createModuleUpdateClient(async args => args === "--json capabilities" ? result(capabilities) : { ok: false, stdout: JSON.stringify({ schema: 1, ok: false, command: "machine.error", error: { code: "module-update.conflict", message: "private device exception" } }) });
  await broken.discover();
  await assert.rejects(broken.check("webui_12345"), error => error.message === "module-update.conflict");
  const timed = createModuleUpdateClient(async args => args === "--json capabilities" ? result(capabilities) : { ok: false, stdout: "private stderr", timedOut: true });
  await timed.discover();
  await assert.rejects(timed.check("webui_12345"), /request_unconfirmed/);
});
