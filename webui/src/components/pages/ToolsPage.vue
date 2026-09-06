<script setup lang="ts">
import { t } from "@/i18n";
import { ClipboardPaste, Copy, Download, FileLock, Network, Power, PowerOff, RadioTower, RefreshCw, Upload } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, readClipboardText, redactedCliPreview } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import DnsToolsCard from "./DnsToolsCard.vue";
import EcaptureToolsCard from "./EcaptureToolsCard.vue";
import McpToolsCard from "./McpToolsCard.vue";
import NetworkPolicyCard from "./NetworkPolicyCard.vue";
import NetworkSnapshotPanel from "./NetworkSnapshotPanel.vue";
import WarpRouteRulesPanel from "./WarpRouteRulesPanel.vue";
import { summarizeBackupPayload } from "./backupPayloadSummary";
import type { PendingToolAction } from "./toolActions";
import { formatWarpImportSummaryReport, summarizeWarpImport, warpImportTone } from "./warpImportSummary";
import { summarizeRefreshTools } from "./refreshToolsState";

const {
  state,
  runCli,
  runPrivateCli,
  stagePrivatePayload,
  removePrivatePayload,
  refreshDns,
  refreshMcp,
  refreshTopology,
  refreshSysroute,
  refreshWarp,
  shellQuote,
} = useMagicNet();
const { isRunning, withAction } = useActionLock();
const toolsRefreshing = ref(false);
const pendingToolAction = ref<PendingToolAction | null>(null);
const backupSummaryCopied = ref(false);
const warpSummaryCopied = ref(false);
const backupPayloadSummary = computed(() => summarizeBackupPayload(state.backup.payload.trim()));
const warpImportSummary = computed(() => summarizeWarpImport(state.warp.importText));
watch(() => state.backup.payload, () => { backupSummaryCopied.value = false; });
watch(() => state.warp.importText, () => { warpSummaryCopied.value = false; });

async function refreshTools(): Promise<void> {
  toolsRefreshing.value = true;
  state.task = t("刷新工具状态");
  try {
    const steps = [
      { label: "DNS", ok: await refreshDns(true, redactedCliPreview("refresh tools [private-output]")) },
      { label: "WARP", ok: await refreshWarp(true) },
      { label: "MCP", ok: await refreshMcp(true) },
    ] as const;
    const summary = summarizeRefreshTools(steps, state.output);
    state.notice = summary.notice;
    state.output = summary.output;
    state.phase = summary.completed ? "done" : "error";
  } finally {
    toolsRefreshing.value = false;
    state.task = "";
  }
}
function requestToolAction(action: PendingToolAction): void {
  pendingToolAction.value = action;
}
function cancelToolAction(): void {
  pendingToolAction.value = null;
}
async function confirmToolAction(): Promise<void> {
  const action = pendingToolAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingToolAction.value = null;
  }
}
async function exportBackup(): Promise<void> {
  await withAction("backup-export", async () => {
    const securityCode = state.backup.exportPassword.trim();
    const preview = redactedCliPreview("backup export [备份内容和安全码已隐藏]");
    state.output = t("正在安全导出备份...");
    const outcome = await runPrivateCli(
      securityCode ? `backup export ${shellQuote(securityCode)}` : "backup export",
      t("导出配置备份"),
      preview,
    );
    const payload = outcome.ok ? outcome.stdout.trim().split(/\s+/).pop() || "" : "";
    const exported = outcome.ok && Boolean(payload);
    state.phase = exported ? "done" : "error";
    if (!exported) {
      state.backup.status = t("导出失败，请检查设备状态后重试。");
      state.output = state.backup.status;
      return;
    }
    state.backup.payload = payload;
    state.backup.status = t("已导出到备份输入框；为保护敏感内容，未自动复制到剪切板。");
    state.output = state.backup.status;
  });
}

async function pasteBackup(): Promise<void> {
  await withAction("backup-paste", async () => {
    const text = (await readClipboardText()).trim();
    if (!text) {
      state.backup.status = t("剪切板为空或不可读取，请手动粘贴");
      state.output = state.backup.status;
      return;
    }
    state.backup.payload = text;
    state.backup.status = t("已从剪切板读取 {length} 字符", { length: text.length });
  });
}

async function copyBackupSummary(): Promise<void> {
  const summary = backupPayloadSummary.value;
  const report = [
    "MagicNet backup payload summary",
    "privacy_note=payload body is not included",
    `payload_present=${state.backup.payload.trim() ? 1 : 0}`,
    `looks_valid=${summary.looksValid ? 1 : 0}`,
    `lines=${summary.lines}`,
    `chars=${summary.chars}`,
    `compact_chars=${summary.compactChars}`,
    `has_whitespace=${summary.hasWhitespace ? 1 : 0}`,
    `invalid_chars=${summary.invalidChars ? 1 : 0}`,
    `too_large=${summary.tooLarge ? 1 : 0}`,
    `fnv32=${summary.fingerprint}`
  ].join("\n");
  backupSummaryCopied.value = await copyText(report);
  state.output = backupSummaryCopied.value ? t("备份摘要已复制。") : t("剪贴板不可用，备份摘要未复制。");
}

async function runRestoreBackup(payload: string): Promise<void> {
  await withAction("backup-restore", async () => {
    const rawCode = state.backup.restorePassword.trim();
    const securityCode = rawCode || "-";
    const staged = await stageBackupPayload(payload);
    if (!staged) {
      state.backup.status = t("安全临时数据写入失败，导入未开始。");
      state.output = state.backup.status;
      return;
    }
    try {
      const outcome = await runPrivateCli(
        `backup restore-file ${shellQuote(securityCode)} ${shellQuote(staged.path)}`,
        t("导入配置备份"),
        redactedCliPreview("backup restore-file [安全码和备份内容已隐藏]"),
      );
      const restored = outcome.ok && outcome.stdout.includes("[info] Backup restored");
      state.phase = restored ? "done" : "error";
      state.backup.status = restored
        ? t("导入成功，运行配置已应用")
        : t("导入失败，请检查安全码和备份内容后重试。");
      state.output = state.backup.status;
    } finally {
      const cleaned = await removePrivatePayload("tmp", staged.basename, t("备份导入载荷"));
      if (!cleaned) {
        state.backup.status = t("{status} 私有临时数据清理未确认。", { status: state.backup.status });
        state.phase = "error";
        state.output = state.backup.status;
      }
    }
  });
}

function restoreBackup(): void {
  const payload = state.backup.payload.trim();
  if (!payload) {
    state.backup.status = t("请先粘贴备份字符串");
    state.output = state.backup.status;
    return;
  }
  if (!backupPayloadSummary.value.looksValid) {
    state.backup.status = t("备份字符串看起来不完整或包含非法字符");
    state.output = state.backup.status;
    return;
  }
  requestToolAction({
    key: "backup-restore",
    get title() { return t("导入配置备份"); },
    get detail() { return t("会覆盖设备上的订阅、应用名单、黑名单和路由等运行配置。"); },
    command: "backup restore-file <security-code> <payload-file>",
    run: () => runRestoreBackup(payload),
  });
}

function privatePayloadBasename(prefix: string, extension: string): string {
  return prefix
    + "-"
    + Date.now().toString(36)
    + "-"
    + Math.random().toString(36).slice(2, 8)
    + "."
    + extension;
}

async function stageBackupPayload(payload: string) {
  state.backup.status = t("正在安全暂存备份数据...");
  state.output = t("正在安全暂存备份数据...");
  return stagePrivatePayload(
    "tmp",
    privatePayloadBasename("webui-backup-restore", "b64"),
    payload,
    t("备份导入载荷"),
  );
}

async function runImportWarp(payload: string): Promise<void> {
  await withAction("warp-import", async () => {
    const staged = await stagePrivatePayload(
      "tmp",
      privatePayloadBasename("webui-warp", "conf"),
      payload,
      t("WARP 导入载荷"),
    );
    if (!staged) {
      state.output = t("安全临时数据写入失败，WARP 导入未开始。");
      return;
    }
    try {
      const outcome = await runPrivateCli(
        "warp import-file " + shellQuote(staged.path),
        t("导入并启用 WARP"),
        redactedCliPreview("warp import-file [private-payload]"),
      );
      if (!outcome.ok) {
        state.output = t("WARP 导入失败，请检查配置后重试。");
        return;
      }
      state.warp.importText = "";
      state.output = t("WARP 配置已导入并应用。");
      if (!(await refreshWarp(true))) {
        state.output = t("WARP 配置已导入，但状态刷新未确认，请检查输出后重试。");
        return;
      }
      state.output = t("WARP 配置已导入并应用。");
    } finally {
      const cleaned = await removePrivatePayload("tmp", staged.basename, t("WARP 导入载荷"));
      if (!cleaned) {
        state.phase = "error";
        state.output = state.output + t("\n\nWARP 私有临时数据清理未确认。");
      }
    }
  });
}

function importWarp(): void {
  const payload = state.warp.importText.trim();
  if (!payload) {
    state.output = t("请先粘贴 WARP/WireGuard 配置。");
    return;
  }
  if (!warpImportSummary.value.looksImportable) {
    state.output = warpImportSummary.value.message;
    return;
  }
  requestToolAction({
    key: "warp-import",
    get title() { return t("导入并启用 WARP"); },
    get detail() {
      const summary = summarizeWarpImport(payload);
      return t("会写入 WireGuard/WARP 配置，并让 MagicNet 应用新的 WARP 出站。{warning}", { warning: summary.status === "warning" ? ` ${summary.message}` : "" });
    },
    command: "warp import-file <config-file>",
    run: () => runImportWarp(payload),
  });
}

async function copyWarpSummary(): Promise<void> {
  warpSummaryCopied.value = await copyText(formatWarpImportSummaryReport(warpImportSummary.value));
  state.output = warpSummaryCopied.value ? t("WARP 导入摘要已复制。") : t("剪贴板不可用，WARP 导入摘要未复制。");
}

async function runSetWarpEnabled(enabled: boolean): Promise<void> {
  await withAction(enabled ? "warp-enable" : "warp-disable", async () => {
    const text = await runCli(enabled ? "warp enable" : "warp disable", enabled ? t("启用 WARP") : t("禁用 WARP"));
    if (execFailed(text)) return;
    state.output = text;
    if (!(await refreshWarp(true))) {
      state.output = t("WARP 开关已执行，但状态刷新未确认，请检查输出后重试。");
      return;
    }
    state.output = text || (enabled ? t("WARP 已启用。") : t("WARP 已禁用。"));
  });
}

function setWarpEnabled(enabled: boolean): void {
  requestToolAction({
    key: enabled ? "warp-enable" : "warp-disable",
    get title() { return enabled ? t("启用 WARP") : t("禁用 WARP"); },
    get detail() { return enabled ? t("会启用当前 WARP 出站配置。") : t("会关闭 WARP 出站，已依赖 WARP 的路由会失效。"); },
    command: enabled ? "warp enable" : "warp disable",
    run: () => runSetWarpEnabled(enabled),
  });
}

async function testWarp(): Promise<void> {
  await withAction("warp-test", async () => {
    state.output = await runCli("warp test", t("测试 WARP"));
  });
}

async function runSelectWarpGlobal(enabled: boolean): Promise<void> {
  await withAction(enabled ? "warp-global" : "warp-rule", async () => {
    state.output = await runCli(enabled ? "warp global" : "warp rule", enabled ? t("全局走 WARP") : t("恢复规则出站"));
  });
}

function selectWarpGlobal(enabled: boolean): void {
  requestToolAction({
    key: enabled ? "warp-global" : "warp-rule",
    get title() { return enabled ? t("全局走 WARP") : t("恢复规则出站"); },
    get detail() { return enabled ? t("会把默认出站切到 WARP。") : t("会恢复按规则选择出站。"); },
    command: enabled ? "warp global" : "warp rule",
    run: () => runSelectWarpGlobal(enabled),
  });
}

</script>

<template>
  <div class="grid gap-4">
    <PageHeader :overline="t('工具')" :title="t('工具')">
      <Button variant="outline" :loading="toolsRefreshing" @click="refreshTools">
        <RefreshCw :size="17" />{{ t("刷新") }}
      </Button>
    </PageHeader>

    <ToolActionConfirmCard
      v-if="pendingToolAction"
      :action="pendingToolAction"
      :loading="isRunning(pendingToolAction.key)"
      @cancel="cancelToolAction"
      @confirm="confirmToolAction"
    />

    <div class="grid min-w-0 gap-3 md:grid-cols-2">
      <NetworkPolicyCard />

      <DnsToolsCard />

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Network :size="17" /> {{ t("WARP 出站") }}</h3>
        <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("导入 WireGuard 配置后，可全局使用 WARP，或仅用于指定域名。") }}</p>
        <Textarea v-model="state.warp.importText" class="min-h-32 font-mono text-xs" spellcheck="false" placeholder="[Interface]&#10;PrivateKey = ...&#10;Address = ...&#10;&#10;[Peer]&#10;PublicKey = ...&#10;Endpoint = ...:2408" />
        <div class="rounded-md border p-3 text-sm leading-6" :class="warpImportTone(warpImportSummary.status)">
          <p class="font-medium">{{ warpImportSummary.status === 'ok' ? t("可导入") : warpImportSummary.status === 'warning' ? t("可导入但需确认") : warpImportSummary.status === 'error' ? t("不能导入") : t("等待配置") }}</p>
          <p class="mt-1 text-xs opacity-80">{{ warpImportSummary.message }}</p>
          <p class="mt-2 text-xs opacity-80">
            Interface {{ warpImportSummary.hasInterface ? t("存在") : t("缺失") }} · Peer {{ warpImportSummary.hasPeer ? t("存在") : t("缺失") }} · Address {{ warpImportSummary.hasAddress ? t("存在") : t("缺失") }} · Endpoint {{ warpImportSummary.hasEndpoint ? t("存在") : t("缺失") }}
          </p>
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <Button :disabled="!warpImportSummary.looksImportable" :loading="isRunning('warp-import')" @click="importWarp"><Upload :size="16" />{{ t("导入并启用") }}</Button>
          <Button variant="outline" :disabled="!state.warp.importText.trim()" @click="copyWarpSummary"><Copy :size="16" />{{ warpSummaryCopied ? t("已复制摘要") : t("复制导入摘要") }}</Button>
          <Button variant="secondary" :disabled="!state.warp.configured" :loading="isRunning('warp-test')" @click="testWarp"><RadioTower :size="16" />{{ t("测试 WARP") }}</Button>
          <Button variant="outline" :disabled="!state.warp.configured || state.warp.enabled" :loading="isRunning('warp-enable')" @click="setWarpEnabled(true)"><Power :size="16" />{{ t("启用") }}</Button>
          <Button variant="outline" :disabled="!state.warp.enabled" :loading="isRunning('warp-disable')" @click="setWarpEnabled(false)"><PowerOff :size="16" />{{ t("禁用") }}</Button>
          <Button variant="secondary" :disabled="!state.warp.enabled" :loading="isRunning('warp-global')" @click="selectWarpGlobal(true)">{{ t("全局走 WARP") }}</Button>
          <Button variant="outline" :loading="isRunning('warp-rule')" @click="selectWarpGlobal(false)">{{ t("恢复规则") }}</Button>
        </div>
        <WarpRouteRulesPanel />
        <pre class="max-h-44 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">enabled={{ state.warp.enabled ? "1" : "0" }}
configured={{ state.warp.configured ? "1" : "0" }}
tag={{ state.warp.tag }}
endpoint={{ state.warp.endpoint || "-" }}
addresses={{ state.warp.addresses }}
allowed_ips={{ state.warp.allowedIps }}</pre>
      </Card>

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" /> {{ t("配置迁移") }}</h3>
        <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("导出会打包订阅、应用名单、黑名单、路由规则等用户配置。安全码可留空；设置后导入时必须填写一致。") }}</p>
        <div class="grid gap-2 sm:grid-cols-2">
          <Input v-model="state.backup.exportPassword" type="password" autocomplete="new-password" :placeholder="t('导出安全码，可留空')" />
          <Button :loading="isRunning('backup-export')" @click="exportBackup"><Download :size="16" />{{ t("导出到备份框") }}</Button>
        </div>
        <Textarea v-model="state.backup.payload" class="min-h-28" spellcheck="false" :placeholder="t('备份字符串会出现在这里，也可以手动粘贴剪切板内容')" />
        <div class="grid gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
          <span>{{ t("行数：{count}", { count: backupPayloadSummary.lines }) }}</span>
          <span>{{ t("字符数：{count}", { count: backupPayloadSummary.chars }) }}</span>
          <span>{{ t("非空白字符数：{count}", { count: backupPayloadSummary.compactChars }) }}</span>
          <span :class="backupPayloadSummary.looksValid ? 'text-[var(--mn-success)]' : 'text-[var(--mn-warning)]'">
            {{ backupPayloadSummary.looksValid ? `fnv32:${backupPayloadSummary.fingerprint}` : backupPayloadSummary.tooLarge ? t("超过 5MiB") : backupPayloadSummary.invalidChars ? t("含非法字符") : backupPayloadSummary.hasWhitespace ? t("含空白，将压缩检查") : t("等待有效备份") }}
          </span>
        </div>
        <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto_auto]">
          <Input v-model="state.backup.restorePassword" type="password" autocomplete="current-password" :placeholder="t('导入安全码，可留空')" />
          <Button variant="secondary" :loading="isRunning('backup-paste')" @click="pasteBackup"><ClipboardPaste :size="16" />{{ t("读剪切板") }}</Button>
          <Button variant="outline" :disabled="!state.backup.payload.trim()" @click="copyBackupSummary"><Copy :size="16" />{{ backupSummaryCopied ? t("已复制摘要") : t("复制摘要") }}</Button>
          <Button :loading="isRunning('backup-restore')" @click="restoreBackup"><Upload :size="16" />{{ t("导入配置") }}</Button>
        </div>
        <p class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ t(state.backup.status) }}</p>
      </Card>

      <EcaptureToolsCard />

    </div>

    <div class="grid min-w-0 gap-3 md:grid-cols-2">
      <McpToolsCard />

      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Network :size="17" /> {{ t("拓扑 / 路由") }}</h3>
        <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("只读网络与路由快照。") }}</p>
        <div class="grid gap-2">
          <Button variant="secondary" :loading="isRunning('refresh-topology')" @click="withAction('refresh-topology', () => refreshTopology())">{{ t("刷新拓扑/路由") }}</Button>
          <Button variant="secondary" :loading="isRunning('refresh-sysroute')" @click="withAction('refresh-sysroute', () => refreshSysroute())">{{ t("刷新路由") }}</Button>
        </div>
      </Card>
    </div>

    <NetworkSnapshotPanel :topology="state.topology" :sysroute="state.sysroute" />
  </div>
</template>
