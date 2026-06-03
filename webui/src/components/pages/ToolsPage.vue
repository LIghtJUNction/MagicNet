<script setup lang="ts">
import { Copy, FileLock, Network, RadioTower, RefreshCw, Server, ShieldPlus, Trash2, Wand2 } from "lucide-vue-next";
import { ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, copyText } from "@/utils";

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
