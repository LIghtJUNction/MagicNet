<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, Gauge, RefreshCw, Zap } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { buildNodeDelayStats, formatNodeDelayReport, nodeDelayQualityLabel, parseCurrentNode, parseNodeTestAll, sanitizeNodeText, type NodeDelayEntry } from "@/composables/nodeDelayParsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, shellQuote } from "@/utils";

type PendingNodeAction = {
  node: NodeDelayEntry;
  run: () => Promise<void>;
};

const { runCli, state } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const rawOutput = ref("");
const currentNode = ref("");
const copied = ref(false);
const pendingAction = ref<PendingNodeAction | null>(null);

const entries = computed(() => parseNodeTestAll(rawOutput.value));
const stats = computed(() => buildNodeDelayStats(entries.value));

async function refreshCurrentNode(): Promise<void> {
  await withAction("node-current", async () => {
    currentNode.value = parseCurrentNode(await runCli("node current", "读取当前节点", true));
  });
}

async function testNodes(): Promise<void> {
  await withAction("node-delay-test-all", async () => {
    copied.value = false;
    pendingAction.value = null;
    rawOutput.value = await runCli("node test-all", "节点延迟批测");
  });
}

async function testAndPrepareFastest(): Promise<void> {
  await withAction("node-test-use-fastest", async () => {
    copied.value = false;
    pendingAction.value = null;
    const text = await runCli("node test-all", "测速并选择最快节点");
    rawOutput.value = text;
    const fastest = buildNodeDelayStats(parseNodeTestAll(text)).fastest;
    if (!fastest) {
      state.output = "测速完成，但没有可用节点可切换。";
      return;
    }
    pendingAction.value = {
      node: fastest,
      run: () => useNode(fastest.node)
    };
  });
}

async function copyReport(): Promise<void> {
  const report = formatNodeDelayReport(entries.value);
  copied.value = await copyText(report);
  state.output = copied.value ? "节点测速摘要已复制。" : "剪贴板不可用，节点测速摘要未复制。";
}

function requestUseFastest(): void {
  const node = stats.value.fastest;
  if (!node) return;
  pendingAction.value = {
    node,
    run: () => useNode(node.node)
  };
}

async function useNode(node: string): Promise<void> {
  await withAction("node-use-fastest", async () => {
    const text = await runCli(`node use ${shellQuote(node)}`, "切换到最快节点");
    state.output = text;
    currentNode.value = parseCurrentNode(await runCli("node current", "读取当前节点", true));
  });
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

function delayLabel(value: number | null): string {
  return value === null ? "无" : `${value}ms`;
}

onMounted(() => {
  void refreshCurrentNode();
});
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Gauge :size="17" /> 节点延迟批测</h3>
        <p class="mt-1 text-sm leading-6 text-zinc-400">
          真实调用 <code>node test-all</code>，默认测试当前解析到的前 16 个节点。
        </p>
        <p class="mt-1 truncate text-xs text-zinc-500">当前：{{ currentNode ? sanitizeNodeText(currentNode) : "未读取" }}</p>
      </div>
      <div class="flex gap-2">
        <Button size="sm" :loading="isRunning('node-delay-test-all')" @click="testNodes">
          <RefreshCw :size="15" />开始测速
        </Button>
        <Button size="sm" variant="secondary" :loading="isRunning('node-test-use-fastest')" @click="testAndPrepareFastest">
          <Zap :size="15" />测速选最快
        </Button>
        <Button size="sm" variant="secondary" :disabled="!entries.length" @click="copyReport">
          <Copy :size="15" />{{ copied ? "已复制" : "复制" }}
        </Button>
      </div>
    </div>

    <div v-if="pendingAction" class="rounded-md border border-amber-400/30 bg-amber-500/10 p-3">
      <p class="text-sm font-semibold text-amber-100">切换到最快节点</p>
      <p class="mt-1 text-sm leading-6 text-amber-100/80">
        将把 proxy selector 切换到 {{ sanitizeNodeText(pendingAction.node.node) }}，当前连接可能重新选择出站。
      </p>
      <code class="mt-2 block rounded bg-black/50 p-2 text-xs text-amber-50">node use &lt;fastest-node&gt;</code>
      <div class="mt-3 grid gap-2 sm:grid-cols-2">
        <Button size="sm" variant="secondary" :loading="isRunning('node-use-fastest')" @click="confirmAction">确认切换</Button>
        <Button size="sm" variant="outline" @click="cancelAction">取消</Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">已测</p>
        <p class="text-lg font-semibold text-zinc-100">{{ stats.tested }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">可用</p>
        <p class="text-lg font-semibold text-zinc-100">{{ stats.usable }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">失败</p>
        <p class="text-lg font-semibold text-zinc-100">{{ stats.failed }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">平均</p>
        <p class="text-lg font-semibold text-zinc-100">{{ delayLabel(stats.averageMillis) }}</p>
      </div>
    </div>

    <div v-if="stats.fastest || stats.slowest" class="grid gap-2 sm:grid-cols-2">
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">最快</p>
        <p class="mt-1 truncate text-sm text-zinc-100">{{ stats.fastest ? sanitizeNodeText(stats.fastest.node) : "无" }}</p>
        <p class="text-xs text-lime-300">{{ stats.fastest?.summary || "" }}</p>
        <Button
          v-if="stats.fastest"
          class="mt-3"
          size="sm"
          variant="secondary"
          :disabled="stats.fastest.node === currentNode"
          @click="requestUseFastest"
        >
          <Zap :size="15" />{{ stats.fastest.node === currentNode ? "当前已使用" : "使用最快" }}
        </Button>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">最慢</p>
        <p class="mt-1 truncate text-sm text-zinc-100">{{ stats.slowest ? sanitizeNodeText(stats.slowest.node) : "无" }}</p>
        <p class="text-xs text-amber-300">{{ stats.slowest?.summary || "" }}</p>
      </div>
    </div>

    <div v-if="entries.length" class="grid max-h-80 gap-2 overflow-auto pr-1">
      <div
        v-for="entry in entries"
        :key="entry.node"
        class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2"
      >
        <div class="min-w-0">
          <p class="truncate text-sm font-semibold text-zinc-100">{{ sanitizeNodeText(entry.node) }}</p>
          <p class="text-xs text-zinc-500">{{ sanitizeNodeText(entry.summary) }}</p>
        </div>
        <span class="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-300">
          {{ nodeDelayQualityLabel(entry.quality) }}
        </span>
      </div>
    </div>
    <pre v-else-if="rawOutput" class="max-h-48 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-300 whitespace-pre-wrap">{{ rawOutput }}</pre>
  </Card>
</template>
