<script setup lang="ts">
import { DownloadCloud, RefreshCw } from "lucide-vue-next";
import { computed } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  isSubscriptionBackgroundArgs,
  subscriptionLifecycleRunning,
} from "@/composables/backgroundTasks";

const props = defineProps<{
  configured: boolean;
}>();

const { state, startBackgroundCli } = useMagicNet();
const { isRunning, withAction } = useActionLock();

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

async function updateAll(): Promise<void> {
  if (!props.configured) return;
  await withAction("update-all", async () => {
    await startBackgroundCli("sub update-all", "立即刷新订阅", "", "sub update-all");
  });
}
</script>

<template>
  <Card>
    <div class="flex items-center justify-between gap-3">
      <div>
        <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Lifecycle record</span>
        <h3 class="mt-1 text-base font-semibold text-[var(--mn-ink)]">应用与刷新</h3>
      </div>
      <DownloadCloud :size="18" :class="lifecycleStatus === 'running' ? 'motion-safe:animate-pulse text-[var(--mn-info)]' : 'text-[var(--mn-ink-faint)]'" />
    </div>

    <dl class="mt-4 grid grid-cols-2 gap-px rounded-md bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] p-px text-xs">
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-3"><dt class="text-[var(--mn-ink-faint)]">阶段</dt><dd class="mt-1 break-words text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastPhase }}</dd></div>
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-3"><dt class="text-[var(--mn-ink-faint)]">结果</dt><dd class="mt-1 break-words text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastResult }}</dd></div>
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-3"><dt class="text-[var(--mn-ink-faint)]">来源 / 导入</dt><dd class="mt-1 text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastSourceCount }} / {{ state.subscriptions.lastImportedCount }}</dd></div>
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-3"><dt class="text-[var(--mn-ink-faint)]">跳过 / 强身份缓存</dt><dd class="mt-1 text-[var(--mn-ink-soft)]">{{ state.subscriptions.lastSkippedCount }} / {{ state.subscriptions.cacheProvenanceCount }}</dd></div>
    </dl>
    <div v-if="lifecycleStatus === 'timeout'" class="mt-3 rounded-md bg-[var(--mn-oat)]/[0.055] p-3 text-xs leading-5 text-[var(--mn-warning)] ring-1 ring-[color-mix(in_srgb,var(--mn-oat)_45%,transparent)]">
      WebUI 只停止了日志跟踪，未判定设备侧任务失败。点击上方刷新按钮重新读取订阅阶段；完整过程仍可在“输出”的后台日志中核对。
    </div>
    <div class="mt-3 space-y-1 text-xs leading-5 text-[var(--mn-ink-muted)]">
      <p>尝试：{{ formatEpoch(state.subscriptions.lastAttemptEpoch) }}</p>
      <p>成功：{{ formatEpoch(state.subscriptions.lastSuccessEpoch) }}</p>
      <p class="break-words">原因：{{ state.subscriptions.lastReason }}</p>
      <p class="break-words">缓存来源：{{ state.subscriptions.cacheSource }}</p>
      <p class="truncate" :title="state.subscriptions.lastGenerationId">代次：{{ state.subscriptions.lastGenerationId }}</p>
    </div>
    <Button v-if="configured" variant="outline" class="mt-4 w-full" :loading="isRunning('update-all')" @click="updateAll">
      <RefreshCw :size="16" />立即刷新
    </Button>
  </Card>
</template>
