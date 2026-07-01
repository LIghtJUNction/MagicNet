<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Copy, Power, PowerOff, Save, Server } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, refreshMcp, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const mcpBind = ref(state.mcp.bind);
const mcpPort = ref(state.mcp.port);
const pendingMcpAction = ref<PendingToolAction | null>(null);
const copied = ref(false);

const mcpInsight = computed(() => {
  if (!state.mcp.enabled) return { tone: "warning", title: "MCP 未启用", detail: "启用后可通过 adb forward 连接电脑侧工具。" };
  if (state.mcp.pid === "stopped") return { tone: "warning", title: "MCP 已启用但未运行", detail: "可直接启动 MCP，或保存配置后重启。" };
  if (!state.mcp.secretSet) return { tone: "warning", title: "MCP secret 未设置", detail: "连接前需要在设备侧读取 secret。" };
  return { tone: "success", title: "MCP 可连接", detail: `${state.mcp.bind}:${state.mcp.port} 正在运行，电脑侧需要 adb forward。` };
});

watch(() => state.mcp.bind, (value) => { mcpBind.value = value; });
watch(() => state.mcp.port, (value) => { mcpPort.value = value; });
watch(() => [state.mcp.bind, state.mcp.port, state.mcp.pid, state.mcp.enabled], () => { copied.value = false; });
watch([mcpBind, mcpPort], () => { copied.value = false; });

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

async function runSaveMcpEndpoint(endpoint: { bind: string; port: string }): Promise<void> {
  await withAction("save-mcp", async () => {
    await runCli(`mcp set ${shellQuote(endpoint.bind)} ${shellQuote(endpoint.port)}`, "保存 MCP 地址");
    if (state.mcp.pid !== "stopped") await runCli("mcp restart", "重启 MCP");
    await refreshMcp(true);
  });
}

function saveMcpEndpoint(): void {
  const endpoint = validateMcpEndpoint();
  if (!endpoint) return;
  requestMcpAction({
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
  requestMcpAction({
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
  requestMcpAction({
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
  requestMcpAction({
    key: "disable-mcp",
    title: "禁用并停止 MCP",
    detail: "会关闭 MCP 自启动并停止当前进程。",
    command: "mcp disable",
    run: runDisableMcp,
  });
}

function requestMcpAction(action: PendingToolAction): void {
  pendingMcpAction.value = action;
}

async function confirmMcpAction(): Promise<void> {
  const action = pendingMcpAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingMcpAction.value = null;
  }
}

async function copyMcp(): Promise<void> {
  const command = `adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp secret"'\nadb forward tcp:${state.mcp.port} tcp:${state.mcp.port}`;
  copied.value = await copyText(`${state.mcp.url}\n${command}`);
  state.output = copied.value ? "已复制 MCP URL 和 adb forward 命令。" : "剪贴板不可用，MCP 连接未复制。";
}
</script>

<template>
  <Card>
    <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Server :size="17" /> MCP 服务器</h3>
    <p class="text-sm leading-6 text-zinc-400">用于电脑侧通过 adb forward 控制模块。保存地址会写入模块配置；服务运行中保存会自动重启 MCP。</p>

    <ToolActionConfirmCard
      v-if="pendingMcpAction"
      :action="pendingMcpAction"
      :loading="isRunning(pendingMcpAction.key)"
      @cancel="pendingMcpAction = null"
      @confirm="confirmMcpAction"
    />

    <div class="my-3 rounded-md border p-3" :class="mcpInsight.tone === 'success' ? 'border-lime-400/20 bg-lime-400/10 text-lime-100' : 'border-amber-400/30 bg-amber-400/10 text-amber-100'">
      <p class="text-sm font-semibold">{{ mcpInsight.title }}</p>
      <p class="mt-1 break-words text-sm leading-6 opacity-80">{{ mcpInsight.detail }}</p>
    </div>

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
      <Button variant="outline" @click="copyMcp"><Copy :size="16" />{{ copied ? "已复制连接" : "复制连接" }}</Button>
    </div>
    <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">pid={{ state.mcp.pid }}
enabled={{ state.mcp.enabled ? "1" : "0" }}
bind={{ state.mcp.bind }}
port={{ state.mcp.port }}
secret_set={{ state.mcp.secretSet ? "1" : "0" }}
url={{ state.mcp.url }}
secret_command=su -M -c "/data/adb/modules/MagicNet/cli mcp secret"</pre>
  </Card>
</template>
