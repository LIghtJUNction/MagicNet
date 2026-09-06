import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const note = readFileSync(
  new URL("./src/components/OpenSourceSupportNote.vue", import.meta.url),
  "utf8",
);

for (const copy of [
  "支持项目",
  "MagicNet 由个人维护",
  "提交 Issue、Pull Request、建议或测试结果",
  "提供独立的 AI API 服务",
  "是否使用完全自愿",
  "不使用不会影响 MagicNet 的任何功能",
  "服务收入会用于项目维护",
  "了解外部服务",
]) {
  assert.match(note, new RegExp(copy.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

assert.match(note, /<details[\s\S]*aria-label="MagicNet 开源支持说明"/);
assert.doesNotMatch(note, /<details[^>]*\sopen(?:\s|=|>)/);
assert.match(note, /<summary[\s\S]*支持项目/);
assert.match(note, /href="https:\/\/api\.lmm\.best\/"/);
assert.match(note, /target="_blank"/);
assert.match(note, /rel="noopener noreferrer"/);

for (const forbidden of [
  /localStorage/,
  /setTimeout/,
  /setInterval/,
  /onMounted/,
  /onUnmounted/,
  /position:\s*fixed/i,
  /fixed inset/i,
  /dialog/i,
  /toast/i,
  /modal/i,
  /打赏/,
  /返利/,
  /固定比例/,
  /保证/,
]) {
  assert.doesNotMatch(note, forbidden);
}

assert.match(
  app,
  /import OpenSourceSupportNote from "@\/components\/OpenSourceSupportNote\.vue";/,
);
const mainEnd = app.lastIndexOf("</main>");
const utilityIndex = app.indexOf('ref="utilityDialog"', mainEnd);
const supportIndex = app.indexOf("<OpenSourceSupportNote />", utilityIndex);
const utilityEnd = app.indexOf("</Transition>", utilityIndex);
assert.ok(
  mainEnd >= 0 &&
    utilityIndex > mainEnd &&
    supportIndex > utilityIndex &&
    supportIndex < utilityEnd,
  "support note must remain reachable in More without occupying the main task surface",
);
assert.equal(
  app.slice(0, mainEnd).includes("<OpenSourceSupportNote />"),
  false,
);
assert.doesNotMatch(
  app,
  /showSupportNote|supportNoteVisible|SUPPORT_NOTE_STORAGE_KEY/,
);

console.log("support note tests passed");
