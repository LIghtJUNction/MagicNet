import { statusToneClasses } from "@/lib/statusTone";
export type DnsTestSummary = {
  lineCount: number;
  issueCount: number;
  domain: string;
  probePath: string;
  httpStatus: number | null;
  proxyIp: string;
  remoteIp: string;
  timeTotalMillis: number | null;
  status: "ok" | "warn" | "fail" | "idle";
  summary: string;
  issueLines: string[];
};

const ISSUE_PATTERN = /\b(error|fail|failed|timeout|timed out|refused|reset|unreachable|no route|no such|denied|curl:|could not|couldn't|cannot|name or service not known)\b/i;

export function parseDnsTestSummary(text: string, fallbackDomain = ""): DnsTestSummary {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const fields = parseFields(lines);
  const issueLines = lines.filter((line) => ISSUE_PATTERN.test(line));
  const httpStatus = parseHttpStatus(fields.http_code || "");
  const probePath = fields.probe_path || "";
  const proxyIp = fields.proxy_ip || "";
  const remoteIp = fields.remote_ip || "";
  const timeTotalMillis = parseSecondsToMillis(fields.time_total || "");
  const domain = cleanDomain(fields.domain || fallbackDomain);
  const status = dnsStatus(lines.length, issueLines.length, probePath, httpStatus, proxyIp, remoteIp, timeTotalMillis);
  return {
    lineCount: lines.length,
    issueCount: issueLines.length,
    domain,
    probePath,
    httpStatus,
    proxyIp,
    remoteIp,
    timeTotalMillis,
    status,
    summary: dnsSummary(status, domain, probePath, httpStatus, proxyIp, remoteIp, timeTotalMillis, issueLines.length),
    issueLines
  };
}

export function formatDnsTestReport(summary: DnsTestSummary, profile: string, primary: string, secondary: string, transport: string, rawOutput: string): string {
  return [
    "MagicNet DNS test",
    `profile=${profile}`,
    `primary=${primary}`,
    `secondary=${secondary || "-"}`,
    `transport=${transport}`,
    `domain=${summary.domain || "unknown"}`,
    `probe_path=${summary.probePath || "legacy-direct"}`,
    `http_code=${summary.httpStatus ?? "none"}`,
    `proxy_ip=${summary.proxyIp || "none"}`,
    `remote_ip=${summary.remoteIp || "none"}`,
    `time_total_ms=${summary.timeTotalMillis ?? "none"}`,
    `status=${summary.status}`,
    `lines=${summary.lineCount}`,
    `issues=${summary.issueCount}`,
    "",
    rawOutput
  ].join("\n").trim();
}

export function dnsStatusTone(status: DnsTestSummary["status"]): string {
  if (status === "ok") return statusToneClasses("ok");
  if (status === "warn") return statusToneClasses("warn");
  if (status === "fail") return statusToneClasses("danger");
  return statusToneClasses("neutral");

}

function parseFields(lines: string[]): Record<string, string> {
  return Object.fromEntries(lines.map((line) => line.split("=", 2)).filter((pair) => pair.length === 2));
}

function parseSecondsToMillis(value: string): number | null {
  if (!/^\d+(?:\.\d+)?$/.test(value)) return null;
  return Math.round(Number(value) * 1000);
}

function parseHttpStatus(value: string): number | null {
  if (!/^\d{3}$/.test(value)) return null;
  const status = Number(value);
  return status >= 100 && status <= 599 ? status : null;
}

function cleanDomain(value: string): string {
  return value.replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
}

function dnsStatus(lineCount: number, issueCount: number, probePath: string, httpStatus: number | null, proxyIp: string, remoteIp: string, timeTotalMillis: number | null): DnsTestSummary["status"] {
  if (!lineCount) return "idle";
  if (issueCount) return "fail";
  if (probePath === "magicnet-mixed") {
    if (!proxyIp || httpStatus === null) return "fail";
  } else if (probePath || !remoteIp) {
    return "fail";
  }
  if (httpStatus !== null && httpStatus >= 400) return "warn";
  if (timeTotalMillis !== null && timeTotalMillis > 2500) return "warn";
  return "ok";
}

function dnsSummary(status: DnsTestSummary["status"], domain: string, probePath: string, httpStatus: number | null, proxyIp: string, remoteIp: string, timeTotalMillis: number | null, issueCount: number): string {
  if (status === "idle") return "尚未运行 DNS 测试。";
  if (status === "fail") {
    if (issueCount) return `发现 ${issueCount} 条 DNS/连接问题线索。`;
    return probePath === "magicnet-mixed"
      ? "未取得有效的 MagicNet 混合入口与 HTTP 结果，DNS 或 HTTPS 连通性需要检查。"
      : "未解析到 remote_ip，DNS 或 HTTPS 连通性需要检查。";
  }
  if (probePath === "magicnet-mixed") {
    if (httpStatus !== null && httpStatus >= 400) {
      return `${domain || "目标域名"} 已通过 MagicNet 混合入口（${proxyIp}）完成 DNS/HTTPS 连接，但目标返回 HTTP ${httpStatus}；链路可达。`;
    }
    if (status === "warn") {
      return `${domain || "目标域名"} 已通过 MagicNet 混合入口（${proxyIp}）完成 DNS/HTTPS 探测，但总耗时 ${timeTotalMillis}ms 偏高。`;
    }
    return `${domain || "目标域名"} 已通过 MagicNet 混合入口（${proxyIp}）完成 DNS/HTTPS 探测，总耗时 ${timeTotalMillis ?? "未知"}ms。`;
  }
  if (httpStatus !== null && httpStatus >= 400) {
    return `${domain || "目标域名"} 已解析到 ${remoteIp}，但 HTTPS 返回 HTTP ${httpStatus}；DNS/网络链路可达。`;
  }
  if (status === "warn") return `${domain || "目标域名"} 解析到 ${remoteIp}，但总耗时 ${timeTotalMillis}ms 偏高。`;
  return `${domain || "目标域名"} 解析到 ${remoteIp}，总耗时 ${timeTotalMillis ?? "未知"}ms。`;
}
