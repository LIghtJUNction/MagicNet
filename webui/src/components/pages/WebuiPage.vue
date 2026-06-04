<script setup lang="ts">
import { DownloadCloud, ExternalLink, Github, RefreshCw } from "lucide-vue-next";
import { ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, openExternal, shellQuote, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const status = ref("");
const panel = ref({
  name: "zashboard",
  url: "",
  metadata: ""
});

async function refreshWebui(): Promise<void> {
  await withAction("webui-status", async () => {
    status.value = await runCli("webui status", "读取 WebUI 配置", true);
    state.output = status.value;
  });
}

async function installLocal(): Promise<void> {
  await withAction("webui-install", async () => {
    const url = panel.value.url.trim();
    if (!/^https?:\/\/\S+$/i.test(url)) {
      state.output = "本地面板下载 URL 必须是 http(s) 链接。";
      return;
    }
    await runCli(`webui install-local ${shellQuote(url)} ${shellQuote(panel.value.name.trim() || "custom")}`, "安装本地 WebUI 面板");
    await refreshWebui();
  });
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
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Core WebUI" title="面板配置" description="管理核心 WebUI 面板入口。本地面板会下载到模块目录，在线面板通过申请 issue 进入内置审核。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('webui-status')" @click="refreshWebui"><RefreshCw :size="17" />读取</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), 'WebUI 适配 Issue')"><Github :size="17" />申请适配</Button>
      </div>
    </PageHeader>

    <div class="grid gap-3 md:grid-cols-2">
      <Card class="grid gap-3">
        <h3 class="text-base font-semibold">本地面板</h3>
        <Input v-model="panel.name" placeholder="面板名字，例如 zashboard" spellcheck="false" />
        <Input v-model="panel.url" placeholder="https://example.com/panel.zip" spellcheck="false" />
        <Textarea v-model="panel.metadata" class="min-h-28" placeholder="面板元数据、说明、仓库链接、适配注意事项" spellcheck="false" />
        <Button :loading="isRunning('webui-install')" @click="installLocal"><DownloadCloud :size="17" />下载并安装</Button>
      </Card>

      <Card class="grid gap-3">
        <h3 class="text-base font-semibold">当前状态</h3>
        <p class="text-sm leading-6 text-zinc-400">sing-box 默认使用本地 zashboard；mihomo 可从控制页打开 Meta Cube X、Yacd 或 zashboard。</p>
        <Button variant="outline" @click="openExternal(REPO, 'MagicNet GitHub')"><ExternalLink :size="17" />打开项目仓库</Button>
        <pre class="max-h-80 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ status || "点击读取查看 webui status。" }}</pre>
      </Card>
    </div>
  </div>
</template>
