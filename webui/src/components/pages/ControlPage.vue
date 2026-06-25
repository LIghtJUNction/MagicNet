<script setup lang="ts">
import { ExternalLink, Power, Radar, RotateCcw, Save, ShieldCheck, Unplug, Zap } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import type { TransparentMode } from "@/types";

const { state, runCli, startBackgroundCli, refreshAll, refreshStatus, openSingBoxUi } = useMagicNet();
const { isRunning, withAction } = useActionLock();

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
  return state.hasKsu && !isModeSwitching();
}

async function toggleSingBox(): Promise<void> {
  const running = state.runtime.singBoxState === "sing-box";
  await withAction("toggle-sing-box", async () => {
    await startBackgroundCli(running ? "service stop" : "service restart sing-box", running ? "停止 sing-box" : "启动 sing-box");
    window.setTimeout(() => void refreshStatus(), 1200);
  });
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

async function setTransparentMode(mode: TransparentMode): Promise<void> {
  if (!canSwitchModes() || state.runtime.transparentMode === mode) return;
  const key = modeActionKey(mode);
  await withAction(key, async () => {
    await startBackgroundCli(`transparent set ${mode}`, `切换 ${mode} 模式`);
    window.setTimeout(() => void refreshStatus(), 1200);
  });
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
      <Badge :tone="state.runtime.singBoxState === 'stopped' ? 'warning' : 'success'">{{ state.runtime.singBoxState }}</Badge>
    </div>

    <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">sing-box</span>
            <h3 class="mt-1 break-words text-xl font-semibold">{{ state.runtime.singBoxState === "sing-box" ? "running" : state.runtime.singBoxState }}</h3>
          </div>
        </div>
        <p class="text-sm leading-6 text-zinc-400">MagicNet now runs only sing-box.</p>
        <Button :loading="isRunning('toggle-sing-box')" class="w-full" @click="toggleSingBox">
          <Power :size="18" />
          {{ state.runtime.singBoxState === "sing-box" ? "停止 sing-box" : "启动 sing-box" }}
        </Button>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Quick Actions</span>
        <div class="mt-3 grid gap-2">
          <Button variant="secondary" :loading="isRunning('restart-sing-box')" @click="runAction('restart-sing-box', 'service restart sing-box', '重启 sing-box', true)">
            <RotateCcw :size="17" />重启 sing-box
          </Button>
          <Button variant="secondary" :loading="isRunning('apply-config')" @click="runAction('apply-config', 'config apply', '应用全部配置')">
            <Save :size="17" />应用配置
          </Button>
          <Button variant="secondary" :loading="isRunning('repair')" @click="runAction('repair', 'repair', '一键自修复')">
            <Zap :size="17" />一键自修复
          </Button>
          <Button variant="secondary" :loading="isRunning('stop-all')" @click="runAction('stop-all', 'service stop', '停止全部服务', true)">
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
        <Button variant="secondary" :loading="isRunning('transparent-apply')" @click="runAction('transparent-apply', 'transparent apply', '应用编排模式')">
          <Radar :size="17" />重新应用模式
        </Button>
      </Card>
    </div>
  </div>
</template>
