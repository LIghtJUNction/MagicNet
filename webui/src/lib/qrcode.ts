import qrcode from "qrcode-generator";

// Keep authentication URLs on the device. No remote QR service is involved.
qrcode.stringToBytes = (text: string) => Array.from(new TextEncoder().encode(text));

export function generateQrMatrix(text: string): { matrix: boolean[][]; size: number } {
  if (!text) throw new RangeError("QR data must not be empty");
  const code = qrcode(0, "M");
  code.addData(text, "Byte");
  try {
    code.make();
  } catch {
    // Never truncate the URL, or include private input in error messages.
    throw new RangeError("QR data exceeds supported capacity");
  }
  const size = code.getModuleCount();
  const matrix = Array.from({ length: size }, (_, y) =>
    Array.from({ length: size }, (_, x) => code.isDark(y, x)),
  );
  return { matrix, size };
}

export function generateQrSvgPath(text: string): { path: string; size: number } {
  const { matrix, size } = generateQrMatrix(text);
  const parts: string[] = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (matrix[y][x]) parts.push(`M${x} ${y}h1v1h-1z`);
    }
  }
  return { path: parts.join(""), size };
}
