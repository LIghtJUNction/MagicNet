import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(
  path.join(root, "src/components/pages/controlDangerActions.ts"),
  "utf8",
);

test("start action does not disguise a forced restart", () => {
  assert.match(source, /running \? "service stop" : "service start"/);
  assert.doesNotMatch(
    source,
    /running \? "service stop" : "service restart sing-box"/,
  );
});

test("explicit restart action remains explicit", () => {
  assert.match(source, /args: "service restart sing-box"/);
});
