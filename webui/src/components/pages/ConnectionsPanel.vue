<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, RefreshCw, Search, Unplug } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { connectionBuckets, connectionMatchesQuery, parseConnectionSnapshot, type ConnectionTarget } from "@/composables/parsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, shellQuote } from "@/utils";

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
const pendingAction = ref<PendingConnectionAction | null>(null);

const snapshot = computed(() => parseConnectionSnapshot(rawOutput.value));
const filtered = computed(() => snapshot.value?.connections.filter((item) => connectionMatchesQuery(item, query.value)) || []);
const visibleConnections = computed(() => (query.value ? filtered.value : snapshot.value?.connections || []).slice(0, 10));
const ruleBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "rule"));
const chainBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "chain"));
const processBuckets = computed(() => connectionBuckets(snapshot.value?.connections || [], "process"));
const totalBytes = computed(() => (snapshot.value?.uploadTotal || 0) + (snapshot.value?.downloadTotal || 0));

async function refreshConnections(): Promise<void> {
  await withAction("connections-refresh", async () => {
    copied.value = false;
    rawOutput.value = await runCli("api conns", "读取活动连接");
  });
}

async function copyReport(): Promise<void> {
  const report = [
    "MagicNet active connections",
    `count=${snapshot.value?.count || 0}`,
    `upload=${formatBytes(snapshot.value?.uploadTotal || 0)}`,
    `download=${formatBytes(snapshot.value?.downloadTotal || 0)}`,
    query.value ? `query=${query.value}` : "",
    "",
    ...filtered.value.map((item) => `${item.label} ${formatBytes(item.totalBytes)} ${item.detail}`)
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
  pendingAction.value = {
    key: "connections-action",
    title: "关闭流量最高的 3 条连接",
    detail: "会断开当前传输量最高的活动代理连接，应用可能自动重连。",
    command: "api close-top 3",
    run: () => runConnectionAction("api close-top 3", "关闭 Top 连接")
  };
}

function requestCloseMatched(): void {
  const cleanQuery = query.value.trim();
  if (!cleanQuery || !filtered.value.length) return;
  pendingAction.value = {
    key: "connections-action",
    title: `关闭 ${filtered.value.length} 条匹配连接`,
    detail: "会按当前过滤条件断开命中的活动代理连接。",
    command: `api close-matching ${cleanQuery}`,
    run: () => runConnectionAction(`api close-matching ${shellQuote(cleanQuery)}`, "关闭匹配连接")
  };
}

function requestCloseAll(): void {
  const count = snapshot.value?.connections.length || 0;
  if (!count) return;
  pendingAction.value = {
    key: "connections-action",
    title: `关闭全部 ${count} 条活动连接`,
    detail: "会断开当前所有活动代理连接，正在使用网络的应用可能立即重连。",
    command: "api close-all",
    run: () => runConnectionAction("api close-all", "关闭全部连接")
  };
}

function requestCloseOne(target: ConnectionTarget): void {
  pendingAction.value = {
    key: "connections-action",
    title: `关闭连接 ${target.label}`,
    detail: `只会断开这一条活动代理连接，其他连接不受影响；该连接流量 ${formatBytes(target.totalBytes)}。`,
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

function formatBytes(value: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = Math.max(0, value);
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  return unit === 0 ? `${Math.round(amount)} ${units[unit]}` : `${amount.toFixed(1)} ${units[unit]}`;
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
        <p class="mt-1 text-sm leading-6 text-zinc-400">
          {{ snapshot ? `${snapshot.count} 条连接 · ${formatBytes(totalBytes)}` : rawOutput || "读取 sing-box API 连接列表。" }}
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
      <Input v-model="query" placeholder="按域名、规则、链路过滤" spellcheck="false" />
      <span class="inline-flex items-center gap-1 text-sm text-zinc-500"><Search :size="15" />{{ filtered.length }} 命中</span>
    </div>

    <div v-if="pendingAction" class="rounded-md border border-amber-400/30 bg-amber-500/10 p-3">
      <p class="text-sm font-semibold text-amber-100">{{ pendingAction.title }}</p>
      <p class="mt-1 text-sm leading-6 text-amber-100/80">{{ pendingAction.detail }}</p>
      <code class="mt-2 block break-words rounded bg-black/50 p-2 text-xs text-amber-50">{{ pendingAction.command }}</code>
      <div class="mt-3 grid gap-2 sm:grid-cols-2">
        <Button size="sm" variant="secondary" :loading="isRunning(pendingAction.key)" @click="confirmAction">确认执行</Button>
        <Button size="sm" variant="outline" @click="cancelAction">取消</Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-3">
      <Button variant="outline" :disabled="!snapshot?.connections.length" @click="requestCloseTop">
        关闭 Top 3
      </Button>
      <Button variant="outline" :disabled="!query.trim() || !filtered.length" @click="requestCloseMatched">
        关闭命中连接
      </Button>
      <Button variant="outline" :disabled="!snapshot?.connections.length" @click="requestCloseAll">
        关闭全部
      </Button>
    </div>

    <div v-if="processBuckets.length || ruleBuckets.length || chainBuckets.length" class="grid gap-2 md:grid-cols-3">
      <div v-if="processBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">应用热点</p>
        <button
          v-for="bucket in processBuckets"
          :key="`process-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-zinc-200">{{ bucket.name }}</span>
          <span class="text-zinc-500">{{ bucket.count }} · {{ formatBytes(bucket.bytes) }}</span>
        </button>
      </div>
      <div v-if="ruleBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">规则热点</p>
        <button
          v-for="bucket in ruleBuckets"
          :key="`rule-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-zinc-200">{{ bucket.name }}</span>
          <span class="text-zinc-500">{{ bucket.count }} · {{ formatBytes(bucket.bytes) }}</span>
        </button>
      </div>
      <div v-if="chainBuckets.length" class="grid gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">链路热点</p>
        <button
          v-for="bucket in chainBuckets"
          :key="`chain-${bucket.name}`"
          class="grid grid-cols-[minmax(0,1fr)_auto] rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 text-left text-sm"
          type="button"
          @click="selectQuery(bucket.query)"
        >
          <span class="truncate text-zinc-200">{{ bucket.name }}</span>
          <span class="text-zinc-500">{{ bucket.count }} · {{ formatBytes(bucket.bytes) }}</span>
        </button>
      </div>
    </div>

    <div v-if="visibleConnections.length" class="grid max-h-[34rem] gap-2 overflow-auto pr-1">
      <div
        v-for="item in visibleConnections"
        :key="item.id"
        class="grid gap-1 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2"
      >
        <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-2">
          <span class="truncate text-sm font-semibold text-zinc-100">{{ item.label }}</span>
          <span class="text-xs text-zinc-500">{{ formatBytes(item.totalBytes) }}</span>
          <Button size="sm" variant="ghost" :disabled="isRunning('connections-action')" @click="requestCloseOne(item)">关闭</Button>
        </div>
        <p class="truncate text-xs text-zinc-500">{{ item.detail }}</p>
        <p v-if="item.process || item.source" class="truncate text-xs text-zinc-500">
          {{ [item.process, item.source].filter(Boolean).join(" · ") }}
        </p>
        <p class="text-xs text-zinc-400">↑ {{ formatBytes(item.upload) }} / ↓ {{ formatBytes(item.download) }}</p>
      </div>
    </div>
    <p v-else class="rounded-md border border-zinc-800 bg-zinc-950 p-3 text-sm text-zinc-500">
      {{ snapshot ? "没有匹配的活动连接。" : "还没有连接数据。" }}
    </p>
  </Card>
</template>
