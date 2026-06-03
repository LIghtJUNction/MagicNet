<script setup lang="ts">
import { Plus, RefreshCw, RotateCcw, Trash2, X } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, refreshApps, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const removedBypass = ref<string[]>([]);

const recycledBypass = computed(() => {
  const active = new Set(state.appPolicy.bypass);
  return removedBypass.value.filter((pkg) => !active.has(pkg));
});

function commandFailed(text: string): boolean {
  return /\b(error|failed|fail|Usage:|not found)\b/i.test(text);
}

function rememberRemovedBypass(pkg: string): void {
  removedBypass.value = [pkg, ...removedBypass.value.filter((item) => item !== pkg)].slice(0, 24);
}

function forgetRemovedBypass(pkg: string): void {
  removedBypass.value = removedBypass.value.filter((item) => item !== pkg);
}

async function addApp(target: "proxy" | "bypass"): Promise<void> {
  await withAction(`add-${target}`, async () => {
    const pkg = state.packageInput.trim();
    if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
      state.output = "包名格式不对。示例：com.android.chrome";
      return;
    }
    const list = target === "proxy" ? state.appPolicy.proxy : state.appPolicy.bypass;
    if (list.includes(pkg)) {
      state.output = `${pkg} 已存在，已自动去重。`;
      state.packageInput = "";
      return;
    }
    list.push(pkg);
    state.packageInput = "";
    if (target === "bypass") forgetRemovedBypass(pkg);
    state.output = `已加入界面，正在保存 ${pkg}...`;
    const text = await runCli(`app add ${shellQuote(pkg)} ${target}`, `添加应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      if (target === "proxy") {
        state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
      } else {
        state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
      }
      return;
    }
    await refreshApps(true);
  });
}

async function removeApp(pkg: string, target: "proxy" | "bypass"): Promise<void> {
  await withAction(`remove-${target}-${pkg}`, async () => {
    if (target === "proxy") {
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    } else {
      state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
      rememberRemovedBypass(pkg);
    }
    state.output = `已从界面移除 ${pkg}，正在后台保存...`;
    const text = await runCli(`app remove ${shellQuote(pkg)}`, `移除应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      if (target === "proxy" && !state.appPolicy.proxy.includes(pkg)) state.appPolicy.proxy.unshift(pkg);
      if (target === "bypass" && !state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.unshift(pkg);
      return;
    }
    await refreshApps(true);
  });
}

async function restoreBypass(pkg: string): Promise<void> {
  await withAction(`restore-bypass-${pkg}`, async () => {
    if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
    state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    state.output = `正在把 ${pkg} 加回 Bypass...`;
    const text = await runCli(`app add ${shellQuote(pkg)} bypass`, `恢复 Bypass 应用 ${pkg}`, true);
    await refreshApps(true);
    if (!commandFailed(text)) forgetRemovedBypass(pkg);
  });
}

async function setMode(mode: "blacklist" | "whitelist"): Promise<void> {
  await withAction(`mode-${mode}`, async () => {
    await runCli(`app mode ${mode}`, mode === "blacklist" ? "切换黑名单模式" : "切换白名单模式");
    await refreshApps(true);
  });
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Per App Policy" title="应用名单" description="只管理应用进入或绕过 MagicNet TUN 的名单，不做节点和代理模式控制。">
      <Button variant="outline" :loading="isRunning('refresh-apps')" @click="withAction('refresh-apps', () => refreshApps())"><RefreshCw :size="17" />读取</Button>
    </PageHeader>

    <Card class="grid gap-3">
      <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
        <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-blacklist')" :class="{ 'bg-zinc-800 text-zinc-50': state.appPolicy.mode === 'blacklist' }" @click="setMode('blacklist')">黑名单</button>
        <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-whitelist')" :class="{ 'bg-zinc-800 text-zinc-50': state.appPolicy.mode === 'whitelist' }" @click="setMode('whitelist')">白名单</button>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
        <Input v-model="state.packageInput" placeholder="com.android.chrome" spellcheck="false" />
        <Button variant="secondary" :loading="isRunning('add-proxy')" @click="addApp('proxy')"><Plus :size="16" />{{ isRunning('add-proxy') ? '保存中' : 'Proxy' }}</Button>
        <Button variant="secondary" :loading="isRunning('add-bypass')" @click="addApp('bypass')"><Plus :size="16" />{{ isRunning('add-bypass') ? '保存中' : 'Bypass' }}</Button>
      </div>
    </Card>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 text-base font-semibold">Proxy</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.proxy" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-proxy-${pkg}`)" type="button" title="移除" @click="removeApp(pkg, 'proxy')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.proxy.length" class="text-sm not-italic text-zinc-500">暂无应用</em>
        </div>
      </Card>
      <Card>
        <h3 class="mb-2 text-base font-semibold">Bypass</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.bypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-bypass-${pkg}`)" type="button" title="移入回收站" @click="removeApp(pkg, 'bypass')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.bypass.length" class="text-sm not-italic text-zinc-500">暂无应用</em>
        </div>
      </Card>
    </div>

    <Card class="grid gap-3 border-zinc-800/80 bg-zinc-950/65">
      <div class="flex items-center justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold">Bypass 回收站</h3>
          <p class="mt-1 text-sm text-zinc-500">从 Bypass 点 X 移除的应用会暂存在这里，可以直接加回名单。</p>
        </div>
        <Trash2 class="shrink-0 text-zinc-500" :size="18" />
      </div>
      <div class="flex max-h-56 flex-wrap gap-2 overflow-auto">
        <span v-for="pkg in recycledBypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-dashed border-zinc-700 bg-zinc-950 px-2 py-1 text-xs text-zinc-300 break-all">
          {{ pkg }}
          <button class="grid size-6 place-items-center rounded-full bg-emerald-500/15 text-emerald-300 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`restore-bypass-${pkg}`)" type="button" title="加回 Bypass" @click="restoreBypass(pkg)">
            <RotateCcw :size="14" />
          </button>
        </span>
        <em v-if="!recycledBypass.length" class="text-sm not-italic text-zinc-500">回收站为空</em>
      </div>
    </Card>
  </div>
</template>
