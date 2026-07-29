import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const control = readFileSync(
  new URL("./src/components/pages/ControlPage.vue", import.meta.url),
  "utf8",
);
const routes = readFileSync(
  new URL("../src/MagicNet/lib/magicnet/routes.sh", import.meta.url),
  "utf8",
);

assert.match(control, /type="checkbox"/);
assert.match(control, /允许热点使用代理/);
assert.match(control, /hotspot \$\{enabled \? "enable" : "disable"\}/);
assert.match(control, /proxy<\/code> 代理组/);
assert.match(control, /不勾选时统一走\s*<code>direct<\/code>/);

for (const source of [
  "192.168.0.0/16",
  "10.42.0.0/16",
  "172.20.10.0/28",
]) {
  assert.match(routes, new RegExp(source.replaceAll(".", String.raw`\.`)));
}
assert.match(routes, /"outbound": "hotspot"/);
assert.match(routes, /"outbounds": \["direct", "proxy"\]/);

console.log("hotspot policy tests passed");
