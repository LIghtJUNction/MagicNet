import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const note = readFileSync(new URL("./src/components/OpenSourceSupportNote.vue", import.meta.url), "utf8");

for (const copy of [
  "关于 MagicNet 的维护与支持",
  "这个项目一直由我个人持续维护",
  "我是一名大学生",
  "AI 辅助开发、持续调用、服务器开销和排障本身都会消耗真实的 Token、时间和资源",
  "我不太想把它做成一段单纯的捐赠请求",
  "如果你刚好有实际使用需求，可以在那里购买 AI 使用额度",
  "支持 MagicNet 继续做开源维护",
  "它是一个独立的外部服务，是否使用完全自愿，不使用也不会影响 MagicNet 的任何功能",
  "一部分收入也会尽量继续投入到 MagicNet 这样的开源维护里",
  "提交 Issue、Pull Request、建议，或者帮忙测试新版本",
  "合适的时候我也会尽量提供一些使用额度回馈",
  "访问中转站",
]) {
  assert.match(note, new RegExp(copy.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

assert.match(note, /<details[\s\S]*aria-label="MagicNet 开源支持说明"/);
assert.doesNotMatch(note, /<details[^>]*\sopen(?:\s|=|>)/);
assert.match(note, /<summary[\s\S]*关于 MagicNet 的维护与支持/);
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

assert.match(app, /import OpenSourceSupportNote from "@\/components\/OpenSourceSupportNote\.vue";/);
assert.match(app, /<\/main>\s*<OpenSourceSupportNote \/>\s*<nav class="mobile-nav/m);
assert.doesNotMatch(app, /showSupportNote|supportNoteVisible|SUPPORT_NOTE_STORAGE_KEY/);

console.log("support note tests passed");
