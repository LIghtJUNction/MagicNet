<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, RefreshCw, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Input from "@/components/ui/Input.vue";
import { parseRouteRuleSummary } from "@/composables/parsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed } from "@/utils";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const domain = ref("");
const routeOutput = ref("");
const pendingAction = ref<PendingToolAction | null>(null);
const copied = ref(false);
const summary = computed(() => parseRouteRuleSummary(routeOutput.value));

async function refreshRoutes(): Promise<void> {
  routeOutput.value = await runCli("route list", "读取路由规则", true);
}

async function addWarpRoute(cleanDomain: string): Promise<void> {
  await withAction("warp-route", async () => {
    const text = await runCli(`route add-domain warp ${shellQuote(cleanDomain)}`, `添加 WARP 路由 ${cleanDomain}`);
    if (!execFailed(text)) domain.value = "";
    await refreshRoutes();
  });
}

async function removeWarpRoute(cleanDomain: string): Promise<void> {
  await withAction(`warp-route-remove-${cleanDomain}`, async () => {
    await runCli(`route remove-domain warp ${shellQuote(cleanDomain)}`, `移除 WARP 路由 ${cleanDomain}`);
    await refreshRoutes();
  });
}

function requestAddWarpRoute(): void {
  const clean = domain.value.trim().toLowerCase();
  if (!validRouteDomain(clean)) {
    state.output = "域名后缀格式不对。示例：example.com";
    return;
  }
  pendingAction.value = {
    key: "warp-route",
    title: "添加 WARP 域名路由",
    detail: "会把这个域名后缀写入 WARP 路由规则，并立即回读 route list。",
    command: `route add-domain warp ${clean}`,
    run: () => addWarpRoute(clean),
  };
}

function validRouteDomain(value: string): boolean {
  if (!/^[a-z0-9.-]+$/i.test(value) || value.length > 253 || value.includes("..")) return false;
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(value) || value === "localhost") return false;
  const labels = value.split(".");
  if (labels.length < 2 || /^\d+$/.test(labels.at(-1) || "")) return false;
  return labels.every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
}

async function copyRouteSnapshot(): Promise<void> {
  const report = [
    "MagicNet route snapshot",
    "source=last route list",
    `proxy_count=${summary.value.proxy.length}`,
    `direct_count=${summary.value.direct.length}`,
    `block_count=${summary.value.block.length}`,
    `warp_count=${summary.value.warp.length}`,
    "",
    "[warp]",
    ...summary.value.warp
  ].join("\n").trim();
  copied.value = await copyText(report);
  state.output = copied.value ? "路由快照已复制。" : "剪贴板不可用，路由快照未复制。";
}

function requestRemoveWarpRoute(cleanDomain: string): void {
  pendingAction.value = {
    key: `warp-route-remove-${cleanDomain}`,
    title: "移除 WARP 域名路由",
    detail: "会从 WARP 路由规则里移除这个域名后缀，并立即回读 route list。",
    command: `route remove-domain warp ${cleanDomain}`,
    run: () => removeWarpRoute(cleanDomain),
  };
}

async function confirmAction(): Promise<void> {
  const action = pendingAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingAction.value = null;
  }
}

onMounted(() => {
  void refreshRoutes();
});
</script>

<template>
  <div class="grid gap-3">
    <div v-if="pendingAction" class="rounded-md border border-amber-400/30 bg-amber-500/10 p-3">
      <p class="text-sm font-semibold text-amber-100">{{ pendingAction.title }}</p>
      <p class="mt-1 text-sm leading-6 text-amber-100/80">{{ pendingAction.detail }}</p>
      <code class="mt-2 block break-words rounded bg-black/50 p-2 text-xs text-amber-50">{{ pendingAction.command }}</code>
      <div class="mt-3 grid gap-2 sm:grid-cols-2">
        <Button variant="outline" :disabled="isRunning(pendingAction.key)" @click="pendingAction = null">取消</Button>
        <Button :loading="isRunning(pendingAction.key)" @click="confirmAction">确认执行</Button>
      </div>
    </div>
    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <Input v-model="domain" placeholder="example.com" spellcheck="false" />
      <Button variant="secondary" :disabled="!state.warp.enabled" :loading="isRunning('warp-route')" @click="requestAddWarpRoute">域名走 WARP</Button>
    </div>
    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">Proxy</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.proxy.length }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">Direct</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.direct.length }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">Block</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.block.length }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">WARP</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.warp.length }}</p>
      </div>
    </div>
    <div v-if="summary.warp.length" class="rounded-md border border-zinc-800 bg-zinc-950 p-3 text-xs leading-6 text-zinc-300">
      <p class="mb-1 text-zinc-500">WARP 域名</p>
      <div class="grid max-h-64 gap-2 overflow-auto pr-1">
        <div v-for="item in summary.warp" :key="item" class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded bg-black/30 px-2 py-1">
          <span class="truncate">{{ item }}</span>
          <button
            class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60"
            :disabled="!state.warp.enabled || isRunning(`warp-route-remove-${item}`)"
            type="button"
            @click="requestRemoveWarpRoute(item)"
          >
            <X :size="14" />
          </button>
        </div>
      </div>
    </div>
    <div class="grid gap-2 sm:grid-cols-2">
      <Button variant="outline" :loading="isRunning('warp-route-refresh')" @click="withAction('warp-route-refresh', () => refreshRoutes())">
        <RefreshCw :size="16" />刷新路由规则
      </Button>
      <Button variant="outline" @click="copyRouteSnapshot">
        <Copy :size="16" />{{ copied ? '已复制快照' : '复制快照' }}
      </Button>
    </div>
  </div>
</template>
