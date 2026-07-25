import { statusToneClasses } from "@/lib/statusTone";
export type WebuiInstallPlan = {
  status: "ok" | "warning" | "danger";
  title: string;
  detail: string;
  protocol: string;
  host: string;
  archive: string;
  hasCredentials: boolean;
  hasQuery: boolean;
  hasFragment: boolean;
  safeCommand: string;
};

export function buildWebuiInstallPlan(urlText: string, nameText: string): WebuiInstallPlan {
  const name = nameText.trim() || "custom";
  const url = urlText.trim();
  if (!url) return plan("danger", "不能安装", "未填写下载 URL。", "", "", "", false, false, false, "");
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return plan("danger", "不能安装", "URL 无法解析。", "", "", "", false, false, false, "");
  }
  const protocolOk = parsed.protocol === "http:" || parsed.protocol === "https:";
  const archive = archiveKind(parsed.pathname);
  const hasCredentials = Boolean(parsed.username || parsed.password || signedUrlPattern.test(url));
  const safeCommand = `webui install-local [filtered-url] ${shellWord(name)}`;
  if (!protocolOk) {
    return plan("danger", "不能安装", "只支持 http(s) 下载链接。", parsed.protocol, parsed.hostname, archive, hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (!archive) {
    return plan("danger", "不能安装", "CLI 当前只支持 zip 面板包。", parsed.protocol, parsed.hostname, "unsupported", hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (hasCredentials) {
    return plan("warning", "敏感链接", "链接包含凭据或签名参数，界面报告会隐藏完整 URL。", parsed.protocol, parsed.hostname, archive, true, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  return plan("ok", "可安装", "后台下载和解压结果以任务日志为准。", parsed.protocol, parsed.hostname, archive, false, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
}

export function formatWebuiInstallPlanReport(plan: WebuiInstallPlan): string {
  return [
    "MagicNet WebUI install plan",
    "privacy_note=full download URL is omitted",
    `status=${plan.status}`,
    `title=${plan.title}`,
    `detail=${plan.detail}`,
    `protocol=${plan.protocol || "none"}`,
    `host=${plan.host || "none"}`,
    `archive=${plan.archive || "none"}`,
    `has_credentials=${plan.hasCredentials ? 1 : 0}`,
    `has_query=${plan.hasQuery ? 1 : 0}`,
    `has_fragment=${plan.hasFragment ? 1 : 0}`,
    `safe_command=${plan.safeCommand || "none"}`
  ].join("\n");
}

export function webuiInstallPlanTone(status: WebuiInstallPlan["status"]): string {
  if (status === "danger") return statusToneClasses("danger");
  if (status === "warning") return statusToneClasses("warning");
  return statusToneClasses("ok");

}

const signedUrlPattern = /(token|secret|signature|expires|x-amz-|x-oss-)/i;

function archiveKind(pathname: string): string {
  if (/\.zip$/i.test(pathname)) return "zip";
  return "";
}

function shellWord(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function plan(
  status: WebuiInstallPlan["status"],
  title: string,
  detail: string,
  protocol: string,
  host: string,
  archive: string,
  hasCredentials: boolean,
  hasQuery: boolean,
  hasFragment: boolean,
  safeCommand: string
): WebuiInstallPlan {
  return { status, title, detail, protocol, host, archive, hasCredentials, hasQuery, hasFragment, safeCommand };
}
