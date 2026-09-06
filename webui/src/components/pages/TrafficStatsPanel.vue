<script setup lang="ts">
import { locale, t } from "@/i18n";
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from "vue";
import { Activity, Bell, Copy, Gauge, Pause, Play, RefreshCw, Trash2 } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { buildTrafficStatsSummary, evaluateTrafficAlert, formatTrafficStatsReport, parseTrafficSample, type TrafficSample } from "@/composables/trafficStatsParsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import { buildTrafficBudgetPlan } from "./trafficBudgetPlan";
import { evaluateTrafficSamplingHealth } from "./trafficSamplingHealth";

const { runCli, state } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const samples = ref<TrafficSample[]>([]);
const lastOutput = ref("");
const lastFailure = ref("");
const failedSamples = ref(0);
const copied = ref(false);
const autoSampling = ref(false);
const thresholdMiB = ref("10");
const budgetGiB = ref("");
const budgetHorizonMinutes = ref("60");
const nowMillis = ref(Date.now());
let timer = 0;
let clockTimer = 0;

const summary = computed(() => buildTrafficStatsSummary(samples.value));
const alert = computed(() => evaluateTrafficAlert(samples.value, Number(thresholdMiB.value) || 0));
const budgetPlan = computed(() => buildTrafficBudgetPlan(samples.value, budgetGiB.value, budgetHorizonMinutes.value));
const confidenceLabel = computed(() => ({ none: t("无"), low: t("低"), normal: t("正常") })[budgetPlan.value.confidence]);
const samplingHealth = computed(() => evaluateTrafficSamplingHealth(samples.value, failedSamples.value, autoSampling.value, nowMillis.value));
const trendSamples = computed(() => samples.value.slice(-12));
const trendPeak = computed(() => Math.max(1, ...trendSamples.value.map((sample) => sample.up + sample.down)));
const lastUpdated = computed(() => summary.value.latest ? new Date(summary.value.latest.timestampMillis).toLocaleTimeString(locale.value) : t("未采样"));
const latestTrendSeries = computed(() => {
  return trendSamples.value.map((sample, index) => {
    const previous = trendSamples.value[index - 1];
    const previousTotal = previous ? previous.up + previous.down : 0;
    const currentTotal = sample.up + sample.down;
    return {
      sample,
      indexLabel: samples.value.length - trendSamples.value.length + index + 1,
      deltaTotal: previous ? currentTotal - previousTotal : null,
      deltaIntervalMillis: previous ? Math.max(0, sample.timestampMillis - previous.timestampMillis) : 0
    };
  });
});
const latestTrendDelta = computed(() => {
  const last = latestTrendSeries.value.at(-1);
  return last?.deltaTotal || 0;
});
const latestTrendDirection = computed(() => {
  if (latestTrendSeries.value.length < 2) return t("暂无对比");
  if (latestTrendDelta.value > 0) return t("总速率上升");
  if (latestTrendDelta.value < 0) return t("总速率下降");
  return t("持平");
});
const latestTrendColor = computed(() => {
  if (latestTrendSeries.value.length < 2) return "text-[var(--mn-ink-soft)]";
  if (latestTrendDelta.value > 0) return "text-[var(--mn-success)]";
  if (latestTrendDelta.value < 0) return "text-[var(--mn-danger)]";
  return "text-[var(--mn-ink-muted)]";
});
const trendWindowPeakTotal = computed(() => {
  return Math.max(0, ...trendSamples.value.map((sample) => sample.up + sample.down));
});
const peakTime = computed(() => summary.value.peakTotalTimestampMillis
  ? new Date(summary.value.peakTotalTimestampMillis).toLocaleTimeString(locale.value)
  : t("无"));

async function sampleNow(quiet = false): Promise<void> {
  await withAction("traffic-stats-sample", async () => {
    nowMillis.value = Date.now();
    const text = await runCli("api stats", t("读取实时流量"), quiet);
    lastOutput.value = text;
    const sample = parseTrafficSample(text);
    if (!sample) {
      failedSamples.value += 1;
      lastFailure.value = text || t("api stats 没有返回可解析的流量样本。");
      if (failedSamples.value >= 3) {
        autoSampling.value = false;
        stopTimer();
      }
      if (!quiet) state.output = text || t("api stats 没有返回可解析的流量样本。");
      return;
    }
    failedSamples.value = 0;
    lastFailure.value = "";
    samples.value = [...samples.value, sample].slice(-36);
    copied.value = false;
  });
}

function startTimer(): void {
  stopTimer();
  timer = window.setInterval(() => {
    if (!isRunning("traffic-stats-sample")) void sampleNow(true);
  }, 5000);
}

function toggleAutoSampling(): void {
  autoSampling.value = !autoSampling.value;
  if (!autoSampling.value) {
    stopTimer();
    return;
  }
  void sampleNow(true);
  startTimer();
}

function clearSamples(): void {
  samples.value = [];
  failedSamples.value = 0;
  lastFailure.value = "";
  copied.value = false;
}

async function copyReport(): Promise<void> {
  const text = [
    formatTrafficStatsReport(samples.value, alert.value, samplingHealth.value),
    "",
    "[budget_projection]",
    ...budgetPlan.value.reportLines
  ].join("\n");
  copied.value = await copyText(text);
  state.output = copied.value ? t("实时流量报告已复制。") : t("剪贴板不可用，实时流量报告未复制。");
}

function stopTimer(): void {
  if (!timer) return;
  window.clearInterval(timer);
  timer = 0;
}

function formatRate(value: number): string {
  return `${formatBytes(value)}/s`;
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

function sampleWidth(value: number): string {
  return `${Math.max(2, Math.round((value / trendPeak.value) * 100))}%`;
}

function formatSampleTime(timestampMillis: number): string {
  return new Date(timestampMillis).toLocaleTimeString(locale.value);
}

function formatTrendBadge(delta: number | null): string {
  if (delta === null) return t("起点");
  if (delta > 0) return `+${formatRate(delta)}`;
  if (delta < 0) return `-${formatRate(Math.abs(delta))}`;
  return "±0";
}

function trendBadgeClass(delta: number | null): string {
  if (delta === null) return "text-[var(--mn-ink-muted)]";
  if (delta > 0) return "text-[var(--mn-success)]";
  if (delta < 0) return "text-[var(--mn-warning)]";
  return "text-[var(--mn-ink-muted)]";
}

function upShare(sample: TrafficSample | null): string {
  const total = (sample?.up || 0) + (sample?.down || 0);
  return total > 0 ? `${Math.round(((sample?.up || 0) / total) * 100)}%` : "0%";
}

function alertClasses(): string {
  if (alert.value.level === "danger") return "border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]";
  if (alert.value.level === "warning") return "mn-tone-warn";
  if (alert.value.level === "ok") return "border-[color-mix(in_srgb,var(--mn-cactus)_50%,transparent)] bg-[color-mix(in_srgb,var(--mn-cactus)_35%,var(--mn-carrier))] text-[var(--mn-success)]";
  return "border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] text-[var(--mn-ink-soft)]";
}

function healthClasses(): string {
  if (samplingHealth.value.level === "danger") return "border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]";
  if (samplingHealth.value.level === "warning") return "mn-tone-warn";
  if (samplingHealth.value.level === "ok") return "mn-tone-ok";
  return "border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] text-[var(--mn-ink-soft)]";
}

function budgetClasses(): string {
  if (budgetPlan.value.level === "danger") return "border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]";
  if (budgetPlan.value.level === "warning") return "mn-tone-warn";
  if (budgetPlan.value.level === "ok") return "border-[color-mix(in_srgb,var(--mn-heather)_60%,transparent)] bg-[color-mix(in_srgb,var(--mn-heather)_40%,var(--mn-carrier))] text-[var(--mn-info)]";
  return "border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] text-[var(--mn-ink-soft)]";
}

function formatDuration(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return t("无预测");
  if (seconds < 60) return `${Math.max(1, Math.round(seconds))}s`;
  const minutes = seconds / 60;
  if (minutes < 60) return `${Math.round(minutes)}min`;
  const hours = minutes / 60;
  if (hours < 48) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

function startClock(): void {
  // Idempotent: under <KeepAlive> both onMounted and onActivated fire on the
  // first mount, and an overwritten handle would leak an unclearable interval.
  stopClock();
  clockTimer = window.setInterval(() => {
    nowMillis.value = Date.now();
  }, 15000);
}

function stopClock(): void {
  if (!clockTimer) return;
  window.clearInterval(clockTimer);
  clockTimer = 0;
}

onMounted(startClock);
// Under <KeepAlive> a tab switch deactivates (not unmounts) this panel; stop
// both the sampling loop (which fires root `api stats` and writes global state)
// and the clock while off-screen, and restart them on return.
onDeactivated(() => {
  stopTimer();
  stopClock();
});
onActivated(() => {
  startClock();
  if (autoSampling.value) startTimer();
});
onUnmounted(() => {
  stopTimer();
  stopClock();
});
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Activity :size="17" /> {{ t("实时流量") }}</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]"> {{ t("调用 api stats 读取 sing-box 当前上下行速率。") }} </p>
        <p class="mt-1 text-xs text-[var(--mn-ink-muted)]"> {{ t("更新：") }}{{ lastUpdated }} {{ t("· 来源：") }}{{ summary.latest?.source || t("无") }} {{ summary.latest?.sourceKey || "" }} {{ t("· 窗口") }} {{ Math.round(summary.windowMillis / 1000) }}s
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" :loading="isRunning('traffic-stats-sample')" @click="sampleNow(false)">
          <RefreshCw :size="15" />{{ t("采样") }} </Button>
        <Button size="sm" variant="secondary" @click="toggleAutoSampling">
          <Pause v-if="autoSampling" :size="15" />
          <Play v-else :size="15" />{{ autoSampling ? t("暂停") : t("自动") }}
        </Button>
      </div>
    </div>

    <div class="grid gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 sm:grid-cols-[minmax(0,1fr)_9rem] sm:items-end">
      <div class="min-w-0">
        <p class="inline-flex items-center gap-2 text-sm font-semibold text-[var(--mn-ink)]"><Bell :size="15" /> {{ t("流量告警") }}</p>
        <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]"> {{ t("基于真实样本的上行+下行总速率判断，连续 3 个样本超阈值会标为严重。") }} </p>
      </div>
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]"> {{ t("阈值 MiB/s") }} <Input v-model="thresholdMiB" inputmode="decimal" placeholder="10" />
      </label>
    </div>

    <div class="rounded-md border p-3 text-sm leading-6" :class="alertClasses()">
      {{ alert.message }} {{ t("当前") }} {{ formatRate(alert.latestTotal) }} {{ t("· 阈值") }} {{ formatRate(alert.thresholdBytesPerSecond) }}
    </div>

    <div class="rounded-md border p-3 text-sm leading-6" :class="healthClasses()">
      <p class="font-semibold">{{ samplingHealth.label }}</p>
      <p class="mt-1 text-xs opacity-80">
        {{ samplingHealth.detail }} {{ t("· 样本") }} {{ samplingHealth.sampleCount }} {{ t("· 连续失败") }} {{ samplingHealth.consecutiveFailures }}
        <span v-if="samplingHealth.latestAgeSeconds !== null"> {{ t("· 最近样本 {seconds}s 前", { seconds: samplingHealth.latestAgeSeconds }) }}</span>
      </p>
    </div>

    <div class="rounded-md border p-3" :class="budgetClasses()">
      <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_8rem_8rem] md:items-end">
        <div class="min-w-0">
          <p class="inline-flex items-center gap-2 text-sm font-semibold"><Gauge :size="15" /> {{ t("流量预算预测") }}</p>
          <p class="mt-1 text-xs leading-5 opacity-80">
            {{ budgetPlan.detail }} {{ t("· 置信度 {confidence} · 基于 {count} 个真实样本", { confidence: confidenceLabel, count: summary.sampleCount }) }} </p>
        </div>
        <label class="grid gap-1 text-xs opacity-80"> {{ t("剩余 GiB") }} <Input v-model="budgetGiB" inputmode="decimal" :placeholder="t('例如 20')" />
        </label>
        <label class="grid gap-1 text-xs opacity-80"> {{ t("预测分钟") }} <Input v-model="budgetHorizonMinutes" inputmode="numeric" placeholder="60" />
        </label>
      </div>
      <div class="mt-3 grid gap-2 sm:grid-cols-3">
        <div class="rounded bg-[var(--mn-carrier-deep)]/25 p-2">
          <p class="text-xs opacity-70">{{ t("预计消耗") }}</p>
          <p class="mt-1 text-sm font-semibold">{{ formatBytes(budgetPlan.projectedBytes) }}</p>
        </div>
        <div class="rounded bg-[var(--mn-carrier-deep)]/25 p-2">
          <p class="text-xs opacity-70">{{ t("预算后剩余") }}</p>
          <p class="mt-1 text-sm font-semibold">{{ formatBytes(budgetPlan.remainingBytes) }}</p>
        </div>
        <div class="rounded bg-[var(--mn-carrier-deep)]/25 p-2">
          <p class="text-xs opacity-70">{{ t("按均速可用") }}</p>
          <p class="mt-1 text-sm font-semibold">{{ formatDuration(budgetPlan.timeToBudgetSeconds) }}</p>
        </div>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("当前上传") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ formatRate(summary.latest?.up || 0) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("当前下载") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ formatRate(summary.latest?.down || 0) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("平均总速率") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ formatRate(summary.averageUp + summary.averageDown) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("样本") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ summary.sampleCount }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("最近 12 峰值总速率") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ formatRate(trendWindowPeakTotal) }}</p>
        <p class="mt-1 text-xs text-[var(--mn-ink-muted)]">{{ t("峰值时间") }} {{ peakTime }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("最近变化") }}</p>
        <p class="text-lg font-semibold" :class="latestTrendColor">{{ latestTrendDirection }}</p>
        <p class="mt-1 text-xs text-[var(--mn-ink-muted)]">{{ formatRate(Math.abs(latestTrendDelta)) }}</p>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-2">
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("峰值上传") }}</p>
        <p class="mt-1 text-sm text-[var(--mn-ink)]">{{ formatRate(summary.peakUp) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("峰值下载") }}</p>
        <p class="mt-1 text-sm text-[var(--mn-ink)]">{{ formatRate(summary.peakDown) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("上传占比") }}</p>
        <p class="mt-1 text-sm text-[var(--mn-ink)]">{{ upShare(summary.latest) }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("连续失败") }}</p>
        <p class="mt-1 text-sm text-[var(--mn-ink)]">{{ failedSamples }}</p>
      </div>
    </div>

    <div v-if="lastFailure" class="mn-panel-warn rounded-md p-3 text-sm leading-6 text-[var(--mn-warning)]/85"> {{ t("最近一次采样未解析：") }}{{ lastFailure.slice(0, 220) }}
    </div>

    <div v-if="trendSamples.length" class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
      <div class="mb-2 flex items-center justify-between gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-[var(--mn-ink-muted)]">{{ t("最近趋势") }}</p>
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("最多 12 个真实样本") }}</p>
      </div>
      <div class="grid gap-2">
        <div v-for="sample in latestTrendSeries" :key="`${sample.sample.timestampMillis}-${sample.indexLabel}`" class="grid grid-cols-[2.25rem_4.75rem_minmax(0,1fr)_5rem] items-center gap-2">
          <span class="text-xs text-[var(--mn-ink-faint)]">#{{ sample.indexLabel }}</span>
          <span class="text-xs text-[var(--mn-ink-muted)]">{{ formatSampleTime(sample.sample.timestampMillis) }}</span>
          <div class="grid min-w-0 gap-1">
            <div class="h-2 rounded bg-[var(--mn-carrier)]">
              <div class="h-2 rounded bg-[var(--mn-cactus)]" :style="{ width: sampleWidth(sample.sample.up) }" />
            </div>
            <div class="h-2 rounded bg-[var(--mn-carrier)]">
              <div class="h-2 rounded bg-cyan-400" :style="{ width: sampleWidth(sample.sample.down) }" />
            </div>
          </div>
          <div class="text-right text-xs">
            <p class="text-[var(--mn-ink)]">{{ formatRate(sample.sample.up + sample.sample.down) }}</p>
            <p :class="trendBadgeClass(sample.deltaTotal)" class="mt-0.5">{{ formatTrendBadge(sample.deltaTotal) }}</p>
          </div>
        </div>
      </div>
    </div>

    <div class="flex flex-wrap gap-2">
      <Button size="sm" variant="outline" :disabled="!samples.length" @click="copyReport">
        <Copy :size="15" />{{ copied ? t("已复制") : t("复制报告") }}
      </Button>
      <Button size="sm" variant="ghost" :disabled="!samples.length" @click="clearSamples">
        <Trash2 :size="15" />{{ t("清空") }} </Button>
    </div>

    <pre v-if="!samples.length && lastOutput" class="max-h-40 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ lastOutput }}</pre>
  </Card>
</template>
