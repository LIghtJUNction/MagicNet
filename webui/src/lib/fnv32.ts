/** FNV-1a 32-bit, used only for short UI fingerprints. */
export function fnv32(value: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

export function fnv32Hex(value: string): string {
  return fnv32(value).toString(16).padStart(8, "0");
}
