import { t } from "@/i18n";
import { statusToneClasses } from "@/lib/statusTone";
import { isSensitiveExternalUrl } from "@/utils";
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

export function buildWebuiInstallPlan(urlText: string, sha256Text: string, nameText: string): WebuiInstallPlan {
  const name = nameText.trim() || "custom";
  const url = urlText.trim();
  const sha256 = sha256Text.trim();
  if (!url) return plan("danger", t("不能安装"), t("未填写下载 URL。"), "", "", "", false, false, false, "");
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return plan("danger", t("不能安装"), t("URL 无法解析。"), "", "", "", false, false, false, "");
  }
  const protocolOk = parsed.protocol === "http:" || parsed.protocol === "https:";
  const archive = archiveKind(parsed.pathname);
  const hasCredentials = isSensitiveExternalUrl(url);
  const safeCommand = `webui install-local [filtered-url] ${sha256 || "[sha256]"} ${shellWord(name)}`;
  if (!protocolOk) {
    return plan("danger", t("不能安装"), t("只支持 http(s) 下载链接。"), parsed.protocol, parsed.hostname, archive, hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (parsed.protocol !== "https:") {
    return plan("danger", t("不能安装"), t("明文 http 下载可被中间人劫持为恶意 root 写入，必须改用 https。"), parsed.protocol, parsed.hostname, archive, hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (!archive) {
    return plan("danger", t("不能安装"), t("CLI 当前只支持 zip 面板包。"), parsed.protocol, parsed.hostname, "unsupported", hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (!/^[a-fA-F0-9]{64}$/.test(sha256)) {
    return plan("danger", t("不能安装"), t("必须提供 64 位十六进制 SHA-256 校验值。"), parsed.protocol, parsed.hostname, archive, hasCredentials, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  if (hasCredentials) {
    return plan("warning", t("敏感链接"), t("链接包含凭据或签名参数，界面报告会隐藏完整 URL。"), parsed.protocol, parsed.hostname, archive, true, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
  }
  return plan("ok", t("可安装"), t("后台下载、校验和解压结果以任务日志为准。"), parsed.protocol, parsed.hostname, archive, false, Boolean(parsed.search), Boolean(parsed.hash), safeCommand);
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
