<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, RefreshCw, Route } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import SearchField from "@/components/ui/SearchField.vue";
import { buildNodeDelayStats, nodeDelayQualityLabel, parseNodeTestAll, sanitizeNodeText, type NodeDelayEntry } from "@/composables/nodeDelayParsers";
import { parseProxyGroupsSnapshot, sanitizeProxyName, type ProxyGroupSummary } from "@/composables/proxyGroupParsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, shellQuote } from "@/utils";
import { buildProxySelectionPlan, formatProxySelectionPlanReport, type ProxySelectionPlan } from "./proxySelectionPlan";

type PendingProxyAction = {
  group: ProxyGroupSummary;
  node: string;
  run: () => Promise<void>;
};

const { runCli, state } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const rawOutput = ref("");
const copied = ref(false);
const groupQuery = ref("");
const groupDelays = ref<Record<string, NodeDelayEntry[]>>({});
const pendingAction = ref<PendingProxyAction | null>(null);
const selectionPlanCopied = ref(false);

const snapshot = computed(() => parseProxyGroupsSnapshot(rawOutput.value));
const pendingPlan = computed<ProxySelectionPlan | null>(() => {
  const action = pendingAction.value;
  if (!action) return null;
  return buildProxySelectionPlan(action.group, action.node, groupDelays.value[action.group.name] || []);
});
const filteredGroups = computed(() => {
  const query = groupQuery.value.trim().toLowerCase();
  const groups = snapshot.value?.groups || [];
  if (!query) return groups;
  return groups.filter((group) => [
    group.name,
    group.type,
    group.now,
    ...group.proxies
  ].some((value) => sanitizeProxyName(value).toLowerCase().includes(query)));
});
const visibleGroups = computed(() => filteredGroups.value.slice(0, 8));

async function refreshGroups(): Promise<void> {
  await withAction("proxy-groups-refresh", async () => {
    copied.value = false;
    pendingAction.value = null;
    selectionPlanCopied.value = false;
    groupDelays.value = {};
    rawOutput.value = await runCli("api proxies", "读取代理组");
  });
}

function requestSelect(group: ProxyGroupSummary, node: string): void {
  if (!validProxyChoice(group.name, node)) {
    state.output = "代理组或节点名称为空/过长，已拒绝执行。";
    return;
  }
  pendingAction.value = {
    group,
    node,
    run: () => selectNode(group.name, node)
  };
  selectionPlanCopied.value = false;
}

function validProxyChoice(group: string, node: string): boolean {
  return Boolean(group.trim() && node.trim() && group.length <= 180 && node.length <= 240);
}

async function testGroup(group: ProxyGroupSummary): Promise<void> {
  const nodes = group.proxies.slice(0, 16);
  if (!nodes.length) return;
  await withAction(`proxy-group-test-${group.name}`, async () => {
    const output = await runCli(`node test-all ${nodes.map(shellQuote).join(" ")}`, `测速 ${group.name}`);
    const requested = new Set(nodes);
    const entries = parseNodeTestAll(output).filter((entry) => requested.has(entry.node));
    groupDelays.value = { ...groupDelays.value, [group.name]: entries };
  });
}

function requestUseFastest(group: ProxyGroupSummary): void {
  const fastest = groupDelayStats(group).fastest;
  if (!fastest) {
    state.output = "请先测速本组，且至少需要一个可用节点。";
    return;
  }
  requestSelect(group, fastest.node);
}

function groupDelayStats(group: ProxyGroupSummary) {
  return buildNodeDelayStats(groupDelays.value[group.name] || []);
}

function visibleGroupNodes(group: ProxyGroupSummary): string[] {
  const query = groupQuery.value.trim().toLowerCase();
  if (!query) return group.proxies.slice(0, 9);
  const groupMatched = [group.name, group.type, group.now]
    .some((value) => sanitizeProxyName(value).toLowerCase().includes(query));
  const nodes = groupMatched
    ? group.proxies
    : group.proxies.filter((node) => sanitizeProxyName(node).toLowerCase().includes(query));
  return nodes.slice(0, 9);
}

async function selectNode(group: string, node: string): Promise<void> {
  await withAction("proxy-groups-select", async () => {
    const text = await runCli(`api select ${shellQuote(group)} ${shellQuote(node)}`, "切换代理节点");
    if (execFailed(text)) return;
    state.output = text;
    const refreshed = await runCli("api proxies", "刷新代理组", true);
    if (execFailed(refreshed)) {
      state.output = `代理节点切换已执行，但代理组刷新未确认：\n${refreshed}`;
      return;
    }
    rawOutput.value = refreshed;
  });
}

function cancelAction(): void {
  pendingAction.value = null;
  selectionPlanCopied.value = false;
}

async function confirmAction(): Promise<void> {
  const action = pendingAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingAction.value = null;
    selectionPlanCopied.value = false;
  }
}

async function copySelectionPlan(): Promise<void> {
  const action = pendingAction.value;
  const plan = pendingPlan.value;
  if (!action || !plan) return;
  selectionPlanCopied.value = await copyText(formatProxySelectionPlanReport(plan));
  state.output = selectionPlanCopied.value ? "代理切换计划摘要已复制。" : "剪贴板不可用，代理切换计划未复制。";
}

async function copyReport(): Promise<void> {
  const report = visibleGroups.value.flatMap((group) => {
    const stats = groupDelayStats(group);
    const delays = groupDelays.value[group.name] || [];
    return [
      `${sanitizeProxyName(group.name)} type=${group.type} now=${sanitizeProxyName(group.now || "none")} count=${group.proxies.length}`,
      `delay_tested=${stats.tested} usable=${stats.usable} failed=${stats.failed} median_ms=${stats.medianMillis ?? "none"} parsed_usable_percent=${stats.usablePercent} fastest=${stats.fastest ? `${sanitizeNodeText(stats.fastest.node)} ${sanitizeNodeText(stats.fastest.summary)}` : "none"}`,
      ...visibleGroupNodes(group).map((node) => {
        const delay = delays.find((entry) => entry.node === node);
        return `  - ${sanitizeProxyName(node)}${delay ? ` delay=${sanitizeNodeText(delay.summary)} quality=${delay.quality}` : ""}`;
      })
    ];
  }).join("\n");
  copied.value = await copyText(report);
  state.output = copied.value ? "代理组报告已复制。" : "剪贴板不可用，代理组报告未复制。";
}

onMounted(() => {
  void refreshGroups();
});
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Route :size="17" /> 代理组</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
          真实调用 <code>api proxies</code> 读取 selector/provider，并可确认后执行 <code>api select</code>。
        </p>
      </div>
      <div class="flex gap-2">
        <Button size="sm" variant="outline" :loading="isRunning('proxy-groups-refresh')" @click="refreshGroups">
          <RefreshCw :size="15" />刷新
        </Button>
        <Button size="sm" variant="secondary" :disabled="!visibleGroups.length" @click="copyReport">
          <Copy :size="15" />{{ copied ? "已复制" : "复制" }}
        </Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <SearchField v-model="groupQuery" placeholder="搜索代理组或节点" />
      <span class="text-sm text-[var(--mn-ink-muted)]">
        {{ filteredGroups.length }} / {{ snapshot?.groups.length || 0 }} 组
      </span>
    </div>

    <ConfirmPanel
      v-if="pendingAction"
      title="切换代理节点"
      :detail="`${sanitizeProxyName(pendingAction.group.name)}：${sanitizeProxyName(pendingPlan?.summary || '')}`"
      command="api select <group> <node>"
      :loading="isRunning('proxy-groups-select')"
      confirm-label="确认切换"
      confirm-variant="secondary"
      @cancel="cancelAction"
      @confirm="confirmAction"
    >
      <div class="mt-3 flex flex-wrap gap-2">
        <InsightChip
          v-for="item in pendingPlan?.items || []"
          :key="item.label"
          :label="item.label"
          :value="sanitizeProxyName(item.value)"
          :tone="item.tone"
        />
      </div>
      <p v-if="pendingPlan?.warnings.length" class="mt-2 text-xs leading-5 text-[var(--mn-warning)]/80">
        {{ pendingPlan.warnings.join("；") }}
      </p>
      <template #actions>
        <Button size="sm" variant="outline" @click="cancelAction">取消</Button>
        <Button size="sm" variant="outline" @click="copySelectionPlan">{{ selectionPlanCopied ? "已复制计划" : "复制计划" }}</Button>
        <Button size="sm" variant="secondary" :loading="isRunning('proxy-groups-select')" @click="confirmAction">确认切换</Button>
      </template>
    </ConfirmPanel>

    <div v-if="visibleGroups.length" class="grid gap-3">
      <div v-for="group in visibleGroups" :key="group.name" class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <div class="mb-2 grid grid-cols-[minmax(0,1fr)_auto] gap-2">
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold text-[var(--mn-ink)]">{{ sanitizeProxyName(group.name) }}</p>
            <p class="text-xs text-[var(--mn-ink-muted)]">{{ group.type }} · {{ group.proxies.length }} nodes</p>
          </div>
          <span class="truncate rounded border border-[color-mix(in_srgb,var(--mn-ink)_14%,transparent)] px-2 py-1 text-xs text-[var(--mn-ink-soft)]">{{ sanitizeProxyName(group.now || "未选择") }}</span>
        </div>
        <div class="mb-2 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-center">
          <p class="text-xs text-[var(--mn-ink-muted)]">
            <template v-if="groupDelayStats(group).tested">
              已测 {{ groupDelayStats(group).tested }} · 可用 {{ groupDelayStats(group).usable }} · 最快 {{ groupDelayStats(group).fastest?.summary || "无" }}
            </template>
            <template v-else>可测速本组前 16 个节点。</template>
          </p>
          <Button size="sm" variant="outline" :loading="isRunning(`proxy-group-test-${group.name}`)" @click="testGroup(group)">测速本组</Button>
          <Button size="sm" variant="secondary" :disabled="!groupDelayStats(group).fastest" @click="requestUseFastest(group)">使用最快</Button>
        </div>
        <div class="grid gap-2 md:grid-cols-3">
          <button
            v-for="node in visibleGroupNodes(group)"
            :key="`${group.name}-${node}`"
            class="grid rounded-md border px-3 py-2 text-left text-sm"
            :class="node === group.now ? 'border-[color-mix(in_srgb,var(--mn-cactus)_55%,transparent)] bg-[color-mix(in_srgb,var(--mn-cactus)_40%,var(--mn-carrier))] text-[var(--mn-success)]' : 'border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-carrier-deep)]/30 text-[var(--mn-ink-soft)]'"
            type="button"
            :disabled="node === group.now || isRunning('proxy-groups-select')"
            @click="requestSelect(group, node)"
          >
            <span class="truncate">{{ sanitizeProxyName(node) }}</span>
            <span v-if="groupDelays[group.name]?.find((entry) => entry.node === node)" class="mt-1 text-xs text-[var(--mn-ink-muted)]">
              {{ sanitizeNodeText(groupDelays[group.name].find((entry) => entry.node === node)?.summary || "") }}
              · {{ nodeDelayQualityLabel(groupDelays[group.name].find((entry) => entry.node === node)?.quality || "failed") }}
            </span>
          </button>
        </div>
      </div>
    </div>
    <pre v-else-if="rawOutput" class="max-h-48 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ rawOutput }}</pre>
  </Card>
</template>
