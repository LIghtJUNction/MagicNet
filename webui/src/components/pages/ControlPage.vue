<script setup lang="ts">
import { t } from "@/i18n";
import {
  Copy,
  DownloadCloud,
  ExternalLink,
  Plus,
  Power,
  Radar,
  RotateCcw,
  RefreshCw,
  ArrowUpRight,
  Save,
  Share2,
  ShieldCheck,
  Unplug,
  Wifi,
  Zap,
} from "lucide-vue-next";
import { computed, nextTick, onDeactivated, onMounted, ref, watch } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import CardHeading from "@/components/ui/CardHeading.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import Input from "@/components/ui/Input.vue";
import RemovableTag from "@/components/ui/RemovableTag.vue";
import StatTile from "@/components/ui/StatTile.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import {
  applyConfigAction,
  applyTransparentModeAction,
  type ControlDangerAction,
  repairAction,
  restartSingBoxAction,
  setTransparentModeAction,
  singBoxToggleAction,
  stopAllServicesAction,
} from "@/components/pages/controlDangerActions";
import { useActionLock } from "@/composables/useActionLock";
import { servicePresentation } from "@/lib/servicePresentation";
import { useMagicNet } from "@/composables/useMagicNet";
import { restoreFocusAfterUpdate, trapFocusWithin } from "@/lib/focus";
import type { TransparentMode } from "@/types";
import { copyText, execFailed } from "@/utils";
import {
  buildControlRuntimeInsight,
  controlInsightTone,
  controlRuntimeBusy,
} from "./controlRuntimeInsight";

const {
  state,
  runCli,
  startBackgroundCli,
  refreshAll,
  refreshStatus,
  refreshWifiPolicy,
  openSingBoxUi,
  shellQuote,
} = useMagicNet();
const { isRunning, withAction } = useActionLock();

const emit = defineEmits<{
  (e: "goto-tab", tab: "about" | "health" | "output" | "subs"): void;
}>();
type HotspotPolicyPhase = "loading" | "ready" | "error";


const pendingDangerAction = ref<ControlDangerAction | null>(null);
const dangerConfirmCard = ref<HTMLElement | null>(null);
const snapshotCopied = ref(false);
const wifiSsidInput = ref("");
const wifiBssidInput = ref("");
const hotspotProxyEnabled = ref(false);
const hotspotRouteStatus = ref("");
const hotspotForwardingLabel = computed(() => {
  switch (hotspotRouteStatus.value) {
    case "ready": return t("热点转发规则已就绪");
    case "waiting-for-hotspot": return t("已启用，等待热点开启");
    case "degraded": return t("已启用，但转发规则异常");
    case "shared-tc-unverified": return t("eBPF 共享转发待核实");
    default: return t("已设置，转发状态未确认");
  }
});
const hotspotPolicyPhase = ref<HotspotPolicyPhase>("loading");
const hotspotPolicyError = ref("");
let dangerActionTrigger: HTMLElement | null = null;

const pendingDangerMessage = computed(
  () => pendingDangerAction.value?.message ?? "",
);
const serviceStatus = computed(() => servicePresentation(state.runtime, state.hasKsu));
const runtimeInsight = computed(() =>
  buildControlRuntimeInsight({
    hasKsu: state.hasKsu,
    phase: state.phase,
    queueDepth: state.queueDepth,
    backgroundStatus: state.backgroundTask.status,
    runtime: state.runtime,
    output: state.output,
  }),
);
const runtimeBusy = computed(() =>
  controlRuntimeBusy(state.phase, state.queueDepth, state.backgroundTask.status),
);
const missingNodeCache = computed(() =>
  /No cached sing-box nodes found|run cli sub update sing-box/i.test(
    state.output,
  ),
);

const showRuntimeNotice = computed(() => state.hasKsu && (
  state.phase === "error" || runtimeBusy.value || serviceStatus.value.state === "unready" ||
  serviceStatus.value.state === "unknown" ||
  (runtimeInsight.value.status !== "ok" && state.runtime.singBoxState === "sing-box")
));
const controlTitle = computed(() => serviceStatus.value.label);
const coreFact = computed(() => !state.hasKsu || state.runtime.singBoxState === "unknown" ? t("未确认")
  : state.runtime.singBoxState === "sing-box" ? t("进程存在") : t("已停止"));
const readinessFact = computed(() => !state.hasKsu || state.runtime.serviceReady == null ? t("未确认")
  : state.runtime.singBoxState === "sing-box" && state.runtime.serviceReady ? t("已就绪") : t("未就绪"));
const controlDescription = computed(() => {
  if (!state.hasKsu) return t("在模块管理器中打开，连接设备后管理代理服务。");
  if (serviceStatus.value.state === "ready") return t("服务已就绪。实际联网情况可在诊断中确认。");
  if (serviceStatus.value.state === "stopped") return t("启动前确认订阅已配置；现有配置和节点会保留。");
  return t("先确认服务状态，再继续操作。刷新不会重启服务。");
});

const transparentModeLabel = computed(() => {
  if (state.runtime.transparentMode === "tun") return "TUN";
  if (state.runtime.transparentMode === "ebpf") return "eBPF";
  return t("状态未知");
});
const transparentEffectiveLabel = computed(() => {
  const effective = state.runtime.transparentEffectiveMode;
  if (effective === "tun") return "TUN · magicnet0";
  if (effective === "local") return "eBPF local";
  if (effective === "hybrid") return "eBPF hybrid";
  return t("状态未知");
});
const transparentDescription = computed(() => {
  if (state.runtime.transparentMode === "unknown") {
    return t("无法读取透明代理状态；当前模式不会按 TUN 或 eBPF 猜测。");
  }
  if (state.runtime.transparentMode === "tun") {
    return t("sing-box TUN 通过 magicnet0 接管本机流量。");
  }
  if (state.runtime.transparentEffectiveMode === "hybrid") {
    return t("eBPF local 已接管本机流量，shared TC 使用已确认的下游接口。");
  }
  if (state.runtime.transparentSharedTc === "pending") {
    return t("eBPF local 已配置；尚无已确认下游接口，shared TC 保持 pending。");
  }
  return t("eBPF 使用 cgroup 接管本机流量；shared 状态以运行时报告为准。");
});
const transparentTransitionTone = computed<"neutral" | "success" | "warning" | "danger">(() => {
  if (state.runtime.transparentTransition === "rollback") return "danger";
  if (state.runtime.transparentTransition === "pending") return "warning";
  if (state.runtime.transparentTransition === "stable") return "success";
  return "neutral";
});
const transparentSwitchBusy = computed(() =>
  runtimeBusy.value ||
  isRunning("transparent-set-tun") ||
  isRunning("transparent-set-ebpf") ||
  isRunning("transparent-apply"),
);
const sharedInterfacesLabel = computed(() =>
  state.runtime.transparentSharedInterfaces.join(", ") ||
    (state.runtime.transparentSharedInterfaceCount === null ? t("状态未知")
      : String(state.runtime.transparentSharedInterfaceCount)),
);

const wifiPolicyModes = ["blacklist", "whitelist"] as const;

async function toggleSingBox(event: MouseEvent): Promise<void> {
  const running = state.runtime.singBoxState === "sing-box";
  requestDangerAction(singBoxToggleAction(running), event.currentTarget);
}

async function runAction(
  key: string,
  args: string,
  label: string,
  background = false,
): Promise<void> {
  await withAction(key, async () => {
    if (background) {
      const launch = await startBackgroundCli(args, label);
      if (execFailed(launch)) return;
      window.setTimeout(() => void refreshStatus(), 1200);
    } else {
      const output = await runCli(args, label);
      if (execFailed(output)) {
        if (args.startsWith("transparent set ")) await refreshStatus();
        return;
      }
      await refreshAll();
    }
  });
}

function requestTransparentMode(mode: TransparentMode, event: MouseEvent): void {
  if (mode === state.runtime.transparentMode || transparentSwitchBusy.value) return;
  requestDangerAction(
    setTransparentModeAction(mode, state.runtime.transparentMode),
    event.currentTarget,
  );
}

async function rebuildNodeCache(): Promise<void> {
  await withAction("rebuild-node-cache", async () => {
    // The background follower refreshes subscriptions and service status.
    await startBackgroundCli("sub update sing-box", t("重建 sing-box 节点缓存"));
  });
}

function restoreDangerActionFocus(): void {
  const trigger = dangerActionTrigger;
  dangerActionTrigger = null;
  restoreFocusAfterUpdate(trigger);
}

function requestDangerAction(
  action: ControlDangerAction,
  trigger: EventTarget | null = document.activeElement,
): void {
  dangerActionTrigger = trigger instanceof HTMLElement ? trigger : null;
  pendingDangerAction.value = action;
  void nextTick(() => {
    const reduceMotion =
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    dangerConfirmCard.value?.scrollIntoView({
      block: "nearest",
      behavior: reduceMotion ? "auto" : "smooth",
    });
    dangerConfirmCard.value
      ?.querySelector<HTMLButtonElement>("[data-danger-cancel]")
      ?.focus();
  });
}

function cancelDangerAction(): void {
  pendingDangerAction.value = null;
  restoreDangerActionFocus();
}

function handleDangerKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    cancelDangerAction();
    return;
  }
  trapFocusWithin(event, dangerConfirmCard.value);
}

watch(pendingDangerAction, (action, _previous, onCleanup) => {
  if (!action) return;
  const previousOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  onCleanup(() => { document.body.style.overflow = previousOverflow; });
});

onDeactivated(() => {
  pendingDangerAction.value = null;
  dangerActionTrigger = null;
});

async function confirmDangerAction(): Promise<void> {
  const action = pendingDangerAction.value;
  if (!action) return;
  if (runtimeBusy.value) {
    state.output = t("后台任务未结束，已拒绝执行新的控制操作。");
    return;
  }
  pendingDangerAction.value = null;
  restoreDangerActionFocus();
  await runAction(action.key, action.args, action.label, action.background);
}

async function runWifiAction(
  key: string,
  args: string,
  label: string,
): Promise<void> {
  await withAction(key, async () => {
    const output = await runCli(args, label);
    if (execFailed(output)) return;
    await refreshWifiPolicy(true);
  });
}

async function toggleWifiPolicy(): Promise<void> {
  const enable = !state.wifiPolicy.enabled;
  await runWifiAction(
    "wifi-toggle",
    `wifi ${enable ? "enable" : "disable"}`,
    enable ? t("启用 Wi-Fi 自动模式") : t("停用 Wi-Fi 自动模式"),
  );
}

async function refreshHotspotPolicy(): Promise<boolean> {
  hotspotPolicyPhase.value = "loading";
  hotspotPolicyError.value = "";
  const output = await runCli("hotspot status", t("读取热点代理策略"), true);
  if (execFailed(output)) {
    hotspotPolicyPhase.value = "error";
    hotspotPolicyError.value =
      t("MagicNet 没读到当前热点设置。设备设置没变，请重新读取。");
    state.output = t("读取热点代理策略失败：\n{output}", { output: output });
    return false;
  }
  const matched = output.match(/^enabled=([01])$/m);
  if (!matched) {
    hotspotPolicyPhase.value = "error";
    hotspotPolicyError.value =
      t("MagicNet 没认出设备返回的热点状态。设备设置没变，请重新读取。");
    state.output = t("读取热点代理策略失败：设备返回了无法解析的状态。");
    return false;
  }
  hotspotProxyEnabled.value = matched[1] === "1";
  hotspotRouteStatus.value = output.match(/^route_status=([a-z-]+)$/m)?.[1] ?? "";
  hotspotPolicyPhase.value = "ready";
  return true;
}

async function retryHotspotPolicy(): Promise<void> {
  await withAction("hotspot-policy-refresh", async () => {
    await refreshHotspotPolicy();
  });
}

async function toggleHotspotProxy(event: Event): Promise<void> {
  const checkbox = event.currentTarget as HTMLInputElement;
  if (hotspotPolicyPhase.value !== "ready") {
    checkbox.checked = hotspotProxyEnabled.value;
    return;
  }
  const previous = hotspotProxyEnabled.value;
  const enabled = checkbox.checked;
  hotspotProxyEnabled.value = enabled;
  await withAction("hotspot-proxy", async () => {
    const output = await runCli(
      `hotspot ${enabled ? "enable" : "disable"}`,
      enabled ? t("启用热点代理") : t("停用热点代理"),
    );
    if (execFailed(output)) {
      hotspotProxyEnabled.value = previous;
      return;
    }
    if (!(await refreshHotspotPolicy())) {
      hotspotProxyEnabled.value = previous;
    }
  });
}

async function setWifiPolicyMode(mode: "blacklist" | "whitelist"): Promise<void> {
  if (state.wifiPolicy.policyMode === mode) return;
  await runWifiAction(
    `wifi-mode-${mode}`,
    `wifi mode ${mode}`,
    t("切换 Wi-Fi {mode}", { mode: mode }),
  );
}

async function addWifiEntry(kind: "ssid" | "bssid"): Promise<void> {
  const input = kind === "ssid" ? wifiSsidInput : wifiBssidInput;
  const value = input.value.trim();
  if (!value) {
    state.output = kind === "ssid" ? t("请输入 SSID。") : t("请输入 BSSID。");
    return;
  }
  await runWifiAction(
    `wifi-add-${kind}`,
    `wifi add-${kind} ${shellQuote(value)}`,
    t("添加 Wi-Fi {kind}", { kind: kind.toUpperCase() }),
  );
  input.value = "";
}

async function removeWifiEntry(
  kind: "ssid" | "bssid",
  value: string,
): Promise<void> {
  await runWifiAction(
    `wifi-remove-${kind}-${value}`,
    `wifi remove-${kind} ${shellQuote(value)}`,
    t("移除 Wi-Fi {kind}", { kind: kind.toUpperCase() }),
  );
}

async function copyControlSnapshot(): Promise<void> {
  const report = [
    "MagicNet control snapshot",
    `has_ksu=${state.hasKsu ? 1 : 0}`,
    `phase=${state.phase}`,
    `task=${state.task || "none"}`,
    `queue_depth=${state.queueDepth}`,
    `sing_box_state=${state.runtime.singBoxState}`,
    `sing_box=${state.runtime.singBox}`,
    `fswatch=${state.runtime.fswatch}`,
    `transparent_mode=${state.runtime.transparentMode}`,
    `transparent_effective_mode=${state.runtime.transparentEffectiveMode}`,
    `transparent_capability=${state.runtime.transparentCapability}`,
    `transparent_local_cgroup=${state.runtime.transparentLocalCgroup}`,
    `transparent_shared_tc=${state.runtime.transparentSharedTc}`,
    `transparent_shared_interfaces=${sharedInterfacesLabel.value}`,
    `transparent_transition=${state.runtime.transparentTransition}`,
    `insight_status=${runtimeInsight.value.status}`,
    `insight_title=${runtimeInsight.value.title}`,
    `recommended_actions=${runtimeInsight.value.actions.join(",") || "none"}`,
    `last_command_kind=${classifyLastCommand(state.lastCommand)}`,
  ].join("\n");
  snapshotCopied.value = await copyText(sanitizeControlSnapshot(report));
  state.notice = snapshotCopied.value
    ? t("控制状态快照已复制。")
    : t("剪贴板不可用，控制状态快照未复制。");
}

function sanitizeControlSnapshot(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, "[filtered-url]")
    .replace(
      /\b(token|secret|password|passwd|authorization|bearer|api[_-]?key|key)\b\s*[:=]\s*\S+/gi,
      "$1=[filtered]",
    );
}

function classifyLastCommand(command: string): string {
  if (!command) return "none";
  if (/\bbackup\b/.test(command)) return "backup";
  if (/\bsub(?:scription)?\b|sub set-file|subscription/i.test(command))
    return "subscription";
  if (/\btransparent\b/.test(command)) return "transparent";
  if (/\bservice\b/.test(command)) return "service";
  if (/\bconfig\b/.test(command)) return "config";
  if (/\bmcp\b/.test(command)) return "mcp";
  if (/\bwebui\b/.test(command)) return "webui";
  return "other";
}

onMounted(() => {
  void refreshHotspotPolicy();
});
</script>

<template>
  <div class="mn-control">
    <section class="mn-control-hero" :data-service-state="serviceStatus.state" :aria-label="t('服务概览')">
      <div class="mn-control-overview">
        <div class="mn-control-status" role="status" aria-live="polite">
          <div class="mn-control-state-heading">
            <p class="mn-control-eyebrow"><StatusDot :tone="serviceStatus.tone" />{{ t("代理服务") }}</p>
            <h2>{{ controlTitle }}</h2>
            <p class="mn-control-description">{{ controlDescription }}</p>
          </div>
          <dl v-if="state.hasKsu && state.runtime.singBoxState === 'sing-box'" class="mn-control-memory">
            <dt>{{ t("内核内存（RSS）") }}</dt>
            <dd :data-unavailable="state.runtime.singBoxRssKib == null">
              <template v-if="state.runtime.singBoxRssKib != null">{{ (state.runtime.singBoxRssKib / 1024).toFixed(1) }} <span>MiB</span></template>
              <template v-else>{{ t("暂不可用") }}</template>
            </dd>
          </dl>
        </div>
        <div class="mn-control-actions">
          <Button class="mn-control-power" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('toggle-sing-box')" @click="toggleSingBox">
            <Power :size="18" />{{ state.runtime.singBoxState === 'sing-box' ? t("停止服务") : t("启动服务") }}
          </Button>
          <div class="mn-control-shortcuts">
            <Button variant="ghost" :disabled="!state.hasKsu" :loading="isRunning('refresh-control-status')" @click="withAction('refresh-control-status', () => refreshStatus())">
              <RefreshCw :size="16" />{{ t("刷新状态") }}
            </Button>
            <Button variant="ghost" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('restart-sing-box')" @click="requestDangerAction(restartSingBoxAction(), $event.currentTarget)">
              <RotateCcw :size="16" />{{ t("重启服务") }}
            </Button>
          </div>
        </div>
      </div>
      <dl class="mn-service-facts" :aria-label="t('运行证据')">
        <div><dt>sing-box</dt><dd>{{ coreFact }}</dd></div>
        <div><dt>{{ t("服务检查") }}</dt><dd>{{ readinessFact }}</dd></div>
        <div><dt>{{ t("实际模式") }}</dt><dd>{{ state.hasKsu ? transparentEffectiveLabel : t("未确认") }}</dd></div>
      </dl>
      <section v-if="showRuntimeNotice" class="mn-control-notice" :class="controlInsightTone(runtimeInsight.status)" :role="state.phase === 'error' ? 'alert' : 'status'" aria-live="polite">
        <h3><StatusDot tone="current" />{{ runtimeInsight.title }}</h3>
        <p>{{ runtimeInsight.detail }}</p>
        <div class="mn-notice-actions">
          <Button v-if="missingNodeCache" variant="outline" :disabled="runtimeBusy" :loading="isRunning('rebuild-node-cache')" @click="rebuildNodeCache">
            <DownloadCloud :size="17" />{{ t("更新订阅并重建节点") }}
          </Button>
          <Button variant="outline" @click="emit('goto-tab', 'output')">{{ t("查看输出") }}<ArrowUpRight :size="16" /></Button>
          <Button variant="ghost" @click="emit('goto-tab', 'health')">{{ t("打开诊断") }}</Button>
        </div>
      </section>
    </section>

    <nav class="mn-control-destinations" :aria-label="t('常用入口')">
      <button type="button" @click="emit('goto-tab', 'subs')"><DownloadCloud :size="19" /><span>{{ t("订阅与节点") }}<small>{{ t("管理来源与更新") }}</small></span><ArrowUpRight :size="16" /></button>
      <button type="button" :disabled="!state.hasKsu || serviceStatus.state !== 'ready'" @click="withAction('open-zashboard', () => openSingBoxUi('zashboard'))"><ExternalLink :size="19" /><span>{{ t("节点面板") }}<small>{{ t("服务就绪后可打开") }}</small></span><ArrowUpRight :size="16" /></button>
    </nav>
    <div class="mn-control-section-title"><h3>{{ t("网络设置") }}</h3><span>{{ t("按需调整，无需反复重启") }}</span></div>

    <div class="mn-control-settings">
      <Card class="grid gap-5">
        <CardHeading :title="t('代理模式')">
          <Badge v-if="state.runtime.transparentMode === 'unknown'" tone="neutral">{{ t("未确认") }}</Badge>
        </CardHeading>

        <div
          role="group"
          :aria-label="t('选择透明代理模式')"
          class="grid grid-cols-2 gap-2"
        >
          <Button
            :variant="state.runtime.transparentMode === 'tun' ? 'default' : 'outline'"
            :disabled="!state.hasKsu || transparentSwitchBusy || state.runtime.transparentMode === 'tun'"
            :loading="isRunning('transparent-set-tun')"
            :aria-pressed="state.runtime.transparentMode === 'tun'"
            :class="state.runtime.transparentMode === 'tun' ? 'disabled:cursor-default disabled:opacity-100' : ''"
            @click="requestTransparentMode('tun', $event)"
          >
            TUN
          </Button>
          <Button
            :variant="state.runtime.transparentMode === 'ebpf' ? 'default' : 'outline'"
            :disabled="!state.hasKsu || transparentSwitchBusy || state.runtime.transparentMode === 'ebpf'"
            :loading="isRunning('transparent-set-ebpf')"
            :aria-pressed="state.runtime.transparentMode === 'ebpf'"
            :class="state.runtime.transparentMode === 'ebpf' ? 'disabled:cursor-default disabled:opacity-100' : ''"
            @click="requestTransparentMode('ebpf', $event)"
          >
            eBPF
          </Button>
        </div>

        <details class="mn-control-details">
          <summary>{{ t("运行详情") }}</summary>
          <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ transparentDescription }}</p>
          <Badge :tone="transparentTransitionTone">{{ state.runtime.transparentTransition }}</Badge>
        <dl
          aria-live="polite"
          class="grid gap-x-4 gap-y-2 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-surface-sunken)] p-3 text-xs sm:grid-cols-2"
        >
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">configured</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ state.runtime.transparentMode }}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">effective</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ transparentEffectiveLabel }}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">local cgroup</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ state.runtime.transparentLocalCgroup }}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">shared TC</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ state.runtime.transparentSharedTc }}</dd>
          </div>
          <div class="min-w-0 sm:col-span-2">
            <dt class="text-[var(--mn-ink-muted)]">shared interfaces</dt>
            <dd class="break-all font-mono text-[var(--mn-ink)]">{{ sharedInterfacesLabel }}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">capability</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ state.runtime.transparentCapability }}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[var(--mn-ink-muted)]">transition</dt>
            <dd class="break-words font-mono text-[var(--mn-ink)]">{{ state.runtime.transparentTransition }}</dd>
          </div>
        </dl>

        <Button
          variant="secondary"
          :disabled="!state.hasKsu || transparentSwitchBusy"
          :loading="isRunning('transparent-apply')"
          @click="requestDangerAction(applyTransparentModeAction(), $event.currentTarget)"
        >
          <Radar :size="17" />{{ t("重新应用当前模式") }} </Button>
        </details>
        <p v-if="state.runtime.transparentRecentError" role="alert" class="text-sm leading-6 text-[var(--mn-danger)]">
          {{ state.runtime.transparentRecentError }}
        </p>
      </Card>

      <Card class="grid gap-2" :aria-busy="hotspotPolicyPhase === 'loading'">
        <label class="mn-hotspot-switch">
          <input
            type="checkbox"
            role="switch"
            class="mn-hotspot-input"
            :checked="hotspotProxyEnabled"
            :disabled="!state.hasKsu || hotspotPolicyPhase !== 'ready' || runtimeBusy || isRunning('hotspot-proxy')"
            :aria-label="t('允许热点使用代理')"
            aria-describedby="hotspot-proxy-description hotspot-proxy-status"
            @change="toggleHotspotProxy"
          />
          <span class="min-w-0">
            <span class="mn-hotspot-label"><Share2 :size="17" />{{ t("热点代理") }}</span>
            <span id="hotspot-proxy-status" class="mn-hotspot-state">
              {{ !state.hasKsu ? t("未连接设备") : hotspotPolicyPhase === 'loading' ? t("读取中") : hotspotPolicyPhase === 'error' ? t("读取失败") : hotspotProxyEnabled ? hotspotForwardingLabel : t("已关闭") }}
            </span>
          </span>
          <span class="mn-hotspot-track" aria-hidden="true" />
        </label>
        <details class="mn-control-details">
          <summary>{{ t("共享设置") }}</summary>
          <p id="hotspot-proxy-description" class="text-sm leading-6 text-[var(--mn-ink-muted)]"> {{ t("热点设备使用 proxy 代理组；不勾选时统一走 direct。TUN 模式会关闭 Android 热点硬件加速，关闭代理后恢复原设置；eBPF 模式使用共享 TC。") }} </p>
          <Button v-if="state.hasKsu && hotspotProxyEnabled" variant="ghost" :disabled="runtimeBusy" @click="retryHotspotPolicy">{{ t("重新读取") }}</Button>
        </details>
        <div v-if="state.hasKsu && hotspotPolicyPhase === 'error'" class="mn-control-notice mn-tone-warn" role="alert">
          <p>{{ hotspotPolicyError }}</p>
          <Button variant="outline" :loading="isRunning('hotspot-policy-refresh')" @click="retryHotspotPolicy">
            <RotateCcw :size="16" />{{ t("重新读取") }} </Button>
        </div>
      </Card>

      <details class="mn-disclosure">
        <summary><Wifi :size="18" />{{ t("Wi-Fi 自动切换") }}<span>{{ state.wifiPolicy.enabled ? t("已开启") : t("已关闭") }}</span></summary>
      <Card class="grid gap-5">
        <CardHeading :title="t('Wi-Fi 策略')">
          <Badge :tone="state.wifiPolicy.observed && state.wifiPolicy.connected ? 'success' : 'neutral'">
            {{ !state.wifiPolicy.observed ? t("状态未知") : state.wifiPolicy.connected ? state.wifiPolicy.ssid || t("Wi-Fi 已连接") : t("未连接 Wi-Fi") }}
          </Badge>
          <Badge :tone="state.wifiPolicy.enabled ? 'success' : 'warning'">
            {{ state.wifiPolicy.enabled ? t("已启用") : t("已停用") }}
          </Badge>
          <Button
            :loading="isRunning('wifi-toggle')"
            :disabled="runtimeBusy || !state.hasKsu"
            @click="toggleWifiPolicy"
          >
            <Power :size="17" />{{ state.wifiPolicy.enabled ? t("停用") : t("启用") }}
          </Button>
        </CardHeading>

        <div class="grid gap-3 md:grid-cols-2">
          <button
            v-for="mode in wifiPolicyModes"
            :key="mode"
            type="button"
            :aria-pressed="state.wifiPolicy.policyMode === mode"
            :disabled="!state.hasKsu || runtimeBusy || state.wifiPolicy.policyMode === mode"
            :class="[
              'rounded-[var(--mn-radius-md)] border border-transparent px-4 py-3 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)] disabled:cursor-default',
              state.wifiPolicy.policyMode === mode
                ? 'bg-[var(--mn-cactus)] text-[var(--mn-on-accent)]'
                : 'bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] text-[var(--mn-ink-soft)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_8%,transparent)]',
            ]"
            @click="setWifiPolicyMode(mode)"
          >
            <span class="font-semibold">{{ mode === "blacklist" ? t("黑名单") : t("白名单") }}</span>
            <span class="mt-1 block text-xs">
              {{ mode === "blacklist" ? t("名单命中 → Direct") : t("名单命中 → Rule") }}
            </span>
          </button>
        </div>

        <div class="grid gap-3 md:grid-cols-3">
          <StatTile :label="t('当前 BSSID')" :value="state.wifiPolicy.bssid || '—'" />
          <StatTile :label="t('匹配结果')" :value="!state.wifiPolicy.observed ? t('状态未知') : state.wifiPolicy.matched ? t('已命中名单') : t('未命中')" />
          <StatTile :label="t('代理模式')" :value="`${state.wifiPolicy.currentMode} → ${state.wifiPolicy.desiredMode}`" />
        </div>

        <div class="grid gap-5 lg:grid-cols-2">
          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiSsidInput"
                aria-label="Wi-Fi SSID"
                :placeholder="t('Wi-Fi 名称（SSID）')"
                @keyup.enter="addWifiEntry('ssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-ssid')"
                @click="addWifiEntry('ssid')"
              ><Plus :size="17" />SSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span v-if="!state.wifiPolicy.ssids.length" class="mn-empty text-xs">{{ t("还没有 SSID 条目") }}</span>
              <RemovableTag
                v-for="ssid in state.wifiPolicy.ssids"
                :key="ssid"
                variant="soft"
                remove-variant="ghost"
                :remove-label="t('移除 SSID {ssid}', { ssid: ssid })"
                @remove="removeWifiEntry('ssid', ssid)"
              >{{ ssid }}</RemovableTag>
            </div>
          </div>

          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiBssidInput"
                aria-label="Wi-Fi BSSID"
                :placeholder="t('BSSID 地址')"
                @keyup.enter="addWifiEntry('bssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-bssid')"
                @click="addWifiEntry('bssid')"
              ><Plus :size="17" />BSSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span v-if="!state.wifiPolicy.bssids.length" class="mn-empty text-xs">{{ t("还没有 BSSID 条目") }}</span>
              <RemovableTag
                v-for="bssid in state.wifiPolicy.bssids"
                :key="bssid"
                class="font-mono"
                variant="soft"
                remove-variant="ghost"
                :remove-label="t('移除 BSSID {bssid}', { bssid: bssid })"
                @remove="removeWifiEntry('bssid', bssid)"
              >{{ bssid }}</RemovableTag>
            </div>
          </div>
        </div>
      </Card>
      </details>

      <details class="mn-disclosure">
        <summary>{{ t("服务管理") }}</summary>
        <div class="mn-disclosure__body">
          <div class="grid grid-cols-2 gap-3">
            <Button variant="secondary" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('apply-config')" @click="requestDangerAction(applyConfigAction(), $event.currentTarget)">
              <Save :size="17" />{{ t("应用配置") }} </Button>
            <Button variant="secondary" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('repair')" @click="requestDangerAction(repairAction(), $event.currentTarget)">
              <Zap :size="17" />{{ t("自修复") }} </Button>
            <Button variant="outline" :disabled="!state.hasKsu" :loading="isRunning('api-groups')" @click="withAction('api-groups', () => runCli('api groups', t('检查 sing-box API')))">
              <ShieldCheck :size="17" />{{ t("检查 API") }} </Button>
            <Button variant="outline" @click="copyControlSnapshot"><Copy :size="17" />{{ snapshotCopied ? t("已复制") : t("复制快照") }}</Button>
            <Button variant="outline" @click="emit('goto-tab', 'about')">{{ t("流量路径") }}</Button>
            <Button variant="outline" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('stop-all')" @click="requestDangerAction(stopAllServicesAction(), $event.currentTarget)">
              <Unplug :size="17" />{{ t("停止全部") }} </Button>
          </div>
        </div>
      </details>
    </div>

    <Teleport to="body">
      <Transition name="sheet">
        <div v-if="pendingDangerAction" class="mn-sheet-layer">
          <button class="mn-overlay" type="button" :aria-label="t('取消控制操作')" @click="cancelDangerAction" />
          <div ref="dangerConfirmCard" class="mn-utility-sheet mn-control-confirm" role="alertdialog" aria-modal="true" :aria-label="t('确认控制操作')" tabindex="-1" @keydown="handleDangerKeydown">
            <ConfirmPanel
              :title="t('确认操作')"
              :detail="pendingDangerMessage"
              :command="pendingDangerAction.args"
              :loading="isRunning(pendingDangerAction.key)"
              :confirm-label="t('继续执行')"
              confirm-variant="destructive"
              :auto-focus="false"
            >
              <template #actions>
                <Button data-danger-cancel variant="outline" @click="cancelDangerAction">{{ t("取消") }}</Button>
                <Button variant="destructive" :disabled="runtimeBusy" :loading="isRunning(pendingDangerAction.key)" @click="confirmDangerAction">{{ t("继续执行") }}</Button>
              </template>
            </ConfirmPanel>
          </div>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.mn-control { max-width: 960px; margin-inline: auto; }
.mn-control-hero { padding: clamp(20px, 4vw, 36px); border: 1px solid var(--mn-border); border-radius: 24px; background: var(--mn-surface-raised); }
.mn-control-overview { display: grid; gap: 28px; }
.mn-control-status { display: grid; gap: 22px; min-width: 0; }
.mn-control-state-heading { min-width: 0; }
.mn-control-eyebrow { display: flex; align-items: center; gap: 9px; margin: 0 0 16px; color: var(--mn-ink-muted); font-size: 12px; letter-spacing: .04em; }
.mn-control-status h2 { margin: 0; color: var(--mn-ink); font-size: clamp(30px, 7vw, 44px); font-weight: 500; line-height: 1.22; letter-spacing: -.035em; overflow-wrap: anywhere; }
.mn-control-description { margin: 14px 0 0; max-width: 42ch; color: var(--mn-ink-muted); font-size: 13px; line-height: 1.8; }
.mn-control-memory { display: flex; align-items: baseline; gap: 14px; margin: 0; }
.mn-control-memory dt { color: var(--mn-ink-muted); font-size: 12px; }
.mn-control-memory dd { margin: 0; color: var(--mn-ink); font-size: 18px; font-variant-numeric: tabular-nums; }
.mn-control-memory dd > span { color: var(--mn-ink-muted); font-size: 12px; }
.mn-control-memory dd[data-unavailable="true"] { color: var(--mn-ink-muted); font-size: 13px; }
.mn-control-actions { align-self: center; min-width: 0; }
.mn-control-power { width: 100%; min-height: 54px; font-size: 14px; }
.mn-control-shortcuts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px; margin-top: 8px; }
.mn-control-shortcuts > button { padding-inline: 6px; }
.mn-service-facts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin: 28px 0 0; padding-top: 22px; border-top: 1px solid var(--mn-border); }
.mn-service-facts > div { min-width: 0; }
.mn-service-facts dt { color: var(--mn-ink-muted); font-size: 11px; }
.mn-service-facts dd { margin: 7px 0 0; color: var(--mn-ink); font-size: 12px; line-height: 1.6; overflow-wrap: anywhere; }
.mn-control-notice { margin-top: 24px; border-radius: 14px; padding: 16px; font-size: 13px; }
.mn-control-notice h3 { display: flex; align-items: center; gap: 9px; margin: 0; font-size: 14px; font-weight: 600; overflow-wrap: anywhere; }
.mn-control-notice p { margin: 10px 0 0; line-height: 1.8; overflow-wrap: anywhere; }
.mn-notice-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
.mn-control-destinations { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; margin: 16px 0 32px; }
.mn-control-destinations > button { display: flex; align-items: center; gap: 12px; min-width: 0; min-height: 84px; padding: 16px; border: 1px solid var(--mn-border); border-radius: 16px; background: transparent; color: var(--mn-ink); text-align: left; cursor: pointer; }
.mn-control-destinations > button:hover:not(:disabled) { background: var(--mn-surface-raised); border-color: var(--mn-border-strong); }
.mn-control-destinations > button:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: 3px; }
.mn-control-destinations > button:disabled { cursor: not-allowed; opacity: .55; }
.mn-control-destinations svg { flex-shrink: 0; }
.mn-control-destinations span { flex: 1; min-width: 0; font-size: 13px; overflow-wrap: anywhere; }
.mn-control-destinations small { display: block; margin-top: 5px; color: var(--mn-ink-muted); font-size: 11px; line-height: 1.6; }
.mn-control-section-title { display: flex; align-items: baseline; flex-wrap: wrap; gap: 10px; margin: 0 0 16px; }
.mn-control-section-title h3 { margin: 0; color: var(--mn-ink); font-size: 15px; font-weight: 500; }
.mn-control-section-title > span { color: var(--mn-ink-muted); font-size: 12px; }
.mn-control-settings { display: grid; gap: 16px; }
@media (min-width: 760px) {
  .mn-control-overview { grid-template-columns: minmax(0, 1fr) minmax(200px, .6fr); gap: 36px; }
  .mn-control-settings { grid-template-columns: repeat(2, minmax(0, 1fr)); align-items: start; }
}
@media (max-width: 420px) {
  .mn-control-hero { padding: 18px; border-radius: 18px; }
  .mn-control-destinations { grid-template-columns: minmax(0, 1fr); gap: 10px; margin-bottom: 28px; }
  .mn-control-destinations > button { min-height: 72px; }
  .mn-service-facts { gap: 8px; }
}

.mn-control-details > summary {
  display: flex;
  min-height: 48px;
  cursor: pointer;
  align-items: center;
  gap: 8px;
  color: var(--mn-ink-muted);
  font-size: 13px;
  list-style: none;
}

.mn-control-details > summary::after {
  content: "+";
  font-size: 16px;
}

.mn-control-details[open] > summary::after {
  content: "−";
}

.mn-control-details > summary::-webkit-details-marker {
  display: none;
}

.mn-control-details[open] > :not(summary) {
  margin-top: 12px;
}

.mn-hotspot-switch {
  position: relative;
  display: flex;
  min-height: 64px;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}

.mn-hotspot-input {
  position: absolute;
  inset: 0;
  z-index: 1;
  width: 100%;
  height: 100%;
  margin: 0;
  cursor: pointer;
  opacity: 0;
}

.mn-hotspot-input:disabled {
  cursor: not-allowed;
}

.mn-hotspot-label {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 16px;
  font-weight: 500;
}

.mn-hotspot-state {
  display: block;
  margin-top: 5px;
  color: var(--mn-ink-muted);
  font-size: 13px;
}

.mn-hotspot-track {
  position: relative;
  width: 50px;
  height: 30px;
  flex: 0 0 50px;
  border: 1px solid var(--mn-border-strong);
  border-radius: 99px;
  background: var(--mn-carrier-deep);
}

.mn-hotspot-track::after {
  position: absolute;
  top: 3px;
  left: 3px;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--mn-surface-raised);
  content: "";
  transition: transform 150ms ease-out;
}

.mn-hotspot-input:checked ~ .mn-hotspot-track {
  border-color: var(--mn-primary);
  background: var(--mn-primary);
}

.mn-hotspot-input:checked ~ .mn-hotspot-track::after {
  background: var(--mn-on-accent);
  transform: translateX(20px);
}

.mn-hotspot-input:focus-visible ~ .mn-hotspot-track {
  outline: 2px solid var(--mn-focus);
  outline-offset: 4px;
}

.mn-hotspot-input:disabled ~ .mn-hotspot-track {
  opacity: 0.45;
}

.mn-control-confirm :deep(.magic-card) {
  border: 0;
  padding: 0;
  background: transparent;
}
</style>
