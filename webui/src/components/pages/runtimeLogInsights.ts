import { t } from "@/i18n";
import { sanitizeDiagnosticText, stripTerminalControlSequences } from "@/composables/issueDrafts";
import { statusToneClasses } from "@/lib/statusTone";

const WARNING_PATTERN = /\b(warn|warning)\b/i;
const ERROR_PATTERN = /\b(error|fail|failed|fatal|panic|denied|timeout|timed out|not found)\b/i;
const ISSUE_PATTERN = /\b(warn|warning|fail|failed|error|fatal|panic|denied|timeout|timed out|not found)\b/i;

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

function logSeverity(line: string): "warn" | "error" | "other" | "none" {
  const text = stripTerminalControlSequences(line);
  // Explicit levels win over message words: [warn] ... failed is ONE warning,
  // not both a warning and an error. Do not demote unlabelled timeout/denied.
  const explicit = text.match(/(?:^|[\s◬])\[(warn(?:ing)?|error|fatal|panic|info|debug|trace)\]/i)
    || text.match(/(?:^|\s)(WARN(?:ING)?|ERROR|FATAL|PANIC|INFO|DEBUG|TRACE)(?:\s|:)/);
  if (explicit) {
    const level = explicit[1].toLowerCase();
    if (level === "warn" || level === "warning") return "warn";
    if (["error", "fatal", "panic"].includes(level)) return "error";
    return "none";
  }
  if (WARNING_PATTERN.test(text)) return "warn";
  if (ERROR_PATTERN.test(text)) return "error";
  return ISSUE_PATTERN.test(text) ? "other" : "none";
}

export function analyzeRuntimeLogLines(lines: string[]): RuntimeLogAnalysis {
  const classified = lines.map((line) => ({ line, severity: logSeverity(line) }));
  const issues = classified.filter(({ severity }) => severity !== "none");
  return {
    issueLines: issues.map(({ line }) => line).slice(-80),
    issueCount: issues.length,
    warningCount: classified.filter(({ severity }) => severity === "warn").length,
    errorCount: classified.filter(({ severity }) => severity === "error").length,
    otherIssueCount: classified.filter(({ severity }) => severity === "other").length,
  };
}

export function latestRuntimeLogIssueLines(lines: string[]): string[] {
  return analyzeRuntimeLogLines(lines).issueLines.slice(-60);
}

export function runtimeLogLevelMatches(line: string, level: "all" | "warn" | "error"): boolean {
  if (level === "all") return true;
  return logSeverity(line) === level;
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
