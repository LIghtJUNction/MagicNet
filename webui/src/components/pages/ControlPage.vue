<script setup lang="ts">
import { ExternalLink, Power, RotateCcw, Save, ShieldCheck, Unplug, Zap } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, refreshAll, openCoreUi } = useMagicNet();
const { isRunning, withAction } = useActionLock();

async function selectCore(core: "sing-box" | "mihomo"): Promise<void> {
  state.selectedCore = core;
  await withAction(`select-${core}`, async () => {
    await runCli(`core select ${core}`, `选择当前内核 ${core}`);
    await refreshAll();
  });
}

async function toggleCurrentCore(): Promise<void> {
  const running = state.runtime.core === state.selectedCore;
  await withAction("toggle-core", async () => {
    await runCli(running ? "service stop" : `service restart ${state.selectedCore}`, running ? `停止 ${state.selectedCore}` : `启动 ${state.selectedCore}`);
    await refreshAll();
  });
}

async function runAction(key: string, args: string, label: string): Promise<void> {
  await withAction(key, async () => {
    await runCli(args, label);
    await refreshAll();
  });
}
</script>

<template>
  <div class="grid gap-4">
    <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
      <div>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Control Center</span>
        <h2 class="mt-1 text-2xl font-semibold">模块控制</h2>
        <p class="mt-1 text-sm leading-6 text-zinc-400">只放模块生命周期和入口。节点、测速、代理模式交给内核 WebUI。</p>
      </div>
      <Badge :tone="state.runtime.core === 'stopped' ? 'warning' : 'success'">{{ state.runtime.core }}</Badge>
    </div>

    <div class="grid gap-3 md:grid-cols-3">
      <Card class="grid gap-3">
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Current Kernel</span>
        <h3 class="text-xl font-semibold">{{ state.selectedCore }}</h3>
        <p class="text-sm leading-6 text-zinc-400">选择一个当前内核，然后用一个开关启动或停止它。</p>
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('select-sing-box')" :class="{ 'bg-zinc-800 text-zinc-50': state.selectedCore === 'sing-box' }" @click="selectCore('sing-box')">sing-box</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('select-mihomo')" :class="{ 'bg-zinc-800 text-zinc-50': state.selectedCore === 'mihomo' }" @click="selectCore('mihomo')">mihomo</button>
        </div>
        <Button :loading="isRunning('toggle-core')" class="w-full" @click="toggleCurrentCore">
          <Power :size="18" />
          {{ state.runtime.core === state.selectedCore ? "停止当前内核" : "启动当前内核" }}
        </Button>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Quick Actions</span>
        <div class="mt-3 grid gap-2">
          <Button variant="secondary" :loading="isRunning('restart-current')" @click="runAction('restart-current', 'service restart current', '重启当前内核')">
            <RotateCcw :size="17" />重启当前内核
          </Button>
          <Button variant="secondary" :loading="isRunning('apply-config')" @click="runAction('apply-config', 'config apply', '应用全部配置')">
            <Save :size="17" />应用配置
          </Button>
          <Button variant="secondary" :loading="isRunning('repair')" @click="runAction('repair', 'repair', '一键自修复')">
            <Zap :size="17" />一键自修复
          </Button>
          <Button variant="secondary" :loading="isRunning('stop-all')" @click="runAction('stop-all', 'service stop', '停止全部服务')">
            <Unplug :size="17" />停止全部
          </Button>
        </div>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Kernel WebUI</span>
        <div class="mt-3 grid gap-2">
          <Button variant="outline" :loading="isRunning('open-metacubex')" @click="withAction('open-metacubex', () => openCoreUi('metacubex'))"><ExternalLink :size="17" />Meta Cube X</Button>
          <Button variant="outline" :loading="isRunning('open-yacd')" @click="withAction('open-yacd', () => openCoreUi('yacd'))"><ExternalLink :size="17" />Yacd</Button>
          <Button variant="outline" :loading="isRunning('open-zashboard')" @click="withAction('open-zashboard', () => openCoreUi('zashboard'))"><ExternalLink :size="17" />zashboard</Button>
          <Button variant="outline" :loading="isRunning('api-groups')" @click="withAction('api-groups', () => runCli('api groups', '检查内核 API'))"><ShieldCheck :size="17" />检查 API</Button>
        </div>
      </Card>
    </div>
  </div>
</template>
