import { reactive } from "vue";
import { AUTO_CORE_OPEN_ENABLED_KEY, AUTO_CORE_OPEN_TARGET_KEY } from "@/constants";
import type { CoreUiTarget } from "@/types";
import { copyText, intentDataQuote, probeFailed } from "@/utils";

type RuntimeState = {
  api: string;
  core: string;
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
  const autoCoreOpen = reactive({
    enabled: localStorage.getItem(AUTO_CORE_OPEN_ENABLED_KEY) === "1",
    target: (localStorage.getItem(AUTO_CORE_OPEN_TARGET_KEY) || "zashboard") as CoreUiTarget,
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

  function coreUiUrl(target: CoreUiTarget): string {
    if (target === "yacd") return "https://yacd.metacubex.one/?hostname=127.0.0.1&port=9090&secret=";
    if (target === "zashboard") return `${state.runtime.api}/ui/`;
    return "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=9090&secret=";
  }

  async function openCoreUi(target: CoreUiTarget): Promise<void> {
    state.notice = `正在打开 ${target}`;
    const ok = await runCli("api groups", "检查核心 WebUI", true);
    if (!ok || probeFailed(ok)) {
      state.output = `核心 API 未就绪，暂不跳转。\n\n${ok}`;
      state.phase = "error";
      return;
    }
    await openExternal(coreUiUrl(target), target, { preferBrowser: target !== "zashboard" });
  }

  function setAutoCoreOpen(target: CoreUiTarget | ""): void {
    if (!target) {
      autoCoreOpen.enabled = false;
      localStorage.setItem(AUTO_CORE_OPEN_ENABLED_KEY, "0");
      state.output = "已关闭默认进入核心 WebUI。";
      return;
    }
    autoCoreOpen.enabled = true;
    autoCoreOpen.target = target;
    localStorage.setItem(AUTO_CORE_OPEN_ENABLED_KEY, "1");
    localStorage.setItem(AUTO_CORE_OPEN_TARGET_KEY, target);
    state.output = `下次进入管理面板将自动打开 ${target}。`;
  }

  async function tryAutoOpenCoreUi(): Promise<void> {
    if (!autoCoreOpen.enabled || autoCoreOpen.attempted || !state.hasKsu) return;
    autoCoreOpen.attempted = true;
    await refreshStatus();
    if (state.runtime.core === "stopped" || state.runtime.core === "unknown") return;
    await openCoreUi(autoCoreOpen.target);
  }

  return {
    autoCoreOpen,
    openExternal,
    openCoreUi,
    setAutoCoreOpen,
    tryAutoOpenCoreUi
  };
}
