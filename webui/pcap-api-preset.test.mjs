import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { apiCaptureFilter } from "./src/components/pages/pcapApiPreset.ts";

test("API capture follows configured IPv4/IPv6 ports, including the HTTP default", () => {
  assert.equal(apiCaptureFilter("http://127.0.0.1:19090"), "tcp port 19090");
  assert.equal(apiCaptureFilter("http://[::1]:29090"), "tcp port 29090");
  assert.equal(apiCaptureFilter("http://127.0.0.2:65535"), "tcp port 65535");
  assert.equal(apiCaptureFilter("http://127.0.0.1"), "tcp port 80");
});

test("unknown or invalid endpoints do not silently fall back to port 9090", () => {
  for (const value of ["", "unknown", "http://127.0.0.1:0", "http://127.0.0.1:65536", "https://127.0.0.1:9090", "http://example.com:9090", "http://127.0.0.1:9090@evil.example", "http://user:secret@127.0.0.1:9090", "tcp port 9090; touch marker"]) {
    assert.equal(apiCaptureFilter(value), null, value);
  }
});

test("capture presets react to the runtime endpoint rather than embed a fixed port", () => {
  const page = readFileSync(new URL("./src/components/pages/EcaptureToolsCard.vue", import.meta.url), "utf8");
  assert.match(page, /const pcapPresets = computed/);
  assert.match(page, /apiCaptureFilter\(state\.runtime\.api\)/);
  assert.doesNotMatch(page, /tcp port 9090/);
});
