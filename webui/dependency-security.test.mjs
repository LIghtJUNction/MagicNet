import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const minimum = [3, 3, 17];
const atLeast = (version, expected) => {
  const actual = version.split(".").map((part) => Number.parseInt(part, 10));
  return actual.some((part, index) => part !== expected[index])
    ? actual[0] > expected[0] ||
        (actual[0] === expected[0] &&
          (actual[1] > expected[1] ||
            (actual[1] === expected[1] && actual[2] >= expected[2])))
    : true;
};

const packageJson = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
assert.equal(packageJson.overrides?.nanoid, "3.3.17");

const packageLock = JSON.parse(
  readFileSync(new URL("./package-lock.json", import.meta.url), "utf8"),
);
const nanoidPackages = Object.entries(packageLock.packages ?? {}).filter(([path]) =>
  path.endsWith("/node_modules/nanoid"),
);
assert.ok(nanoidPackages.length > 0, "package-lock.json must contain nanoid");
for (const [path, metadata] of nanoidPackages) {
  assert.ok(atLeast(metadata.version, minimum), `${path} is vulnerable: ${metadata.version}`);
}

const bunLock = readFileSync(new URL("./bun.lock", import.meta.url), "utf8");
assert.match(bunLock, /"nanoid": "3\.3\.17"/);
assert.match(bunLock, /"nanoid": \["nanoid@3\.3\.17"/);

console.log("dependency security tests passed");
