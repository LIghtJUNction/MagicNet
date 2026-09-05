<script setup lang="ts">
import { computed } from "vue";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  isSubscriptionBackgroundArgs,
  subscriptionLifecycleRunning,
} from "@/composables/backgroundTasks";

const props = defineProps<{
  configured: boolean;
}>();

const { state } = useMagicNet();

const lifecycleStatus = computed(() => {
  if (subscriptionLifecycleRunning(state.backgroundTask, state.subscriptions.updateRunning)) return "running";
  if (state.backgroundTask.status === "timeout" && isSubscriptionBackgroundArgs(state.backgroundTask.args)) return "timeout";
  if (state.subscriptions.lastResult === "success") return "done";
  if (["failed", "interrupted"].includes(state.subscriptions.lastResult)) return "error";
  return props.configured ? "idle" : "empty";
});

function formatEpoch(epoch: number): string {
  if (!epoch) return "尚无记录";
  return new Date(epoch * 1000).toLocaleString([], {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

const resultLabel = computed(() => ({
  running: "更新中", done: "更新成功", error: "更新未完成", timeout: "等待确认", idle: "尚未更新", empty: "尚未添加订阅",
}[lifecycleStatus.value]));
</script>

<template>
  <div class="update-record">
    <dl>
      <div><dt>更新结果</dt><dd>{{ resultLabel }}</dd></div>
      <div><dt>最近尝试</dt><dd>{{ formatEpoch(state.subscriptions.lastAttemptEpoch) }}</dd></div>
      <div><dt>最近成功</dt><dd>{{ formatEpoch(state.subscriptions.lastSuccessEpoch) }}</dd></div>
      <div><dt>导入节点</dt><dd>{{ state.subscriptions.lastImportedCount }} 个<span v-if="state.subscriptions.lastSkippedCount"> · 跳过 {{ state.subscriptions.lastSkippedCount }} 个</span></dd></div>
    </dl>
    <p v-if="lifecycleStatus === 'timeout'" role="status">日志跟踪已结束，后台任务仍可能运行。重新读取状态可确认结果。</p>
    <p v-if="lifecycleStatus === 'error'" role="status">{{ state.subscriptions.lastReason === 'none' ? '请重试更新，或到诊断页查看原因。' : state.subscriptions.lastReason }}</p>
  </div>
</template>

<style scoped>
.update-record { padding: 0 0 20px; }
dl { margin: 0; font-size: .875rem; }
dl > div { display: flex; justify-content: space-between; gap: 24px; padding: 9px 0; }
dt { flex-shrink: 0; color: var(--mn-ink-muted); }
dd { margin: 0; text-align: right; overflow-wrap: anywhere; color: var(--mn-ink-soft); font-variant-numeric: tabular-nums; }
p { margin: 12px 0 0; color: var(--mn-warning); font-size: .875rem; line-height: 1.65; }
</style>
