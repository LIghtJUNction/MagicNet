<script setup lang="ts">
import { computed, onUnmounted, ref } from "vue";
import { Activity, Bell, Copy, Pause, Play, RefreshCw, Trash2 } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { buildTrafficStatsSummary, evaluateTrafficAlert, formatTrafficStatsReport, parseTrafficSample, type TrafficSample } from "@/composables/trafficStatsParsers";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { runCli, state } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const samples = ref<TrafficSample[]>([]);
const lastOutput = ref("");
const lastFailure = ref("");
const failedSamples = ref(0);
const copied = ref(false);
const autoSampling = ref(false);
const thresholdMiB = ref("10");
let timer = 0;

const summary = computed(() => buildTrafficStatsSummary(samples.value));
const alert = computed(() => evaluateTrafficAlert(samples.value, Number(thresholdMiB.value) || 0));
const trendSamples = computed(() => samples.value.slice(-12));
const trendPeak = computed(() => Math.max(1, ...trendSamples.value.map((sample) => sample.up + sample.down)));
const lastUpdated = computed(() => summary.value.latest ? new Date(summary.value.latest.timestampMillis).toLocaleTimeString() : "未采样");
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
  if (latestTrendSeries.value.length < 2) return "暂无对比";
  if (latestTrendDelta.value > 0) return "总速率上升";
  if (latestTrendDelta.value < 0) return "总速率下降";
  return "持平";
});
const latestTrendColor = computed(() => {
  if (latestTrendSeries.value.length < 2) return "text-zinc-300";
  if (latestTrendDelta.value > 0) return "text-lime-300";
  if (latestTrendDelta.value < 0) return "text-red-300";
  return "text-zinc-400";
});
const trendWindowPeakTotal = computed(() => {
  return Math.max(0, ...trendSamples.value.map((sample) => sample.up + sample.down));
});
const peakTime = computed(() => summary.value.peakTotalTimestampMillis
  ? new Date(summary.value.peakTotalTimestampMillis).toLocaleTimeString()
  : "无");

async function sampleNow(quiet = false): Promise<void> {
  await withAction("traffic-stats-sample", async () => {
    const text = await runCli("api stats", "读取实时流量", quiet);
    lastOutput.value = text;
    const sample = parseTrafficSample(text);
    if (!sample) {
      failedSamples.value += 1;
      lastFailure.value = text || "api stats 没有返回可解析的流量样本。";
      if (failedSamples.value >= 3) {
        autoSampling.value = false;
        stopTimer();
      }
      if (!quiet) state.output = text || "api stats 没有返回可解析的流量样本。";
      return;
    }
    failedSamples.value = 0;
    lastFailure.value = "";
    samples.value = [...samples.value, sample].slice(-36);
    copied.value = false;
  });
}

function toggleAutoSampling(): void {
  autoSampling.value = !autoSampling.value;
  if (!autoSampling.value) {
    stopTimer();
    return;
  }
  void sampleNow(true);
  timer = window.setInterval(() => {
    if (!isRunning("traffic-stats-sample")) void sampleNow(true);
  }, 5000);
}

function clearSamples(): void {
  samples.value = [];
  failedSamples.value = 0;
  lastFailure.value = "";
  copied.value = false;
}

async function copyReport(): Promise<void> {
  copied.value = await copyText(formatTrafficStatsReport(samples.value, alert.value));
  state.output = copied.value ? "实时流量报告已复制。" : "剪贴板不可用，实时流量报告未复制。";
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
  return new Date(timestampMillis).toLocaleTimeString();
}

function formatTrendBadge(delta: number | null): string {
  if (delta === null) return "起点";
  if (delta > 0) return `+${formatRate(delta)}`;
  if (delta < 0) return `-${formatRate(Math.abs(delta))}`;
  return "±0";
}

function trendBadgeClass(delta: number | null): string {
  if (delta === null) return "text-zinc-500";
  if (delta > 0) return "text-lime-300";
  if (delta < 0) return "text-amber-300";
  return "text-zinc-400";
}

function upShare(sample: TrafficSample | null): string {
  const total = (sample?.up || 0) + (sample?.down || 0);
  return total > 0 ? `${Math.round(((sample?.up || 0) / total) * 100)}%` : "0%";
}

function alertClasses(): string {
  if (alert.value.level === "danger") return "border-red-400/30 bg-red-500/10 text-red-100";
  if (alert.value.level === "warning") return "border-amber-400/30 bg-amber-500/10 text-amber-100";
  if (alert.value.level === "ok") return "border-lime-400/25 bg-lime-400/10 text-lime-100";
  return "border-zinc-800 bg-zinc-950 text-zinc-300";
}

onUnmounted(stopTimer);
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Activity :size="17" /> 实时流量</h3>
        <p class="mt-1 text-sm leading-6 text-zinc-400">
          真实调用 <code>api stats</code> 读取 sing-box 当前上下行速率。
        </p>
        <p class="mt-1 text-xs text-zinc-500">
          更新：{{ lastUpdated }} · 来源：{{ summary.latest?.source || "无" }} {{ summary.latest?.sourceKey || "" }} · 窗口 {{ Math.round(summary.windowMillis / 1000) }}s
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" :loading="isRunning('traffic-stats-sample')" @click="sampleNow(false)">
          <RefreshCw :size="15" />采样
        </Button>
        <Button size="sm" variant="secondary" @click="toggleAutoSampling">
          <Pause v-if="autoSampling" :size="15" />
          <Play v-else :size="15" />{{ autoSampling ? "暂停" : "自动" }}
        </Button>
      </div>
    </div>

    <div class="grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3 sm:grid-cols-[minmax(0,1fr)_9rem] sm:items-end">
      <div class="min-w-0">
        <p class="inline-flex items-center gap-2 text-sm font-semibold text-zinc-100"><Bell :size="15" /> 流量告警</p>
        <p class="mt-1 text-xs leading-5 text-zinc-500">
          基于真实样本的上行+下行总速率判断，连续 3 个样本超阈值会标为严重。
        </p>
      </div>
      <label class="grid gap-1 text-xs text-zinc-500">
        阈值 MiB/s
        <Input v-model="thresholdMiB" inputmode="decimal" placeholder="10" />
      </label>
    </div>

    <div class="rounded-md border p-3 text-sm leading-6" :class="alertClasses()">
      {{ alert.message }} 当前 {{ formatRate(alert.latestTotal) }} · 阈值 {{ formatRate(alert.thresholdBytesPerSecond) }}
    </div>

    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">当前上传</p>
        <p class="text-lg font-semibold text-zinc-100">{{ formatRate(summary.latest?.up || 0) }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">当前下载</p>
        <p class="text-lg font-semibold text-zinc-100">{{ formatRate(summary.latest?.down || 0) }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">平均总速率</p>
        <p class="text-lg font-semibold text-zinc-100">{{ formatRate(summary.averageUp + summary.averageDown) }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">样本</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.sampleCount }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">最近 12 峰值总速率</p>
        <p class="text-lg font-semibold text-zinc-100">{{ formatRate(trendWindowPeakTotal) }}</p>
        <p class="mt-1 text-xs text-zinc-500">峰值时间 {{ peakTime }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">最近变化</p>
        <p class="text-lg font-semibold" :class="latestTrendColor">{{ latestTrendDirection }}</p>
        <p class="mt-1 text-xs text-zinc-500">{{ formatRate(Math.abs(latestTrendDelta)) }}</p>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-2">
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">峰值上传</p>
        <p class="mt-1 text-sm text-zinc-100">{{ formatRate(summary.peakUp) }}</p>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">峰值下载</p>
        <p class="mt-1 text-sm text-zinc-100">{{ formatRate(summary.peakDown) }}</p>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">上传占比</p>
        <p class="mt-1 text-sm text-zinc-100">{{ upShare(summary.latest) }}</p>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <p class="text-xs text-zinc-500">连续失败</p>
        <p class="mt-1 text-sm text-zinc-100">{{ failedSamples }}</p>
      </div>
    </div>

    <div v-if="lastFailure" class="rounded-md border border-amber-400/30 bg-amber-500/10 p-3 text-sm leading-6 text-amber-100/85">
      最近一次采样未解析：{{ lastFailure.slice(0, 220) }}
    </div>

    <div v-if="trendSamples.length" class="rounded-md border border-zinc-800 bg-zinc-950 p-3">
      <div class="mb-2 flex items-center justify-between gap-2">
        <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">最近趋势</p>
        <p class="text-xs text-zinc-500">最多 12 个真实样本</p>
      </div>
      <div class="grid gap-2">
        <div v-for="sample in latestTrendSeries" :key="`${sample.sample.timestampMillis}-${sample.indexLabel}`" class="grid grid-cols-[2.25rem_4.75rem_minmax(0,1fr)_5rem] items-center gap-2">
          <span class="text-xs text-zinc-600">#{{ sample.indexLabel }}</span>
          <span class="text-xs text-zinc-500">{{ formatSampleTime(sample.sample.timestampMillis) }}</span>
          <div class="grid min-w-0 gap-1">
            <div class="h-2 rounded bg-zinc-900">
              <div class="h-2 rounded bg-lime-400" :style="{ width: sampleWidth(sample.sample.up) }" />
            </div>
            <div class="h-2 rounded bg-zinc-900">
              <div class="h-2 rounded bg-cyan-400" :style="{ width: sampleWidth(sample.sample.down) }" />
            </div>
          </div>
          <div class="text-right text-xs">
            <p class="text-zinc-100">{{ formatRate(sample.sample.up + sample.sample.down) }}</p>
            <p :class="trendBadgeClass(sample.deltaTotal)" class="mt-0.5">{{ formatTrendBadge(sample.deltaTotal) }}</p>
          </div>
        </div>
      </div>
    </div>

    <div class="flex flex-wrap gap-2">
      <Button size="sm" variant="outline" :disabled="!samples.length" @click="copyReport">
        <Copy :size="15" />{{ copied ? "已复制" : "复制报告" }}
      </Button>
      <Button size="sm" variant="ghost" :disabled="!samples.length" @click="clearSamples">
        <Trash2 :size="15" />清空
      </Button>
    </div>

    <pre v-if="!samples.length && lastOutput" class="max-h-40 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-300 whitespace-pre-wrap">{{ lastOutput }}</pre>
  </Card>
</template>
