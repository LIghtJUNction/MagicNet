<script setup lang="ts">
import {
  ArrowUpRight,
  Copy,
  DownloadCloud,
  ExternalLink,
  Megaphone,
  Plus,
  Power,
  Radar,
  RotateCcw,
  Save,
  ShieldCheck,
  Trash2,
  Unplug,
  Wifi,
  Zap,
} from "lucide-vue-next";
import { computed, nextTick, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import {
  applyConfigAction,
  applyTransparentModeAction,
  type ControlDangerAction,
  repairAction,
  restartSingBoxAction,
  singBoxToggleAction,
  stopAllServicesAction,
  transparentModeAction,
} from "@/components/pages/controlDangerActions";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { PROMOTION_URL } from "@/constants";
import { copyText } from "@/utils";
import type { TransparentMode } from "@/types";
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
  openExternal,
  shellQuote,
} = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingDangerAction = ref<ControlDangerAction | null>(null);
const dangerConfirmCard = ref<HTMLElement | null>(null);
const snapshotCopied = ref(false);
const wifiSsidInput = ref("");
const wifiBssidInput = ref("");

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

const orchestratorModes: Array<{
  mode: TransparentMode;
  title: string;
  description: string;
}> = [
  {
    mode: "proxy",
    title: "Proxy",
    description: "不创建 TUN，可与系统 VPN 共存",
  },
  {
    mode: "external-tun",
    title: "External TUN",
    description: "外部 VPN 捕获，MagicNet 只路由",
  },
  { mode: "hybrid", title: "Hybrid", description: "TUN 输入后链路到多后端" },
  { mode: "tun", title: "TUN", description: "兼容完整透明代理路径" },
];
const wifiPolicyModes = ["blacklist", "whitelist"] as const;

function modeActionKey(mode: TransparentMode): string {
  return `transparent-${mode}`;
}

function isModeSwitching(): boolean {
  return orchestratorModes.some((item) => isRunning(modeActionKey(item.mode)));
}

function canSwitchModes(): boolean {
  return state.hasKsu && !runtimeBusy.value && !isModeSwitching();
}

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
      await startBackgroundCli(args, label);
      window.setTimeout(() => void refreshStatus(), 1200);
    } else {
      await runCli(args, label);
      await refreshAll();
    }
  });
}

async function rebuildNodeCache(): Promise<void> {
  await withAction("rebuild-node-cache", async () => {
    await startBackgroundCli("sub update sing-box", "重建 sing-box 节点缓存");
    window.setTimeout(() => void refreshAll(), 1600);
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

async function setTransparentMode(mode: TransparentMode): Promise<void> {
  if (!canSwitchModes() || state.runtime.transparentMode === mode) return;
  requestDangerAction(transparentModeAction(mode));
}

async function runWifiAction(
  key: string,
  args: string,
  label: string,
): Promise<void> {
  await withAction(key, async () => {
    await runCli(args, label);
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
</script>

<template>
  <div class="grid gap-6">
    <div
      class="flex flex-col gap-5 md:flex-row md:items-start md:justify-between"
    >
      <div class="max-w-3xl">
        <span
          class="inline-flex rounded-full bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] px-3 py-1 text-[10px] font-semibold uppercase tracking-[0.2em] text-[var(--mn-ink-muted)] shadow-[inset_0_0_0_1px_var(--mn-border)]"
          >Control Center</span
        >
        <h2 class="mt-3 text-3xl font-semibold tracking-[-0.04em] text-[var(--mn-ink)] md:text-4xl">模块控制</h2>
        <p class="mt-2 text-sm leading-6 text-[var(--mn-ink-muted)] md:text-[15px]">
          只放模块生命周期和入口。节点、测速、代理模式交给 sing-box WebUI。
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
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
      </div>
    </div>

    <div class="grid grid-cols-1 gap-4 md:grid-cols-12">
      <Card
        class="grid gap-5 md:col-span-7 md:row-span-2 md:min-h-[25rem]"
        :class="controlInsightTone(runtimeInsight.status)"
      >
        <div class="flex items-start justify-between gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-[0.22em] opacity-60">Runtime Insight</span>
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

      <Card class="grid gap-4 md:col-span-5">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
              >sing-box</span
            >
            <h3 class="mt-2 break-words text-2xl font-semibold tracking-[-0.035em]">
              {{
                state.runtime.singBoxState === "sing-box"
                  ? "running"
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

      <Card class="md:col-span-5">
        <span
          class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
          >Quick Actions</span
        >
        <div class="mt-4 grid gap-2 sm:grid-cols-2 md:grid-cols-1 xl:grid-cols-2">
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

      <Card class="md:col-span-4">
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

      <Card class="grid gap-5 md:col-span-8">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-muted)]"
              >Orchestrator Mode</span
            >
            <h3 class="mt-2 text-2xl font-semibold tracking-[-0.035em]">多 VPN 共存</h3>
          </div>
          <div class="flex flex-wrap gap-2">
            <Badge tone="neutral">{{ state.runtime.transparentMode }}</Badge>
            <Badge v-if="!state.hasKsu" tone="warning"
              >真机 WebUI 才能切换</Badge
            >
          </div>
        </div>
        <div class="grid gap-2 md:grid-cols-2">
          <button
            v-for="item in orchestratorModes"
            :key="item.mode"
            :class="[
              'min-h-[5.25rem] rounded-[1.4rem] px-4 py-3 text-left text-sm shadow-[inset_0_0_0_1px_var(--mn-border)] transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,transparent)] active:scale-[0.98] disabled:cursor-progress disabled:opacity-45 disabled:active:scale-100',
              state.runtime.transparentMode === item.mode
                ? 'bg-[var(--mn-cactus)] text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_8%,transparent)]'
                : 'bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] text-[var(--mn-ink)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_8%,transparent)]',
            ]"
            :aria-pressed="state.runtime.transparentMode === item.mode"
            :disabled="
              !canSwitchModes() || state.runtime.transparentMode === item.mode
            "
            :title="
              !state.hasKsu
                ? '当前没有 KernelSU/root 执行通道，无法在本地预览中切换模式'
                : state.runtime.transparentMode === item.mode
                  ? '当前已处于该模式，可使用重新应用模式'
                  : `切换到 ${item.mode}`
            "
            @click="setTransparentMode(item.mode)"
          >
            <span class="block font-semibold">{{
              isRunning(modeActionKey(item.mode))
                ? "切换中..."
                : state.runtime.transparentMode === item.mode
                  ? `${item.title}（当前）`
                  : item.title
            }}</span>
            <span
              :class="[
                'mt-1 block text-xs leading-5',
                state.runtime.transparentMode === item.mode
                  ? 'text-[var(--mn-ink-muted)]'
                  : 'text-[var(--mn-ink-muted)]',
              ]"
              >{{ item.description }}</span
            >
          </button>
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

      <Card class="grid gap-5 md:col-span-12">
        <div class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
          <div>
            <span
              class="text-[10px] font-semibold uppercase tracking-[0.22em] text-zinc-500"
              >Wi-Fi Mode Policy</span
            >
            <h3 class="mt-2 flex items-center gap-2 text-2xl font-semibold tracking-[-0.035em]">
              <Wifi :size="22" />按 Wi-Fi 自动切换
            </h3>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
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
                ? 'bg-emerald-300 text-emerald-950'
                : 'bg-white/[0.05] text-zinc-200 hover:bg-white/[0.08]',
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
            <span class="text-xs text-zinc-500">当前 BSSID</span>
            <p class="mt-1 break-all text-sm text-zinc-200">{{ state.wifiPolicy.bssid || "—" }}</p>
          </div>
          <div>
            <span class="text-xs text-zinc-500">匹配结果</span>
            <p class="mt-1 text-sm text-zinc-200">{{ state.wifiPolicy.matched ? "已命中名单" : "未命中" }}</p>
          </div>
          <div>
            <span class="text-xs text-zinc-500">代理模式</span>
            <p class="mt-1 text-sm text-zinc-200">
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
                class="text-xs text-zinc-500"
              >还没有 SSID 条目</span>
              <span
                v-for="ssid in state.wifiPolicy.ssids"
                :key="ssid"
                class="inline-flex items-center gap-2 rounded-full bg-white/[0.06] px-3 py-1.5 text-xs text-zinc-200"
              >
                {{ ssid }}
                <button
                  type="button"
                  class="text-zinc-500 hover:text-rose-300"
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
                class="text-xs text-zinc-500"
              >还没有 BSSID 条目</span>
              <span
                v-for="bssid in state.wifiPolicy.bssids"
                :key="bssid"
                class="inline-flex items-center gap-2 rounded-full bg-white/[0.06] px-3 py-1.5 font-mono text-xs text-zinc-200"
              >
                {{ bssid }}
                <button
                  type="button"
                  class="text-zinc-500 hover:text-rose-300"
                  :aria-label="`移除 BSSID ${bssid}`"
                  @click="removeWifiEntry('bssid', bssid)"
                ><Trash2 :size="14" /></button>
              </span>
            </div>
          </div>
        </div>
      </Card>

      <Card
        class="group relative overflow-hidden !bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] !p-0 md:col-span-12"
      >
        <button
          class="relative grid w-full gap-5 overflow-hidden p-5 text-left transition-[transform,background-color] duration-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[color-mix(in_srgb,var(--mn-heather)_70%,transparent)] active:scale-[0.995] sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center md:p-6"
          type="button"
          aria-label="访问推广：AI 自动推广系统"
          @click="openExternal(PROMOTION_URL, 'AI 自动推广系统')"
        >
          <span
            class="relative grid size-14 shrink-0 place-items-center rounded-[1.25rem] bg-[var(--mn-cactus)] text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_10%,transparent)]"
          >
            <Megaphone :size="22" />
          </span>

          <span class="relative min-w-0">
            <span class="flex flex-wrap items-center gap-2">
              <span
                class="rounded-full bg-[color-mix(in_srgb,var(--mn-ink)_7%,transparent)] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.2em] text-[var(--mn-ink-muted)] shadow-[inset_0_0_0_1px_var(--mn-border)]"
                >推广</span
              >
              <span class="text-[10px] font-medium text-[var(--mn-success)]"
                >MagicNet 推荐</span
              >
            </span>
            <strong
              class="mt-3 block text-xl font-semibold tracking-[-0.035em] text-[var(--mn-ink)] md:text-2xl"
              >AI 自动推广系统</strong
            >
            <span class="mt-2 block text-sm leading-6 text-[var(--mn-ink-muted)]"
              >探索 AI 驱动的自动推广工具与工作流。</span
            >
          </span>

          <span
            class="relative inline-flex min-h-[49px] items-center justify-center gap-2 justify-self-start rounded-full bg-[var(--mn-cactus)] px-5 text-sm font-semibold text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_10%,transparent)] transition-[transform,color,background-color] duration-200 group-hover:bg-[var(--mn-cactus-deep)] group-hover:text-[var(--mn-ink)] sm:justify-self-end"
          >
            了解详情
            <ArrowUpRight
              class="transition-transform duration-300 group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
              :size="17"
            />
          </span>
        </button>
      </Card>
    </div>

    <div v-if="pendingDangerAction" ref="dangerConfirmCard" tabindex="-1">
      <Card class="grid gap-3 !bg-[color-mix(in_srgb,var(--mn-oat)_55%,white)] text-[var(--mn-warning)] shadow-[inset_0_0_0_1px_rgba(251,191,36,0.25),inset_0_0_0_7px_rgba(251,191,36,0.025)]">
        <div
          class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"
        >
          <div class="min-w-0">
            <span
              class="text-[11px] font-bold uppercase tracking-wide text-[var(--mn-warning)]"
              >Confirm action</span
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
