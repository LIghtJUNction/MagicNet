import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { buildTailscaleConfig, inspectTailscale, saveTailscale, parseTailscaleLogin, TailscaleSetupError } from "./src/components/pages/tailscaleSetup.ts";

const key = ["tskey", "auth", "fixture-only-not-a-real-key"].join("-");
const draft = () => ({ hostname: "my-phone", authKey: key });
const original = () => JSON.stringify({
  dns: { final: "local", servers: [{ tag: "local", type: "udp", server: "192.0.2.1" }] },
  inbounds: [{ type: "tun", tag: "tun-in" }],
  outbounds: [{ type: "direct", tag: "direct" }],
  route: { final: "direct", rules: [{ domain: ["example.org"], outbound: "direct" }] },
});
const fixture = () => JSON.parse(buildTailscaleConfig(original(), draft(), inspectTailscale(original())));

test("browser login provisions a persistent endpoint without an auth key", () => {
  const result = JSON.parse(buildTailscaleConfig(original(), {hostname:"phone",authKey:"",mode:"browser"},inspectTailscale(original())));
  assert.equal(result.endpoints[0].type,"tailscale");
  assert.equal(result.endpoints[0].system_interface,false);
  assert.equal(result.endpoints[0].auth_key,undefined);
  assert.match(result.experimental.clash_api.tailscale_secret,/^[a-f0-9]{64}$/);
  assert.equal(result.experimental.clash_api.secret, undefined);
});
test("login URL is restricted to the official Tailscale device authorization path", () => {
  assert.equal(parseTailscaleLogin(JSON.stringify({state:"NeedsLogin",auth_url:"https://login.tailscale.com/a/fixture"})).authUrl,"https://login.tailscale.com/a/fixture");
  assert.equal(parseTailscaleLogin('{"state":"Running","auth_url":""}').state,"Running");
  for (const url of ["http://login.tailscale.com/a/x","https://evil.example/a/x","https://login.tailscale.com.evil.example/a/x","https://login.tailscale.com/a/x?redirect=evil","https://user@login.tailscale.com/a/x"]) {
    assert.throws(() => parseTailscaleLogin(JSON.stringify({state:"NeedsLogin",auth_url:url})));
  }
});
function code(fn, expected) {
  assert.throws(fn, (error) => error instanceof TailscaleSetupError && error.code === expected && !error.message.includes(key));
}

test("creates a persistent userspace endpoint without changing unrelated configuration", () => {
  const config = fixture();
  const { endpoints, ...rest } = config;
  assert.deepEqual(rest, JSON.parse(original()));
  assert.equal(endpoints.length, 1);
  assert.equal(endpoints[0].type, "tailscale");
  assert.equal(endpoints[0].auth_key, key);
  assert.equal(endpoints[0].system_interface, false);
  assert.equal(endpoints[0].state_directory, "/data/adb/modules/MagicNet/.state/sing-box/tailscale");
});

test("repeated saves preserve tags, state and unknown endpoint options without keeping a key in the snapshot", () => {
  const config = fixture();
  config.endpoints[0].tag = "existing-tailnet";
  config.endpoints[0].state_directory = "/existing/state";
  config.endpoints[0].accept_routes = true;
  config.endpoints[0].advertise_routes = ["192.168.9.0/24"];
  const source = JSON.stringify(config);
  const view = inspectTailscale(source);
  assert.equal(JSON.stringify(view).includes(key), false);
  const updated = JSON.parse(buildTailscaleConfig(source, { ...draft(), authKey: "" }, view));
  assert.equal(updated.endpoints.length, 1);
  assert.equal(updated.endpoints[0].tag, "existing-tailnet");
  assert.equal(updated.endpoints[0].state_directory, "/existing/state");
  assert.deepEqual(updated.endpoints[0].advertise_routes, ["192.168.9.0/24"]);
  assert.equal(updated.endpoints[0].accept_routes, true);
  assert.equal(updated.endpoints[0].auth_key, key); // Backend moves this into the protected key store.
});

test("avoids endpoint tag collisions and preserves other endpoint types", () => {
  const config = JSON.parse(original());
  config.outbounds.push({ tag: "magicnet-tailscale", type: "direct" });
  config.endpoints = [{ tag: "magicnet-tailscale-2", type: "wireguard", address: ["192.0.2.2/32"] }];
  const source = JSON.stringify(config);
  const updated = JSON.parse(buildTailscaleConfig(source, draft(), inspectTailscale(source)));
  assert.deepEqual(updated.endpoints[0], config.endpoints[0]);
  assert.equal(updated.endpoints[1].tag, "magicnet-tailscale-3");
});

test("rejects invalid config, ambiguous tailnets and keys without leaking private inputs", () => {
  for (const source of ["[]", "null", `{"secret":"${key}",`, '{"endpoints":{}}', '{"endpoints":[null]}']) {
    code(() => inspectTailscale(source), "config");
  }
  const config = fixture();
  config.endpoints.push({ type: "tailscale", tag: "second" });
  code(() => inspectTailscale(JSON.stringify(config)), "multiple");
  for (const hostname of ["", "-phone", "phone-", "x".repeat(64), "$(touch file)"]) {
    code(() => buildTailscaleConfig(original(), { ...draft(), hostname }, inspectTailscale(original())), "hostname");
  }
  for (const authKey of ["", "tskey-api-not-an-auth-key", `${key}\ncommand`, "a".repeat(500)]) {
    code(() => buildTailscaleConfig(original(), { ...draft(), authKey }, inspectTailscale(original())), "auth-key");
  }
});

test("never sends an official auth key to a custom control server", () => {
  const config = fixture();
  config.endpoints[0].control_url = "https://example.org/headscale";
  const source = JSON.stringify(config);
  assert.equal(inspectTailscale(source).controlUrl, "https://example.org/headscale");
  code(() => buildTailscaleConfig(source, draft(), inspectTailscale(source)), "custom-control");
});

test("refuses endpoint conflicts, while merging the latest unrelated configuration", () => {
  const baseline = inspectTailscale(original());
  const config = JSON.parse(original());
  config.route.final = "updated";
  const result = JSON.parse(buildTailscaleConfig(JSON.stringify(config), draft(), baseline));
  assert.equal(result.route.final, "updated");
  code(() => buildTailscaleConfig(JSON.stringify(fixture()), draft(), baseline), "conflict");
});

function client(options = {}) {
  const calls = [];
  let reads = 0;
  let staged = "";
  return {
    calls,
    get staged() { return staged; },
    run: async (args) => {
      calls.push(args);
      if (args === "config-editor get sing-box") {
        reads += 1;
        return { ok: !options.readFailure, stdout: reads > 1 && options.conflict ? `${original()} ` : original() };
      }
      if (args.startsWith("config-editor save-file")) return { ok: !options.validationFailure, stdout: options.missingReceipt ? "" : "[info] Saved and validated sing-box config" };
      if (options.restartThrow) throw Error("private output");
      return { ok: !options.restartFailure, stdout: "" };
    },
    stage: async (text) => {
      calls.push("stage"); staged = text;
      return options.stageFailure ? null : { path: "/private/tailscale.json", basename: "tailscale.json" };
    },
    remove: async (name) => { calls.push(`remove ${name}`); if (options.cleanupThrow) throw Error("private"); return !options.cleanupFailure; },
    quote: (value) => `'${value}'`,
    canSave: () => !options.dirty,
  };
}

test("private save checks the receipt and cleans its payload before restarting", async () => {
  const transport = client();
  const result = await saveTailscale(transport, draft(), inspectTailscale(original()));
  assert.equal(result.stage, "done");
  assert.equal(result.saved, true);
  assert.deepEqual(transport.calls, ["config-editor get sing-box", "stage", "config-editor get sing-box", "config-editor save-file sing-box '/private/tailscale.json'", "remove tailscale.json", "service restart sing-box"]);
  assert.equal(transport.staged.includes(key), true);
  assert.equal(JSON.stringify(transport.calls).includes(key), false);
  assert.equal(JSON.stringify(result).includes(key), false);
});

for (const [option, expected] of Object.entries({
  dirty: "conflict", readFailure: "read", stageFailure: "stage", conflict: "conflict",
  validationFailure: "validate", missingReceipt: "validate", cleanupFailure: "cleanup", cleanupThrow: "cleanup",
})) {
  test(`${option} never restarts the core`, async () => {
    const transport = client({ [option]: true });
    const result = await saveTailscale(transport, draft(), inspectTailscale(original()));
    assert.equal(result.stage, expected);
    assert.equal(transport.calls.includes("service restart sing-box"), false);
    if (["conflict", "validationFailure", "missingReceipt", "cleanupFailure", "cleanupThrow"].includes(option)) assert.ok(transport.calls.includes("remove tailscale.json"));
    if (option === "conflict") assert.equal(transport.calls.some((call) => call.startsWith("config-editor save-file")), false);
  });
}

for (const option of ["restartFailure", "restartThrow"]) {
  test(`${option} reports that saving already succeeded`, async () => {
    const result = await saveTailscale(client({ [option]: true }), draft(), inspectTailscale(original()));
    assert.equal(result.stage, "restart");
    assert.equal(result.saved, true);
    assert.equal(result.snapshot.configured, true);
  });
}

test("page uses the private transport and clears credentials when leaving KeepAlive", () => {
  const source = readFileSync(new URL("./src/components/pages/TailscalePage.vue", import.meta.url), "utf8");
  assert.match(source, /type="password"/);
  assert.match(source, /onDeactivated\(\(\) => \{ authKey.value = "";/);
  assert.match(source, /stagePrivatePayload\("tmp"/);
  assert.doesNotMatch(source, /localStorage|sessionStorage|console\.(?:log|error)|v-html|JSON\.parse/);
  assert.match(source, /state\.config\.dirty/);
  const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
  assert.match(app, /tailscale: \(\) => import\("@\/components\/pages\/TailscalePage.vue"\)/);
});
