<script setup lang="ts">
import { Copy, ExternalLink, Power, Radar, RotateCcw, Save, ShieldCheck, Unplug, Zap } from "lucide-vue-next";
import { computed, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { applyConfigAction, applyTransparentModeAction, type ControlDangerAction, repairAction, restartSingBoxAction, singBoxToggleAction, stopAllServicesAction, transparentModeAction } from "@/components/pages/controlDangerActions";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import type { TransparentMode } from "@/types";
import { buildControlRuntimeInsight, controlInsightTone, controlRuntimeBusy } from "./controlRuntimeInsight";

const { state, runCli, startBackgroundCli, refreshAll, refreshStatus, openSingBoxUi } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingDangerAction = ref<ControlDangerAction | null>(null);
const snapshotCopied = ref(false);

const pendingDangerMessage = computed(() => pendingDangerAction.value?.message ?? "");
const runtimeInsight = computed(() => buildControlRuntimeInsight({
  hasKsu: state.hasKsu,
  phase: state.phase,
  queueDepth: state.queueDepth,
  runtime: state.runtime
}));
const runtimeBusy = computed(() => controlRuntimeBusy(state.phase, state.queueDepth));

const orchestratorModes: Array<{ mode: TransparentMode; title: string; description: string }> = [
  { mode: "proxy", title: "Proxy", description: "不创建 TUN，可与系统 VPN 共存" },
  { mode: "external-tun", title: "External TUN", description: "外部 VPN 捕获，MagicNet 只路由" },
  { mode: "hybrid", title: "Hybrid", description: "TUN 输入后链路到多后端" },
  { mode: "tun", title: "TUN", description: "兼容完整透明代理路径" }
];

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

async function runAction(key: string, args: string, label: string, background = false): Promise<void> {
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

function requestDangerAction(action: ControlDangerAction): void {
  pendingDangerAction.value = action;
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
    `last_command_kind=${classifyLastCommand(state.lastCommand)}`
  ].join("\n");
  snapshotCopied.value = await copyText(sanitizeControlSnapshot(report));
  state.output = snapshotCopied.value ? "控制状态快照已复制。" : "剪贴板不可用，控制状态快照未复制。";
}

function sanitizeControlSnapshot(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, "[filtered-url]")
    .replace(/\b(token|secret|password|passwd|authorization|bearer|api[_-]?key|key)\b\s*[:=]\s*\S+/gi, "$1=[filtered]");
}

function classifyLastCommand(command: string): string {
  if (!command) return "none";
  if (/\bbackup\b/.test(command)) return "backup";
  if (/\bsub(?:scription)?\b|sub set-file|subscription/i.test(command)) return "subscription";
  if (/\btransparent\b/.test(command)) return "transparent";
  if (/\bservice\b/.test(command)) return "service";
  if (/\bconfig\b/.test(command)) return "config";
  if (/\bmcp\b/.test(command)) return "mcp";
  if (/\bwebui\b/.test(command)) return "webui";
  return "other";
}
</script>

<template>
  <div class="grid gap-4">
    <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
      <div>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Control Center</span>
        <h2 class="mt-1 text-2xl font-semibold">模块控制</h2>
        <p class="mt-1 text-sm leading-6 text-zinc-400">只放模块生命周期和入口。节点、测速、代理模式交给 sing-box WebUI。</p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" @click="copyControlSnapshot"><Copy :size="17" />{{ snapshotCopied ? '已复制快照' : '复制快照' }}</Button>
        <Badge :tone="state.runtime.singBoxState === 'stopped' ? 'warning' : 'success'">{{ state.runtime.singBoxState }}</Badge>
      </div>
    </div>

    <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
      <Card class="grid gap-3 border" :class="controlInsightTone(runtimeInsight.status)">
        <span class="text-[11px] font-bold uppercase tracking-wide opacity-70">Runtime Insight</span>
        <div>
          <h3 class="break-words text-lg font-semibold">{{ runtimeInsight.title }}</h3>
          <p class="mt-1 break-words text-sm leading-6 opacity-80">{{ runtimeInsight.detail }}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Badge v-for="item in runtimeInsight.actions" :key="item" tone="neutral">{{ item }}</Badge>
        </div>
      </Card>

      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">sing-box</span>
            <h3 class="mt-1 break-words text-xl font-semibold">{{ state.runtime.singBoxState === "sing-box" ? "running" : state.runtime.singBoxState }}</h3>
          </div>
        </div>
        <p class="text-sm leading-6 text-zinc-400">MagicNet now runs only sing-box.</p>
        <Button :disabled="runtimeBusy" :loading="isRunning('toggle-sing-box')" class="w-full" @click="toggleSingBox">
          <Power :size="18" />
          {{ state.runtime.singBoxState === "sing-box" ? "停止 sing-box" : "启动 sing-box" }}
        </Button>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Quick Actions</span>
        <div class="mt-3 grid gap-2">
          <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning('restart-sing-box')" @click="requestDangerAction(restartSingBoxAction())">
            <RotateCcw :size="17" />重启 sing-box
          </Button>
          <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning('apply-config')" @click="requestDangerAction(applyConfigAction())">
            <Save :size="17" />应用配置
          </Button>
          <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning('repair')" @click="requestDangerAction(repairAction())">
            <Zap :size="17" />一键自修复
          </Button>
          <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning('stop-all')" @click="requestDangerAction(stopAllServicesAction())">
            <Unplug :size="17" />停止全部
          </Button>
        </div>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">sing-box WebUI</span>
        <div class="mt-3 grid gap-2">
          <Button variant="outline" :loading="isRunning('open-zashboard')" @click="withAction('open-zashboard', () => openSingBoxUi('zashboard'))"><ExternalLink :size="17" />zashboard</Button>
          <Button variant="outline" :loading="isRunning('api-groups')" @click="withAction('api-groups', () => runCli('api groups', '检查 sing-box API'))"><ShieldCheck :size="17" />检查 API</Button>
        </div>
      </Card>
    </div>

    <div class="grid gap-3 lg:grid-cols-2">
      <Card class="grid gap-3">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Orchestrator Mode</span>
            <h3 class="mt-1 text-lg font-semibold">多 VPN 共存</h3>
          </div>
          <div class="flex flex-wrap gap-2">
            <Badge tone="neutral">{{ state.runtime.transparentMode }}</Badge>
            <Badge v-if="!state.hasKsu" tone="warning">真机 WebUI 才能切换</Badge>
          </div>
        </div>
        <div class="grid gap-2 md:grid-cols-2">
          <button
            v-for="item in orchestratorModes"
            :key="item.mode"
            :class="[
              'min-h-16 rounded-md border px-3 py-2 text-left text-sm transition-colors disabled:cursor-progress disabled:opacity-60',
              state.runtime.transparentMode === item.mode
                ? 'border-lime-300 bg-lime-300 text-zinc-950'
                : 'border-zinc-800 bg-zinc-800 text-zinc-50 hover:border-zinc-700 hover:bg-zinc-700/80'
            ]"
            :aria-pressed="state.runtime.transparentMode === item.mode"
            :disabled="!canSwitchModes() || state.runtime.transparentMode === item.mode"
            :title="!state.hasKsu ? '当前没有 KernelSU/root 执行通道，无法在本地预览中切换模式' : state.runtime.transparentMode === item.mode ? '当前已处于该模式，可使用重新应用模式' : `切换到 ${item.mode}`"
            @click="setTransparentMode(item.mode)"
          >
            <span class="block font-semibold">{{ isRunning(modeActionKey(item.mode)) ? '切换中...' : state.runtime.transparentMode === item.mode ? `${item.title}（当前）` : item.title }}</span>
            <span :class="['mt-1 block text-xs leading-5', state.runtime.transparentMode === item.mode ? 'text-zinc-800' : 'text-zinc-400']">{{ item.description }}</span>
          </button>
        </div>
        <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning('transparent-apply')" @click="requestDangerAction(applyTransparentModeAction())">
          <Radar :size="17" />重新应用模式
        </Button>
      </Card>
    </div>

    <Card v-if="pendingDangerAction" class="grid gap-3 border border-amber-500/40 bg-amber-500/10">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <span class="text-[11px] font-bold uppercase tracking-wide text-amber-300">Confirm action</span>
          <p class="mt-1 text-sm leading-6 text-amber-100">{{ pendingDangerMessage }}</p>
          <code class="mt-2 block break-all rounded-md bg-zinc-950/60 px-3 py-2 text-xs text-zinc-100">{{ pendingDangerAction.args }}</code>
        </div>
        <div class="flex shrink-0 gap-2">
          <Button variant="secondary" :disabled="runtimeBusy" :loading="isRunning(pendingDangerAction.key)" @click="confirmDangerAction">确认</Button>
          <Button variant="outline" @click="cancelDangerAction">取消</Button>
        </div>
      </div>
    </Card>
  </div>
</template>
