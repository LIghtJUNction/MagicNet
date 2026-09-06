<script setup lang="ts">
import { t } from "@/i18n";
import { computed, onMounted, ref } from "vue";
import { Copy, RefreshCw, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import Input from "@/components/ui/Input.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import StatTile from "@/components/ui/StatTile.vue";
import { parseRouteRuleSummary, type RouteRuleSummary } from "@/composables/parsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, redactedCliPreview } from "@/utils";
import { buildRouteRuleChangePlan, formatRouteRuleChangePlanReport } from "./routeRuleChangePlan";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const domain = ref("");
const routeQuery = ref("");
const routeOutput = ref("");
const pendingAction = ref<PendingToolAction | null>(null);
const pendingPlanInput = ref<{ summary: RouteRuleSummary; domain: string; action: "add" | "remove" } | null>(null);
const pendingPlan = computed(() => {
  const input = pendingPlanInput.value;
  return input ? buildRouteRuleChangePlan(input.summary, "warp", input.domain, input.action) : null;
});
const copied = ref(false);
const planCopied = ref(false);
const summary = computed(() => parseRouteRuleSummary(routeOutput.value));
const visibleWarpDomains = computed(() => {
  const query = routeQuery.value.trim().toLowerCase();
  if (!query) return summary.value.warp;
  return summary.value.warp.filter((item) => item.toLowerCase().includes(query));
});

async function refreshRoutes(trackUserAction = false): Promise<void> {
  const text = await runCli(
    "route list",
    t("读取路由规则"),
    true,
    trackUserAction ? redactedCliPreview("route list [private-output]") : "",
  );
  routeOutput.value = text;
  if (execFailed(text)) {
    state.phase = "error";
    state.notice = t("读取路由规则失败");
    state.output = text;
  }
  pendingAction.value = null;
  pendingPlanInput.value = null;
  planCopied.value = false;
}

async function addWarpRoute(cleanDomain: string): Promise<void> {
  await withAction("warp-route", async () => {
    const text = await runCli(`route add-domain warp ${shellQuote(cleanDomain)}`, t("添加 WARP 路由 {cleanDomain}", { cleanDomain }));
    if (!execFailed(text)) domain.value = "";
    await refreshRoutes();
  });
}

async function removeWarpRoute(cleanDomain: string): Promise<void> {
  await withAction(`warp-route-remove-${cleanDomain}`, async () => {
    const text = await runCli(`route remove-domain warp ${shellQuote(cleanDomain)}`, t("移除 WARP 路由 {cleanDomain}", { cleanDomain }));
    if (execFailed(text)) return;
    await refreshRoutes();
  });
}

function requestAddWarpRoute(): void {
  const clean = domain.value.trim().toLowerCase();
  if (!validRouteDomain(clean)) {
    state.output = t("域名后缀格式不对。示例：example.com");
    return;
  }
  pendingAction.value = {
    key: "warp-route",
    get title() { return t("添加 WARP 域名路由"); },
    get detail() { return t("会把这个域名后缀写入 WARP 路由规则，应用 route 配置并重启当前 core。"); },
    command: `route add-domain warp ${clean}`,
    run: () => addWarpRoute(clean),
  };
  pendingPlanInput.value = { summary: summary.value, domain: clean, action: "add" };
  planCopied.value = false;
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
    `visible_warp_count=${visibleWarpDomains.value.length}`,
    routeQuery.value.trim() ? `visible_warp_query=${routeQuery.value.trim()}` : "",
    "",
    "[proxy]",
    ...summary.value.proxy,
    "",
    "[direct]",
    ...summary.value.direct,
    "",
    "[block]",
    ...summary.value.block,
    "",
    "[warp_visible]",
    ...visibleWarpDomains.value
  ].filter((line) => line !== "").join("\n").trim();
  copied.value = await copyText(report);
  state.output = copied.value ? t("路由快照已复制。") : t("剪贴板不可用，路由快照未复制。");
}

async function copyRouteChangePlan(): Promise<void> {
  if (!pendingPlan.value) return;
  planCopied.value = await copyText(formatRouteRuleChangePlanReport(pendingPlan.value));
  state.output = planCopied.value ? t("路由变更计划已复制。") : t("剪贴板不可用，路由变更计划未复制。");
}

function requestRemoveWarpRoute(cleanDomain: string): void {
  pendingAction.value = {
    key: `warp-route-remove-${cleanDomain}`,
    get title() { return t("移除 WARP 域名路由"); },
    get detail() { return t("会从 WARP 路由规则里移除这个域名后缀，应用 route 配置并重启当前 core。"); },
    command: `route remove-domain warp ${cleanDomain}`,
    run: () => removeWarpRoute(cleanDomain),
  };
  pendingPlanInput.value = { summary: summary.value, domain: cleanDomain, action: "remove" };
  planCopied.value = false;
}

async function confirmAction(): Promise<void> {
  const action = pendingAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingAction.value = null;
    pendingPlanInput.value = null;
    planCopied.value = false;
  }
}

function cancelAction(): void {
  pendingAction.value = null;
  pendingPlanInput.value = null;
  planCopied.value = false;
}

onMounted(() => {
  void refreshRoutes();
});
</script>

<template>
  <div class="grid gap-3">
    <ConfirmPanel
      v-if="pendingAction"
      :title="pendingAction.title"
      :detail="pendingAction.detail"
      :command="pendingAction.command"
      :loading="isRunning(pendingAction.key)"
      @cancel="cancelAction"
      @confirm="confirmAction"
    >
      <div v-if="pendingPlan" class="mt-3 flex flex-wrap gap-2">
        <InsightChip
          v-for="item in pendingPlan.items"
          :key="item.label"
          :label="item.label"
          :value="item.value"
          :tone="item.tone"
        />
      </div>
      <p v-if="pendingPlan?.warnings.length" class="mt-2 text-xs leading-5 text-[var(--mn-warning)]/80">
        {{ pendingPlan.warnings.join("；") }}
      </p>
      <template #actions>
        <Button variant="outline" :disabled="isRunning(pendingAction.key)" @click="cancelAction">{{ t("取消") }}</Button>
        <Button variant="outline" @click="copyRouteChangePlan"><Copy :size="15" />{{ planCopied ? t("已复制计划") : t("复制计划") }}</Button>
        <Button :loading="isRunning(pendingAction.key)" @click="confirmAction">{{ t("确认执行") }}</Button>
      </template>
    </ConfirmPanel>
    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <Input v-model="domain" placeholder="example.com" spellcheck="false" />
      <Button variant="secondary" :disabled="!state.warp.enabled" :loading="isRunning('warp-route')" @click="requestAddWarpRoute">{{ t("域名走 WARP") }}</Button>
    </div>
    <Input v-model="routeQuery" :placeholder="t('过滤 WARP 域名，例如 google / openai')" spellcheck="false" />
    <div class="grid gap-2 sm:grid-cols-4">
      <StatTile :label="t('代理')" :value="summary.proxy.length" />
      <StatTile :label="t('直连')" :value="summary.direct.length" />
      <StatTile :label="t('拦截')" :value="summary.block.length" />
      <StatTile label="WARP" :value="summary.warp.length" />
    </div>
    <div v-if="summary.warp.length" class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)]">
      <p class="mb-1 text-[var(--mn-ink-muted)]">{{ t("WARP 域名 ·") }} {{ visibleWarpDomains.length }} / {{ summary.warp.length }}</p>
      <div class="grid max-h-64 gap-2 overflow-auto pr-1">
        <div v-for="item in visibleWarpDomains" :key="item" class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded bg-[var(--mn-carrier-deep)]/30 px-2 py-1">
          <span class="truncate">{{ item }}</span>
          <button
            class="grid size-6 place-items-center rounded-full bg-[var(--mn-cactus)] text-[var(--mn-on-accent)] disabled:cursor-progress disabled:opacity-60"
            :disabled="!state.warp.enabled || isRunning(`warp-route-remove-${item}`)"
            :aria-label="t('移除 WARP 路由 {domain}', { domain: item })"
            type="button"
            @click="requestRemoveWarpRoute(item)"
          >
            <X :size="14" />
          </button>
        </div>
      </div>
      <p v-if="!visibleWarpDomains.length" class="rounded bg-[var(--mn-carrier-deep)]/30 px-2 py-2 text-[var(--mn-ink-muted)]">{{ t("没有匹配的 WARP 域名。") }}</p>
    </div>
    <div class="grid gap-2 sm:grid-cols-2">
      <Button variant="outline" :loading="isRunning('warp-route-refresh')" @click="withAction('warp-route-refresh', () => refreshRoutes(true))">
        <RefreshCw :size="16" />{{ t("刷新路由规则") }}
      </Button>
      <Button variant="outline" @click="copyRouteSnapshot">
        <Copy :size="16" />{{ copied ? t("已复制快照") : t("复制快照") }}
      </Button>
    </div>
  </div>
</template>
