<script setup lang="ts">
import {
  Copy,
  DownloadCloud,
  ExternalLink,
  Plus,
  Power,
  Radar,
  RotateCcw,
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
  (e: "goto-tab", tab: "about" | "health" | "output"): void;
}>();
type HotspotPolicyPhase = "loading" | "ready" | "error";
type SingBoxStatusPresentation = {
  label: string;
  tone: "neutral" | "success" | "warning";
  dotClass: string;
};

const pendingDangerAction = ref<ControlDangerAction | null>(null);
const dangerConfirmCard = ref<HTMLElement | null>(null);
const snapshotCopied = ref(false);
const wifiSsidInput = ref("");
const wifiBssidInput = ref("");
const hotspotProxyEnabled = ref(false);
const hotspotPolicyPhase = ref<HotspotPolicyPhase>("loading");
const hotspotPolicyError = ref("");
let dangerActionTrigger: HTMLElement | null = null;

const pendingDangerMessage = computed(
  () => pendingDangerAction.value?.message ?? "",
);
const singBoxStatus = computed<SingBoxStatusPresentation>(() => {
  const rawState = state.runtime.singBoxState;
  if (rawState === "sing-box") {
    return {
      label: "运行中",
      tone: "success",
      dotClass: "bg-[var(--mn-cactus)]",
    };
  }
  if (rawState === "stopped") {
    return {
      label: "已停止",
      tone: "warning",
      dotClass: "bg-[var(--mn-oat)]",
    };
  }
  return {
    label: !rawState || rawState === "unknown" ? "状态未知" : rawState,
    tone: "neutral",
    dotClass: "bg-[var(--mn-ink-faint)]",
  };
});
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
  missingNodeCache.value || state.phase === "error" ||
  (runtimeInsight.value.status !== "ok" && state.runtime.singBoxState !== "stopped")
));

const controlTitle = computed(() => {
  if (!state.hasKsu) return "未连接设备";
  if (state.runtime.singBoxState === "sing-box") return "运行中";
  if (state.runtime.singBoxState === "stopped") return "已停止";
  return "状态未知";
});

const transparentModeLabel = computed(() => {
  if (state.runtime.transparentMode === "tun") return "TUN";
  if (state.runtime.transparentMode === "ebpf") return "eBPF";
  return "状态未知";
});
const transparentEffectiveLabel = computed(() => {
  const effective = state.runtime.transparentEffectiveMode;
  if (effective === "tun") return "TUN · magicnet0";
  if (effective === "local") return "eBPF local";
  if (effective === "hybrid") return "eBPF hybrid";
  return "状态未知";
});
const transparentDescription = computed(() => {
  if (state.runtime.transparentMode === "unknown") {
    return "无法读取透明代理状态；当前模式不会按 TUN 或 eBPF 猜测。";
  }
  if (state.runtime.transparentMode === "tun") {
    return "sing-box TUN 通过 magicnet0 接管本机流量。";
  }
  if (state.runtime.transparentEffectiveMode === "hybrid") {
    return "eBPF local 已接管本机流量，shared TC 使用已确认的下游接口。";
  }
  if (state.runtime.transparentSharedTc === "pending") {
    return "eBPF local 已配置；尚无已确认下游接口，shared TC 保持 pending。";
  }
  return "eBPF 使用 cgroup 接管本机流量；shared 状态以运行时报告为准。";
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
  state.runtime.transparentSharedInterfaces.join(", ") || "none",
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
    await startBackgroundCli("sub update sing-box", "重建 sing-box 节点缓存");
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
    state.output = "后台任务未结束，已拒绝执行新的控制操作。";
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
    `${enable ? "启用" : "停用"} Wi-Fi 自动模式`,
  );
}

async function refreshHotspotPolicy(): Promise<boolean> {
  hotspotPolicyPhase.value = "loading";
  hotspotPolicyError.value = "";
  const output = await runCli("hotspot status", "读取热点代理策略", true);
  if (execFailed(output)) {
    hotspotPolicyPhase.value = "error";
    hotspotPolicyError.value =
      "MagicNet 没读到当前热点设置。设备设置没变，请重新读取。";
    state.output = `读取热点代理策略失败：\n${output}`;
    return false;
  }
  const matched = output.match(/^enabled=([01])$/m);
  if (!matched) {
    hotspotPolicyPhase.value = "error";
    hotspotPolicyError.value =
      "MagicNet 没认出设备返回的热点状态。设备设置没变，请重新读取。";
    state.output = "读取热点代理策略失败：设备返回了无法解析的状态。";
    return false;
  }
  hotspotProxyEnabled.value = matched[1] === "1";
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
      `${enabled ? "启用" : "停用"}热点代理`,
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
    `切换 Wi-Fi ${mode}`,
  );
}

async function addWifiEntry(kind: "ssid" | "bssid"): Promise<void> {
  const input = kind === "ssid" ? wifiSsidInput : wifiBssidInput;
  const value = input.value.trim();
  if (!value) {
    state.output = kind === "ssid" ? "请输入 SSID。" : "请输入 BSSID。";
    return;
  }
  await runWifiAction(
    `wifi-add-${kind}`,
    `wifi add-${kind} ${shellQuote(value)}`,
    `添加 Wi-Fi ${kind.toUpperCase()}`,
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
    `移除 Wi-Fi ${kind.toUpperCase()}`,
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
  state.output = snapshotCopied.value
    ? "控制状态快照已复制。"
    : "剪贴板不可用，控制状态快照未复制。";
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
    <section class="mn-control-hero" aria-label="服务概览">
      <div class="mn-control-status" role="status" aria-live="polite">
        <p class="mn-control-caption">{{ state.hasKsu ? 'sing-box' : 'MagicNet' }}</p>
        <h2>{{ controlTitle }}</h2>
        <p class="mn-control-subtitle">
          <span v-if="state.hasKsu" :class="['mn-control-dot', singBoxStatus.dotClass]" />
          {{ state.hasKsu ? transparentModeLabel : '请在模块管理器中打开' }}
        </p>
      </div>

      <Button
        class="mn-control-power"
        :disabled="runtimeBusy || !state.hasKsu"
        :loading="isRunning('toggle-sing-box')"
        @click="toggleSingBox"
      >
        <Power :size="18" />
        {{ state.runtime.singBoxState === 'sing-box' ? '停止服务' : '启动服务' }}
      </Button>
      <div class="mn-control-shortcuts">
        <Button variant="ghost" :disabled="!state.hasKsu" :loading="isRunning('open-zashboard')" @click="withAction('open-zashboard', () => openSingBoxUi('zashboard'))">
          <ExternalLink :size="16" />节点面板
        </Button>
        <Button variant="ghost" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('restart-sing-box')" @click="requestDangerAction(restartSingBoxAction(), $event.currentTarget)">
          <RotateCcw :size="16" />重启服务
        </Button>
      </div>

      <details
        v-if="showRuntimeNotice"
        :open="missingNodeCache"
        class="mn-control-notice"
        :class="controlInsightTone(runtimeInsight.status)"
      >
        <summary><StatusDot tone="current" />{{ runtimeInsight.title }}</summary>
        <p>{{ runtimeInsight.detail }}</p>
        <Button v-if="missingNodeCache" variant="outline" :loading="isRunning('rebuild-node-cache')" @click="rebuildNodeCache">
          <DownloadCloud :size="17" />更新订阅并重建节点
        </Button>
        <Button v-else variant="outline" @click="emit('goto-tab', 'output')">查看输出</Button>
      </details>
    </section>

    <div class="mn-control-settings">
      <Card class="grid gap-5">
        <CardHeading title="代理模式">
          <Badge v-if="state.runtime.transparentMode === 'unknown'" tone="neutral">未确认</Badge>
        </CardHeading>

        <div
          role="group"
          aria-label="选择透明代理模式"
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
          <summary>运行详情</summary>
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
          <Radar :size="17" />重新应用当前模式
        </Button>
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
            aria-label="允许热点使用代理"
            aria-describedby="hotspot-proxy-description hotspot-proxy-status"
            @change="toggleHotspotProxy"
          />
          <span class="min-w-0">
            <span class="mn-hotspot-label"><Share2 :size="17" />热点代理</span>
            <span id="hotspot-proxy-status" class="mn-hotspot-state">
              {{ !state.hasKsu ? '未连接设备' : hotspotPolicyPhase === 'loading' ? '读取中' : hotspotPolicyPhase === 'error' ? '读取失败' : hotspotProxyEnabled ? '已开启' : '已关闭' }}
            </span>
          </span>
          <span class="mn-hotspot-track" aria-hidden="true" />
        </label>
        <details class="mn-control-details">
          <summary>共享设置</summary>
          <p id="hotspot-proxy-description" class="text-sm leading-6 text-[var(--mn-ink-muted)]">
            热点设备使用 <code>proxy</code> 代理组；不勾选时统一走 <code>direct</code>。
            TUN 模式会关闭 Android 热点硬件加速，关闭代理后恢复原设置；eBPF 模式使用共享 TC。
          </p>
        </details>
        <div v-if="state.hasKsu && hotspotPolicyPhase === 'error'" class="mn-control-notice mn-tone-warn" role="alert">
          <p>{{ hotspotPolicyError }}</p>
          <Button variant="outline" :loading="isRunning('hotspot-policy-refresh')" @click="retryHotspotPolicy">
            <RotateCcw :size="16" />重新读取
          </Button>
        </div>
      </Card>

      <details class="mn-disclosure">
        <summary><Wifi :size="18" />Wi-Fi 自动切换<span>{{ state.wifiPolicy.enabled ? '已开启' : '已关闭' }}</span></summary>
      <Card class="grid gap-5">
        <CardHeading title="Wi-Fi 策略">
          <Badge :tone="state.wifiPolicy.connected ? 'success' : 'neutral'">
            {{ state.wifiPolicy.connected ? state.wifiPolicy.ssid || "Wi-Fi 已连接" : "未连接 Wi-Fi" }}
          </Badge>
          <Badge :tone="state.wifiPolicy.enabled ? 'success' : 'warning'">
            {{ state.wifiPolicy.enabled ? "已启用" : "已停用" }}
          </Badge>
          <Button
            :loading="isRunning('wifi-toggle')"
            :disabled="runtimeBusy || !state.hasKsu"
            @click="toggleWifiPolicy"
          >
            <Power :size="17" />{{ state.wifiPolicy.enabled ? "停用" : "启用" }}
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
            <span class="font-semibold">{{ mode === "blacklist" ? "黑名单" : "白名单" }}</span>
            <span class="mt-1 block text-xs">
              {{ mode === "blacklist" ? "名单命中 → Direct" : "名单命中 → Rule" }}
            </span>
          </button>
        </div>

        <div class="grid gap-3 md:grid-cols-3">
          <StatTile label="当前 BSSID" :value="state.wifiPolicy.bssid || '—'" />
          <StatTile label="匹配结果" :value="state.wifiPolicy.matched ? '已命中名单' : '未命中'" />
          <StatTile label="代理模式" :value="`${state.wifiPolicy.currentMode} → ${state.wifiPolicy.desiredMode}`" />
        </div>

        <div class="grid gap-5 lg:grid-cols-2">
          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiSsidInput"
                aria-label="Wi-Fi SSID"
                placeholder="Wi-Fi 名称（SSID）"
                @keyup.enter="addWifiEntry('ssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-ssid')"
                @click="addWifiEntry('ssid')"
              ><Plus :size="17" />SSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span v-if="!state.wifiPolicy.ssids.length" class="mn-empty text-xs">还没有 SSID 条目</span>
              <RemovableTag
                v-for="ssid in state.wifiPolicy.ssids"
                :key="ssid"
                variant="soft"
                remove-variant="ghost"
                :remove-label="`移除 SSID ${ssid}`"
                @remove="removeWifiEntry('ssid', ssid)"
              >{{ ssid }}</RemovableTag>
            </div>
          </div>

          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiBssidInput"
                aria-label="Wi-Fi BSSID"
                placeholder="BSSID 地址"
                @keyup.enter="addWifiEntry('bssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-bssid')"
                @click="addWifiEntry('bssid')"
              ><Plus :size="17" />BSSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span v-if="!state.wifiPolicy.bssids.length" class="mn-empty text-xs">还没有 BSSID 条目</span>
              <RemovableTag
                v-for="bssid in state.wifiPolicy.bssids"
                :key="bssid"
                class="font-mono"
                variant="soft"
                remove-variant="ghost"
                :remove-label="`移除 BSSID ${bssid}`"
                @remove="removeWifiEntry('bssid', bssid)"
              >{{ bssid }}</RemovableTag>
            </div>
          </div>
        </div>
      </Card>
      </details>

      <details class="mn-disclosure">
        <summary>服务管理</summary>
        <div class="mn-disclosure__body">
          <div class="grid grid-cols-2 gap-3">
            <Button variant="secondary" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('apply-config')" @click="requestDangerAction(applyConfigAction(), $event.currentTarget)">
              <Save :size="17" />应用配置
            </Button>
            <Button variant="secondary" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('repair')" @click="requestDangerAction(repairAction(), $event.currentTarget)">
              <Zap :size="17" />自修复
            </Button>
            <Button variant="outline" :disabled="!state.hasKsu" :loading="isRunning('api-groups')" @click="withAction('api-groups', () => runCli('api groups', '检查 sing-box API'))">
              <ShieldCheck :size="17" />检查 API
            </Button>
            <Button variant="outline" @click="copyControlSnapshot"><Copy :size="17" />{{ snapshotCopied ? '已复制' : '复制快照' }}</Button>
            <Button variant="outline" @click="emit('goto-tab', 'about')">流量路径</Button>
            <Button variant="outline" :disabled="runtimeBusy || !state.hasKsu" :loading="isRunning('stop-all')" @click="requestDangerAction(stopAllServicesAction(), $event.currentTarget)">
              <Unplug :size="17" />停止全部
            </Button>
          </div>
        </div>
      </details>
    </div>

    <Teleport to="body">
      <Transition name="sheet">
        <div v-if="pendingDangerAction" class="mn-sheet-layer">
          <button class="mn-overlay" type="button" aria-label="取消控制操作" @click="cancelDangerAction" />
          <div ref="dangerConfirmCard" class="mn-utility-sheet mn-control-confirm" role="alertdialog" aria-modal="true" aria-label="确认控制操作" tabindex="-1" @keydown="handleDangerKeydown">
            <ConfirmPanel
              title="确认操作"
              :detail="pendingDangerMessage"
              :command="pendingDangerAction.args"
              :loading="isRunning(pendingDangerAction.key)"
              confirm-label="继续执行"
              confirm-variant="destructive"
              :auto-focus="false"
            >
              <template #actions>
                <Button data-danger-cancel variant="outline" @click="cancelDangerAction">取消</Button>
                <Button variant="destructive" :disabled="runtimeBusy" :loading="isRunning(pendingDangerAction.key)" @click="confirmDangerAction">继续执行</Button>
              </template>
            </ConfirmPanel>
          </div>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.mn-control {
  max-width: 720px;
  margin-inline: auto;
}

.mn-control-hero {
  padding: 12px 0 32px;
}

.mn-control-status {
  margin-bottom: 36px;
}

.mn-control-caption {
  color: var(--mn-ink-muted);
  font-size: 12px;
  letter-spacing: 0.04em;
}

.mn-control-status h2 {
  margin: 18px 0 14px;
  color: var(--mn-ink);
  font-size: clamp(40px, 11vw, 56px);
  font-weight: 450;
  line-height: 1.15;
  letter-spacing: -0.05em;
}

.mn-control-subtitle {
  display: flex;
  min-height: 24px;
  align-items: center;
  gap: 8px;
  color: var(--mn-ink-muted);
  font-size: 14px;
}

.mn-control-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
}

.mn-control-power {
  width: 100%;
  min-height: 56px;
  font-size: 15px;
}

.mn-control-shortcuts {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
  margin-top: 12px;
}

.mn-control-shortcuts > :first-child {
  position: relative;
}

.mn-control-shortcuts > :first-child::after {
  position: absolute;
  right: -7px;
  width: 1px;
  height: 16px;
  background: var(--mn-border);
  content: "";
}

.mn-control-notice {
  margin-top: 20px;
  border-radius: var(--mn-radius-md);
  padding: 12px 16px;
  font-size: 14px;
}

.mn-control-notice summary {
  display: flex;
  min-height: 48px;
  cursor: pointer;
  align-items: center;
  gap: 12px;
}

.mn-control-notice p,
.mn-control-notice button {
  margin-top: 12px;
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
