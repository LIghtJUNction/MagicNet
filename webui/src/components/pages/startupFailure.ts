import { t } from "@/i18n";
import { stripTerminalControlSequences } from "@/composables/issueDrafts";

const STAGES: Record<string, string> = {
  "subscription": "节点准备",
  "chain": "代理链配置",
  "transparent": "透明代理配置",
  "hotspot": "热点策略",
  "dns": "DNS 配置",
  "tailscale": "Tailscale 配置",
  "apps": "应用分流",
  "warp": "WARP 配置",
  "auth": "Tailscale 授权",
  "config-check": "配置校验",
  "route-baseline": "路由状态读取",
  "core-launch": "内核启动",
  "route-capture": "路由归属验证",
  "network-ready": "网络初始化"
};

/** Classify only explicit evidence, never the shell's LOCK_TIMEOUT=2 setting. */
export function startupFailure(output: string): { title: string; detail: string } | null {
  const text = stripTerminalControlSequences(output);
  const failures = [...text.matchAll(/Startup step failed: stage=([a-z-]+) exit=([0-9]+)\b/g)];
  const stage = failures.at(-1)?.[1];
  if (stage && Object.hasOwn(STAGES, stage)) {
    return { title: t("启动停在：{stage}", { stage: t(STAGES[stage]) }),
      detail: t("此步骤未完成，后续启动已中止。查看输出中的前置错误，再处理对应设置。") };
  }
  if (/Timed out waiting for config lock:/.test(text)) {
    return { title: t("配置正在被其他任务占用"),
      detail: t("已达到配置锁等待上限。先查看后台任务，不要删除锁或反复重启。") };
  }
  if (/sing-box startup failed|magicnet_start_kernel[\s\S]*failed with status/.test(text)) {
    return { title: t("启动失败，原因尚未捕获"),
      detail: t("当前输出只有启动失败的汇总，不能据此判定为锁超时。请查看内核日志和带上下文的日志摘要。") };
  }
  return null;
}
