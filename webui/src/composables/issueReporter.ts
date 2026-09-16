import { t } from "@/i18n";
import { MODULE_DIR, REPO } from "@/constants";
import {
  buildIssueBody,
  buildFullIssueBody,
  summarizeMachineEvidence,
  buildIssueUrl,
  commandFailureContext,
  issueKindLabel,
  propValue,
  sanitizeConnectionLog,
  sanitizeRoutingFeedbackLog,
  summarizeConnectionsForIssue,
  summarizeRoutingFeedback,
  type IssueKind,
  type IssueOperationContext,
  type IssueReportInput,
} from "@/composables/issueDrafts";
import { copyText, intentDataQuote, shellQuote } from "@/utils";
import type { RuntimeState } from "@/types";
import type { BackgroundTaskState } from "@/composables/backgroundTasks";
import type { OperationCapture } from "@/composables/operationCapture";

type IssueReporterState = {
  task: string;
  notice: string;
  busy: boolean;
  phase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  output: string;
  hasKsu: boolean;
  runtime: RuntimeState;
  lastCommand: string;
  operationCapture: OperationCapture;
  backgroundTask: BackgroundTaskState;
};

type IssueReporterDeps = {
  state: IssueReporterState;
  runShell: (commandBody: string, label: string, quiet?: boolean) => Promise<string>;
  runCli: (args: string, label?: string, quiet?: boolean) => Promise<string>;
};

function relevantLogTail(text: string, pattern: RegExp, fallbackLines = 32): string {
  const lines = text.split(/\r?\n/).filter(Boolean);
  const relevant = lines.filter((line) => pattern.test(line));
  return (relevant.length ? relevant.slice(-60) : lines.slice(-fallbackLines)).join("\n");
}

async function collectFocusedContext(
  kind: IssueKind,
  operation: IssueOperationContext,
  runCli: IssueReporterDeps["runCli"],
): Promise<string> {
  if (kind === "command-error") return commandFailureContext(operation);
  if (kind === "route-feedback") {
    const safeRead = async (command: string, label: string) => {
      try { return await runCli(command, label, true); } catch { return "collection=unavailable"; }
    };
    const [connections, network, dns, core, transparent, logs] = await Promise.all([
      safeRead("api conns", "读取路由反馈连接"),
      safeRead("--json network status", "读取路由反馈网络策略"),
      safeRead("--json dns status", "读取 DNS 状态"),
      safeRead("--json service status sing-box", "读取核心状态"),
      safeRead("--json transparent status", "读取 TUN 状态"),
      safeRead("service logs sing-box 240", "读取路由反馈错误日志"),
    ]);
    const logLines = logs.split(/\r?\n/).filter(Boolean);
    const deliberateBlocks = logLines.filter(line => /outbound\/(?:selector\[ad-block\]|block\[block\])/.test(line));
    const relevant = logLines.filter(line => !deliberateBlocks.includes(line));
    // Put actual policy/readiness before noisy active-connection samples.
    // Deliberate policy blocks are counted separately, not blamed for Play.
    return [
      "[network policy]", summarizeMachineEvidence(network),
      "[DNS policy]", summarizeMachineEvidence(dns),
      "[core observation]", summarizeMachineEvidence(core),
      "[transparent observation]", summarizeMachineEvidence(transparent),
      "[route feedback samples]", summarizeRoutingFeedback(connections),
      "[routing/error log tail]",
      `intentional_block_log_lines=${deliberateBlocks.length}`,
      sanitizeRoutingFeedbackLog(relevantLogTail(relevant.join("\n"), /error|warn|fail|timeout|denied/i, 24)),
      "[policy block sample]", sanitizeRoutingFeedbackLog(deliberateBlocks.slice(-2).join("\n")),
    ].join("\n");
  }
  if (kind === "app-connectivity") {
    const [connections, logs] = await Promise.all([
      runCli("api conns", "读取近期活动连接", true),
      runCli("service logs sing-box 160", "读取近期连接日志", true),
    ]);
    return [
      "[recent connection paths]",
      summarizeConnectionsForIssue(connections),
      "",
      "[recent sing-box log tail]",
      sanitizeConnectionLog(relevantLogTail(
        logs,
        /\b(connect|connection|inbound|outbound|route|rule|reject|block|timeout|error|warn|fail|denied)\b/i,
        40,
      )),
    ].join("\n");
  }
  if (kind === "subscription-node") {
    const [status, health, transparent, logs] = await Promise.all([
      runCli("--json sub status", "读取订阅状态", true),
      runCli("health", "检查订阅相关健康状态", true),
      runCli("--json transparent status", "检查 TUN 状态", true),
      runCli("service logs sing-box 160", "读取订阅与节点日志", true),
    ]);
    return [
      "[subscription status]",
      status,
      "",
      "[health]",
      health,
      "",
      "[transparent]",
      transparent,
      "",
      "[selector/subscription log tail]",
      sanitizeConnectionLog(relevantLogTail(
        logs,
        /\b(subscription|selector|proxy|outbound|node|update|timeout|error|warn|fail)\b/i,
      )),
    ].join("\n");
  }
  if (kind === "dns-routing") {
    const [health, dns, network, transparent] = await Promise.all([
      runCli("health", "运行健康检查", true),
      runCli("--json dns status", "读取 DNS 状态", true),
      runCli("--json network status", "读取网络策略", true),
      runCli("--json transparent status", "读取 TUN 状态", true),
    ]);
    return [
      "[health]",
      health,
      "",
      "[dns]",
      dns,
      "",
      "[network]",
      network,
      "",
      "[transparent]",
      transparent,
    ].join("\n");
  }
  return [
    "No additional category-specific command was run.",
    "The support summary and captured UI operation are included below.",
  ].join("\n");
}

export async function createMagicNetIssue(
  { state, runShell, runCli }: IssueReporterDeps,
  report: IssueReportInput,
): Promise<void> {
  const captured = state.operationCapture.command
    ? state.operationCapture
    : {
        phase: state.phase,
        command: state.lastCommand,
        output: state.output,
      };
  const operation: IssueOperationContext = {
    phase: captured.phase,
    lastCommand: captured.command,
    lastOutput: captured.output,
    backgroundLabel: state.backgroundTask.label,
    backgroundArgs: state.backgroundTask.args,
    backgroundStatus: state.backgroundTask.status,
  };
  const normalizedReport = report.kind === "route-feedback" && !report.summary.trim()
    ? { ...report, summary: "自动路由反馈：最近应用 / 网站路由样本" }
    : report;
  state.task = "创建 GitHub issue";
  state.notice = report.kind === "route-feedback"
    ? t("正在收集路由反馈")
    : t("正在收集 issue 诊断信息");
  state.busy = true;
  state.phase = "running";
  try {
    const moduleProp = await runShell(`cat ${shellQuote(`${MODULE_DIR}/module.prop`)}`, "读取模块版本", true);
    const version = propValue(moduleProp, "version") || "unknown";
    const runtimeLabel = state.runtime.singBoxState === "unknown" ? "runtime" : state.runtime.singBoxState;
    const title = `[MagicNet] ${version} ${issueKindLabel(report.kind)} · ${runtimeLabel}`;
    const [device, support, focusedContext] = await Promise.all([
      runShell("getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; uname -a", "读取设备信息", true),
      runCli("support bundle", "生成支持包", true),
      collectFocusedContext(report.kind, operation, runCli),
    ]);
    const bodyParts = {
      kind: report.kind,
      moduleProp,
      device,
      support,
      focusedContext,
      operation,
      report: normalizedReport,
    };
    const body = buildIssueBody(bodyParts);
    const fullReport = buildFullIssueBody(bodyParts);
    let downloadRequested = false;
    try {
      const url = URL.createObjectURL(new Blob([fullReport], { type: "text/plain;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = `MagicNet-diagnostic-${Date.now()}.txt`;
      document.body.appendChild(link);
      link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
      downloadRequested = true;
    } catch { /* The bounded report still opens when Blob downloads are unsupported. */ }
    const copied = await copyText(body);
    const issueUrl = buildIssueUrl(REPO, title, body);
    state.output = [
      copied ? t("隐私处理后的 issue 正文已复制。") : t("剪贴板不可用。"),
      t("剪贴板与 GitHub URL 使用同一份正文，共 {p0} 字符。", { p0: body.length }),
      downloadRequested ? t("已请求下载完整诊断；请确认文件已保存，再添加为 issue 附件。") : t("完整诊断下载未确认，下面保留完整正文。"),
      "",
      issueUrl,
      "",
      fullReport,
    ].join("\n");
    state.notice = t("正在打开 GitHub issue");
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
    state.notice = t("GitHub issue 已打开");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.phase = "error";
    state.notice = t("创建 issue 失败");
    state.output = t("创建 GitHub issue 失败：\n{p0}", { p0: message });
  } finally {
    state.busy = false;
    state.task = "";
  }
}
