import assert from "node:assert/strict";
import { MAX_LOCAL_CONFIG_BYTES, parseLocalConfigFile } from "./src/components/pages/configFileImport.ts";

const encoder = new TextEncoder();
const imported = parseLocalConfigFile("private-config.json", encoder.encode('{"route":{"rules":[]},"outbounds":[]}'));
assert.equal(imported.fileName, "private-config.json");
assert.equal(imported.sizeBytes > 0, true);
assert.equal(imported.text, '{\n  "route": {\n    "rules": []\n  },\n  "outbounds": []\n}\n');

assert.throws(() => parseLocalConfigFile("empty.json", new Uint8Array()), /文件为空/);
assert.throws(() => parseLocalConfigFile("array.json", encoder.encode("[]")), /顶层必须是 JSON 对象/);
assert.throws(() => parseLocalConfigFile("broken.json", encoder.encode("{")), /JSON 语法错误/);
assert.throws(() => parseLocalConfigFile("binary.json", new Uint8Array([0xff, 0xfe])), /UTF-8/);
assert.throws(
  () => parseLocalConfigFile("large.json", new Uint8Array(MAX_LOCAL_CONFIG_BYTES + 1)),
  /4 MiB/,
);

console.log("config file import tests passed");
