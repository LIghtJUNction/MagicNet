<script setup lang="ts">
import { ClipboardPaste, Copy, Download, Network, Power, PowerOff, RadioTower, RefreshCw, Save, Server, Upload } from "lucide-vue-next";
import { ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, readClipboardText, shellQuote as quoteShell } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import DnsToolsCard from "./DnsToolsCard.vue";
import NetworkSnapshotPanel from "./NetworkSnapshotPanel.vue";
import WarpRouteRulesPanel from "./WarpRouteRulesPanel.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runShell, runCli, refreshDns, refreshMcp, refreshTopology, refreshSysroute, refreshWarp, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const toolsRefreshing = ref(false);
const mcpBind = ref(state.mcp.bind);
const mcpPort = ref(state.mcp.port);
const pendingToolAction = ref<PendingToolAction | null>(null);
watch(() => state.mcp.bind, (value) => { mcpBind.value = value; });
watch(() => state.mcp.port, (value) => { mcpPort.value = value; });

async function refreshTools(): Promise<void> {
  toolsRefreshing.value = true;
  state.task = "刷新工具状态";
  try {
    await refreshDns(true);
    await refreshWarp(true);
    await refreshMcp(true);
    state.output = "工具状态已刷新。";
  } finally {
    toolsRefreshing.value = false;
    state.task = "";
  }
}
async function copyMcp(): Promise<void> {
  const command = `adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp secret"'\nadb forward tcp:${state.mcp.port} tcp:${state.mcp.port}`;
  state.output = await copyText(`${state.mcp.url}\n${command}`)
    ? "已复制 MCP URL 和 adb forward 命令。"
    : "剪贴板不可用，MCP 连接未复制。";
}
async function runTcpdumpProbe(): Promise<void> {
  await runShell("timeout 10 tcpdump -i any -nn -c 30 'tcp port 443 or udp port 53 or tcp port 53 or tcp port 853 or udp port 853'", "tcpdump 快速抓包");
}

async function runEcaptureTlsCapture(): Promise<void> {
  await withAction("ecapture-tls-quick", async () => {
    state.output = await runCli("ecapture tls 8 all all", "eCapture TLS 短抓");
  });
}

function tcpdumpProbe(): void {
  requestToolAction({
    key: "tcpdump-probe",
    title: "执行 tcpdump 探测",
    detail: "会短时间读取设备网络流量元数据，可能影响性能并暴露连接信息。",
    command: "timeout 10 tcpdump -i any -nn -c 30 ...",
    run: runTcpdumpProbe,
  });
}

function ecaptureTlsCapture(): void {
  requestToolAction({
    key: "ecapture-tls-quick",
    title: "执行 eCapture TLS 短抓",
    detail: "会运行 8 秒无证书 TLS 文本抓取，可能输出连接域名、进程或明文片段，仅在排障时使用。",
    command: "ecapture tls 8 all all",
    run: runEcaptureTlsCapture,
  });
}
function validateMcpEndpoint(): { bind: string; port: string } | null {
  const bind = mcpBind.value.trim();
  const port = mcpPort.value.trim();
  if (!bind || !/^[A-Za-z0-9_.:-]+$/.test(bind)) {
    state.output = "MCP host 格式不对。常用值：127.0.0.1 或 0.0.0.0。";
    return null;
  }
  const portNumber = Number(port);
  if (!/^\d+$/.test(port) || !Number.isInteger(portNumber) || portNumber < 1 || portNumber > 65535) {
    state.output = "MCP port 必须是 1-65535 的数字。";
    return null;
  }
  return { bind, port };
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
async function runSaveMcpEndpoint(endpoint: { bind: string; port: string }): Promise<void> {
  await withAction("save-mcp", async () => {
    await runCli(`mcp set ${shellQuote(endpoint.bind)} ${shellQuote(endpoint.port)}`, "保存 MCP 地址");
    if (state.mcp.pid !== "stopped") {
      await runCli("mcp restart", "重启 MCP");
    }
    await refreshMcp(true);
  });
}
function saveMcpEndpoint(): void {
  const endpoint = validateMcpEndpoint();
  if (!endpoint) return;
  requestToolAction({
    key: "save-mcp",
    title: "保存并重启 MCP",
    detail: "会写入 MCP 监听地址；如果 MCP 正在运行，还会重启服务。",
    command: `mcp set ${endpoint.bind} ${endpoint.port}${state.mcp.pid !== "stopped" ? " && mcp restart" : ""}`,
    run: () => runSaveMcpEndpoint(endpoint),
  });
}
async function runStartMcp(endpoint: { bind: string; port: string }): Promise<void> {
  await withAction("start-mcp", async () => {
    await runCli(`mcp enable ${shellQuote(endpoint.bind)} ${shellQuote(endpoint.port)}`, "启动 MCP");
    await refreshMcp(true);
  });
}
function startMcp(): void {
  const endpoint = validateMcpEndpoint();
  if (!endpoint) return;
  requestToolAction({
    key: "start-mcp",
    title: "启动 MCP 服务",
    detail: "会启用设备侧 MCP，并按当前 host/port 写入监听配置。",
    command: `mcp enable ${endpoint.bind} ${endpoint.port}`,
    run: () => runStartMcp(endpoint),
  });
}
async function runStopMcp(): Promise<void> {
  await withAction("stop-mcp", async () => {
    await runCli("mcp stop", "停止 MCP");
    await refreshMcp(true);
  });
}

function stopMcp(): void {
  requestToolAction({
    key: "stop-mcp",
    title: "停止 MCP 进程",
    detail: "会停止当前 MCP 进程，但保留启用配置。",
    command: "mcp stop",
    run: runStopMcp,
  });
}

async function runDisableMcp(): Promise<void> {
  await withAction("disable-mcp", async () => {
    await runCli("mcp disable", "禁用 MCP");
    await refreshMcp(true);
  });
}

function disableMcp(): void {
  requestToolAction({
    key: "disable-mcp",
    title: "禁用并停止 MCP",
    detail: "会关闭 MCP 自启动并停止当前进程。",
    command: "mcp disable",
    run: runDisableMcp,
  });
}

async function exportBackup(): Promise<void> {
  await withAction("backup-export", async () => {
    const password = state.backup.exportPassword.trim();
    const text = await runCli(password ? `backup export ${shellQuote(password)}` : "backup export", "导出配置备份");
    const payload = text.trim().split(/\s+/).pop() || "";
    if (!payload || payload.includes("[error]")) {
      state.backup.status = "导出失败";
      return;
    }
    state.backup.payload = payload;
    state.backup.status = await copyText(payload) ? "已导出并复制到剪切板" : "已导出，剪切板不可用";
    state.output = state.backup.status;
  });
}

async function pasteBackup(): Promise<void> {
  await withAction("backup-paste", async () => {
    const text = (await readClipboardText()).trim();
    if (!text) {
      state.backup.status = "剪切板为空或不可读取，请手动粘贴";
      state.output = state.backup.status;
      return;
    }
    state.backup.payload = text;
    state.backup.status = `已从剪切板读取 ${text.length} 字符`;
  });
}

async function runRestoreBackup(payload: string): Promise<void> {
  await withAction("backup-restore", async () => {
    const password = state.backup.restorePassword.trim() || "-";
    const path = await writeBackupPayloadFile(payload);
    try {
      const text = await runCli(`backup restore-file ${shellQuote(password)} ${shellQuote(path)}`, "导入配置备份");
      state.backup.status = text.includes("Backup restored") ? "导入成功，运行配置已应用" : "导入失败，请检查安全码和备份内容";
      state.output = `${state.backup.status}\n\n${text}`;
    } finally {
      await runShell(`rm -f ${quoteShell(path)}`, "清理备份导入文件", true);
    }
  });
}

function restoreBackup(): void {
  const payload = state.backup.payload.trim();
  if (!payload) {
    state.backup.status = "请先粘贴备份字符串";
    state.output = state.backup.status;
    return;
  }
  requestToolAction({
    key: "backup-restore",
    title: "导入配置备份",
    detail: "会覆盖设备上的订阅、应用名单、黑名单和路由等运行配置。",
    command: "backup restore-file <security-code> <payload-file>",
    run: () => runRestoreBackup(payload),
  });
}

async function writeWarpImportFile(payload: string): Promise<string> {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const path = `/data/adb/modules/MagicNet/.tmp/webui-warp-${stamp}.conf`;
  await runShell(`mkdir -p /data/adb/modules/MagicNet/.tmp; : > ${quoteShell(path)}`, "准备 WARP 导入文件", true);
  const chunkSize = 2800;
  for (let offset = 0; offset < payload.length; offset += chunkSize) {
    const chunk = payload.slice(offset, offset + chunkSize);
    await runShell(`printf %s ${quoteShell(chunk)} >> ${quoteShell(path)}`, "写入 WARP 导入文件", true);
  }
  await runShell(`printf '\\n' >> ${quoteShell(path)}`, "完成 WARP 导入文件", true);
  return path;
}

async function runImportWarp(payload: string): Promise<void> {
  await withAction("warp-import", async () => {
    const path = await writeWarpImportFile(payload);
    const text = await runCli(`warp import-file ${shellQuote(path)}`, "导入并启用 WARP");
    await runShell(`rm -f ${quoteShell(path)}`, "清理 WARP 导入文件", true);
    state.warp.importText = "";
    state.output = text.includes("[error]") ? text : "WARP 配置已导入并应用。";
    await refreshWarp(true);
  });
}

function importWarp(): void {
  const payload = state.warp.importText.trim();
  if (!payload) {
    state.output = "请先粘贴 WARP/WireGuard 配置。";
    return;
  }
  requestToolAction({
    key: "warp-import",
    title: "导入并启用 WARP",
    detail: "会写入 WireGuard/WARP 配置，并让 MagicNet 应用新的 WARP 出站。",
    command: "warp import-file <config-file>",
    run: () => runImportWarp(payload),
  });
}

async function runSetWarpEnabled(enabled: boolean): Promise<void> {
  await withAction(enabled ? "warp-enable" : "warp-disable", async () => {
    const text = await runCli(enabled ? "warp enable" : "warp disable", enabled ? "启用 WARP" : "禁用 WARP");
    state.output = text;
    await refreshWarp(true);
  });
}

function setWarpEnabled(enabled: boolean): void {
  requestToolAction({
    key: enabled ? "warp-enable" : "warp-disable",
    title: enabled ? "启用 WARP" : "禁用 WARP",
    detail: enabled ? "会启用当前 WARP 出站配置。" : "会关闭 WARP 出站，已依赖 WARP 的路由会失效。",
    command: enabled ? "warp enable" : "warp disable",
    run: () => runSetWarpEnabled(enabled),
  });
}

async function testWarp(): Promise<void> {
  await withAction("warp-test", async () => {
    state.output = await runCli("warp test", "测试 WARP");
  });
}

async function runSelectWarpGlobal(enabled: boolean): Promise<void> {
  await withAction(enabled ? "warp-global" : "warp-rule", async () => {
    state.output = await runCli(enabled ? "warp global" : "warp rule", enabled ? "全局走 WARP" : "恢复规则出站");
  });
}

function selectWarpGlobal(enabled: boolean): void {
  requestToolAction({
    key: enabled ? "warp-global" : "warp-rule",
    title: enabled ? "全局走 WARP" : "恢复规则出站",
    detail: enabled ? "会把默认出站切到 WARP。" : "会恢复按规则选择出站。",
    command: enabled ? "warp global" : "warp rule",
    run: () => runSelectWarpGlobal(enabled),
  });
}

async function writeBackupPayloadFile(payload: string): Promise<string> {
  const path = `/data/adb/modules/MagicNet/.tmp/webui-backup-restore.b64`;
  state.backup.status = `正在写入备份 ${payload.length} 字符`;
  state.output = "正在分块写入备份文件...";
  await runShell(`mkdir -p /data/adb/modules/MagicNet/.tmp; : > ${quoteShell(path)}`, "准备导入文件", true);
  const chunkSize = 3800;
  for (let offset = 0; offset < payload.length; offset += chunkSize) {
    const chunk = payload.slice(offset, offset + chunkSize);
    await runShell(`printf %s ${quoteShell(chunk)} >> ${quoteShell(path)}`, "写入导入文件", true);
    state.backup.status = `正在写入备份 ${Math.min(offset + chunk.length, payload.length)} / ${payload.length}`;
  }
  await runShell(`printf '\\n' >> ${quoteShell(path)}`, "完成导入文件", true);
  return path;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Tools" title="工具" description="eCapture、MCP、拓扑和路由快照集中在这里。">
      <Button variant="outline" :loading="toolsRefreshing" @click="refreshTools">
        <RefreshCw :size="17" />刷新工具状态
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
      <DnsToolsCard />

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Network :size="17" /> WARP 出站</h3>
        <p class="text-sm leading-6 text-zinc-400">导入自己的 WARP/WireGuard 配置后，MagicNet 会生成 sing-box wireguard endpoint；可全局在 sing-box 选择器里选择 warp，也可给指定域名添加 warp 路由。</p>
        <Textarea v-model="state.warp.importText" class="min-h-32 font-mono text-xs" spellcheck="false" placeholder="[Interface]&#10;PrivateKey = ...&#10;Address = ...&#10;&#10;[Peer]&#10;PublicKey = ...&#10;Endpoint = ...:2408" />
        <div class="grid gap-2 sm:grid-cols-2">
          <Button :loading="isRunning('warp-import')" @click="importWarp"><Upload :size="16" />导入并启用</Button>
          <Button variant="secondary" :disabled="!state.warp.configured" :loading="isRunning('warp-test')" @click="testWarp"><RadioTower :size="16" />测试 WARP</Button>
          <Button variant="outline" :disabled="!state.warp.configured || state.warp.enabled" :loading="isRunning('warp-enable')" @click="setWarpEnabled(true)"><Power :size="16" />启用</Button>
          <Button variant="outline" :disabled="!state.warp.enabled" :loading="isRunning('warp-disable')" @click="setWarpEnabled(false)"><PowerOff :size="16" />禁用</Button>
          <Button variant="secondary" :disabled="!state.warp.enabled" :loading="isRunning('warp-global')" @click="selectWarpGlobal(true)">全局走 WARP</Button>
          <Button variant="outline" :loading="isRunning('warp-rule')" @click="selectWarpGlobal(false)">恢复规则</Button>
        </div>
        <WarpRouteRulesPanel />
        <pre class="max-h-44 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">enabled={{ state.warp.enabled ? "1" : "0" }}
configured={{ state.warp.configured ? "1" : "0" }}
tag={{ state.warp.tag }}
endpoint={{ state.warp.endpoint || "-" }}
addresses={{ state.warp.addresses }}
allowed_ips={{ state.warp.allowedIps }}</pre>
      </Card>

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" /> 配置迁移</h3>
        <p class="text-sm leading-6 text-zinc-400">导出会打包订阅、应用名单、黑名单、路由规则等用户配置。安全码可留空；设置后导入时必须填写一致。</p>
        <div class="grid gap-2 sm:grid-cols-2">
          <Input v-model="state.backup.exportPassword" type="password" autocomplete="new-password" placeholder="导出安全码，可留空" />
          <Button :loading="isRunning('backup-export')" @click="exportBackup"><Download :size="16" />导出并复制</Button>
        </div>
        <Textarea v-model="state.backup.payload" class="min-h-28" spellcheck="false" placeholder="备份字符串会出现在这里，也可以手动粘贴剪切板内容" />
        <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
          <Input v-model="state.backup.restorePassword" type="password" autocomplete="current-password" placeholder="导入安全码，可留空" />
          <Button variant="secondary" :loading="isRunning('backup-paste')" @click="pasteBackup"><ClipboardPaste :size="16" />读剪切板</Button>
          <Button :loading="isRunning('backup-restore')" @click="restoreBackup"><Upload :size="16" />导入配置</Button>
        </div>
        <p class="text-xs leading-5 text-zinc-500">{{ state.backup.status }}</p>
      </Card>

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><RadioTower :size="17" /> 无证书抓包</h3>
        <div class="grid gap-2 sm:grid-cols-2">
          <Button :loading="isRunning('ecapture-status')" @click="withAction('ecapture-status', () => runCli('ecapture status', '检查 eCapture'))">
            <RadioTower :size="16" />eCapture 状态
          </Button>
          <Button variant="secondary" :loading="isRunning('ecapture-version')" @click="withAction('ecapture-version', () => runCli('ecapture version', '查看 eCapture 版本'))">
            版本
          </Button>
          <Button variant="secondary" :loading="isRunning('tcpdump-probe')" @click="tcpdumpProbe">
            <Network :size="16" />tcpdump 探测
          </Button>
          <Button variant="outline" :loading="isRunning('ecapture-tls-quick')" @click="ecaptureTlsCapture">
            TLS 8s
          </Button>
          <Button variant="outline" :loading="isRunning('ecapture-help-tls')" @click="withAction('ecapture-help-tls', () => runCli('ecapture help tls', '查看 TLS 抓包帮助'))">
            TLS help
          </Button>
          <Button variant="outline" :loading="isRunning('ecapture-help-pcap')" @click="withAction('ecapture-help-pcap', () => runCli('ecapture help pcap', '查看 PCAP 抓包帮助'))">
            PCAP help
          </Button>
        </div>
      </Card>

    </div>

    <div class="grid min-w-0 gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Server :size="17" /> MCP 服务器</h3>
        <p class="text-sm leading-6 text-zinc-400">用于电脑侧通过 adb forward 控制模块。保存地址会写入模块配置；服务运行中保存会自动重启 MCP。</p>
        <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_7rem]">
          <Input v-model="mcpBind" placeholder="127.0.0.1" spellcheck="false" />
          <Input v-model="mcpPort" inputmode="numeric" placeholder="8766" spellcheck="false" />
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <Button :loading="isRunning('save-mcp')" @click="saveMcpEndpoint">
            <Save :size="16" />保存并重启
          </Button>
          <Button variant="secondary" :loading="isRunning('start-mcp')" @click="startMcp">
            <Power :size="16" />启动
          </Button>
          <Button variant="outline" :disabled="state.mcp.pid === 'stopped'" :loading="isRunning('stop-mcp')" @click="stopMcp">
            <PowerOff :size="16" />停止进程
          </Button>
          <Button variant="outline" :loading="isRunning('disable-mcp')" @click="disableMcp">
            <PowerOff :size="16" />禁用并停止
          </Button>
          <Button variant="outline" @click="copyMcp"><Copy :size="16" />复制连接</Button>
        </div>
        <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">pid={{ state.mcp.pid }}
enabled={{ state.mcp.enabled ? "1" : "0" }}
bind={{ state.mcp.bind }}
port={{ state.mcp.port }}
secret_set={{ state.mcp.secretSet ? "1" : "0" }}
url={{ state.mcp.url }}
secret_command=su -M -c "/data/adb/modules/MagicNet/cli mcp secret"</pre>
      </Card>

      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Network :size="17" /> 拓扑 / 路由</h3>
        <p class="text-sm leading-6 text-zinc-400">只读展示网络链路和路由快照，设备 CLI 没有拓扑命令时自动回退到路由快照。</p>
        <div class="grid gap-2">
          <Button variant="secondary" :loading="isRunning('refresh-topology')" @click="withAction('refresh-topology', () => refreshTopology())">刷新拓扑/路由</Button>
          <Button variant="secondary" :loading="isRunning('refresh-sysroute')" @click="withAction('refresh-sysroute', () => refreshSysroute())">刷新路由</Button>
        </div>
      </Card>
    </div>

    <NetworkSnapshotPanel :topology="state.topology" :sysroute="state.sysroute" />
  </div>
</template>
