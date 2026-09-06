import { t } from "@/i18n";
export type SupportIssueSeverity = "fatal" | "error" | "warning" | "fail";

export type SupportIssueBucket = {
  section: string;
  severity: SupportIssueSeverity;
  count: number;
};

export type SupportBundleTriage = {
  totalIssues: number;
  sections: number;
  buckets: SupportIssueBucket[];
  report: string;
};

const ISSUE_PATTERN = /\b(fatal|panic|error|failed|fail|warning|warn)\b/i;
const SUPPORT_SECTIONS = new Set(["service", "health", "subscriptions", "routes", "recent logs"]);

export function triageSupportBundle(text: string): SupportBundleTriage {
  const counts = new Map<string, SupportIssueBucket>();
  let section = "service";
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    const header = line.match(/^\[([^\]]+)]$/);
    if (header && SUPPORT_SECTIONS.has(header[1])) {
      section = header[1];
      return;
    }
    const severity = issueSeverity(line);
    if (!severity) return;
    const key = `${section}\t${severity}`;
    const bucket = counts.get(key) || { section, severity, count: 0 };
    bucket.count += 1;
    counts.set(key, bucket);
  });
  const buckets = [...counts.values()].sort((left, right) => severityRank(right.severity) - severityRank(left.severity) || right.count - left.count || left.section.localeCompare(right.section));
  const totalIssues = buckets.reduce((sum, bucket) => sum + bucket.count, 0);
  return {
    totalIssues,
    sections: new Set(buckets.map((bucket) => bucket.section)).size,
    buckets,
    report: formatSupportTriageReport(buckets, totalIssues)
  };
}

export function hideSupportIssueLines(text: string): string {
  return text.split(/\r?\n/).map((raw) => {
    return issueSeverity(raw) ? t("[issue-line hidden: see issue distribution]") : raw;
  }).join("\n");
}

function issueSeverity(line: string): SupportIssueSeverity | null {
  const match = line.match(ISSUE_PATTERN);
  if (!match) return null;
  const value = match[1].toLowerCase();
  if (value === "fatal" || value === "panic") return "fatal";
  if (value === "error") return "error";
  if (value === "warn" || value === "warning") return "warning";
  return "fail";
}

function severityRank(severity: SupportIssueSeverity): number {
  return { fatal: 4, error: 3, fail: 2, warning: 1 }[severity];
}

function formatSupportTriageReport(buckets: SupportIssueBucket[], totalIssues: number): string {
  return [
    "MagicNet support bundle issue triage",
    `total_issues=${totalIssues}`,
    "section,severity,count",
    ...buckets.map((bucket) => `${bucket.section},${bucket.severity},${bucket.count}`)
  ].join("\n").trim();
}
