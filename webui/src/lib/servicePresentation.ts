import { t } from "@/i18n";
import type { RuntimeState } from "@/types";

type ServiceState = "offline" | "stopped" | "unknown" | "unready" | "ready";

/** A process can exist while its network initialization failed or is unknown. */
export function servicePresentation(runtime: Pick<RuntimeState, "singBoxState" | "serviceReady">, connected = true) {
  const state: ServiceState = !connected ? "offline"
    : runtime.singBoxState === "stopped" ? "stopped"
    : runtime.singBoxState !== "sing-box" || runtime.serviceReady === null ? "unknown"
    : runtime.serviceReady === true ? "ready" : "unready";
  return {
    state,
    label: state === "offline" ? t("未连接设备")
      : state === "stopped" ? t("已停止")
      : state === "unknown" ? t("状态待确认")
      : state === "unready" ? t("服务未就绪") : t("运行中"),
    tone: state === "ready" ? "ok" as const
      : state === "stopped" || state === "unready" ? "stop" as const : "unknown" as const,
    routeState: state === "ready" ? "active" : state === "stopped" ? "stopped" : "unknown",
  };
}
