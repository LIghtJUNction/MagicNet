<script setup lang="ts">
import { CheckCircle2, Copy, DownloadCloud, ExternalLink, Github, RefreshCw, Terminal } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";
import { buildWebuiInstallPlan, formatWebuiInstallPlanReport, webuiInstallPlanTone } from "./webuiInstallPlan";
import { buildWebuiPanelInsight, webuiInsightTone, type WebuiVerifyCheck } from "./webuiPanelInsights";

const { state, runCli, startBackgroundCli, openExternal, shellQuote, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const status = ref("");
const verifyOutput = ref("");
const reportCopied = ref(false);
const commandCopied = ref(false);
const planCopied = ref(false);
const pendingWebuiAction = ref<PendingToolAction | null>(null);
const panel = ref({
  name: "zashboard",
  url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip",
  metadata: ""
});
const panelPresets = [
  {
    label: "zashboard no-fonts",
    name: "zashboard",
    url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip",
    note: "MagicNet 默认本地面板，包体更小，适合设备侧后台下载。"
  },
  {
    label: "zashboard full",
    name: "zashboard",
    url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip",
    note: "完整字体包体积更大；CLI 下载失败时会重试 no-fonts 资源。"
  }
];

const verifyChecks = computed(() => parseVerifyChecks(verifyOutput.value));
const verifyFailed = computed(() => verifyOutput.value.toLowerCase().includes("failed") || verifyChecks.value.some((item) => item.status !== "ok"));
const panelInsight = computed(() => buildWebuiPanelInsight(verifyChecks.value, verifyOutput.value));
const installCommand = computed(() => {
  const url = panel.value.url.trim();
  const name = panel.value.name.trim() || "custom";
  return url ? `webui install-local ${shellQuote(url)} ${shellQuote(name)}` : "";
});
const panelWarnings = computed(() => buildPanelWarnings(panel.value.url, panel.value.name));
const installPlan = computed(() => buildWebuiInstallPlan(panel.value.url, panel.value.name));

async function refreshWebui(): Promise<void> {
  await withAction("webui-status", async () => {
    status.value = await runCli("webui status", "读取 WebUI 配置", true);
    state.output = status.value;
  });
}

async function verifyWebui(): Promise<void> {
  await withAction("webui-verify", async () => {
    verifyOutput.value = await runCli("webui verify", "校验 WebUI 面板");
    state.output = verifyOutput.value;
  });
}

async function copyWebuiReport(): Promise<void> {
  const report = [
    "MagicNet WebUI panel report",
    `created_at=${new Date().toISOString()}`,
    `verify_failed=${verifyFailed.value ? 1 : 0}`,
    `insight_status=${panelInsight.value.status}`,
    `insight_title=${panelInsight.value.title}`,
    `missing=${panelInsight.value.missing.join(",") || "none"}`,
    "",
    "[checks]",
    ...verifyChecks.value.map((check) => `${check.name}=${check.status}${check.path ? ` path=${check.path}` : ""}`),
    "",
    "[status]",
    status.value || "(not loaded)",
    "",
    "[verify]",
    verifyOutput.value || "(not verified)"
  ].join("\n").trim();
  reportCopied.value = await copyText(sanitizeWebuiReport(report));
  state.output = reportCopied.value ? "WebUI 面板报告已复制。" : "剪贴板不可用，WebUI 面板报告未复制。";
}

async function copyInstallCommand(): Promise<void> {
  if (!installCommand.value) {
    state.output = "请先填写本地面板下载 URL。";
    return;
  }
  commandCopied.value = await copyText(installCommand.value);
  state.output = commandCopied.value ? "WebUI 安装命令已复制。" : "剪贴板不可用，WebUI 安装命令未复制。";
}

async function copyInstallPlan(): Promise<void> {
  planCopied.value = await copyText(formatWebuiInstallPlanReport(installPlan.value));
  state.output = planCopied.value ? "WebUI 安装计划已复制。" : "剪贴板不可用，安装计划未复制。";
}

function sanitizeWebuiReport(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, "[filtered-url]")
    .replace(/(["']?(?:authorization|proxy-authorization|password|passwd|token|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|key)["']?\s*[:=]\s*)["']?[^"',\s;}\]]+["']?/gi, "$1[filtered]")
    .replace(/\bbearer\s+[A-Za-z0-9._~+/-]+=*/gi, "bearer [filtered]")
    .replace(/\b(?:gho|ghp|github_pat)_[A-Za-z0-9_]+/g, "[filtered-token]")
    .replace(/\bsk-[A-Za-z0-9_-]+/g, "[filtered-token]");
}

function cancelWebuiAction(): void {
  pendingWebuiAction.value = null;
}

async function confirmWebuiAction(): Promise<void> {
  const action = pendingWebuiAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingWebuiAction.value = null;
  }
}

async function runInstallLocal(command: string, preview: string): Promise<void> {
  await withAction("webui-install", async () => {
    await startBackgroundCli(command, "安装本地 WebUI 面板", `su -M -c ${shellQuote(preview)}`, preview);
  });
}

function installLocal(): void {
  const url = panel.value.url.trim();
  const name = panel.value.name.trim() || "custom";
  if (!/^https?:\/\/\S+$/i.test(url)) {
    state.output = "本地面板下载 URL 必须是 http(s) 链接。";
    return;
  }
  if (panelWarnings.value.some((item) => item.tone === "danger")) {
    state.output = "请先修正本地面板配置中的错误项。";
    return;
  }
  const command = installCommand.value;
  const safeCommand = installPlan.value.safeCommand || "webui install-local [filtered-url] custom";
  pendingWebuiAction.value = {
    key: "webui-install",
    title: "后台下载并安装 WebUI 面板",
    detail: `会下载 ${name} 面板压缩包并写入模块本地 WebUI 资源。${installPlan.value.status === "warning" ? ` ${installPlan.value.detail}` : ""}`,
    command: safeCommand,
    run: () => runInstallLocal(command, safeCommand),
  };
}

function applyPanelPreset(item: { name: string; url: string; note: string }): void {
  panel.value = {
    name: item.name,
    url: item.url,
    metadata: item.note
  };
  commandCopied.value = false;
  planCopied.value = false;
}

function issueUrl(): string {
  const body = [
    "## WebUI panel adaptation request",
    "",
    `Name: ${panel.value.name || "custom"}`,
    `Kind: ${panel.value.url ? "local-download" : "online"}`,
    "",
    "## Metadata",
    panel.value.metadata || "(empty)",
    "",
    "请审核后决定是否内置该面板。"
  ].join("\n");
  return `${REPO}/issues/new?${new URLSearchParams({ title: `申请适配 WebUI 面板：${panel.value.name || "custom"}`, body }).toString()}`;
}

function parseVerifyChecks(text: string): WebuiVerifyCheck[] {
  return text.split(/\r?\n/).map((line) => {
    const match = line.match(/^([^=\s]+)=(ok|missing)(?:\s+path=(.*))?$/);
    if (!match) return null;
    return {
      name: match[1].replace(/_/g, " "),
      status: match[2] === "ok" ? "ok" : "missing",
      path: match[3] || ""
    };
  }).filter((item): item is WebuiVerifyCheck => Boolean(item));
}

function buildPanelWarnings(url: string, name: string): Array<{ text: string; tone: "success" | "warning" | "danger" }> {
  const trimmedUrl = url.trim();
  const trimmedName = name.trim();
  const warnings: Array<{ text: string; tone: "success" | "warning" | "danger" }> = [];
  if (!trimmedName) warnings.push({ text: "未填写面板名，CLI 会使用 custom。", tone: "warning" });
  if (!trimmedUrl) return [{ text: "未填写下载 URL，无法安装。", tone: "danger" }, ...warnings];
  if (!/^https?:\/\/\S+$/i.test(trimmedUrl)) warnings.push({ text: "URL 必须是 http(s) 链接且不能包含空白字符。", tone: "danger" });
  if (!/\.zip(\?|#|$)/i.test(trimmedUrl)) warnings.push({ text: "CLI 当前只支持 zip 面板包。", tone: "danger" });
  if (/(token|secret|signature|expires|x-amz-|x-oss-)/i.test(trimmedUrl)) warnings.push({ text: "链接可能包含签名或凭据，复制命令会包含完整 URL。", tone: "warning" });
  if (hasZashboardDistFallback(trimmedUrl)) warnings.push({ text: "zashboard dist.zip 失败时 CLI 会自动重试 dist-no-fonts.zip。", tone: "success" });
  if (!warnings.length) warnings.push({ text: "安装命令可执行，下载和解压结果以后台任务日志为准。", tone: "success" });
  return warnings;
}

watch(() => [panel.value.name, panel.value.url], () => {
  commandCopied.value = false;
  planCopied.value = false;
});

function hasZashboardDistFallback(url: string): boolean {
  return url.startsWith("https://github.com/Zephyruso/zashboard/releases/") && url.endsWith("/dist.zip");
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="sing-box WebUI" title="面板配置" description="管理 sing-box WebUI 面板入口。本地面板会下载到模块目录，在线面板通过申请 issue 进入内置审核。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('webui-status')" @click="refreshWebui"><RefreshCw :size="17" />读取</Button>
        <Button variant="outline" :loading="isRunning('webui-verify')" @click="verifyWebui"><CheckCircle2 :size="17" />校验面板</Button>
        <Button variant="outline" :disabled="!status && !verifyOutput" :loading="isRunning('webui-copy-report')" @click="withAction('webui-copy-report', copyWebuiReport)"><Copy :size="17" />{{ reportCopied ? '已复制报告' : '复制报告' }}</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), 'WebUI 适配 Issue')"><Github :size="17" />申请适配</Button>
      </div>
    </PageHeader>

    <ToolActionConfirmCard
      v-if="pendingWebuiAction"
      :action="pendingWebuiAction"
      :loading="isRunning(pendingWebuiAction.key)"
      @cancel="cancelWebuiAction"
      @confirm="confirmWebuiAction"
    />

    <div class="grid gap-3 md:grid-cols-2">
      <Card class="grid gap-3">
        <h3 class="text-base font-semibold">本地面板</h3>
        <div class="flex flex-wrap gap-2">
          <Button v-for="item in panelPresets" :key="item.url" variant="outline" @click="applyPanelPreset(item)">
            {{ item.label }}
          </Button>
        </div>
        <Input v-model="panel.name" placeholder="面板名字，例如 zashboard" spellcheck="false" />
        <Input v-model="panel.url" placeholder="https://example.com/panel.zip" spellcheck="false" />
        <Textarea v-model="panel.metadata" class="min-h-28" placeholder="面板元数据、说明、仓库链接、适配注意事项" spellcheck="false" />
        <div class="grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="text-sm font-medium text-zinc-100">安装前检查</span>
            <Button variant="outline" :disabled="!installCommand" @click="copyInstallCommand"><Terminal :size="16" />{{ commandCopied ? '已复制命令' : '复制命令' }}</Button>
          </div>
          <div class="flex flex-wrap gap-2">
            <Badge v-for="item in panelWarnings" :key="item.text" :tone="item.tone">{{ item.text }}</Badge>
          </div>
          <div class="rounded-md border p-3 text-sm leading-6" :class="webuiInstallPlanTone(installPlan.status)">
            <p class="font-medium">{{ installPlan.title }}</p>
            <p class="mt-1 text-xs opacity-80">{{ installPlan.detail }}</p>
            <p class="mt-2 text-xs opacity-80">
              {{ installPlan.host || '无主机' }} · {{ installPlan.archive || '未知包类型' }} · query {{ installPlan.hasQuery ? '有' : '无' }}
            </p>
          </div>
          <code class="break-all rounded-md bg-black px-3 py-2 text-xs leading-6 text-zinc-200">{{ installCommand || "webui install-local <download-url> [name]" }}</code>
        </div>
        <Button variant="outline" :disabled="!panel.url.trim()" @click="copyInstallPlan"><Copy :size="17" />{{ planCopied ? '已复制计划' : '复制安装计划' }}</Button>
        <Button :disabled="panelWarnings.some((item) => item.tone === 'danger')" :loading="isRunning('webui-install')" @click="installLocal"><DownloadCloud :size="17" />后台下载并安装</Button>
      </Card>

      <Card class="grid gap-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-base font-semibold">当前状态</h3>
          <Badge v-if="verifyOutput" :tone="verifyFailed ? 'danger' : 'success'">{{ verifyFailed ? "校验失败" : "校验通过" }}</Badge>
        </div>
        <p class="text-sm leading-6 text-zinc-400">sing-box 默认使用本地 zashboard。面板下载会在后台执行，避免大文件下载被前台超时中断。</p>
        <div class="rounded-md border p-3" :class="webuiInsightTone(panelInsight.status)">
          <p class="text-sm font-semibold">{{ panelInsight.title }}</p>
          <p class="mt-1 break-words text-sm leading-6 opacity-80">{{ panelInsight.detail }}</p>
        </div>
        <Button variant="outline" @click="openExternal(REPO, 'MagicNet GitHub')"><ExternalLink :size="17" />打开项目仓库</Button>
        <div v-if="verifyChecks.length" class="grid gap-2">
          <div v-for="check in verifyChecks" :key="check.name" class="grid gap-1 rounded-md border border-zinc-800 bg-zinc-950 p-3">
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-zinc-100">{{ check.name }}</span>
              <Badge :tone="check.status === 'ok' ? 'success' : 'danger'">{{ check.status }}</Badge>
            </div>
            <p v-if="check.path" class="break-all text-xs text-zinc-500">{{ check.path }}</p>
          </div>
        </div>
        <pre class="max-h-80 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ status || "点击读取查看 webui status。" }}</pre>
        <pre v-if="verifyOutput" class="max-h-48 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ verifyOutput }}</pre>
      </Card>
    </div>
  </div>
</template>
