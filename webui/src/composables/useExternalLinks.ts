import { reactive } from "vue";
import { AUTO_SING_BOX_UI_OPEN_ENABLED_KEY, AUTO_SING_BOX_UI_OPEN_TARGET_KEY } from "@/constants";
import type { SingBoxUiTarget } from "@/types";
import { copyText, intentDataQuote, probeFailed } from "@/utils";

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
  runShell: (command: string, label: string, quiet?: boolean) => Promise<string>,
  runCli: (args: string, label?: string, quiet?: boolean) => Promise<string>,
  refreshStatus: () => Promise<unknown>
) {
  const autoSingBoxUiOpen = reactive({
    enabled: localStorage.getItem(AUTO_SING_BOX_UI_OPEN_ENABLED_KEY) === "1",
    target: (localStorage.getItem(AUTO_SING_BOX_UI_OPEN_TARGET_KEY) || "zashboard") as SingBoxUiTarget,
    attempted: false
  });

  async function openExternal(
    url: string,
    label = "链接",
    options: { preferBrowser?: boolean } = {}
  ): Promise<void> {
    await copyText(url);
    state.output = `已复制 ${label}，正在打开系统浏览器：\n${url}`;
    if (!state.hasKsu) {
      window.open(url, "_blank", "noopener,noreferrer");
      return;
    }
    const escaped = intentDataQuote(url);
    const browserFlag = options.preferBrowser === false ? "" : "-p com.android.chrome ";
    await runShell(`am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE ${browserFlag}-d ${escaped} >/dev/null 2>&1 || am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d ${escaped}`, `打开 ${label}`);
  }

  function singBoxUiUrl(target: SingBoxUiTarget): string {
    return `${state.runtime.api}/ui/`;
  }

  async function openSingBoxUi(target: SingBoxUiTarget): Promise<void> {
    state.notice = `正在打开 ${target}`;
    const ok = await runCli("api groups", "检查 sing-box WebUI", true);
    if (!ok || probeFailed(ok)) {
      state.output = `sing-box API 未就绪，暂不跳转。\n\n${ok}`;
      state.phase = "error";
      return;
    }
    await openExternal(singBoxUiUrl(target), target);
  }

  function setAutoSingBoxUiOpen(target: SingBoxUiTarget | ""): void {
    if (!target) {
      autoSingBoxUiOpen.enabled = false;
      localStorage.setItem(AUTO_SING_BOX_UI_OPEN_ENABLED_KEY, "0");
      state.output = "已关闭默认进入 sing-box WebUI。";
      return;
    }
    autoSingBoxUiOpen.enabled = true;
    autoSingBoxUiOpen.target = target;
    localStorage.setItem(AUTO_SING_BOX_UI_OPEN_ENABLED_KEY, "1");
    localStorage.setItem(AUTO_SING_BOX_UI_OPEN_TARGET_KEY, target);
    state.output = `下次进入管理面板将自动打开 ${target}。`;
  }

  async function tryAutoOpenSingBoxUi(): Promise<void> {
    if (!autoSingBoxUiOpen.enabled || autoSingBoxUiOpen.attempted || !state.hasKsu) return;
    autoSingBoxUiOpen.attempted = true;
    await refreshStatus();
    if (state.runtime.singBoxState === "stopped" || state.runtime.singBoxState === "unknown") return;
    await openSingBoxUi(autoSingBoxUiOpen.target);
  }

  return {
    autoSingBoxUiOpen,
    openExternal,
    openSingBoxUi,
    setAutoSingBoxUiOpen,
    tryAutoOpenSingBoxUi
  };
}
