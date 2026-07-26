<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, RefreshCw, Search, Unplug } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { connectionBuckets, connectionFlowSummary, connectionMatchesQuery, parseConnectionSnapshot, type ConnectionTarget } from "@/composables/parsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, shellQuote } from "@/utils";
import { buildConnectionClosePlan, connectionClosePlanTone, formatConnectionCloseDetail } from "./connectionClosePlan";
import { buildConnectionInsights, formatConnectionBytes } from "./connectionInsights";

type PendingConnectionAction = {
  key: string;
  title: string;
  detail: string;
  command: string;
  run: () => Promise<void>;
};

const { runCli, state } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const query = ref("");
const rawOutput = ref("");
const copied = ref(false);
const closeTopCount = ref("3");
const pendingAction = ref<PendingConnectionAction | null>(null);

const snapshot = computed(() => parseConnectionSnapshot(rawOutput.value));
const filtered = computed(() => snapshot.value?.connections.filter((item) => connectionMatchesQuery(item, query.value)) || []);
const visibleConnections = computed(() => (query.value ? filtered.value : snapshot.value?.connections || []).slice(0, 10));
const ruleBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "rule"));
const chainBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "chain"));
const processBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "process"));
const flowSummary = computed(() => connectionFlowSummary(snapshot.value?.connections || []));
const totalBytes = computed(() => (snapshot.value?.uploadTotal || 0) + (snapshot.value?.downloadTotal || 0));
const insights = computed(() => buildConnectionInsights(snapshot.value?.connections || [], filtered.value, query.value));
const closeTopN = computed(() => {
  const count = Number.parseInt(closeTopCount.value, 10);
  return Number.isFinite(count) && count >= 1 && count <= 8 ? count : 3;
});
const allConnections = computed(() => snapshot.value?.connections || []);
const topCloseTargets = computed(() => allConnections.value.slice(0, closeTopN.value));
const topClosePlan = computed(() => buildConnectionClosePlan("top", topCloseTargets.value, allConnections.value));
const matchedCloseTargets = computed(() => filtered.value.slice(0, 8));
const matchedClosePlan = computed(() => buildConnectionClosePlan("matched", matchedCloseTargets.value, allConnections.value, query.value));
const allClosePlan = computed(() => buildConnectionClosePlan("all", allConnections.value, allConnections.value));

async function refreshConnections(): Promise<void> {
  await withAction("connections-refresh", async () => {
    copied.value = false;
    rawOutput.value = await runCli("api conns", "读取活动连接");
  });
}

async function copyReport(): Promise<void> {
  const buckets = [
    ["process", processBuckets.value],
    ["rule", ruleBuckets.value],
    ["chain", chainBuckets.value]
  ] as const;
  const report = [
    "MagicNet active connections",
    `raw_count=${snapshot.value?.count || 0}`,
    `parsed_count=${snapshot.value?.connections.length || 0}`,
    `upload=${formatConnectionBytes(snapshot.value?.uploadTotal || 0)}`,
    `download=${formatConnectionBytes(snapshot.value?.downloadTotal || 0)}`,
    `proxied=${flowSummary.value.proxied}`,
    `direct=${flowSummary.value.direct}`,
    `blocked=${flowSummary.value.blocked}`,
    `unknown=${flowSummary.value.unknown}`,
    query.value ? `query=${query.value}` : "",
    "",
    "[insights]",
    ...insights.value.map((item) => `${item.label}=${item.value} detail=${item.detail} tone=${item.tone}`),
    "",
    ...buckets.flatMap(([kind, items]) => [
      `[${kind}_hotspots]`,
      ...items.map((item) => `${item.name} count=${item.count} bytes=${Math.round(item.bytes)}`)
    ]),
    "",
    ...filtered.value.map((item) => [
      item.label,
      `bytes=${Math.round(item.totalBytes)}`,
      item.process ? `process=${item.process}` : "",
      item.source ? `source=${item.source}` : "",
      item.inbound ? `inbound=${item.inbound}` : "",
      item.rule ? `rule=${item.rule}` : "",
      item.rulePayload ? `payload=${item.rulePayload}` : "",
      item.chain ? `chain=${item.chain}` : ""
    ].filter(Boolean).join(" "))
  ].filter(Boolean).join("\n");
  copied.value = await copyText(report);
  state.output = copied.value ? "活动连接报告已复制。" : "剪贴板不可用，活动连接报告未复制。";
}

async function runConnectionAction(command: string, label: string): Promise<void> {
  await withAction("connections-action", async () => {
    const text = await runCli(command, label);
    state.output = text;
    rawOutput.value = await runCli("api conns", "刷新活动连接", true);
  });
}

function requestCloseTop(): void {
  const count = closeTopN.value;
  const plan = topClosePlan.value;
  pendingAction.value = {
    key: "connections-action",
    title: `关闭流量最高的 ${count} 条连接`,
    detail: formatConnectionCloseDetail(plan),
    command: `api close-top ${count}`,
    run: () => runConnectionAction(`api close-top ${count}`, "关闭 Top 连接")
  };
}

function requestCloseMatched(): void {
  const cleanQuery = query.value.trim();
  if (!cleanQuery || !filtered.value.length) return;
  const plan = matchedClosePlan.value;
  pendingAction.value = {
    key: "connections-action",
    title: `关闭 ${matchedCloseTargets.value.length} 条匹配连接`,
    detail: formatConnectionCloseDetail(plan),
    command: `api close-matching ${shellQuote(cleanQuery)}`,
    run: () => runConnectionAction(`api close-matching ${shellQuote(cleanQuery)}`, "关闭匹配连接")
  };
}

function requestCloseAll(): void {
  const count = snapshot.value?.connections.length || 0;
  if (!count) return;
  const plan = allClosePlan.value;
  pendingAction.value = {
    key: "connections-action",
    title: `关闭全部 ${count} 条活动连接`,
    detail: formatConnectionCloseDetail(plan),
    command: "api close-all",
    run: () => runConnectionAction("api close-all", "关闭全部连接")
  };
}

function requestCloseOne(target: ConnectionTarget): void {
  pendingAction.value = {
    key: "connections-action",
    title: `关闭连接 ${target.label}`,
    detail: `只会断开这一条活动代理连接，其他连接不受影响；该连接流量 ${formatConnectionBytes(target.totalBytes)}。`,
    command: `api close <${target.id.slice(0, 8)}...>`,
    run: () => runConnectionAction(`api close ${shellQuote(target.id)}`, "关闭单条连接")
  };
}

function cancelAction(): void {
  pendingAction.value = null;
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

function selectQuery(value: string): void {
  query.value = value;
  copied.value = false;
  pendingAction.value = null;
}

onMounted(() => {
  void refreshConnections();
});
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Unplug :size="17" /> 活动连接</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
          {{ snapshot ? `${snapshot.connections.length} 条连接 · ${formatConnectionBytes(totalBytes)}` : rawOutput || "读取 sing-box API 连接列表。" }}
        </p>
      </div>
      <div class="flex gap-2">
        <Button size="sm" variant="outline" :loading="isRunning('connections-refresh')" @click="refreshConnections">
          <RefreshCw :size="15" />刷新
        </Button>
        <Button size="sm" variant="secondary" :disabled="!snapshot" @click="copyReport">
          <Copy :size="15" />{{ copied ? "已复制" : "复制" }}
        </Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <Input v-model="query" placeholder="按域名、应用、来源、规则、链路过滤" spellcheck="false" />
      <span class="inline-flex items-center gap-1 text-sm text-[var(--mn-ink-muted)]"><Search :size="15" />{{ filtered.length }} 命中</span>
    </div>

    <div v-if="snapshot" class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">代理连接</p>
        <p class="mt-1 text-lg font-semibold text-[var(--mn-ink)]">{{ flowSummary.proxied }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">直连/绕过</p>
        <p class="mt-1 text-lg font-semibold text-[var(--mn-ink)]">{{ flowSummary.direct }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">阻断/拒绝</p>
        <p class="mt-1 text-lg font-semibold text-[var(--mn-ink)]">{{ flowSummary.blocked }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">未知流向</p>
        <p class="mt-1 text-lg font-semibold text-[var(--mn-ink)]">{{ flowSummary.unknown }}</p>
      </div>
    </div>

    <div v-if="snapshot" class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
      <div
        v-for="item in insights"
        :key="item.label"
        class="rounded-md border p-3"
        :class="{
          'mn-tone-ok': item.tone === 'success',
          'mn-tone-warn': item.tone === 'warning',
          'border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))]': item.tone === 'danger',
          'border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)]': item.tone === 'neutral',
        }"
      >
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ item.label }}</p>
        <p class="mt-1 text-base font-semibold text-[var(--mn-ink)]">{{ item.value }}</p>
        <p class="mt-1 truncate text-xs text-[var(--mn-ink-muted)]">{{ item.detail }}</p>
      </div>
    </div>

    <div v-if="pendingAction" class="mn-panel-warn rounded-md p-3">
      <p class="text-sm font-semibold text-[var(--mn-warning)]">{{ pendingAction.title }}</p>
      <p class="mt-1 text-sm leading-6 text-[var(--mn-warning)]/80">{{ pendingAction.detail }}</p>
      <code class="mt-2 block break-words rounded bg-[var(--mn-carrier-deep)]/50 p-2 text-xs text-[var(--mn-ink-soft)]">{{ pendingAction.command }}</code>
      <div class="mt-3 grid gap-2 sm:grid-cols-2">
        <Button size="sm" variant="secondary" :loading="isRunning(pendingAction.key)" @click="confirmAction">确认执行</Button>
        <Button size="sm" variant="outline" @click="cancelAction">取消</Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-[8rem_minmax(0,1fr)_minmax(0,1fr)_minmax(0,1fr)]">
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
        Top N (1-8)
        <Input v-model="closeTopCount" inputmode="numeric" placeholder="3" />
      </label>
      <Button variant="outline" :disabled="!snapshot?.connections.length" @click="requestCloseTop">
        关闭 Top {{ closeTopN }}
      </Button>
      <Button variant="outline" :disabled="!query.trim() || !filtered.length" @click="requestCloseMatched">
        关闭命中连接
      </Button>
      <Button variant="outline" :disabled="!snapshot?.connections.length" @click="requestCloseAll">
        关闭全部
      </Button>
    </div>

    <div v-if="snapshot" class="rounded-md border p-3 text-sm leading-6" :class="connectionClosePlanTone(topClosePlan.status)">
      <p class="font-semibold">{{ topClosePlan.title }}</p>
      <p class="mt-1 text-xs opacity-80">
        Top {{ closeTopN }} 会影响 {{ topClosePlan.targetCount }} / {{ topClosePlan.totalCount }} 条连接，约 {{ topClosePlan.sharePercent }}% 当前流量。
      </p>
    </div>

    <div v-if="processBuckets.length || ruleBuckets.length || chainBuckets.length" class="grid gap-2 md:grid-cols-3">
      <div v-if="processBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-[var(--mn-ink-muted)]">应用热点</p>
        <button
          v-for="bucket in processBuckets"
          :key="`process-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-[var(--mn-ink-soft)]">{{ bucket.name }}</span>
          <span class="text-[var(--mn-ink-muted)]">{{ bucket.count }} · {{ formatConnectionBytes(bucket.bytes) }}</span>
        </button>
      </div>
      <div v-if="ruleBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-[var(--mn-ink-muted)]">规则热点</p>
        <button
          v-for="bucket in ruleBuckets"
          :key="`rule-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-[var(--mn-ink-soft)]">{{ bucket.name }}</span>
          <span class="text-[var(--mn-ink-muted)]">{{ bucket.count }} · {{ formatConnectionBytes(bucket.bytes) }}</span>
        </button>
      </div>
      <div v-if="chainBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-[var(--mn-ink-muted)]">链路热点</p>
        <button
          v-for="bucket in chainBuckets"
          :key="`chain-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-[var(--mn-ink-soft)]">{{ bucket.name }}</span>
          <span class="text-[var(--mn-ink-muted)]">{{ bucket.count }} · {{ formatConnectionBytes(bucket.bytes) }}</span>
        </button>
      </div>
    </div>

    <div v-if="visibleConnections.length" class="grid max-h-[34rem] gap-2 overflow-auto pr-1">
      <div
        v-for="item in visibleConnections"
        :key="item.id"
        class="grid gap-1 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2"
      >
        <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-2">
          <span class="truncate text-sm font-semibold text-[var(--mn-ink)]">{{ item.label }}</span>
          <span class="text-xs text-[var(--mn-ink-muted)]">{{ formatConnectionBytes(item.totalBytes) }}</span>
          <Button size="sm" variant="ghost" :disabled="isRunning('connections-action')" @click="requestCloseOne(item)">关闭</Button>
        </div>
        <p class="truncate text-xs text-[var(--mn-ink-muted)]">{{ item.detail }}</p>
        <p v-if="item.process || item.source" class="truncate text-xs text-[var(--mn-ink-muted)]">
          {{ [item.process, item.source].filter(Boolean).join(" · ") }}
        </p>
        <p class="text-xs text-[var(--mn-ink-muted)]">↑ {{ formatConnectionBytes(item.upload) }} / ↓ {{ formatConnectionBytes(item.download) }}</p>
      </div>
    </div>
    <p v-else class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-sm text-[var(--mn-ink-muted)]">
      {{ snapshot ? "没有匹配的活动连接。" : "还没有连接数据。" }}
    </p>
  </Card>
</template>
