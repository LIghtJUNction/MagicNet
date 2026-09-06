<script setup lang="ts">
import { computed, ref } from "vue";
import { Bug, Copy, ExternalLink, FileText, RadioTower, RefreshCw, Server, ShieldCheck, TimerReset } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { statusToneClasses } from "@/lib/statusTone";
import { sanitizeDiagnosticText } from "@/composables/issueDrafts";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, probeFailed, redactedCliPreview } from "@/utils";
import { formatApiEndpointProbeReport, summarizeApiEndpointProbes, summarizeApiProbeOutput, validateApiProbeOutput, type ApiEndpointProbe, type ApiProbeKey } from "./apiEndpointProbe";
import ConnectionsPanel from "./ConnectionsPanel.vue";
import { formatHealthCheckReport, summarizeHealthChecks } from "./healthCheckSummary";
import NodeDelayPanel from "./NodeDelayPanel.vue";
import ProxyGroupsPanel from "./ProxyGroupsPanel.vue";
import { hideSupportIssueLines, triageSupportBundle } from "./supportBundleTriage";
import TrafficStatsPanel from "./TrafficStatsPanel.vue";

const { state, refreshHealth, refreshMcp, refreshPing, runCli, createIssue, openExternal } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const supportBundle = ref("");
const supportCopied = ref(false);
const supportIssuesCopied = ref(false);
const supportTriageCopied = ref(false);
const healthSummaryCopied = ref(false);
const apiProbes = ref<ApiEndpointProbe[]>([]);
const apiProbeCopied = ref(false);
const apiProbeSummary = computed(() => summarizeApiEndpointProbes(apiProbes.value));
const healthSummary = computed(() => summarizeHealthChecks(state.health));
const supportSummary = computed(() => {
  const text = supportBundle.value;
  return {
    lines: text ? text.split(/\r?\n/).length : 0,
    chars: text.length
  };
});
const supportIssueLines = computed(() => supportBundle.value
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter((line) => /\b(warn|warning|fail|failed|error|fatal|panic)\b/i.test(line))
  .slice(0, 40));
const supportTriage = computed(() => triageSupportBundle(supportBundle.value));
const supportPreview = computed(() => supportBundle.value ? hideSupportIssueLines(supportBundle.value) : "点击生成查看脱敏支持包。");

const assistants = [
  ["ChatGPT", "https://chatgpt.com/"],
  ["Gemini", "https://gemini.google.com/"],
  ["Kimi", "https://www.kimi.com/"],
  ["Qwen", "https://chat.qwen.ai/"],
  ["DeepSeek", "https://chat.deepseek.com/"]
];

async function copyContextUnlocked(): Promise<void> {
  const text = await runCli(
    "support bundle",
    "生成诊断上下文",
    true,
    redactedCliPreview("support bundle [private-output]"),
  );
  if (execFailed(text)) {
    state.output = text;
    return;
  }
  const sanitized = sanitizeDiagnosticText(text);
  supportBundle.value = sanitized;
  supportCopied.value = false;
  supportIssuesCopied.value = false;
  supportTriageCopied.value = false;
  state.output = await copyText(sanitized) ? "脱敏诊断上下文已复制。" : "剪贴板不可用，脱敏诊断上下文已生成但未复制。";
}

async function copyContext(): Promise<void> {
  await withAction("copy-context", copyContextUnlocked);
}

async function refreshSupportBundle(): Promise<void> {
  await withAction("support-bundle", async () => {
    const text = await runCli(
      "support bundle",
      "生成支持包",
      true,
      redactedCliPreview("support bundle [private-output]"),
    );
    if (execFailed(text)) {
      state.output = text;
      return;
    }
    supportBundle.value = sanitizeDiagnosticText(text);
    supportCopied.value = false;
    supportIssuesCopied.value = false;
    supportTriageCopied.value = false;
    state.output = "脱敏支持包已生成，可在诊断页预览。";
  });
}

async function copySupportBundle(): Promise<void> {
  if (!supportBundle.value) return;
  supportCopied.value = await copyText(supportBundle.value);
  state.output = supportCopied.value ? "脱敏支持包已复制。" : "剪贴板不可用，脱敏支持包未复制。";
}

async function copySupportIssues(): Promise<void> {
  if (!supportTriage.value.totalIssues) return;
  supportIssuesCopied.value = await copyText(supportTriage.value.report);
  state.output = supportIssuesCopied.value ? "支持包问题摘要已复制。" : "剪贴板不可用，问题摘要未复制。";
}

async function copySupportTriage(): Promise<void> {
  if (!supportTriage.value.totalIssues) return;
  supportTriageCopied.value = await copyText(supportTriage.value.report);
  state.output = supportTriageCopied.value ? "支持包问题分布已复制。" : "剪贴板不可用，问题分布未复制。";
}

async function refreshDiagnostics(): Promise<void> {
  const mcpOk = await refreshMcp(true);
  const mcpOutput = mcpOk ? "" : state.output;
  const healthOk = await refreshHealth();
  const healthOutput = healthOk ? "" : state.output;
  if (!mcpOk || !healthOk) {
    state.phase = "error";
    state.notice = "诊断刷新不完整";
    state.output = [
      !mcpOk ? `MCP 刷新失败：${mcpOutput}` : "",
      !healthOk ? `健康检查刷新失败：${healthOutput}` : "",
    ].filter(Boolean).join("\n\n");
  }
  healthSummaryCopied.value = false;
}

async function runApiProbe(): Promise<void> {
  await withAction("api-probe", async () => {
    apiProbeCopied.value = false;
    const targets: { key: ApiProbeKey; label: string; command: string }[] = [
      { key: "groups", label: "代理组", command: "api groups" },
      { key: "stats", label: "流量", command: "api stats" },
      { key: "connections", label: "连接", command: "api conns" }
    ];
    const next: ApiEndpointProbe[] = [];
    for (const target of targets) {
      const startedAt = performance.now();
      const text = await runCli(
        target.command,
        `预检 ${target.label}`,
        true,
        redactedCliPreview("api preflight [private-output]"),
      );
      next.push({
        ...target,
        ok: !probeFailed(text) && validateApiProbeOutput(target.key, text),
        durationMillis: Math.round(performance.now() - startedAt),
        outputBytes: new TextEncoder().encode(text).length,
        summary: summarizeApiProbeOutput(text)
      });
    }
    apiProbes.value = next;
    const summary = summarizeApiEndpointProbes(next);
    state.output = `API 端点预检：${summary.label}\n${summary.detail}`;
  });
}

async function copyApiProbeReport(): Promise<void> {
  if (!apiProbes.value.length) return;
  apiProbeCopied.value = await copyText(formatApiEndpointProbeReport(apiProbes.value, apiProbeSummary.value));
  state.output = apiProbeCopied.value ? "API 端点预检报告已复制。" : "剪贴板不可用，API 端点预检报告未复制。";
}

async function copyHealthSummary(): Promise<void> {
  if (!state.health.length) return;
  healthSummaryCopied.value = await copyText(formatHealthCheckReport(state.health, healthSummary.value));
  state.output = healthSummaryCopied.value ? "健康检查聚合报告已复制。" : "剪贴板不可用，健康检查报告未复制。";
}

async function askAi(url: string, name: string): Promise<void> {
  await withAction(`ask-${name}`, async () => {
    await copyContextUnlocked();
    await openExternal(url, name);
  });
}
const healthLabels: Record<string, string> = { fail: "失败", warn: "注意", info: "提示", ok: "正常" };
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="诊断" title="诊断">
      <template #actions>
        <Button :loading="isRunning('health')" @click="withAction('health', refreshDiagnostics)"><RefreshCw :size="17" />健康检查</Button>
        <Button variant="outline" :loading="isRunning('ping')" @click="withAction('ping', () => refreshPing())"><RadioTower :size="17" />连通性测试</Button>
        <details class="config-action-menu">
          <summary>更多</summary>
          <div>
            <Button variant="ghost" :loading="isRunning('create-issue')" @click="withAction('create-issue', createIssue)"><Bug :size="17" />创建 Issue</Button>
            <Button variant="ghost" :loading="isRunning('copy-context')" @click="copyContext"><Copy :size="17" />复制上下文</Button>
          </div>
        </details>
      </template>
    </PageHeader>

    <Card class="grid gap-5">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-medium"><ShieldCheck :size="17" />检查结果</h3>
        <Button size="sm" variant="outline" :disabled="!state.health.length" @click="copyHealthSummary"><Copy :size="15" />{{ healthSummaryCopied ? '已复制' : '复制摘要' }}</Button>
      </div>
      <div class="rounded-md p-4" :class="statusToneClasses(healthSummary.level)" role="status">
        <p class="font-medium">{{ healthSummary.label }}</p>
        <p v-if="state.health.length" class="mt-2 text-sm leading-6">{{ healthSummary.detail }}</p>
      </div>
      <div class="grid grid-cols-4 gap-3">
        <div v-for="status in ['fail', 'warn', 'info', 'ok']" :key="status">
          <p class="text-xs text-[var(--mn-ink-muted)]">{{ healthLabels[status] }}</p>
          <p class="mt-2 text-2xl font-medium tabular-nums">{{ healthSummary.counts[status] }}</p>
        </div>
      </div>
    </Card>

    <div v-if="state.health.length" class="grid">
      <details v-for="item in state.health" :key="item.key" class="mn-disclosure" :open="item.status === 'fail' || item.status === 'warn'">
        <summary>
          <span class="min-w-0 break-words">{{ item.key }}</span>
          <Badge :tone="item.status === 'ok' ? 'success' : item.status === 'fail' ? 'danger' : 'warning'">{{ healthLabels[item.status] || item.status }}</Badge>
        </summary>
        <p class="break-words pb-6 text-sm leading-6 text-[var(--mn-ink-soft)]">{{ item.detail }}</p>
      </details>
    </div>

    <Card v-if="state.pingtest">
      <h3 class="text-base font-medium">连通性输出</h3>
      <pre class="mt-3 max-h-[58vh] overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ state.pingtest }}</pre>
    </Card>

    <details class="mn-disclosure">
      <summary>协助排查</summary>
    <Card>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
        <div class="min-w-0">
          <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Server :size="17" /> MCP 服务器</h3>
          <p class="mt-1 break-all text-sm text-[var(--mn-ink-muted)]">pid={{ state.mcp.pid }} · {{ state.mcp.url }}</p>
        </div>
        <Badge :tone="state.mcp.pid !== 'stopped' ? 'success' : 'warning'">{{ state.mcp.pid !== "stopped" ? "已开启" : "未开启" }}</Badge>
      </div>
      <div class="flex flex-col gap-3">
        <div>
          <h3 class="text-base font-medium">咨询 AI</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">先复制脱敏报告，再打开助手。</p>
        </div>
        <div class="grid grid-cols-2 gap-2 sm:grid-cols-5">
        <Button v-for="[name, url] in assistants" :key="name" variant="secondary" size="sm" :loading="isRunning(`ask-${name}`)" @click="askAi(url, name)">
          <ExternalLink :size="15" />{{ name }}
        </Button>
        </div>
      </div>
    </Card>

    </details>
    <details class="mn-disclosure" :open="apiProbes.some((probe) => !probe.ok)">
      <summary>API 连通性</summary>
    <Card class="grid gap-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="inline-flex items-center gap-2 text-base font-medium"><TimerReset :size="17" /> 检查 API</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">检查节点组、流量统计和连接接口是否可用。</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" :loading="isRunning('api-probe')" @click="runApiProbe">
            <RefreshCw :size="15" />开始检查
          </Button>
          <Button size="sm" variant="secondary" :disabled="!apiProbes.length" @click="copyApiProbeReport">
            <Copy :size="15" />{{ apiProbeCopied ? "已复制" : "复制" }}
          </Button>
        </div>
      </div>
      <div class="rounded-md p-3 text-sm leading-6" :class="statusToneClasses(apiProbeSummary.level)">
        <p class="font-semibold">{{ apiProbeSummary.label }}</p>
        <p class="mt-1 text-xs opacity-80">
          {{ apiProbeSummary.detail }} · 总耗时 {{ apiProbeSummary.totalMillis }}ms
          <span v-if="apiProbeSummary.slowest"> · 最慢 {{ apiProbeSummary.slowest.label }} {{ apiProbeSummary.slowest.durationMillis }}ms</span>
        </p>
      </div>
      <div v-if="apiProbes.length" class="grid gap-2 sm:grid-cols-3">
        <div v-for="probe in apiProbes" :key="probe.key" class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
          <div class="flex items-center justify-between gap-2">
            <p class="text-sm font-semibold text-[var(--mn-ink)]">{{ probe.label }}</p>
            <Badge :tone="probe.ok ? 'success' : 'danger'">{{ probe.ok ? "ok" : "fail" }}</Badge>
          </div>
          <p class="mt-2 text-lg font-semibold text-[var(--mn-ink)]">{{ probe.durationMillis }}ms</p>
          <p class="mt-1 text-xs text-[var(--mn-ink-muted)]">{{ probe.outputBytes }} bytes · {{ probe.command }}</p>
          <p class="mt-2 truncate text-xs text-[var(--mn-ink-muted)]">{{ probe.summary }}</p>
        </div>
      </div>
    </Card>

    </details>
    <details class="mn-disclosure" :open="supportTriage.totalIssues > 0">
      <summary>诊断报告</summary>
    <Card class="grid gap-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="inline-flex items-center gap-2 text-base font-medium"><FileText :size="17" /> 诊断报告</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">生成可安全分享的设备诊断信息。</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" :loading="isRunning('support-bundle')" @click="refreshSupportBundle">
            <RefreshCw :size="15" />生成
          </Button>
          <Button size="sm" variant="secondary" :disabled="!supportBundle" @click="copySupportBundle">
            <Copy :size="15" />{{ supportCopied ? "已复制" : "复制" }}
          </Button>
          <Button size="sm" variant="outline" :disabled="!supportTriage.totalIssues" @click="copySupportIssues">
            <Copy :size="15" />{{ supportIssuesCopied ? "已复制摘要" : "复制问题" }}
          </Button>
          <Button size="sm" variant="outline" :disabled="!supportTriage.totalIssues" @click="copySupportTriage">
            <Copy :size="15" />{{ supportTriageCopied ? "已复制分布" : "复制分布" }}
          </Button>
        </div>
      </div>
      <div v-if="supportBundle" class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-3">
        <span>{{ supportSummary.lines }} 行</span>
        <span>{{ supportSummary.chars }} 字符</span>
        <span>{{ supportIssueLines.length }} 条问题线索</span>
      </div>
      <div v-if="supportTriage.totalIssues" class="grid gap-2 sm:grid-cols-3">
        <div v-for="bucket in supportTriage.buckets.slice(0, 6)" :key="`${bucket.section}-${bucket.severity}`" class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3">
          <p class="truncate text-xs text-[var(--mn-ink-muted)]">{{ bucket.section }}</p>
          <p class="mt-1 text-base font-semibold text-[var(--mn-ink)]">{{ bucket.count }} · {{ bucket.severity }}</p>
        </div>
      </div>
      <div v-if="supportTriage.totalIssues" class="rounded-md mn-panel-warn p-3 text-sm leading-6 text-[var(--mn-warning)]/85">
          <p class="text-xs font-semibold text-[var(--mn-warning)]">发现问题</p>
        <p class="mt-2 text-xs leading-5 text-[var(--mn-warning)]">
          共 {{ supportTriage.totalIssues }} 条，分布在 {{ supportTriage.sections }} 个检查项目中。复制摘要不会包含原始内容。
        </p>
      </div>
      <pre class="max-h-72 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ supportPreview }}</pre>
    </Card>

    </details>

    <details class="mn-disclosure"><summary>实时流量</summary><TrafficStatsPanel /></details>
    <details class="mn-disclosure"><summary>当前连接</summary><ConnectionsPanel /></details>
    <details class="mn-disclosure"><summary>节点与代理组</summary><ProxyGroupsPanel /></details>
    <details class="mn-disclosure"><summary>节点测速</summary><NodeDelayPanel /></details>

  </div>
</template>
