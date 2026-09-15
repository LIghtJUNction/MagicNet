/**
 * Compact, zero-dependency QR code SVG generator.
 * Encodes UTF-8 / ASCII strings into standard QR Code matrix and returns SVG path.
 */

// Galois Field GF(256) tables for QR polynomial arithmetic
const GF256_EXP = new Uint8Array(512);
const GF256_LOG = new Uint8Array(256);

(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF256_EXP[i] = x;
    GF256_LOG[x] = i;
    x <<= 1;
    if (x & 256) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) {
    GF256_EXP[i] = GF256_EXP[i - 255];
  }
})();

function gfMul(x: number, y: number): number {
  if (x === 0 || y === 0) return 0;
  return GF256_EXP[GF256_LOG[x] + GF256_LOG[y]];
}

function polyMul(p1: Uint8Array, p2: Uint8Array): Uint8Array {
  const res = new Uint8Array(p1.length + p2.length - 1);
  for (let i = 0; i < p1.length; i++) {
    for (let j = 0; j < p2.length; j++) {
      res[i + j] ^= gfMul(p1[i], p2[j]);
    }
  }
  return res;
}

function getGeneratorPoly(degree: number): Uint8Array {
  let gen: Uint8Array = new Uint8Array([1]);
  for (let i = 0; i < degree; i++) {
    gen = new Uint8Array(polyMul(gen, new Uint8Array([1, GF256_EXP[i]])));
  }
  return gen;
}

function calculateEcc(data: Uint8Array, eccLen: number): Uint8Array {
  const gen = getGeneratorPoly(eccLen);
  const msg = new Uint8Array(data.length + eccLen);
  msg.set(data);
  for (let i = 0; i < data.length; i++) {
    const coef = msg[i];
    if (coef !== 0) {
      for (let j = 0; j < gen.length; j++) {
        msg[i + j] ^= gfMul(gen[j], coef);
      }
    }
  }
  return msg.slice(data.length);
}

type VersionConfig = {
  version: number;
  totalCodewords: number;
  eccPerBlock: number;
  blocks1: number;
  data1: number;
  blocks2: number;
  data2: number;
  alignments: number[];
};

const VERSION_CONFIGS_M: VersionConfig[] = [
  { version: 1, totalCodewords: 26, eccPerBlock: 10, blocks1: 1, data1: 16, blocks2: 0, data2: 0, alignments: [] },
  { version: 2, totalCodewords: 44, eccPerBlock: 16, blocks1: 1, data1: 28, blocks2: 0, data2: 0, alignments: [6, 18] },
  { version: 3, totalCodewords: 70, eccPerBlock: 26, blocks1: 1, data1: 44, blocks2: 0, data2: 0, alignments: [6, 22] },
  { version: 4, totalCodewords: 100, eccPerBlock: 18, blocks1: 2, data1: 32, blocks2: 0, data2: 0, alignments: [6, 26] },
  { version: 5, totalCodewords: 134, eccPerBlock: 24, blocks1: 2, data1: 43, blocks2: 0, data2: 0, alignments: [6, 30] },
  { version: 6, totalCodewords: 172, eccPerBlock: 16, blocks1: 4, data1: 27, blocks2: 0, data2: 0, alignments: [6, 34] },
  { version: 7, totalCodewords: 196, eccPerBlock: 18, blocks1: 4, data1: 31, blocks2: 0, data2: 0, alignments: [6, 22, 38] },
  { version: 8, totalCodewords: 242, eccPerBlock: 22, blocks1: 2, data1: 38, blocks2: 2, data2: 39, alignments: [6, 24, 42] },
  { version: 9, totalCodewords: 292, eccPerBlock: 22, blocks1: 3, data1: 36, blocks2: 2, data2: 37, alignments: [6, 26, 46] },
  { version: 10, totalCodewords: 346, eccPerBlock: 26, blocks1: 4, data1: 43, blocks2: 1, data2: 44, alignments: [6, 28, 50] },
];

class BitBuffer {
  private buffer: number[] = [];
  private length = 0;

  put(num: number, length: number): void {
    for (let i = 0; i < length; i++) {
      this.putBit(((num >>> (length - i - 1)) & 1) === 1);
    }
  }

  putBit(bit: boolean): void {
    const bufIndex = Math.floor(this.length / 8);
    if (this.buffer.length <= bufIndex) {
      this.buffer.push(0);
    }
    if (bit) {
      this.buffer[bufIndex] |= 0x80 >>> (this.length % 8);
    }
    this.length++;
  }

  getBytes(): Uint8Array {
    return new Uint8Array(this.buffer);
  }

  get bitLength(): number {
    return this.length;
  }
}

export function generateQrMatrix(text: string): { matrix: boolean[][]; size: number } {
  const encoder = new TextEncoder();
  const rawBytes = encoder.encode(text);
  const dataLen = rawBytes.length;

  let config: VersionConfig | undefined;
  for (const c of VERSION_CONFIGS_M) {
    const totalData = c.blocks1 * c.data1 + c.blocks2 * c.data2;
    const requiredBits = 4 + (c.version <= 9 ? 8 : 16) + dataLen * 8;
    if (requiredBits <= totalData * 8) {
      config = c;
      break;
    }
  }

  if (!config) {
    config = VERSION_CONFIGS_M[VERSION_CONFIGS_M.length - 1];
  }

  const totalDataBytes = config.blocks1 * config.data1 + config.blocks2 * config.data2;

  const bb = new BitBuffer();
  bb.put(4, 4);
  bb.put(dataLen, config.version <= 9 ? 8 : 16);
  for (let i = 0; i < dataLen; i++) {
    bb.put(rawBytes[i], 8);
  }

  const remainingBits = totalDataBytes * 8 - bb.bitLength;
  const termBits = Math.min(4, Math.max(0, remainingBits));
  bb.put(0, termBits);

  while (bb.bitLength % 8 !== 0) {
    bb.putBit(false);
  }

  let padToggle = false;
  while (bb.bitLength < totalDataBytes * 8) {
    bb.put(padToggle ? 0x11 : 0xec, 8);
    padToggle = !padToggle;
  }

  const allData = bb.getBytes();

  const dataBlocks: Uint8Array[] = [];
  const eccBlocks: Uint8Array[] = [];
  let offset = 0;

  for (let b = 0; b < config.blocks1; b++) {
    const blockData = allData.slice(offset, offset + config.data1);
    offset += config.data1;
    dataBlocks.push(blockData);
    eccBlocks.push(calculateEcc(blockData, config.eccPerBlock));
  }
  for (let b = 0; b < config.blocks2; b++) {
    const blockData = allData.slice(offset, offset + config.data2);
    offset += config.data2;
    dataBlocks.push(blockData);
    eccBlocks.push(calculateEcc(blockData, config.eccPerBlock));
  }

  const finalCodewords: number[] = [];
  const maxDataLen = Math.max(config.data1, config.data2);
  for (let i = 0; i < maxDataLen; i++) {
    for (const b of dataBlocks) {
      if (i < b.length) {
        finalCodewords.push(b[i]);
      }
    }
  }
  for (let i = 0; i < config.eccPerBlock; i++) {
    for (const b of eccBlocks) {
      finalCodewords.push(b[i]);
    }
  }

  const size = config.version * 4 + 17;
  const matrix: boolean[][] = Array.from({ length: size }, () => Array(size).fill(false));
  const reserved: boolean[][] = Array.from({ length: size }, () => Array(size).fill(false));

  function set(r: number, c: number, v: boolean, res = true): void {
    if (r >= 0 && r < size && c >= 0 && c < size) {
      matrix[r][c] = v;
      if (res) reserved[r][c] = true;
    }
  }

  function addFinder(top: number, left: number): void {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        const row = top + r;
        const col = left + c;
        if (row >= 0 && row < size && col >= 0 && col < size) {
          const isDark =
            (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
            (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
            (r >= 2 && r <= 4 && c >= 2 && c <= 4);
          set(row, col, isDark);
        }
      }
    }
  }

  addFinder(0, 0);
  addFinder(0, size - 7);
  addFinder(size - 7, 0);

  for (let i = 8; i < size - 8; i++) {
    set(6, i, i % 2 === 0);
    set(i, 6, i % 2 === 0);
  }

  const aligns = config.alignments;
  for (let i = 0; i < aligns.length; i++) {
    for (let j = 0; j < aligns.length; j++) {
      const ar = aligns[i];
      const ac = aligns[j];
      if (
        (ar < 9 && ac < 9) ||
        (ar < 9 && ac > size - 10) ||
        (ar > size - 10 && ac < 9)
      ) {
        continue;
      }
      for (let r = -2; r <= 2; r++) {
        for (let c = -2; c <= 2; c++) {
          const isDark = Math.abs(r) === 2 || Math.abs(c) === 2 || (r === 0 && c === 0);
          set(ar + r, ac + c, isDark);
        }
      }
    }
  }

  set(4 * config.version + 9, 8, true);

  for (let i = 0; i < 9; i++) {
    if (i !== 6) {
      set(8, i, false);
      set(i, 8, false);
    }
  }
  for (let i = 0; i < 8; i++) {
    set(8, size - 1 - i, false);
    set(size - 1 - i, 8, false);
  }

  let bitIdx = 0;
  const totalBits = finalCodewords.length * 8;
  let dir = -1;
  for (let col = size - 1; col > 0; col -= 2) {
    if (col === 6) col--;
    const rows = dir === -1 ? Array.from({ length: size }, (_, i) => size - 1 - i) : Array.from({ length: size }, (_, i) => i);
    for (const row of rows) {
      for (let cOffset = 0; cOffset < 2; cOffset++) {
        const c = col - cOffset;
        if (!reserved[row][c]) {
          let bitVal = false;
          if (bitIdx < totalBits) {
            const byte = finalCodewords[Math.floor(bitIdx / 8)];
            bitVal = ((byte >>> (7 - (bitIdx % 8))) & 1) === 1;
            bitIdx++;
          }
          if ((row + c) % 2 === 0) {
            bitVal = !bitVal;
          }
          matrix[row][c] = bitVal;
        }
      }
    }
    dir = -dir;
  }

  const formatBits = 0x5412;
  for (let i = 0; i < 15; i++) {
    const bit = ((formatBits >>> i) & 1) === 1;
    if (i < 6) set(8, i, bit, false);
    else if (i < 8) set(8, i + 1, bit, false);
    else if (i === 8) set(7, 8, bit, false);
    else set(14 - i, 8, bit, false);

    if (i < 8) set(size - 1 - i, 8, bit, false);
    else set(8, size - 15 + i, bit, false);
  }

  return { matrix, size };
}

export function generateQrSvgPath(text: string): { path: string; size: number } {
  const { matrix, size } = generateQrMatrix(text);
  const parts: string[] = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (matrix[y][x]) {
        parts.push(`M${x} ${y}h1v1h-1z`);
      }
    }
  }
  return { path: parts.join(""), size };
}
