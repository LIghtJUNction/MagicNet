<script setup lang="ts">
import { computed, ref } from "vue";
import { Copy, Gauge, RefreshCw, Zap } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import StatTile from "@/components/ui/StatTile.vue";
import { buildNodeDelayStats, formatNodeDelayReport, nodeDelayHealthText, nodeDelayQualityLabel, parseCurrentNode, parseNodeTestAll, sanitizeNodeText, type NodeDelayEntry } from "@/composables/nodeDelayParsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { useVisibilityTask } from "@/composables/useVisibilityTask";
import { copyText, execFailed, shellQuote } from "@/utils";
import { buildNodeSwitchPlan, formatNodeSwitchPlanReport, nodeSwitchPlanTone } from "./nodeSwitchPlan";

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
const healthText = computed(() => nodeDelayHealthText(stats.value));
const switchPlan = computed(() => buildNodeSwitchPlan(currentNode.value, entries.value));

async function refreshCurrentNode(): Promise<void> {
  await withAction("node-current", async () => {
    const text = await runCli("node current", "读取当前节点", true);
    if (execFailed(text)) {
      state.output = text;
      return;
    }
    currentNode.value = parseCurrentNode(text);
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
    if (execFailed(text)) return;
    rawOutput.value = text;
    const currentText = await runCli("node current", "读取当前节点", true);
    if (execFailed(currentText)) {
      state.output = currentText;
      return;
    }
    const latestCurrent = parseCurrentNode(currentText);
    currentNode.value = latestCurrent;
    const parsedEntries = parseNodeTestAll(text);
    const plan = buildNodeSwitchPlan(latestCurrent, parsedEntries);
    const fastest = buildNodeDelayStats(parsedEntries).fastest;
    if (!fastest || !plan.recommended) {
      state.output = `测速完成：${plan.detail}`;
      return;
    }
    pendingAction.value = {
      node: fastest,
      run: () => useNode(fastest.node)
    };
  });
}

async function copyReport(): Promise<void> {
  const report = `${formatNodeDelayReport(entries.value)}\n\n${formatNodeSwitchPlanReport(switchPlan.value)}`;
  copied.value = await copyText(report);
  state.output = copied.value ? "节点测速摘要已复制。" : "剪贴板不可用，节点测速摘要未复制。";
}

function requestUseFastest(): void {
  const node = stats.value.fastest;
  if (!node || !switchPlan.value.recommended) return;
  pendingAction.value = {
    node,
    run: () => useNode(node.node)
  };
}

async function useNode(node: string): Promise<void> {
  await withAction("node-use-fastest", async () => {
    const text = await runCli(`node use ${shellQuote(node)}`, "切换到最快节点");
    if (execFailed(text)) return;
    state.output = text;
    const currentText = await runCli("node current", "读取当前节点", true);
    if (execFailed(currentText)) {
      state.output = `节点已切换，但当前节点读取未确认：\n${currentText}`;
      return;
    }
    currentNode.value = parseCurrentNode(currentText);
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

const { target: visibilityTarget } = useVisibilityTask(refreshCurrentNode);
</script>

<template>
  <div ref="visibilityTarget" class="mn-deferred-region">
    <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Gauge :size="17" /> 节点延迟批测</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
          真实调用 <code>node test-all</code>，默认测试当前解析到的前 16 个节点。
        </p>
        <p class="mt-1 truncate text-xs text-[var(--mn-ink-muted)]">当前：{{ currentNode ? sanitizeNodeText(currentNode) : "未读取" }}</p>
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

    <ConfirmPanel
      v-if="pendingAction"
      title="切换到最快节点"
      :detail="`将把 proxy selector 切换到 ${sanitizeNodeText(pendingAction.node.node)}，当前连接可能重新选择出站。`"
      command="node use <fastest-node>"
      :loading="isRunning('node-use-fastest')"
      confirm-label="确认切换"
      confirm-variant="secondary"
      @cancel="cancelAction"
      @confirm="confirmAction"
    />

    <div v-if="entries.length" class="rounded-md border border-[color-mix(in_srgb,var(--mn-heather)_55%,transparent)] bg-[color-mix(in_srgb,var(--mn-heather)_40%,var(--mn-carrier))] p-3">
      <p class="text-sm font-semibold text-[var(--mn-info)]">测速健康摘要</p>
      <p class="mt-1 text-sm leading-6 text-[var(--mn-info)]">{{ healthText }}</p>
    </div>

    <div v-if="entries.length" class="rounded-md border p-3 text-sm leading-6" :class="nodeSwitchPlanTone(switchPlan.status)">
      <p class="font-semibold">{{ switchPlan.title }}</p>
      <p class="mt-1 text-xs opacity-80">{{ switchPlan.detail }}</p>
      <p class="mt-2 truncate text-xs opacity-80">
        当前 {{ switchPlan.currentNode ? sanitizeNodeText(switchPlan.currentNode) : '未读取' }} · 目标 {{ switchPlan.targetNode ? sanitizeNodeText(switchPlan.targetNode) : '无' }}
      </p>
    </div>

    <div class="grid gap-2 sm:grid-cols-5">
      <StatTile label="已测" :value="stats.tested" />
      <StatTile label="可用" :value="stats.usable" />
      <StatTile label="失败" :value="stats.failed" />
      <StatTile label="平均" :value="delayLabel(stats.averageMillis)" />
      <StatTile label="中位/解析可用率" :value="`${delayLabel(stats.medianMillis)} · ${stats.usablePercent}%`" />
    </div>

    <div v-if="stats.fastest || stats.slowest" class="grid gap-2 sm:grid-cols-2">
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">最快</p>
        <p class="mt-1 truncate text-sm text-[var(--mn-ink)]">{{ stats.fastest ? sanitizeNodeText(stats.fastest.node) : "无" }}</p>
        <p class="text-xs text-[var(--mn-success)]">{{ stats.fastest?.summary || "" }}</p>
        <Button
          v-if="stats.fastest"
          class="mt-3"
          size="sm"
          variant="secondary"
          :disabled="!switchPlan.recommended"
          @click="requestUseFastest"
        >
          <Zap :size="15" />{{ switchPlan.recommended ? "使用最快" : "不必切换" }}
        </Button>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">最慢</p>
        <p class="mt-1 truncate text-sm text-[var(--mn-ink)]">{{ stats.slowest ? sanitizeNodeText(stats.slowest.node) : "无" }}</p>
        <p class="text-xs text-[var(--mn-warning)]">{{ stats.slowest?.summary || "" }}</p>
      </div>
    </div>

    <div v-if="entries.length" class="grid max-h-80 gap-2 overflow-auto pr-1">
      <div
        v-for="entry in entries"
        :key="entry.node"
        class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2"
      >
        <div class="min-w-0">
          <p class="truncate text-sm font-semibold text-[var(--mn-ink)]">{{ sanitizeNodeText(entry.node) }}</p>
          <p class="text-xs text-[var(--mn-ink-muted)]">{{ sanitizeNodeText(entry.summary) }}</p>
        </div>
        <span class="rounded border border-[color-mix(in_srgb,var(--mn-ink)_14%,transparent)] px-2 py-1 text-xs text-[var(--mn-ink-soft)]">
          {{ nodeDelayQualityLabel(entry.quality) }}
        </span>
      </div>
    </div>
    <pre v-else-if="rawOutput" class="max-h-48 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ rawOutput }}</pre>
    </Card>
  </div>
</template>
