import assert from "node:assert/strict";
import { chunkSurrogateSafe } from "./src/utils.ts";

// Chunks reassemble to the original, regardless of boundary.
const ascii = "abcdefghij";
assert.equal([...chunkSurrogateSafe(ascii, 4)].join(""), ascii);
assert.deepEqual([...chunkSurrogateSafe(ascii, 4)], ["abcd", "efgh", "ij"]);

// A surrogate pair (😀 = U+1F600, two UTF-16 code units) straddling the size
// boundary must not be split — otherwise a lone surrogate corrupts on write.
const emoji = "aaa😀bbb"; // length 8 in UTF-16 code units
const chunks = [...chunkSurrogateSafe(emoji, 4)];
assert.equal(chunks.join(""), emoji);
for (const chunk of chunks) {
  // No chunk may end on a lone high surrogate.
  const last = chunk.charCodeAt(chunk.length - 1);
  assert.ok(!(last >= 0xd800 && last <= 0xdbff), `chunk ends on lone high surrogate: ${chunk}`);
}

// Empty and exact-multiple inputs behave.
assert.deepEqual([...chunkSurrogateSafe("", 4)], []);
assert.deepEqual([...chunkSurrogateSafe("abcd", 4)], ["abcd"]);

// A chunk size of one cannot keep a surrogate pair whole. Reject it rather
// than yielding an empty chunk forever at a high-surrogate boundary.
assert.throws(() => [...chunkSurrogateSafe("😀", 1)], /at least 2/);
assert.throws(() => [...chunkSurrogateSafe("a", 0)], RangeError);

console.log("chunkSurrogateSafe tests passed");
