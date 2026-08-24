<script setup lang="ts">
import { AlertTriangle, Check, Clock3, Database } from "lucide-vue-next";
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
  if (!state.subscriptions.scheduleEnabled) return "自动刷新关闭。首次启用订阅不会改动此设置。";
  if (!state.subscriptions.scheduleOwnerValid) return "计划已保存，但后台 owner 状态不一致；请重新保存计划或检查输出。";
  if (state.subscriptions.scheduleRunning) return `后台刷新守护已就绪；每轮完成后按 ${state.subscriptions.scheduleIntervalHours} 小时间隔再次等待。`;
  return "计划已开启，但后台守护尚未就绪。";
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
    const result = await runCli(`sub schedule set ${scheduleValue.value}`, "保存自动刷新计划");
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
        <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Automatic refresh</span>
        <h3 class="mt-1 text-base font-semibold text-[var(--mn-ink)]">自动刷新计划</h3>
      </div>
    </div>

    <label class="mt-4 block text-xs font-medium text-[var(--mn-ink-muted)]" for="subscription-schedule">刷新间隔</label>
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
          enabled={{ state.subscriptions.scheduleEnabled ? 1 : 0 }} · running={{ state.subscriptions.scheduleRunning ? 1 : 0 }} · owner={{ state.subscriptions.scheduleOwner }}
        </span>
      </div>
      <p class="mt-2 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ scheduleMeaning }}</p>
    </div>

    <Button class="mt-4 w-full" :disabled="!scheduleChanged" :loading="isRunning('save-schedule')" @click="saveSchedule">
      <Clock3 :size="16" />保存自动刷新设置
    </Button>
  </Card>

  <div class="flex items-start gap-3 rounded-md bg-[color-mix(in_srgb,var(--mn-heather)_35%,var(--mn-carrier))] p-3 text-xs leading-5 text-[var(--mn-ink-muted)] ring-1 ring-[color-mix(in_srgb,var(--mn-heather)_40%,transparent)]">
    <Database :size="16" class="mt-0.5 shrink-0 text-[var(--mn-info)]" />
    <p>计划只表示刷新节奏，不承诺精确“下次时间”；系统休眠、重启或正在运行的任务都会影响实际触发时刻。</p>
  </div>
</template>
