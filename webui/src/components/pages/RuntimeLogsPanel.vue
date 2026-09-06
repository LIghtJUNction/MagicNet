<script setup lang="ts">
import { t } from "@/i18n";
import { computed, onActivated, onDeactivated, onUnmounted, ref } from "vue";
import { Copy, FileText, Pause, Play, RefreshCw } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import { sanitizeOutputText } from "./outputDiagnostics";
import {
  analyzeRuntimeLogLines,
  buildRuntimeLogInsight,
  formatRuntimeLogIssueReport,
  runtimeLogInsightTone,
  runtimeLogLevelMatches,
} from "./runtimeLogInsights";

const { runCli, state, compactOutput } = useMagicNet();
const { isRunning, withAction } = useActionLock();
type RuntimeLogTarget = "webui" | "sing-box" | "mcp" | "fswatch" | "supervisors";
const target = ref<RuntimeLogTarget>("webui");
const lines = ref("120");
const query = ref("");
const level = ref<"all" | "warn" | "error">("all");
const output = ref("");
const copied = ref(false);
const issueCopied = ref(false);
const lastLabel = ref("");
const loadedTarget = ref<RuntimeLogTarget>("webui");
const autoRefresh = ref(false);
let timer = 0;

const commandPreview = computed(() => {
  const count = normalizedLines();
  return target.value === "mcp" ? `mcp logs ${count}` : `service logs ${target.value} ${count}`;
});
const logLines = computed(() => output.value.split(/\r?\n/).filter(Boolean));
const logAnalysis = computed(() => analyzeRuntimeLogLines(logLines.value));
const filteredLines = computed(() => logLines.value.filter((line) => {
  const lower = line.toLowerCase();
  const keyword = query.value.trim().toLowerCase();
  const matchesKeyword = !keyword || lower.includes(keyword);
  const matchesLevel = runtimeLogLevelMatches(line, level.value);
  return matchesKeyword && matchesLevel;
}));
const warningCount = computed(() => logAnalysis.value.warningCount);
const errorCount = computed(() => logAnalysis.value.errorCount);
const visibleOutput = computed(() => filteredLines.value.join("\n"));
const issueLines = computed(() => logAnalysis.value.issueLines);
const logInsight = computed(() => buildRuntimeLogInsight(logLines.value, warningCount.value, errorCount.value, issueLines.value, logAnalysis.value.issueCount));
const quickFilters = [
  { label: "错误", query: "", level: "error" },
  { label: "警告", query: "", level: "warn" },
  { label: "DNS", query: "dns", level: "all" },
  { label: "Selector", query: "selector", level: "all" },
  { label: "Outbound", query: "outbound", level: "all" }
] as const;

async function refreshLogs(): Promise<void> {
  const command = commandPreview.value;
  const label = {
    webui: t("读取 WebUI 后台任务日志"),
    "sing-box": t("读取 sing-box 日志"),
    mcp: t("读取 MCP 日志"),
    fswatch: t("读取 fswatch 日志"),
    supervisors: t("读取监督器日志"),
  }[target.value];
  await withAction("runtime-logs", async () => {
    output.value = await runCli(command, label);
    lastLabel.value = label;
    loadedTarget.value = target.value;
    copied.value = false;
    issueCopied.value = false;
  });
}

function startTimer(): void {
  stopTimer();
  timer = window.setInterval(() => {
    if (!isRunning("runtime-logs")) void refreshLogs();
  }, 5000);
}

function toggleAutoRefresh(): void {
  autoRefresh.value = !autoRefresh.value;
  if (!autoRefresh.value) {
    stopTimer();
    return;
  }
  void refreshLogs();
  startTimer();
}

async function copyLogs(): Promise<void> {
  copied.value = await copyText(sanitizeOutputText(visibleOutput.value || output.value));
  state.output = copied.value ? t("脱敏运行日志已复制。") : t("剪贴板不可用，运行日志未复制。");
}

async function copyIssueSummary(): Promise<void> {
  issueCopied.value = await copyText(formatRuntimeLogIssueReport({
    target: loadedTarget.value,
    lines: logLines.value,
    issueLines: issueLines.value,
    issueCount: logAnalysis.value.issueCount,
    warningCount: warningCount.value,
    errorCount: errorCount.value,
    otherIssueCount: logAnalysis.value.otherIssueCount
  }));
  state.output = issueCopied.value ? t("日志问题摘要已复制。") : t("剪贴板不可用，日志问题摘要未复制。");
}

function normalizedLines(): number {
  const parsed = Number(lines.value);
  if (!Number.isFinite(parsed)) return 120;
  return Math.max(20, Math.min(1000, Math.round(parsed)));
}

function applyQuickFilter(filter: typeof quickFilters[number]): void {
  query.value = filter.query;
  level.value = filter.level;
  copied.value = false;
}

function quickFilterActive(filter: typeof quickFilters[number]): boolean {
  return query.value === filter.query && level.value === filter.level;
}

function stopTimer(): void {
  if (!timer) return;
  window.clearInterval(timer);
  timer = 0;
}

// Under <KeepAlive> the panel is deactivated (not unmounted) on tab switch, so
// stop polling when hidden — otherwise it keeps firing root commands and
// overwriting the global status/output from an off-screen tab — and resume it
// on return if auto-refresh is still toggled on.
onDeactivated(stopTimer);
onActivated(() => {
  if (autoRefresh.value) startTimer();
});
onUnmounted(stopTimer);
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileText :size="17" />{{ t("运行日志") }}</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("真实读取设备侧日志尾部，用于排查 sing-box 和 MCP。") }}</p>
      </div>
      <div class="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" :loading="isRunning('runtime-logs')" @click="refreshLogs">
          <RefreshCw :size="15" />{{ t("刷新") }}</Button>
        <Button size="sm" variant="secondary" @click="toggleAutoRefresh">
          <Pause v-if="autoRefresh" :size="15" />
          <Play v-else :size="15" />{{ autoRefresh ? t("暂停") : t("自动") }}
        </Button>
      </div>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_7rem_auto]">
      <select v-model="target" class="h-10 min-w-0 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 text-sm text-[var(--mn-ink)]">
        <option value="webui">{{ t("WebUI 后台任务") }}</option>
        <option value="sing-box">sing-box</option>
        <option value="fswatch">fswatch</option>
        <option value="supervisors">{{ t("监督器") }}</option>
        <option value="mcp">MCP</option>
      </select>
      <Input v-model="lines" inputmode="numeric" placeholder="120" />
      <Button variant="secondary" :disabled="!output" @click="copyLogs">
        <Copy :size="15" />{{ copied ? t("已复制") : t("复制") }}
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_8rem]">
      <Input v-model="query" :placeholder="t('过滤关键字，例如 error / dns / selector')" spellcheck="false" />
      <select v-model="level" class="h-10 min-w-0 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 text-sm text-[var(--mn-ink)]">
        <option value="all">{{ t("全部") }}</option>
        <option value="warn">{{ t("警告") }}</option>
        <option value="error">{{ t("错误") }}</option>
      </select>
    </div>

    <div v-if="output" class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
      <span>{{ t("日志 {value1} 行", { value1: logLines.length }) }}</span>
      <span>{{ t("命中 {value1} 行", { value1: filteredLines.length }) }}</span>
      <span class="text-[var(--mn-warning)]">{{ t("警告 {value1}", { value1: warningCount }) }}</span>
      <span class="text-[var(--mn-danger)]">{{ t("问题 {value1}", { value1: issueLines.length }) }}</span>
    </div>
    <div v-if="output" class="rounded-md border p-3 text-sm leading-6" :class="runtimeLogInsightTone(logInsight.status)">
      <p class="font-medium">{{ logInsight.label }}</p>
      <p class="mt-1 text-xs opacity-80">{{ logInsight.detail }}</p>
      <p v-if="logInsight.lastIssue" class="mt-2 truncate text-xs opacity-90">{{ t("最近问题：{value1}", { value1: logInsight.lastIssue }) }}</p>
    </div>
    <div v-if="output" class="flex flex-wrap gap-2">
      <Button
        v-for="filter in quickFilters"
        :key="filter.label"
        size="sm"
        :variant="quickFilterActive(filter) ? 'secondary' : 'ghost'"
        @click="applyQuickFilter(filter)"
      >
        {{ t(filter.label) }}
      </Button>
      <Button size="sm" variant="ghost" :disabled="!query && level === 'all'" @click="query = ''; level = 'all'">{{ t("全部") }}</Button>
    </div>
    <Button v-if="issueLines.length" size="sm" variant="outline" @click="copyIssueSummary">
      <Copy :size="15" />{{ issueCopied ? t("已复制摘要") : t("复制问题摘要") }}
    </Button>

    <code class="break-all rounded-md bg-[var(--mn-carrier-deep)] px-3 py-2 text-xs text-[var(--mn-ink-muted)]">{{ commandPreview }}{{ autoRefresh ? t(" · 每 5 秒刷新") : "" }}</code>
    <pre class="max-h-72 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ output ? compactOutput(visibleOutput || t("没有匹配的日志行。"), 9000) : `${lastLabel || t("选择目标后点击刷新。")} ` }}</pre>
  </Card>
</template>
