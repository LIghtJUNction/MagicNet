<script setup lang="ts">
import { ClipboardPaste, Copy, Download, FileLock, Network, RadioTower, RefreshCw, Server, ShieldPlus, Trash2, Upload, Wand2 } from "lucide-vue-next";
import { ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, copyText, readClipboardText } from "@/utils";

const { state, runCli, refreshCapture, refreshCerts, refreshMcp, refreshTopology, refreshSysroute, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const captureApp = ref("");
const captureDomain = ref("");
const toolsRefreshing = ref(false);

async function refreshTools(): Promise<void> {
  toolsRefreshing.value = true;
  state.task = "刷新工具状态";
  try {
    await refreshCapture(true);
    await refreshCerts(true);
    await refreshMcp(true);
    state.output = "工具状态已刷新。";
  } finally {
    toolsRefreshing.value = false;
    state.task = "";
  }
}

async function saveCapture(): Promise<void> {
  await withAction("save-capture", async () => {
    await runCli(`capture set ${shellQuote(state.capture.host)} ${shellQuote(state.capture.port)} ${shellQuote(state.capture.name)}`, "保存抓包代理");
    await refreshCapture(true);
  });
}

async function addCapture(kind: "app" | "domain"): Promise<void> {
  const value = (kind === "app" ? captureApp.value : captureDomain.value).trim();
  if (!value) return;
  if (kind === "app" && !/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(value)) {
    state.output = "App 包名格式不对。示例：com.example.app";
    return;
  }
  if (kind === "domain" && !/^[A-Za-z0-9*_.-]+\.[A-Za-z0-9*_.-]+$/.test(value)) {
    state.output = "域名后缀格式不对。示例：target-api.com";
    return;
  }
  await runCli(kind === "app" ? `capture add-app ${shellQuote(value)}` : `capture add-domain ${shellQuote(value)}`, `添加抓包${kind}`);
  if (kind === "app") captureApp.value = "";
  else captureDomain.value = "";
  await refreshCapture(true);
}

async function ensureDefaultCert(): Promise<void> {
  await withAction("default-cert", async () => {
    await runCli("cert ensure-default", "生成 MagicNet 默认证书");
    await refreshCerts(true);
  });
}

async function installCert(): Promise<void> {
  await withAction("install-cert", async () => {
    const text = state.certs.text.trim();
    if (!text) {
      state.output = "请先粘贴 PEM/CRT 证书内容。";
      return;
    }
    await runCli(`cert install ${shellQuote(state.certs.name)} ${shellQuote(bytesToBase64(new TextEncoder().encode(text)))}`, "安装证书");
    state.certs.text = "";
    await refreshCerts(true);
  });
}

async function copyMcp(): Promise<void> {
  state.output = await copyText(`${state.mcp.url}\nadb forward tcp:${state.mcp.port} tcp:${state.mcp.port}`)
    ? "已复制 MCP URL 和 adb forward 命令。"
    : "剪贴板不可用，MCP 连接未复制。";
}

async function removeCert(file: string): Promise<void> {
  await withAction(`remove-cert-${file}`, async () => {
    state.certs.files = state.certs.files.filter((item) => item !== file);
    await runCli(`cert remove ${shellQuote(file)}`, `删除证书 ${file}`, true);
    await refreshCerts(true);
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

async function restoreBackup(): Promise<void> {
  await withAction("backup-restore", async () => {
    const payload = state.backup.payload.trim();
    if (!payload) {
      state.backup.status = "请先粘贴备份字符串";
      state.output = state.backup.status;
      return;
    }
    const password = state.backup.restorePassword.trim() || "-";
    const text = await runCli(`backup restore ${shellQuote(password)} ${shellQuote(payload)}`, "导入配置备份");
    state.backup.status = text.includes("Backup restored") ? "导入成功，运行配置已应用" : "导入失败，请检查安全码和备份内容";
    state.output = `${state.backup.status}\n\n${text}`;
  });
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Tools" title="工具" description="抓包、证书、MCP、拓扑和路由快照集中在这里。">
      <Button variant="outline" :loading="toolsRefreshing" @click="refreshTools">
        <RefreshCw :size="17" />刷新工具状态
      </Button>
    </PageHeader>

    <div class="grid gap-3 md:grid-cols-2">
      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" /> 配置迁移</h3>
        <p class="text-sm leading-6 text-zinc-400">导出会打包订阅、应用名单、黑名单、抓包规则等用户配置。安全码可留空；设置后导入时必须填写一致。</p>
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
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><RadioTower :size="17" /> 抓包代理</h3>
        <div class="grid gap-2">
          <Input v-model="state.capture.host" placeholder="电脑 IP" />
          <Input v-model="state.capture.port" placeholder="8888" />
          <Input v-model="state.capture.name" placeholder="MagicNet-Capture" />
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Button :loading="isRunning('save-capture')" @click="saveCapture">保存代理</Button>
          <Button :variant="state.capture.enabled ? 'default' : 'outline'" :loading="isRunning('toggle-capture')" @click="withAction('toggle-capture', async () => { await runCli(state.capture.enabled ? 'capture disable' : 'capture enable', '切换抓包'); await refreshCapture(true); })">
            {{ state.capture.enabled ? "已启用" : "已关闭" }}
          </Button>
        </div>
        <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <Input v-model="captureApp" placeholder="com.example.app" />
          <Button variant="secondary" :loading="isRunning('add-capture-app')" @click="withAction('add-capture-app', () => addCapture('app'))">加 App</Button>
        </div>
        <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <Input v-model="captureDomain" placeholder="target-api.com" />
          <Button variant="secondary" :loading="isRunning('add-capture-domain')" @click="withAction('add-capture-domain', () => addCapture('domain'))">加域名</Button>
        </div>
      </Card>

      <Card class="grid gap-3">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><ShieldPlus :size="17" /> 证书</h3>
        <Input v-model="state.certs.name" placeholder="magicnet-ca" />
        <Textarea v-model="state.certs.text" class="my-2 min-h-36" placeholder="粘贴 PEM/CRT 内容" />
        <div class="flex flex-wrap items-center gap-2">
          <Button variant="secondary" :loading="isRunning('default-cert')" @click="ensureDefaultCert"><Wand2 :size="16" />生成默认 CA</Button>
          <Button :loading="isRunning('install-cert')" @click="installCert">安装证书</Button>
          <Button variant="outline" :loading="isRunning('refresh-certs')" @click="withAction('refresh-certs', () => refreshCerts())"><RefreshCw :size="16" />读取</Button>
        </div>
        <p class="text-sm leading-6 text-zinc-400">{{ state.certs.dir }}</p>
        <div class="flex max-h-40 flex-wrap gap-2 overflow-auto">
          <span v-for="file in state.certs.files" :key="file" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ file }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-cert-${file}`)" type="button" title="删除证书" @click="removeCert(file)"><Trash2 :size="13" /></button>
          </span>
          <em v-if="!state.certs.files.length" class="text-sm not-italic text-zinc-500">暂无已安装证书</em>
        </div>
      </Card>
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Server :size="17" /> MCP 服务器</h3>
        <p class="text-sm leading-6 text-zinc-400">用于电脑侧通过 adb forward 控制模块。</p>
        <div class="grid gap-2">
          <Button :variant="state.mcp.pid !== 'stopped' ? 'default' : 'outline'" :loading="isRunning('toggle-mcp')" @click="withAction('toggle-mcp', async () => { await runCli(state.mcp.pid !== 'stopped' ? 'mcp disable' : 'mcp enable', '切换 MCP'); await refreshMcp(true); })">
            {{ state.mcp.pid !== "stopped" ? "关闭 MCP" : "开启 MCP" }}
          </Button>
          <Button variant="outline" @click="copyMcp"><Copy :size="16" />复制连接</Button>
        </div>
        <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">pid={{ state.mcp.pid }}
url={{ state.mcp.url }}</pre>
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

    <Card v-if="state.topology || state.sysroute">
      <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" /> 当前网络快照</h3>
      <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ state.topology || state.sysroute }}</pre>
    </Card>
  </div>
</template>
