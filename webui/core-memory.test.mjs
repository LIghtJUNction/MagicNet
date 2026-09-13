import test from "node:test";
import assert from "node:assert/strict";
import { parseRuntime, runtimeDefaults } from "./src/composables/parsers.ts";

test("core RSS is parsed in KiB and clears on unavailable or stopped runtime", () => {
  const running = parseRuntime(
    "sing-box: 123\nsing-box-rss-kib: 131072",
    runtimeDefaults,
  );
  assert.equal(running.singBoxRssKib, 131072);
  for (const value of ["unknown", "", "-1", "NaN", "1.5", "9007199254740992"]) {
    assert.equal(
      parseRuntime(`sing-box: 123\nsing-box-rss-kib: ${value}`, running)
        .singBoxRssKib,
      null,
    );
  }
  assert.equal(parseRuntime("sing-box: 123", running).singBoxRssKib, null);
  assert.equal(
    parseRuntime("sing-box: stopped\nsing-box-rss-kib: 123", running)
      .singBoxRssKib,
    null,
  );
});
