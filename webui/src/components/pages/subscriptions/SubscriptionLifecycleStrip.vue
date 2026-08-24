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

const lifecycleLabel = computed(() => ({
  empty: "等待首次配置",
  idle: "订阅已配置",
  running: "正在应用或刷新",
  done: "最近一次成功",
  error: "最近一次失败",
  timeout: "后台待对账",
}[lifecycleStatus.value] || lifecycleStatus.value));

const lifecycleTone = computed(() => {
  if (lifecycleStatus.value === "done" || lifecycleStatus.value === "idle") return "emerald";
  if (lifecycleStatus.value === "error") return "rose";
  if (lifecycleStatus.value === "timeout") return "amber";
  if (lifecycleStatus.value === "running") return "cyan";
  return "amber";
});

const lifecycleDotClass = computed(() => ({
  emerald: "bg-[var(--mn-cactus)]",
  rose: "bg-[var(--mn-clay)]",
  cyan: "bg-[var(--mn-heather)]",
  amber: "bg-[var(--mn-oat)]",
}[lifecycleTone.value]));
</script>

<template>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Lifecycle</span>
    <div class="mt-2 flex items-center gap-2">
      <span :class="['size-2 rounded-full', lifecycleDotClass, lifecycleStatus === 'running' ? 'motion-safe:animate-pulse' : '']" />
      <strong class="truncate text-sm text-[var(--mn-ink)]">{{ lifecycleLabel }}</strong>
    </div>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Sources / Cache</span>
    <p class="mt-2 text-sm text-[var(--mn-ink-soft)]"><strong class="text-[var(--mn-ink)]">{{ state.subscriptions.configuredCount }}</strong> 来源 · {{ state.subscriptions.sourceMode === 'local' ? '本地' : 'URL' }} · <strong class="text-[var(--mn-ink)]">{{ state.subscriptions.cacheCount }}</strong> 缓存</p>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Last result</span>
    <p class="mt-2 truncate text-sm text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastResult }} · {{ state.subscriptions.lastPhase }}</p>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Automatic refresh</span>
    <p class="mt-2 text-sm" :class="state.subscriptions.scheduleOwnerValid ? 'text-[var(--mn-ink-soft)]' : 'text-[var(--mn-warning)]'">
      {{ state.subscriptions.scheduleEnabled ? `${state.subscriptions.scheduleIntervalHours} 小时` : '关闭' }} · {{ state.subscriptions.scheduleRunning ? 'running' : 'stopped' }}
    </p>
  </div>
</template>
