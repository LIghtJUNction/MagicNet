import { sanitizeOutputText } from "./outputDiagnostics";

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
  warningCount: number;
  errorCount: number;
  otherIssueCount: number;
};

export function buildRuntimeLogInsight(lines: string[], warningCount: number, errorCount: number, issueLines: string[]): RuntimeLogInsight {
  if (!lines.length) {
    return {
      status: "idle",
      label: "等待日志",
      detail: "刷新后会基于真实日志尾部判断错误和警告。",
      lastIssue: ""
    };
  }
  const lastIssue = sanitizeOutputText(issueLines.at(-1) || "");
  if (errorCount) {
    return {
      status: "error",
      label: "发现错误",
      detail: `${errorCount} 行错误，${warningCount} 行警告。建议复制问题摘要排查。`,
      lastIssue
    };
  }
  if (warningCount) {
    return {
      status: "warning",
      label: "发现警告",
      detail: `${warningCount} 行警告，暂未匹配 fatal/error。`,
      lastIssue
    };
  }
  if (issueLines.length) {
    return {
      status: "warning",
      label: "发现异常线索",
      detail: `${issueLines.length} 行匹配 timeout/denied/not found 等异常关键词。`,
      lastIssue
    };
  }
  return {
    status: "ok",
    label: "日志正常",
    detail: `${lines.length} 行日志未匹配常见错误关键词。`,
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
    "",
    ...input.issueLines.map((line) => sanitizeOutputText(line))
  ].join("\n").trim();
}

export function runtimeLogInsightTone(status: RuntimeLogInsight["status"]): string {
  if (status === "error") return "border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,white)] text-[var(--mn-danger)]";
  if (status === "warning") return "border-[color-mix(in_srgb,var(--mn-oat)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-oat)_55%,white)] text-[var(--mn-warning)]";
  if (status === "ok") return "border-[color-mix(in_srgb,var(--mn-cactus)_50%,transparent)] bg-[color-mix(in_srgb,var(--mn-cactus)_40%,white)] text-[var(--mn-success)]";
  return "border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] text-[var(--mn-ink-muted)]";
}
