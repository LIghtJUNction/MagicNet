import { t } from "@/i18n";
import { statusToneClasses } from "@/lib/statusTone";
export type OutputDiagnostic = {
  status: "ok" | "warning" | "error" | "idle";
  title: string;
  detail: string;
};

type OutputDiagnosticInput = {
  phase: string;
  lines: number;
  chars: number;
  issueLines: number;
  filtered: boolean;
};

export function buildOutputDiagnostic(input: OutputDiagnosticInput): OutputDiagnostic {
  if (!input.chars) {
    return {
      status: "idle",
      title: t("尚无命令输出"),
      detail: t("执行命令后会在这里显示输出摘要、问题线索和最近输出。")
    };
  }
  if (["accepted", "queued", "running"].includes(input.phase)) {
    return {
      status: "warning",
      title: t("命令仍在执行"),
      detail: t("phase={value1}，当前输出可能还不完整。", { value1: input.phase })
    };
  }
  if (input.phase === "error" && !input.issueLines) {
    return {
      status: "error",
      title: t("命令进入错误状态"),
      detail: t("当前 phase=error，但输出未匹配到常见错误关键词，请查看完整输出。")
    };
  }
  if (input.phase === "error" || input.issueLines > 0) {
    return {
      status: "error",
      title: t("输出包含问题线索"),
      detail: t("{value1} 行匹配 warning/error/timeout 等关键词，复制时会先脱敏。", { value1: input.issueLines })
    };
  }
  if (input.filtered) {
    return {
      status: "warning",
      title: t("正在查看过滤结果"),
      detail: t("当前只显示匹配过滤条件的输出，原始输出共有 {value1} 行。", { value1: input.lines })
    };
  }
  return {
    status: "ok",
    title: t("输出未发现明显问题"),
    detail: t("{value1} 行输出，{value2} 字符。", { value1: input.lines, value2: input.chars })
  };
}

export function outputDiagnosticTone(status: OutputDiagnostic["status"]): string {
  if (status === "ok") return statusToneClasses("ok");
  if (status === "error") return statusToneClasses("error");
  if (status === "warning") return statusToneClasses("warning");
  return statusToneClasses("neutral");

}

export function sanitizeOutputText(text: string): string {
  return text.split(/\r?\n/).map(sanitizeOutputLine).join("\n");
}

function sanitizeOutputLine(line: string): string {
  if (/\bsub set-file sing-box\b/i.test(line)) return redactCommandLine(line, "sub set-file sing-box [filtered-payload]");
  if (/\bbackup export\b/i.test(line)) return redactCommandLine(line, "backup export [filtered-code]");
  if (/\bbackup restore-file\b/i.test(line)) return redactCommandLine(line, "backup restore-file [filtered-code] [payload-file]");
  return line
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic):\/\/[^\s"'<>]+/gi, "[filtered-url]")
    .replace(/(["']?(?:authorization|proxy-authorization|private_?key|password|passwd|token|secret|uuid|api[_-]?key|access[_-]?token|refresh[_-]?token|subscription(?:[_-]?url)?|security(?:[_ -]?code)?)["']?\s*[:=]\s*)["']?[^"',\s;}\]]+["']?/gi, "$1[filtered]")
    .replace(/\bbearer\s+[A-Za-z0-9._~+/-]+=*/gi, "bearer [filtered]")
    .replace(/\b(?:gho|ghp|github_pat)_[A-Za-z0-9_]+/g, "[filtered-token]")
    .replace(/\bsk-[A-Za-z0-9_-]+/g, "[filtered-token]");
}

function redactCommandLine(line: string, replacement: string): string {
  const prompt = line.match(/^(\$\s*)/);
  return `${prompt?.[1] || ""}${replacement}`;
}
