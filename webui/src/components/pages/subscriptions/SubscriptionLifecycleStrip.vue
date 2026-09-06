<script setup lang="ts">
import { t } from "@/i18n";
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
  empty: t("等待首次配置"),
  idle: t("订阅已配置"),
  running: t("正在应用或刷新"),
  done: t("最近一次成功"),
  error: t("最近一次失败"),
  timeout: t("后台待对账"),
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
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">{{ t("生命周期") }}</span>
    <div class="mt-2 flex items-center gap-2">
      <span :class="['size-2 rounded-full', lifecycleDotClass, lifecycleStatus === 'running' ? 'motion-safe:animate-pulse' : '']" />
      <strong class="truncate text-sm text-[var(--mn-ink)]">{{ lifecycleLabel }}</strong>
    </div>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">{{ t("来源 / 缓存") }}</span>
    <p class="mt-2 text-sm text-[var(--mn-ink-soft)]"><strong class="text-[var(--mn-ink)]">{{ state.subscriptions.configuredCount }}</strong> {{ t("来源 · {value} ·", { value: state.subscriptions.sourceMode === 'local' ? t("本地") : 'URL' }) }} <strong class="text-[var(--mn-ink)]">{{ state.subscriptions.cacheCount }}</strong> {{ t("缓存") }}</p>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">{{ t("最近结果") }}</span>
    <p class="mt-2 truncate text-sm text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastResult }} · {{ state.subscriptions.lastPhase }}</p>
  </div>
  <div class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-4 py-3.5">
    <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">{{ t("自动刷新") }}</span>
    <p class="mt-2 text-sm" :class="state.subscriptions.scheduleOwnerValid ? 'text-[var(--mn-ink-soft)]' : 'text-[var(--mn-warning)]'">
      {{ state.subscriptions.scheduleEnabled ? t("{value} 小时", { value: state.subscriptions.scheduleIntervalHours }) : t("关闭") }} · {{ state.subscriptions.scheduleRunning ? t("运行中") : t("已停止") }}
    </p>
  </div>
</template>
