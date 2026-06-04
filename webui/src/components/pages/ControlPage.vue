<script setup lang="ts">
import { ExternalLink, KeyRound, Power, Radar, RadioTower, RotateCcw, Save, ShieldCheck, Unplug, Zap } from "lucide-vue-next";
import { ref, watch } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, startBackgroundCli, refreshAll, refreshStatus, refreshTailscale, openCoreUi, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const tailscaleAuth = ref("");
const tailscaleHostname = ref(state.tailscale.hostname);
const tailscaleSubnets = ref(state.tailscale.subnets);

watch(() => state.tailscale.hostname, (value) => { tailscaleHostname.value = value; });
watch(() => state.tailscale.subnets, (value) => { tailscaleSubnets.value = value; });

async function selectCore(core: "sing-box" | "mihomo"): Promise<void> {
  state.selectedCore = core;
  await withAction(`select-${core}`, async () => {
    await runCli(`core select ${core}`, `选择核心 ${core}`);
    await refreshAll();
  });
}

async function setSelectedCoreDefault(): Promise<void> {
  const core = state.selectedCore;
  if (core !== "sing-box" && core !== "mihomo") {
    state.output = "请选择 sing-box 或 mihomo 后再设为默认。";
    return;
  }
  await withAction("default-core", async () => {
    await runCli(`core select ${core}`, `设为默认核心 ${core}`);
    state.selectedCore = core;
    await refreshStatus();
  });
}

async function toggleCurrentCore(): Promise<void> {
  const running = state.runtime.core === state.selectedCore;
  await withAction("toggle-core", async () => {
    await startBackgroundCli(running ? "service stop" : `service restart ${state.selectedCore}`, running ? `停止 ${state.selectedCore}` : `启动 ${state.selectedCore}`);
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

async function setTransparentMode(mode: "tun" | "tproxy"): Promise<void> {
  await withAction(`transparent-${mode}`, async () => {
    await runCli(`transparent set ${mode}`, `切换 ${mode.toUpperCase()} 模式`);
    await refreshStatus();
  });
}

async function setHotspotMode(mode: "proxy" | "direct"): Promise<void> {
  await withAction(`hotspot-${mode}`, async () => {
    await runCli(`hotspot set ${mode}`, `热点切换为${mode === "proxy" ? "代理" : "直连"}`);
    await refreshStatus();
  });
}

async function ensureHotspotNetwork(): Promise<void> {
  await withAction("hotspot-ensure", async () => {
    await runCli("hotspot reload", "确保热点网络规则");
    await refreshStatus();
  });
}

async function setVpnCoexist(mode: "on" | "off"): Promise<void> {
  await withAction(`vpn-${mode}`, async () => {
    await runCli(`vpn set ${mode}`, `${mode === "on" ? "开启" : "关闭"} VPN 共存保护`);
    await refreshStatus();
  });
}

async function reloadVpnCoexist(): Promise<void> {
  await withAction("vpn-reload", async () => {
    await runCli("vpn reload", "重载 VPN 共存规则");
    await refreshStatus();
  });
}

async function saveTailscale(): Promise<void> {
  await withAction("tailscale-save", async () => {
    const auth = tailscaleAuth.value.trim() || "-keep";
    const hostname = tailscaleHostname.value.trim() || "android-magicnet";
    const subnets = tailscaleSubnets.value.split(/[\s,]+/).map((item) => item.trim()).filter(Boolean).join(",");
    await runCli(`tailscale set ${shellQuote(auth)} ${shellQuote(hostname)} ${shellQuote(subnets || "100.64.0.0/10")}`, "保存 Tailscale 快捷配置");
    tailscaleAuth.value = "";
    await refreshTailscale(true);
    await refreshStatus();
  });
}

async function disableTailscale(): Promise<void> {
  await withAction("tailscale-disable", async () => {
    await runCli("tailscale disable", "关闭 Tailscale 快捷配置");
    await refreshTailscale(true);
  });
}
</script>

<template>
  <div class="grid gap-4">
    <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
      <div>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Control Center</span>
        <h2 class="mt-1 text-2xl font-semibold">模块控制</h2>
        <p class="mt-1 text-sm leading-6 text-zinc-400">只放模块生命周期和入口。节点、测速、代理模式交给核心 WebUI。</p>
      </div>
      <Badge :tone="state.runtime.core === 'stopped' ? 'warning' : 'success'">{{ state.runtime.core }}</Badge>
    </div>

    <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Current Core</span>
            <h3 class="mt-1 break-words text-xl font-semibold">{{ state.selectedCore }}</h3>
          </div>
          <Button size="sm" variant="secondary" :loading="isRunning('default-core')" :disabled="state.selectedCore !== 'sing-box' && state.selectedCore !== 'mihomo'" @click="setSelectedCoreDefault">设为默认</Button>
        </div>
        <p class="text-sm leading-6 text-zinc-400">先选 sing-box 或 mihomo，再启动、停止或设为默认。</p>
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('select-sing-box')" :class="{ 'bg-zinc-800 text-zinc-50': state.selectedCore === 'sing-box' }" @click="selectCore('sing-box')">sing-box</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('select-mihomo')" :class="{ 'bg-zinc-800 text-zinc-50': state.selectedCore === 'mihomo' }" @click="selectCore('mihomo')">mihomo</button>
        </div>
        <Button :loading="isRunning('toggle-core')" class="w-full" @click="toggleCurrentCore">
          <Power :size="18" />
          {{ state.runtime.core === state.selectedCore ? "停止当前核心" : "启动当前核心" }}
        </Button>
      </Card>

      <Card>
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Quick Actions</span>
        <div class="mt-3 grid gap-2">
          <Button variant="secondary" :loading="isRunning('restart-current')" @click="runAction('restart-current', 'service restart current', '重启当前核心', true)">
            <RotateCcw :size="17" />重启当前核心
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
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Core WebUI</span>
        <div class="mt-3 grid gap-2">
          <Button variant="outline" :loading="isRunning('open-metacubex')" @click="withAction('open-metacubex', () => openCoreUi('metacubex'))"><ExternalLink :size="17" />Meta Cube X</Button>
          <Button variant="outline" :loading="isRunning('open-yacd')" @click="withAction('open-yacd', () => openCoreUi('yacd'))"><ExternalLink :size="17" />Yacd</Button>
          <Button variant="outline" :loading="isRunning('open-zashboard')" @click="withAction('open-zashboard', () => openCoreUi('zashboard'))"><ExternalLink :size="17" />zashboard</Button>
          <Button variant="outline" :loading="isRunning('api-groups')" @click="withAction('api-groups', () => runCli('api groups', '检查核心 API'))"><ShieldCheck :size="17" />检查 API</Button>
        </div>
      </Card>
    </div>

    <div class="grid gap-3 md:grid-cols-3">
      <Card class="grid gap-3">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Transparent Mode</span>
            <h3 class="mt-1 text-lg font-semibold">{{ state.runtime.transparentMode.toUpperCase() }}</h3>
          </div>
          <Badge tone="neutral">{{ state.runtime.transparentMode }}</Badge>
        </div>
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('transparent-tun')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.transparentMode === 'tun' }" @click="setTransparentMode('tun')">TUN</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('transparent-tproxy')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.transparentMode === 'tproxy' }" @click="setTransparentMode('tproxy')">TPROXY</button>
        </div>
        <Button variant="secondary" :loading="isRunning('transparent-apply')" @click="runAction('transparent-apply', 'transparent apply', '应用透明代理模式')">
          <Radar :size="17" />重新应用模式
        </Button>
      </Card>

      <Card class="grid gap-3">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Watchdog</span>
            <h3 class="mt-1 text-lg font-semibold">{{ state.runtime.watchdog === "stopped" ? "stopped" : `pid ${state.runtime.watchdog}` }}</h3>
          </div>
          <Badge :tone="state.runtime.watchdog === 'stopped' ? 'warning' : 'success'">{{ state.runtime.watchdog === "stopped" ? "off" : "on" }}</Badge>
        </div>
        <div class="grid gap-2 sm:grid-cols-3">
          <Button variant="secondary" :loading="isRunning('watchdog-start')" @click="runAction('watchdog-start', 'watchdog start', '启动 watchdog')">
            <Power :size="16" />启动
          </Button>
          <Button variant="secondary" :loading="isRunning('watchdog-restart')" @click="runAction('watchdog-restart', 'watchdog restart', '重启 watchdog')">
            <RotateCcw :size="16" />重启
          </Button>
          <Button variant="outline" :loading="isRunning('watchdog-stop')" @click="runAction('watchdog-stop', 'watchdog stop', '停止 watchdog')">
            <Unplug :size="16" />停止
          </Button>
        </div>
      </Card>

      <Card class="grid gap-3">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Hotspot</span>
            <h3 class="mt-1 text-lg font-semibold">热点网络</h3>
          </div>
          <Badge :tone="state.runtime.hotspotMode === 'proxy' ? 'success' : 'neutral'">{{ state.runtime.hotspotMode }}</Badge>
        </div>
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('hotspot-proxy')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.hotspotMode === 'proxy' }" @click="setHotspotMode('proxy')">代理</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('hotspot-direct')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.hotspotMode === 'direct' }" @click="setHotspotMode('direct')">直连</button>
        </div>
        <Button variant="secondary" :loading="isRunning('hotspot-ensure')" @click="ensureHotspotNetwork">
          <RadioTower :size="17" />确保热点有网
        </Button>
      </Card>

      <Card class="grid gap-3">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">VPN Coexist</span>
            <h3 class="mt-1 text-lg font-semibold">VPN 共存</h3>
          </div>
          <Badge :tone="state.runtime.vpnCoexist === 'on' ? 'success' : 'warning'">{{ state.runtime.vpnCoexist }}</Badge>
        </div>
        <p class="text-sm leading-6 text-zinc-400">保护 Tailscale、WireGuard、OpenVPN、WARP 等外部 VPN，不让 overlay 流量被 MagicNet 回环。</p>
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('vpn-on')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.vpnCoexist === 'on' }" @click="setVpnCoexist('on')">开启</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('vpn-off')" :class="{ 'bg-zinc-800 text-zinc-50': state.runtime.vpnCoexist === 'off' }" @click="setVpnCoexist('off')">关闭</button>
        </div>
        <Button variant="secondary" :loading="isRunning('vpn-reload')" @click="reloadVpnCoexist">
          <ShieldCheck :size="17" />重载共存规则
        </Button>
      </Card>

      <Card class="grid gap-3 md:col-span-2 xl:col-span-4">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="min-w-0">
            <span class="block text-[11px] font-bold uppercase tracking-wide text-zinc-500">Mesh Network</span>
            <h3 class="mt-1 flex min-w-0 items-center gap-2 text-lg font-semibold"><KeyRound :size="18" class="shrink-0" /><span class="block break-words">Tailscale 快捷配置</span></h3>
            <p class="mt-1 text-sm leading-6 text-zinc-400">给 sing-box endpoints / mihomo tailscale proxy 写入同一套配置。密钥只保存到模块配置，不在状态里回显。</p>
          </div>
          <Badge :tone="state.tailscale.enabled ? 'success' : 'neutral'">{{ state.tailscale.enabled ? "enabled" : "disabled" }}</Badge>
        </div>
        <div class="grid gap-3 lg:grid-cols-12">
          <label class="grid gap-1 lg:col-span-4">
            <span class="text-xs font-medium text-zinc-400">Auth key</span>
            <Input v-model="tailscaleAuth" type="password" :placeholder="state.tailscale.authKeySet ? '已保存，留空沿用' : 'tskey-auth-...'" autocomplete="off" />
          </label>
          <label class="grid gap-1 lg:col-span-3">
            <span class="text-xs font-medium text-zinc-400">Hostname</span>
            <Input v-model="tailscaleHostname" placeholder="android-magicnet" />
          </label>
          <label class="grid gap-1 lg:col-span-5">
            <span class="text-xs font-medium text-zinc-400">路由网段</span>
            <Input v-model="tailscaleSubnets" placeholder="100.64.0.0/10,192.168.100.0/24" />
          </label>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Button :loading="isRunning('tailscale-save')" @click="saveTailscale"><Save :size="16" />保存并应用</Button>
          <Button variant="outline" :loading="isRunning('tailscale-disable')" @click="disableTailscale">关闭</Button>
          <Button variant="secondary" :loading="isRunning('tailscale-refresh')" @click="withAction('tailscale-refresh', () => refreshTailscale())"><RotateCcw :size="16" />刷新</Button>
        </div>
      </Card>
    </div>
  </div>
</template>
