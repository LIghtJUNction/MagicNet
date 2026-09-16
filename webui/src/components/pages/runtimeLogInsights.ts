import { t } from "@/i18n";
import { sanitizeDiagnosticText, stripTerminalControlSequences } from "@/composables/issueDrafts";
import { statusToneClasses } from "@/lib/statusTone";

const WARNING_PATTERN = /\b(warn|warning)\b/i;
const ERROR_PATTERN = /\b(error|fail|failed|fatal|panic|denied|timeout|timed out|not found)\b/i;
// A declared log level wins over words in its message. In particular a
// capability WARN containing "failed" must not count as both warning and error.
const EXPLICIT_LEVEL = /^(?:[+-]\d{4}\s+)?(?:\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\s+)?[^\w\s[\]]*\s*(?:\[(trace|debug|info|warn|warning|error|fatal|panic)\]|(trace|debug|info|warn|warning|error|fatal|panic)\b)/i;

function runtimeLogLevel(line: string): "warn" | "error" | null {
  const normalized = stripTerminalControlSequences(line);
  const match = normalized.match(EXPLICIT_LEVEL);
  const declared = (match?.[1] || match?.[2] || "").toLowerCase();
  if (declared === "warn" || declared === "warning") return "warn";
  if (["error", "fatal", "panic"].includes(declared)) return "error";
  if (declared) return null;
  if (ERROR_PATTERN.test(normalized)) return "error";
  return WARNING_PATTERN.test(normalized) ? "warn" : null;
}

export type RuntimeLogInsight = {
  status: "idle" | "ok" | "warning" | "error";
  label: string;
  detail: string;
  lastIssue: string;
};

export type RuntimeLogIssueReportInput = {
  target: string;
  lines: string[];
  issueLines: string[];
  issueCount: number;
  warningCount: number;
  errorCount: number;
  otherIssueCount: number;
};

export type RuntimeLogAnalysis = Pick<RuntimeLogIssueReportInput,
  "issueLines" | "issueCount" | "warningCount" | "errorCount" | "otherIssueCount"
>;

export function analyzeRuntimeLogLines(lines: string[]): RuntimeLogAnalysis {
  const classified = lines.map((line) => ({ line, level: runtimeLogLevel(line) }));
  const issues = classified.filter(({ level }) => level !== null);
  return {
    issueLines: issues.map(({ line }) => line).slice(-80),
    issueCount: issues.length,
    warningCount: issues.filter(({ level }) => level === "warn").length,
    errorCount: issues.filter(({ level }) => level === "error").length,
    otherIssueCount: 0,
  };
}

export function latestRuntimeLogIssueLines(lines: string[]): string[] {
  return analyzeRuntimeLogLines(lines).issueLines.slice(-60);
}

export function runtimeLogLevelMatches(line: string, level: "all" | "warn" | "error"): boolean {
  if (level === "all") return true;
  return runtimeLogLevel(line) === level;
}

export function buildRuntimeLogInsight(lines: string[], warningCount: number, errorCount: number, issueLines: string[], issueCount = issueLines.length): RuntimeLogInsight {
  if (!lines.length) {
    return {
      status: "idle",
      label: t("等待日志"),
      detail: t("刷新后会基于真实日志尾部判断错误和警告。"),
      lastIssue: ""
    };
  }
  const lastIssue = sanitizeDiagnosticText(issueLines.at(-1) || "");
  if (errorCount) {
    return {
      status: "error",
      label: t("发现错误"),
      detail: t("{value1} 行错误，{value2} 行警告。建议复制问题摘要排查。", { value1: errorCount, value2: warningCount }),
      lastIssue
    };
  }
  if (warningCount) {
    return {
      status: "warning",
      label: t("发现警告"),
      detail: t("{value1} 行警告，暂未匹配 fatal/error。", { value1: warningCount }),
      lastIssue
    };
  }
  if (issueCount) {
    return {
      status: "warning",
      label: t("发现异常线索"),
      detail: t("{value1} 行匹配 timeout/denied/not found 等异常关键词。", { value1: issueCount }),
      lastIssue
    };
  }
  return {
    status: "ok",
    label: t("日志正常"),
    detail: t("{value1} 行日志未匹配常见错误关键词。", { value1: lines.length }),
    lastIssue: ""
  };
}

export function formatRuntimeLogIssueReport(input: RuntimeLogIssueReportInput): string {
  return [
    `MagicNet ${input.target} log issues`,
    "privacy_note=log lines are sanitized before export",
    `lines=${input.lines.length}`,
    `warnings=${input.warningCount}`,
    `errors=${input.errorCount}`,
    `other_issues=${input.otherIssueCount}`,
    `issues=${input.issueCount}`,
    `excerpt_lines=${input.issueLines.length}`,
    "",
    ...input.issueLines.map((line) => sanitizeDiagnosticText(line))
  ].join("\n").trim();
}

export function runtimeLogInsightTone(status: RuntimeLogInsight["status"]): string {
  if (status === "error") return statusToneClasses("error");
  if (status === "warning") return statusToneClasses("warning");
  if (status === "ok") return statusToneClasses("ok");
  return statusToneClasses("neutral");

}
