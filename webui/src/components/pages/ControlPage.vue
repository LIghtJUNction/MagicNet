<script setup lang="ts">
import { ExternalLink, Power, Radar, RotateCcw, Save, ShieldCheck, Unplug, Zap } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, startBackgroundCli, refreshAll, refreshStatus, openSingBoxUi } = useMagicNet();
const { isRunning, withAction } = useActionLock();

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

async function setTransparentMode(mode: "tun" | "ebpf"): Promise<void> {
  await withAction(`transparent-${mode}`, async () => {
    if (mode === "ebpf") {
      await runCli("ebpf profile set tcp", "启用 eBPF TCP");
    }
    await runCli(`transparent set ${mode}`, mode === "ebpf" ? "切换 eBPF TCP 模式" : "切换 TUN 稳定模式");
    await refreshStatus();
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
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Transparent Mode</span>
            <h3 class="mt-1 text-lg font-semibold">{{ state.runtime.transparentMode === "ebpf" ? "eBPF TCP" : "TUN Stable" }}</h3>
          </div>
          <Badge tone="neutral">{{ state.runtime.transparentMode }}</Badge>
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <button class="min-h-16 rounded-md border border-zinc-800 px-3 py-2 text-left text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('transparent-tun')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.transparentMode === 'tun' }" @click="setTransparentMode('tun')">
            <span class="block font-semibold">TUN Stable</span>
            <span class="mt-1 block text-xs leading-5 text-zinc-500">完整透明代理</span>
          </button>
          <button class="min-h-16 rounded-md border border-zinc-800 px-3 py-2 text-left text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('transparent-ebpf')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.transparentMode === 'ebpf' }" @click="setTransparentMode('ebpf')">
            <span class="block font-semibold">eBPF TCP</span>
            <span class="mt-1 block text-xs leading-5 text-zinc-500">TCP 加速，UDP 由 TUN 兜底</span>
          </button>
        </div>
        <Button variant="secondary" :loading="isRunning('transparent-apply')" @click="runAction('transparent-apply', 'transparent apply', '应用透明代理模式')">
          <Radar :size="17" />重新应用模式
        </Button>
      </Card>
    </div>
  </div>
</template>
