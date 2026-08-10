import assert from "node:assert/strict";
import { refreshAllNotice } from "./src/composables/refreshAllState.ts";

assert.equal(refreshAllNotice(true, "正在刷新面板数据"), "面板数据已刷新。");
assert.equal(
  refreshAllNotice(false, "面板刷新不完整"),
  "面板刷新不完整",
  "a failed refresh must not be overwritten by the success notice",
);
assert.equal(refreshAllNotice(false, "读取 DNS 失败"), "读取 DNS 失败");

console.log("refresh-all state tests passed");
