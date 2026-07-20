import { MODULE_DIR, REPO } from "@/constants";
import { buildIssueBody, buildIssueUrl, propValue } from "@/composables/issueDrafts";
import { copyText, intentDataQuote, shellQuote } from "@/utils";
import type { RuntimeState } from "@/types";
import type { BackgroundTaskState } from "@/composables/backgroundTasks";

type IssueReporterState = {
  task: string;
  notice: string;
  busy: boolean;
  phase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  output: string;
  hasKsu: boolean;
  runtime: RuntimeState;
  lastCommand: string;
  backgroundTask: BackgroundTaskState;
};

type IssueReporterDeps = {
  state: IssueReporterState;
  runShell: (commandBody: string, label: string, quiet?: boolean) => Promise<string>;
  runCli: (args: string, label?: string, quiet?: boolean) => Promise<string>;
};

export async function createMagicNetIssue({ state, runShell, runCli }: IssueReporterDeps): Promise<void> {
  const operation = {
    phase: state.phase,
    lastCommand: state.lastCommand,
    backgroundLabel: state.backgroundTask.label,
    backgroundArgs: state.backgroundTask.args,
    backgroundStatus: state.backgroundTask.status,
  };
  state.task = "创建 GitHub issue";
  state.notice = "正在收集 issue 诊断信息";
  state.busy = true;
  state.phase = "running";
  try {
    const moduleProp = await runShell(`cat ${shellQuote(`${MODULE_DIR}/module.prop`)}`, "读取模块版本", true);
    const version = propValue(moduleProp, "version") || "unknown";
    const runtimeLabel = state.runtime.singBoxState === "unknown" ? "runtime" : state.runtime.singBoxState;
    const title = `[MagicNet] ${version} ${runtimeLabel} diagnostic report`;
    const [device, support] = await Promise.all([
      runShell("getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; uname -a", "读取设备信息", true),
      runCli("support bundle", "生成支持包", true)
    ]);
    const body = buildIssueBody({ moduleProp, device, support, operation });
    const copied = await copyText(body);
    const issueUrl = buildIssueUrl(REPO, title, body);
    state.output = [
      copied ? "隐私处理后的 issue 正文已复制。" : "剪贴板不可用。",
      `剪贴板与 GitHub URL 使用同一份正文，共 ${body.length} 字符。`,
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
