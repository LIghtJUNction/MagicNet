import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const component = readFileSync(
  new URL("./src/components/pages/SubscriptionsPage.vue", import.meta.url),
  "utf8",
);
const installer = readFileSync(
  new URL("../src/MagicNet/customize.sh", import.meta.url),
  "utf8",
);
const defaults = ["免费", "free", "HK", "香港", "TW", "台湾"];

for (const keyword of defaults) {
  assert.match(component, new RegExp(`"${keyword}"`));
  assert.match(installer, new RegExp(`"${keyword}"`));
}
assert.match(component, /清空并保存即可关闭过滤/);
assert.match(installer, /\[ -e "\$_magicnet_filter_file" \]/);

console.log("subscription filter default tests passed");
