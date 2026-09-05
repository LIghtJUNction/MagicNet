<script setup lang="ts">
import { AlertTriangle, Check, Clock3 } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { execFailed } from "@/utils";

type ScheduleValue = "off" | "12" | "24" | "48" | "72";

const { state, runCli, refreshSubs } = useMagicNet();
const { isRunning, withAction } = useActionLock();

const scheduleValue = ref<ScheduleValue>("off");
const scheduleDirty = ref(false);

const scheduleChanged = computed(() => scheduleValue.value !== state.subscriptions.scheduleIntervalHours);

const scheduleMeaning = computed(() => {
  if (!state.subscriptions.scheduleEnabled) return "按需手动更新订阅。";
  if (!state.subscriptions.scheduleOwnerValid) return "自动更新暂未正常启动，请重新保存设置。";
  if (state.subscriptions.scheduleRunning) return `每次更新完成后，间隔 ${state.subscriptions.scheduleIntervalHours} 小时再次更新。`;
  return "已开启，等待后台启动。";
});

watch(() => state.subscriptions.scheduleIntervalHours, (value) => {
  if (!scheduleDirty.value || value === scheduleValue.value) {
    scheduleValue.value = value as ScheduleValue;
    scheduleDirty.value = false;
  }
}, { immediate: true });

async function saveSchedule(): Promise<void> {
  if (!scheduleChanged.value) return;
  await withAction("save-schedule", async () => {
    const result = await runCli(`sub schedule set ${scheduleValue.value}`, "保存自动更新");
    if (execFailed(result)) return;
    await refreshSubs(true);
    scheduleDirty.value = false;
  });
}
</script>

<template>
  <Card>
    <div class="flex items-start gap-3">
      <Clock3 :size="18" class="mt-0.5 shrink-0 text-[var(--mn-ink-muted)]" />
      <div class="min-w-0">
        <h3 class="mt-1 text-base font-semibold text-[var(--mn-ink)]">自动更新</h3>
      </div>
    </div>

    <label class="mt-4 block text-xs font-medium text-[var(--mn-ink-muted)]" for="subscription-schedule">更新频率</label>
    <select
      id="subscription-schedule"
      v-model="scheduleValue"
      class="mt-2 min-h-11 w-full rounded-md bg-[var(--mn-ivory)] px-3 text-sm text-[var(--mn-ink)] outline-none ring-1 ring-inset ring-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] transition-[box-shadow,background-color] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus:bg-[var(--mn-ivory)] focus:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,transparent)]"
      @change="scheduleDirty = true"
    >
      <option value="off">关闭</option>
      <option value="12">每 12 小时</option>
      <option value="24">每 24 小时</option>
      <option value="48">每 48 小时</option>
      <option value="72">每 72 小时</option>
    </select>

    <div class="mt-3 rounded-md bg-[var(--mn-ivory)] p-3 ring-1 ring-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)]">
      <div class="flex items-center gap-2 text-xs">
        <Check v-if="state.subscriptions.scheduleOwnerValid" :size="15" class="text-[var(--mn-success)]" />
        <AlertTriangle v-else :size="15" class="text-[var(--mn-warning)]" />
        <span :class="state.subscriptions.scheduleOwnerValid ? 'text-[var(--mn-ink-soft)]' : 'text-[var(--mn-warning)]'">
          {{ !state.subscriptions.scheduleEnabled ? '手动更新' : state.subscriptions.scheduleRunning && state.subscriptions.scheduleOwnerValid ? '自动更新已开启' : '自动更新待确认' }}
        </span>
      </div>
      <p class="mt-2 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ scheduleMeaning }}</p>
    </div>

    <Button class="mt-4 w-full" :disabled="!scheduleChanged" :loading="isRunning('save-schedule')" @click="saveSchedule">
      <Clock3 :size="16" />保存更新设置
    </Button>
  </Card>

  <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">系统休眠、重启或正在执行的任务可能推迟自动更新。</p>
</template>
