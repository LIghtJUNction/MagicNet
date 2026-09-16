import assert from "node:assert/strict";
import test from "node:test";
import jsQR from "jsqr";
import { generateQrMatrix, generateQrSvgPath } from "./src/lib/qrcode.ts";

function decode(matrix) {
  const scale = 4;
  const quiet = 4;
  const width = (matrix.length + quiet * 2) * scale;
  const pixels = new Uint8ClampedArray(width * width * 4).fill(255);
  for (let y = 0; y < matrix.length; y++) {
    for (let x = 0; x < matrix.length; x++) {
      if (!matrix[y][x]) continue;
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const offset = (((y + quiet) * scale + dy) * width + (x + quiet) * scale + dx) * 4;
          pixels.fill(0, offset, offset + 3);
        }
      }
    }
  }
  return jsQR(pixels, width, width, { inversionAttempts: "dontInvert" });
}

for (const [name, text] of [
  ["plain text", "hello"],
  ["Tailscale login", "https://login.tailscale.com/a/fixtureAuth"],
  ["UTF-8", "连接 MagicNet — 日本語 🌐"],
  ["version information", "a".repeat(180)],
  ["large payload", "a".repeat(500)],
]) {
  test(`independent decoder round-trips ${name} without truncation`, () => {
    const { matrix, size } = generateQrMatrix(text);
    assert.equal(matrix.length, size);
    assert.ok(matrix.every(row => row.length === size));
    assert.equal(decode(matrix)?.data, text);
    if (text.length >= 180) assert.ok(size >= 45, "exercise version >= 7");
    const svg = generateQrSvgPath(text);
    assert.equal(svg.size, size);
    const modules = [...svg.path.matchAll(/M(\d+) (\d+)h1v1h-1z/g)];
    assert.equal(modules.length, matrix.flat().filter(Boolean).length);
    const rendered = Array.from({ length: size }, () => Array(size).fill(false));
    for (const [, x, y] of modules) rendered[Number(y)][Number(x)] = true;
    assert.deepEqual(rendered, matrix);
  });
}

test("empty and over-capacity input fail without leaking private input", () => {
  assert.throws(() => generateQrMatrix(""), RangeError);
  const privateInput = "https://login.tailscale.com/a/" + "secret".repeat(500);
  assert.throws(() => generateQrSvgPath(privateInput), error =>
    error instanceof RangeError && !error.message.includes("secret"));
});
