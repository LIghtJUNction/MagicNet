import { statusToneClasses } from "@/lib/statusTone";
export type DnsTestSummary = {
  lineCount: number;
  issueCount: number;
  domain: string;
  httpStatus: number | null;
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
  const remoteIp = fields.remote_ip || "";
  const timeTotalMillis = parseSecondsToMillis(fields.time_total || "");
  const domain = cleanDomain(fields.domain || fallbackDomain);
  const status = dnsStatus(lines.length, issueLines.length, httpStatus, remoteIp, timeTotalMillis);
  return {
    lineCount: lines.length,
    issueCount: issueLines.length,
    domain,
    httpStatus,
    remoteIp,
    timeTotalMillis,
    status,
    summary: dnsSummary(status, domain, httpStatus, remoteIp, timeTotalMillis, issueLines.length),
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
    `http_code=${summary.httpStatus ?? "none"}`,
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
  return Number(value);
}

function cleanDomain(value: string): string {
  return value.replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
}

function dnsStatus(lineCount: number, issueCount: number, httpStatus: number | null, remoteIp: string, timeTotalMillis: number | null): DnsTestSummary["status"] {
  if (!lineCount) return "idle";
  if (!remoteIp || issueCount) return "fail";
  if (httpStatus !== null && httpStatus >= 400) return "warn";
  if (timeTotalMillis !== null && timeTotalMillis > 2500) return "warn";
  return "ok";
}

function dnsSummary(status: DnsTestSummary["status"], domain: string, httpStatus: number | null, remoteIp: string, timeTotalMillis: number | null, issueCount: number): string {
  if (status === "idle") return "尚未运行 DNS 测试。";
  if (status === "fail") return issueCount ? `发现 ${issueCount} 条 DNS/连接问题线索。` : "未解析到 remote_ip，DNS 或 HTTPS 连通性需要检查。";
  if (httpStatus !== null && httpStatus >= 400) {
    return `${domain || "目标域名"} 已解析到 ${remoteIp}，但 HTTPS 返回 HTTP ${httpStatus}；DNS/网络链路可达。`;
  }
  if (status === "warn") return `${domain || "目标域名"} 解析到 ${remoteIp}，但总耗时 ${timeTotalMillis}ms 偏高。`;
  return `${domain || "目标域名"} 解析到 ${remoteIp}，总耗时 ${timeTotalMillis ?? "未知"}ms。`;
}
