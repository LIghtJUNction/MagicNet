/** Redact credential values before formatting or truncating a public report. */
const secretField = /^(?:private[_-]?key|password|passwd|token|secret|uuid|api[_-]?key|auth[_-]?(?:key|token)|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|proxy-authorization|subscription(?:_url)?|query|node|server|endpoint|path|device[_-]?id|android[_-]?id|serial|imei)$/i;

function quotedEnd(text: string, start: number): number {
  const quote = text[start];
  for (let i = start + 1; i < text.length; i++) {
    if (text[i] === "\\") { i++; continue; }
    if (text[i] === quote) {
      if (quote === "'" && text[i + 1] === "'") { i++; continue; }
      return i + 1;
    }
  }
  return text.length;
}

function valueEnd(text: string, start: number): number {
  if (text[start] === '"' || text[start] === "'") return quotedEnd(text, start);
  if (text[start] === "{" || text[start] === "[") {
    const stack: string[] = [];
    for (let i = start; i < text.length; i++) {
      const char = text[i];
      if (char === '"' || char === "'") { i = quotedEnd(text, i) - 1; continue; }
      if (char === "{" || char === "[") stack.push(char === "{" ? "}" : "]");
      else if (char === "}" || char === "]") {
        if (stack.pop() !== char) return text.length;
        if (!stack.length) return i + 1;
      }
    }
    return text.length; // Malformed sensitive containers cannot expose their tail.
  }
  let end = start;
  while (end < text.length && !/[,;\r\n}\]]/.test(text[end])) end++;
  return end;
}

export function redactFeedbackSecrets(text: string): string {
  const fields = /("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')(\s*[:=]\s*)/g;
  const chunks: string[] = [];
  let copied = 0;
  for (let match = fields.exec(text); match; match = fields.exec(text)) {
    let key: string;
    try { key = match[1][0] === '"' ? JSON.parse(match[1]) : match[1].slice(1, -1); }
    catch { continue; }
    if (!secretField.test(key)) continue;
    const end = valueEnd(text, fields.lastIndex);
    chunks.push(text.slice(copied, fields.lastIndex), '"[filtered]"');
    copied = end;
    fields.lastIndex = end;
  }
  chunks.push(text.slice(copied));
  return chunks.join("")
    .replace(/\btskey-(?:auth|api)-[a-z0-9-]+\b/gi, "[filtered-tailscale-key]")
    .replace(/\b(?:auth[_-]?(?:key|token)|access[_-]?token|refresh[_-]?token|client[_-]?secret)\s*[:=]\s*[^\s,;}\]]+/gi, "[filtered-credential]")
    .replace(/-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----|$)/g, "[filtered-private-key]");
}
