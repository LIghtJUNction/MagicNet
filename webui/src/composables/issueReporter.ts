import { MODULE_DIR, REPO } from "@/constants";
import { buildIssueBody, buildShortIssueBody, propValue } from "@/composables/issueDrafts";
import { copyText, intentDataQuote, shellQuote } from "@/utils";
import type { RuntimeState } from "@/types";

type IssueReporterState = {
  task: string;
  notice: string;
  busy: boolean;
  phase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  output: string;
  hasKsu: boolean;
  runtime: RuntimeState;
};

type IssueReporterDeps = {
  state: IssueReporterState;
  runShell: (commandBody: string, label: string, quiet?: boolean) => Promise<string>;
  runCli: (args: string, label?: string, quiet?: boolean) => Promise<string>;
};

export async function createMagicNetIssue({ state, runShell, runCli }: IssueReporterDeps): Promise<void> {
  state.task = "创建 GitHub issue";
  state.notice = "正在收集 issue 诊断信息";
  state.busy = true;
  state.phase = "running";
  try {
    const moduleProp = await runShell(`cat ${shellQuote(`${MODULE_DIR}/module.prop`)}`, "读取模块版本", true);
    const version = propValue(moduleProp, "version") || "unknown";
    const runtimeLabel = state.runtime.singBoxState === "unknown" ? "runtime" : state.runtime.singBoxState;
    const title = `[MagicNet] ${version} ${runtimeLabel} diagnostic report`;
    const [device, status, health, mcp, network, support] = await Promise.all([
      runShell("getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; uname -a", "读取设备信息", true),
      runCli("service status", "读取服务状态", true),
      runCli("health", "运行健康检查", true),
      runCli("mcp status", "读取 MCP 状态", true),
      runShell("ip -br addr; echo; ip route; echo; ss -lntp 2>/dev/null | grep -E '7890|7891|7892|9090|8766|18766' || true; echo; ping -c 1 -W 3 www.baidu.com >/dev/null && echo network_ok || echo network_fail", "读取网络诊断", true),
      runCli("support bundle", "生成支持包", true)
    ]);
    const body = buildIssueBody({ moduleProp, device, status, health, mcp, network, support });
    const copied = await copyText(body);
    const urlBody = buildShortIssueBody({ version, device, status, health, copied });
    const issueUrl = `${REPO}/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(urlBody)}`;
    state.output = [
      copied ? "完整 issue 正文已复制到剪贴板。" : "剪贴板不可用，issue URL 只包含摘要。",
      `issue URL 只包含 ${urlBody.length} 字符的摘要，完整正文长度 ${body.length} 字符。`,
      "如果 GitHub 页面没有自动带入完整诊断，请长按正文框粘贴。",
      "",
      issueUrl
    ].join("\n");
    state.notice = "正在打开 GitHub issue";
    if (!state.hasKsu) {
      window.open(issueUrl, "_blank", "noopener,noreferrer");
    } else {
      await runShell(
        `am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -p com.android.chrome -d ${intentDataQuote(issueUrl)} >/dev/null 2>&1 || am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d ${intentDataQuote(issueUrl)}`,
        "打开 GitHub issue",
        true
      );
    }
    state.phase = "done";
    state.notice = "GitHub issue 已打开";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.phase = "error";
    state.notice = "创建 issue 失败";
    state.output = `创建 GitHub issue 失败：\n${message}`;
  } finally {
    state.busy = false;
    state.task = "";
  }
}
