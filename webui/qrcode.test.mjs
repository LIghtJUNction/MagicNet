import assert from "node:assert/strict";
import test from "node:test";
import { generateQrMatrix, generateQrSvgPath } from "./src/lib/qrcode.ts";

test("generates valid QR matrix and SVG path for Tailscale auth URLs", () => {
  const url = "https://login.tailscale.com/a/fixtureAuth";
  const { matrix, size } = generateQrMatrix(url);
  assert.ok(size >= 21);
  assert.equal(matrix.length, size);
  assert.equal(matrix[0].length, size);

  // Position detection pattern top-left must be 7x7 dark/light pattern
  assert.equal(matrix[0][0], true);
  assert.equal(matrix[0][6], true);
  assert.equal(matrix[6][0], true);
  assert.equal(matrix[6][6], true);
  assert.equal(matrix[1][1], false);
  assert.equal(matrix[3][3], true);

  const { path, size: svgSize } = generateQrSvgPath(url);
  assert.equal(svgSize, size);
  assert.ok(path.length > 50);
  assert.ok(path.startsWith("M"));
});
