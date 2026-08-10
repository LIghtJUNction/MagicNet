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
  Trash2,
  Unplug,
  Wifi,
  Zap,
} from "lucide-vue-next";
import { computed, nextTick, onMounted, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import {
  applyConfigAction,
  applyTransparentModeAction,
  type ControlDangerAction,
  repairAction,
  restartSingBoxAction,
  singBoxToggleAction,
  stopAllServicesAction,
} from "@/components/pages/controlDangerActions";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
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
const pendingDangerAction = ref<ControlDangerAction | null>(null);
const dangerConfirmCard = ref<HTMLElement | null>(null);
const snapshotCopied = ref(false);
const wifiSsidInput = ref("");
const wifiBssidInput = ref("");
const hotspotProxyEnabled = ref(false);
const hotspotPolicyLoaded = ref(false);

const pendingDangerMessage = computed(
  () => pendingDangerAction.value?.message ?? "",
);
const runtimeInsight = computed(() =>
  buildControlRuntimeInsight({
    hasKsu: state.hasKsu,
    phase: state.phase,
    queueDepth: state.queueDepth,
    runtime: state.runtime,
    output: state.output,
  }),
);
const runtimeBusy = computed(() =>
  controlRuntimeBusy(state.phase, state.queueDepth),
);
const missingNodeCache = computed(() =>
  /No cached sing-box nodes found|run cli sub update sing-box/i.test(
    state.output,
  ),
);

const wifiPolicyModes = ["blacklist", "whitelist"] as const;

async function toggleSingBox(): Promise<void> {
  const running = state.runtime.singBoxState === "sing-box";
  requestDangerAction(singBoxToggleAction(running));
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
      if (execFailed(output)) return;
      await refreshAll();
    }
  });
}

async function rebuildNodeCache(): Promise<void> {
  await withAction("rebuild-node-cache", async () => {
    const launch = await startBackgroundCli("sub update sing-box", "重建 sing-box 节点缓存");
    if (execFailed(launch)) return;
    const operationId = state.backgroundTask.id;
    const refreshWhenComplete = (): void => {
      if (state.backgroundTask.id !== operationId) return;
      if (state.backgroundTask.status === "done") {
        void refreshAll();
        return;
      }
      if (state.backgroundTask.status === "error" || state.backgroundTask.status === "timeout") return;
      window.setTimeout(refreshWhenComplete, 500);
    };
    window.setTimeout(refreshWhenComplete, 1600);
  });
}

function requestDangerAction(action: ControlDangerAction): void {
  pendingDangerAction.value = action;
  void nextTick(() => {
    dangerConfirmCard.value?.scrollIntoView({
      block: "nearest",
      behavior: "smooth",
    });
    dangerConfirmCard.value
      ?.querySelector<HTMLButtonElement>("button")
      ?.focus();
  });
}

function cancelDangerAction(): void {
  pendingDangerAction.value = null;
}

async function confirmDangerAction(): Promise<void> {
  const action = pendingDangerAction.value;
  if (!action) return;
  if (runtimeBusy.value) {
    state.output = "后台任务未结束，已拒绝执行新的控制操作。";
    return;
  }
  pendingDangerAction.value = null;
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
  const output = await runCli("hotspot status", "读取热点代理策略", true);
  if (execFailed(output)) {
    state.phase = "error";
    state.notice = "读取热点代理策略失败";
    state.output = `读取热点代理策略失败：\n${output}`;
    return false;
  }
  const matched = output.match(/^enabled=([01])$/m);
  if (!matched) {
    state.phase = "error";
    state.notice = "热点代理状态无效";
    state.output = "读取热点代理策略失败：设备返回了无法解析的状态。";
    return false;
  }
  hotspotProxyEnabled.value = matched[1] === "1";
  hotspotPolicyLoaded.value = true;
  return true;
}

async function toggleHotspotProxy(event: Event): Promise<void> {
  const previous = hotspotProxyEnabled.value;
  const enabled = (event.currentTarget as HTMLInputElement).checked;
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
  <div class="grid gap-4 md:gap-5">
    <PageHeader
      overline="Control Center"
      title="模块控制"
      description="管理模块生命周期和常用入口；节点、测速与代理组继续由 sing-box WebUI 负责。"
    >
      <template #actions>
        <Button variant="outline" @click="copyControlSnapshot"
          ><Copy :size="17" />{{
            snapshotCopied ? "已复制快照" : "复制快照"
          }}</Button
        >
        <Badge
          :tone="
            state.runtime.singBoxState === 'stopped' ? 'warning' : 'success'
          "
          >{{ state.runtime.singBoxState }}</Badge
        >
      </template>
    </PageHeader>

    <div class="grid grid-cols-1 gap-3 md:grid-cols-12 md:gap-4">
      <Card
        class="grid gap-4 !p-4 md:col-span-7 md:row-span-2 md:min-h-[22rem] md:!p-6"
        :class="controlInsightTone(runtimeInsight.status)"
      >
        <div class="flex items-start justify-between gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-[0.22em] opacity-60">运行状态</span>
          <span class="size-2.5 rounded-full bg-current opacity-70 " />
        </div>
        <div class="my-auto max-w-xl">
          <h3 class="break-words text-2xl font-semibold tracking-[-0.035em] md:text-3xl">
            {{ runtimeInsight.title }}
          </h3>
          <p class="mt-3 break-words text-sm leading-7 opacity-75 md:text-[15px]">
            {{ runtimeInsight.detail }}
          </p>
        </div>
        <div class="flex flex-wrap items-start gap-2">
          <Badge
            v-for="item in runtimeInsight.actions"
            :key="item"
            tone="neutral"
            >{{ item }}</Badge
          >
        </div>
        <div v-if="missingNodeCache" class="grid gap-2">
          <Button
            variant="secondary"
            :loading="isRunning('rebuild-node-cache')"
            @click="rebuildNodeCache"
            ><DownloadCloud :size="17" />更新订阅并重建节点</Button
          >
          <p class="text-xs leading-5 opacity-75">
            会执行 <code>sub update sing-box</code>，成功后再启动 sing-box。
          </p>
        </div>
      </Card>

      <Card class="grid gap-3 !p-4 md:col-span-5 md:!p-6">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
              >sing-box</span
            >
            <h3 class="mt-2 break-words text-2xl font-semibold tracking-[-0.035em]">
              {{
                state.runtime.singBoxState === "sing-box"
                  ? "运行中"
                  : state.runtime.singBoxState
              }}
            </h3>
          </div>
          <span :class="['mt-1 size-3 rounded-full ', state.runtime.singBoxState === 'sing-box' ? 'bg-[var(--mn-cactus)] text-[var(--mn-success)]' : 'bg-[var(--mn-clay)] text-[var(--mn-danger)]']" />
        </div>
        <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">
          MagicNet 当前只运行 sing-box 核心。
        </p>
        <Button
          :disabled="runtimeBusy"
          :loading="isRunning('toggle-sing-box')"
          class="w-full"
          @click="toggleSingBox"
        >
          <Power :size="18" />
          {{
            state.runtime.singBoxState === "sing-box"
              ? "停止 sing-box"
              : "启动 sing-box"
          }}
        </Button>
      </Card>

      <Card class="!p-4 md:col-span-5 md:!p-6">
        <span
          class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
          >快捷操作</span
        >
        <div class="mt-3 grid grid-cols-2 gap-2 md:mt-4 md:grid-cols-1 xl:grid-cols-2">
          <Button
            variant="secondary"
            :disabled="runtimeBusy"
            :loading="isRunning('restart-sing-box')"
            @click="requestDangerAction(restartSingBoxAction())"
          >
            <RotateCcw :size="17" />重启 sing-box
          </Button>
          <Button
            variant="secondary"
            :disabled="runtimeBusy"
            :loading="isRunning('apply-config')"
            @click="requestDangerAction(applyConfigAction())"
          >
            <Save :size="17" />应用配置
          </Button>
          <Button
            variant="secondary"
            :disabled="runtimeBusy"
            :loading="isRunning('repair')"
            @click="requestDangerAction(repairAction())"
          >
            <Zap :size="17" />一键自修复
          </Button>
          <Button
            variant="secondary"
            :disabled="runtimeBusy"
            :loading="isRunning('stop-all')"
            @click="requestDangerAction(stopAllServicesAction())"
          >
            <Unplug :size="17" />停止全部
          </Button>
        </div>
      </Card>

      <Card class="!p-4 md:col-span-4 md:!p-6">
        <span
          class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
          >sing-box WebUI</span
        >
        <h3 class="mt-3 text-xl font-semibold tracking-[-0.03em]">核心控制入口</h3>
        <p class="mt-2 text-sm leading-6 text-[var(--mn-ink-muted)]">进入 zashboard 管理节点与代理组，或直接检查 API 连通性。</p>
        <div class="mt-5 grid gap-2">
          <Button
            variant="outline"
            :loading="isRunning('open-zashboard')"
            @click="
              withAction('open-zashboard', () => openSingBoxUi('zashboard'))
            "
            ><ExternalLink :size="17" />zashboard</Button
          >
          <Button
            variant="outline"
            :loading="isRunning('api-groups')"
            @click="
              withAction('api-groups', () =>
                runCli('api groups', '检查 sing-box API'),
              )
            "
            ><ShieldCheck :size="17" />检查 API</Button
          >
        </div>
      </Card>

      <Card class="grid gap-4 !p-4 md:col-span-8 md:gap-5 md:!p-6">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
              >透明代理模式</span
            >
            <h3 class="mt-2 text-2xl font-semibold tracking-[-0.035em]">TUN</h3>
            <p class="mt-2 text-sm leading-6 text-[var(--mn-ink-muted)]">
              MagicNet 统一使用 sing-box TUN 透明代理路径。
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <Badge tone="neutral">TUN</Badge>
          </div>
        </div>
        <Button
          variant="secondary"
          :disabled="runtimeBusy"
          :loading="isRunning('transparent-apply')"
          @click="requestDangerAction(applyTransparentModeAction())"
        >
          <Radar :size="17" />重新应用模式
        </Button>
      </Card>

      <Card
        class="grid gap-4 !p-4 md:col-span-12 md:!p-6"
        :class="
          hotspotProxyEnabled
            ? 'border-[color-mix(in_srgb,var(--mn-cactus)_55%,transparent)] bg-[color-mix(in_srgb,var(--mn-cactus)_10%,var(--mn-ivory))]'
            : ''
        "
      >
        <label
          class="flex cursor-pointer flex-col gap-4 rounded-[1.35rem] p-1 sm:flex-row sm:items-center sm:justify-between"
        >
          <span class="flex min-w-0 items-start gap-4">
            <input
              type="checkbox"
              class="mt-1 size-7 shrink-0 accent-[var(--mn-cactus)]"
              :checked="hotspotProxyEnabled"
              :disabled="runtimeBusy || isRunning('hotspot-proxy')"
              aria-describedby="hotspot-proxy-description"
              @change="toggleHotspotProxy"
            />
            <span class="min-w-0">
              <span class="flex items-center gap-2 text-xl font-semibold tracking-[-0.03em]">
                <Share2 :size="21" />允许热点使用代理
              </span>
              <span
                id="hotspot-proxy-description"
                class="mt-2 block max-w-3xl text-sm leading-6 text-[var(--mn-ink-muted)]"
              >
                勾选后，连接本机热点的设备统一走 <code>proxy</code> 代理组；不勾选时统一走
                <code>direct</code>。Proxy 会关闭 Android 热点硬件加速以确保流量进入 TUN；关闭后恢复原设置。
              </span>
            </span>
          </span>
          <span class="flex shrink-0 items-center gap-2 pl-11 sm:pl-0">
            <Badge v-if="!hotspotPolicyLoaded" tone="neutral">读取中</Badge>
            <Badge v-else :tone="hotspotProxyEnabled ? 'success' : 'neutral'">
              {{ hotspotProxyEnabled ? "Proxy" : "Direct" }}
            </Badge>
          </span>
        </label>
      </Card>

      <Card class="grid gap-4 !p-4 md:col-span-12 md:gap-5 md:!p-6">
        <div class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
          <div>
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-faint)]"
              >Wi-Fi 模式策略</span
            >
            <h3 class="mt-2 flex items-center gap-2 text-2xl font-semibold tracking-[-0.035em]">
              <Wifi :size="22" />按 Wi-Fi 自动切换
            </h3>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-[var(--mn-ink-muted)]">
              黑名单命中 SSID 或 BSSID 时切换为 Direct，离开 Wi-Fi 后自动恢复 Rule。白名单模式会让名单内 Wi-Fi 使用 Rule，其他 Wi-Fi 使用 Direct。
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <Badge :tone="state.wifiPolicy.connected ? 'success' : 'neutral'">
              {{ state.wifiPolicy.connected ? state.wifiPolicy.ssid || "Wi-Fi 已连接" : "未连接 Wi-Fi" }}
            </Badge>
            <Badge :tone="state.wifiPolicy.enabled ? 'success' : 'warning'">
              {{ state.wifiPolicy.enabled ? "已启用" : "已停用" }}
            </Badge>
            <Button
              :loading="isRunning('wifi-toggle')"
              :disabled="runtimeBusy"
              @click="toggleWifiPolicy"
            >
              <Power :size="17" />{{ state.wifiPolicy.enabled ? "停用" : "启用" }}
            </Button>
          </div>
        </div>

        <div class="grid gap-3 md:grid-cols-2">
          <button
            v-for="mode in wifiPolicyModes"
            :key="mode"
            type="button"
            :aria-pressed="state.wifiPolicy.policyMode === mode"
            :disabled="runtimeBusy || state.wifiPolicy.policyMode === mode"
            :class="[
              'rounded-[1.25rem] px-4 py-3 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/60 disabled:cursor-default',
              state.wifiPolicy.policyMode === mode
                ? 'bg-[var(--mn-cactus)] text-[var(--mn-on-accent)]'
                : 'bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] text-[var(--mn-ink-soft)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_8%,transparent)]',
            ]"
            @click="setWifiPolicyMode(mode)"
          >
            <span class="font-semibold">{{ mode === "blacklist" ? "黑名单" : "白名单" }}</span>
            <span class="mt-1 block text-xs opacity-70">
              {{ mode === "blacklist" ? "名单命中 → Direct" : "名单命中 → Rule" }}
            </span>
          </button>
        </div>

        <div class="grid gap-3 rounded-[1.4rem] bg-black/20 p-4 md:grid-cols-3">
          <div>
            <span class="text-xs text-[var(--mn-ink-faint)]">当前 BSSID</span>
            <p class="mt-1 break-all text-sm text-[var(--mn-ink-soft)]">{{ state.wifiPolicy.bssid || "—" }}</p>
          </div>
          <div>
            <span class="text-xs text-[var(--mn-ink-faint)]">匹配结果</span>
            <p class="mt-1 text-sm text-[var(--mn-ink-soft)]">{{ state.wifiPolicy.matched ? "已命中名单" : "未命中" }}</p>
          </div>
          <div>
            <span class="text-xs text-[var(--mn-ink-faint)]">代理模式</span>
            <p class="mt-1 text-sm text-[var(--mn-ink-soft)]">
              {{ state.wifiPolicy.currentMode }} → {{ state.wifiPolicy.desiredMode }}
            </p>
          </div>
        </div>

        <div class="grid gap-5 lg:grid-cols-2">
          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiSsidInput"
                placeholder="输入完整 SSID，例如 Home WiFi"
                @keyup.enter="addWifiEntry('ssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-ssid')"
                @click="addWifiEntry('ssid')"
              ><Plus :size="17" />SSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span
                v-if="!state.wifiPolicy.ssids.length"
                class="text-xs text-[var(--mn-ink-faint)]"
              >还没有 SSID 条目</span>
              <span
                v-for="ssid in state.wifiPolicy.ssids"
                :key="ssid"
                class="inline-flex items-center gap-2 rounded-full bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] px-3 py-1.5 text-xs text-[var(--mn-ink-soft)]"
              >
                {{ ssid }}
                <button
                  type="button"
                  class="text-[var(--mn-ink-faint)] hover:text-[var(--mn-danger)]"
                  :aria-label="`移除 SSID ${ssid}`"
                  @click="removeWifiEntry('ssid', ssid)"
                ><Trash2 :size="14" /></button>
              </span>
            </div>
          </div>

          <div class="grid gap-3">
            <div class="flex gap-2">
              <Input
                v-model="wifiBssidInput"
                placeholder="输入 BSSID，例如 aa:bb:cc:dd:ee:ff"
                @keyup.enter="addWifiEntry('bssid')"
              />
              <Button
                variant="secondary"
                :loading="isRunning('wifi-add-bssid')"
                @click="addWifiEntry('bssid')"
              ><Plus :size="17" />BSSID</Button>
            </div>
            <div class="flex flex-wrap gap-2">
              <span
                v-if="!state.wifiPolicy.bssids.length"
                class="text-xs text-[var(--mn-ink-faint)]"
              >还没有 BSSID 条目</span>
              <span
                v-for="bssid in state.wifiPolicy.bssids"
                :key="bssid"
                class="inline-flex items-center gap-2 rounded-full bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] px-3 py-1.5 font-mono text-xs text-[var(--mn-ink-soft)]"
              >
                {{ bssid }}
                <button
                  type="button"
                  class="text-[var(--mn-ink-faint)] hover:text-[var(--mn-danger)]"
                  :aria-label="`移除 BSSID ${bssid}`"
                  @click="removeWifiEntry('bssid', bssid)"
                ><Trash2 :size="14" /></button>
              </span>
            </div>
          </div>
        </div>
      </Card>
    </div>

    <div v-if="pendingDangerAction" ref="dangerConfirmCard" tabindex="-1">
      <Card class="grid gap-3 !bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] text-[var(--mn-warning)] shadow-[inset_0_0_0_1px_rgba(251,191,36,0.25),inset_0_0_0_7px_rgba(251,191,36,0.025)]">
        <div
          class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"
        >
          <div class="min-w-0">
            <span
              class="text-[11px] font-bold uppercase tracking-wide text-[var(--mn-warning)]"
              >确认操作</span
            >
            <p class="mt-1 text-sm leading-6 text-[var(--mn-warning)]">
              {{ pendingDangerMessage }}
            </p>
            <code
              class="mt-3 block break-all rounded-[1.15rem] bg-[var(--mn-carrier-deep)]/30 px-4 py-3 text-xs text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_var(--mn-border)]"
              >{{ pendingDangerAction.args }}</code
            >
          </div>
          <div class="flex shrink-0 gap-2">
            <Button
              variant="secondary"
              :disabled="runtimeBusy"
              :loading="isRunning(pendingDangerAction.key)"
              @click="confirmDangerAction"
              >确认</Button
            >
            <Button variant="outline" @click="cancelDangerAction">取消</Button>
          </div>
        </div>
      </Card>
    </div>
  </div>
</template>
