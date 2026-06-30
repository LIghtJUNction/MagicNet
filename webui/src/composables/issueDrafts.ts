function fenced(text: string): string {
  const body = text.trim() || "(empty)";
  return `\`\`\`text\n${body.replace(/```/g, "`\u200b``")}\n\`\`\``;
}

function issueSection(title: string, body: string): string {
  return `## ${title}\n\n${fenced(body)}\n`;
}

function firstLines(text: string, limit: number): string {
  return text
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit)
    .join("\n");
}

export function propValue(text: string, key: string): string {
  const prefix = `${key}=`;
  return text
    .split("\n")
    .find((line) => line.startsWith(prefix))
    ?.slice(prefix.length)
    .trim() || "";
}

export function sanitizeDiagnosticText(text: string): string {
  return text
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic):\/\/[^\s"'<>]+/gi, "[filtered-url]")
    .replace(/\b(private_?key|password|passwd|token|secret|uuid|api[_-]?key|subscription(?:_url)?)(\s*[:=]\s*)[^\s,;}\]]+/gi, "$1$2[filtered]")
    .replace(/(Authorization\s*:\s*)(?:Bearer\s+)?[A-Za-z0-9._~+/=-]+/gi, "$1[filtered]")
    .replace(/(Proxy-Authorization\s*:\s*)[^\s]+/gi, "$1[filtered]");
}

export function buildIssueBody(parts: {
  moduleProp: string;
  device: string;
  status: string;
  health: string;
  mcp: string;
  network: string;
  support: string;
}): string {
  const generatedAt = new Date().toISOString();
  return [
    "## Problem",
    "",
    "请在这里描述你遇到的问题、复现步骤和期望结果。",
    "",
    "## Generated Context",
    "",
    `Generated at: ${generatedAt}`,
    "",
    issueSection("Module", parts.moduleProp),
    issueSection("Device", sanitizeDiagnosticText(parts.device)),
    issueSection("Service Status", sanitizeDiagnosticText(parts.status)),
    issueSection("Health", sanitizeDiagnosticText(parts.health)),
    issueSection("MCP", sanitizeDiagnosticText(parts.mcp)),
    issueSection("Network Probe", sanitizeDiagnosticText(parts.network)),
    issueSection("Support Bundle", sanitizeDiagnosticText(parts.support))
  ].join("\n");
}

export function buildShortIssueBody(parts: {
  version: string;
  device: string;
  status: string;
  health: string;
  copied: boolean;
}): string {
  return [
    "## Problem",
    "",
    "请在这里描述问题、复现步骤和期望结果。",
    "",
    "## Diagnostic Context",
    "",
    parts.copied
      ? "完整诊断上下文已复制到剪贴板，请直接粘贴到这里。"
      : "剪贴板不可用，请回到 MagicNet 输出页复制诊断上下文。",
    "",
    "## Summary",
    "",
    `version: ${parts.version}`,
    "",
    "### Device",
    fenced(firstLines(parts.device, 4)),
    "",
    "### Service Status",
    fenced(firstLines(parts.status, 12)),
    "",
    "### Health",
    fenced(firstLines(parts.health, 12))
  ].join("\n");
}
