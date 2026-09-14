import assert from "node:assert/strict";
import test from "node:test";

import {
  decodeMachineData,
  machineErrorCode,
  machineInterfaceUnavailable,
} from "./src/composables/machineStatus.ts";

test("machine decoder accepts a schema-1 response surrounded by diagnostics", () => {
  const text = [
    '{"schema":1,"ok":true,"command":"network.status","data":{"configured":{"mtu":1400}}}',
    "[warn] harmless stderr copied by the execution layer",
  ].join("\n");
  const data = decodeMachineData(text, "network.status");
  assert.equal(data?.configured?.mtu, 1400);
});

test("machine decoder rejects malformed or mismatched envelopes", () => {
  assert.equal(
    decodeMachineData('{"schema":1,"ok":true,"command":"dns.status","data":{}}', "network.status"),
    null,
  );
  assert.equal(decodeMachineData("not json", "network.status"), null);
  assert.equal(
    decodeMachineData('{"schema":2,"ok":true,"command":"network.status","data":{}}', "network.status"),
    null,
  );
});

test("machine compatibility fallback is restricted to unsupported interfaces", () => {
  const unsupported =
    '{"schema":1,"ok":false,"command":"machine.error","error":{"code":"machine.unsupported_command","message":"unsupported machine command"}}';
  assert.equal(machineErrorCode(unsupported), "machine.unsupported_command");
  assert.equal(machineInterfaceUnavailable(unsupported), true);
  assert.equal(machineInterfaceUnavailable("[error] unknown command: --json\nrc=1"), true);
  assert.equal(machineInterfaceUnavailable("[error] network unavailable\nrc=1"), false);
});
