import type { SingBoxUiTarget } from "@/types";
import {
  copyText,
  execFailed,
  intentDataQuote,
  isSensitiveExternalUrl,
  probeFailed,
  redactedCliPreview,
} from "@/utils";

type RuntimeState = {
  api: string;
  singBoxState: string;
};

type MagicNetState = {
  hasKsu: boolean;
  output: string;
  notice: string;
  phase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  runtime: RuntimeState;
};

export function useExternalLinks(
  state: MagicNetState,
  runShell: (command: string, label: string, quiet?: boolean, previewOverride?: string) => Promise<string>,
  runCli: (args: string, label?: string, quiet?: boolean) => Promise<string>,
) {
  async function openExternal(
    url: string,
    label = "链接",
    options: { preferBrowser?: boolean } = {}
  ): Promise<void> {
    // Only ever hand http(s) to the browser/intent — guards every current and
    // future caller against javascript: or arbitrary intent:// schemes.
    let safeProtocol = false;
    try {
      safeProtocol = /^https?:$/.test(new URL(url).protocol);
    } catch {
      // Unparseable URL stays unsafe.
    }
    const sensitive = isSensitiveExternalUrl(url);
    if (!safeProtocol) {
      state.output = sensitive
        ? "已拒绝打开非 http(s) 链接；敏感链接未显示。"
        : `已拒绝打开非 http(s) 链接：\n${url}`;
      state.phase = "error";
      return;
    }
    if (sensitive) {
      state.output = `正在打开 ${label}；敏感链接不会被复制或显示。`;
    } else {
      await copyText(url);
      state.output = `已复制 ${label}，正在打开系统浏览器：\n${url}`;
    }
    if (!state.hasKsu) {
      window.open(url, "_blank", "noopener,noreferrer");
      state.phase = "done";
      return;
    }
    const escaped = intentDataQuote(url);
    const browserFlag = options.preferBrowser === false ? "" : "-p com.android.chrome ";
    const command = `am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE ${browserFlag}-d ${escaped} >/dev/null 2>&1 || am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d ${escaped}`;
    if (!sensitive) {
      await runShell(command, `打开 ${label}`);
      return;
    }
    const result = await runShell(
      command,
      `打开 ${label}`,
      true,
      redactedCliPreview("open external [filtered-url]"),
    );
    if (execFailed(result)) {
      state.phase = "error";
      state.notice = `打开失败：${label}`;
      state.output = `打开 ${label} 失败；敏感链接未显示。`;
      return;
    }
    state.phase = "done";
    state.notice = `已打开：${label}`;
    state.output = `已打开 ${label}；敏感链接未复制或显示。`;
  }

  async function openSingBoxUi(target: SingBoxUiTarget): Promise<void> {
    state.notice = `正在打开 ${target}`;
    const ok = await runCli("api groups", "检查 sing-box WebUI", true);
    if (!ok || probeFailed(ok)) {
      state.output = `sing-box API 未就绪，暂不跳转。\n\n${ok}`;
      state.phase = "error";
      return;
    }
    await openExternal(`${state.runtime.api}/ui/`, target);
  }

  return {
    openExternal,
    openSingBoxUi,
  };
}
