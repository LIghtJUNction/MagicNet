export const MAX_HIGHLIGHT_CHARACTERS = 120_000;
export const MAX_HIGHLIGHT_LINES = 1_200;

export function shouldHighlightJson(text: string): boolean {
  if (text.length > MAX_HIGHLIGHT_CHARACTERS) return false;
  let lines = 1;
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] !== "\n") continue;
    lines += 1;
    if (lines > MAX_HIGHLIGHT_LINES) return false;
  }
  return true;
}
