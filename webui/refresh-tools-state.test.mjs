import assert from "node:assert/strict";
import { summarizeRefreshTools } from "./src/components/pages/refreshToolsState.ts";

assert.deepEqual(
  summarizeRefreshTools([
    { label: "DNS", ok: true },
    { label: "WARP", ok: true },
    { label: "MCP", ok: true },
  ], "旧输出"),
  {
    completed: true,
    notice: "工具状态已刷新。",
    output: "工具状态已刷新。",
  },
);

const partial = summarizeRefreshTools([
  { label: "DNS", ok: true },
  { label: "WARP", ok: false },
  { label: "MCP", ok: false },
], "刷新 MCP 失败：连接超时");
assert.equal(partial.completed, false);
assert.equal(partial.notice, "工具刷新不完整");
assert.match(partial.output, /WARP、MCP/);
assert.match(partial.output, /刷新 MCP 失败/);

console.log("refresh-tools state tests passed");
