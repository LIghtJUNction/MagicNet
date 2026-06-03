<script setup lang="ts">
import { Copy, DownloadCloud, RefreshCw, Save } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, copyText } from "@/utils";

const { state, runCli, refreshSubs, shellQuote, uniqueNonEmpty } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");

watch(() => state.subscriptions.singBoxUrls, (urls) => {
  singBoxText.value = urls.join("\n");
}, { immediate: true });

const providerNames = computed(() => state.subscriptions.mihomoProviders.map((item) => item.name));

async function saveSingBox(): Promise<void> {
  await withAction("save-singbox", async () => {
    const raw = singBoxText.value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    const lines = uniqueNonEmpty(raw).slice(0, 5);
    if (lines.some((line) => !/^https?:\/\/\S+$/i.test(line))) {
      state.output = "sing-box 订阅格式不对，必须一行一个 http(s) URL。";
      return;
    }
    singBoxText.value = lines.join("\n");
    const encoded = bytesToBase64(new TextEncoder().encode(`${lines.join("\n")}\n`));
    await runCli(`sub set-file sing-box ${shellQuote(encoded)}`, "保存 sing-box 订阅");
    if (raw.length !== lines.length) state.output += `\n\n已自动去重/裁剪：${raw.length} -> ${lines.length}`;
    await refreshSubs(true);
  });
}

async function saveProvider(name: string, value: string): Promise<void> {
  await withAction(`save-provider-${name}`, async () => {
    if (!/^https?:\/\/\S+$/i.test(value)) {
      state.output = `${name} 订阅链接格式不对。`;
      return;
    }
    await runCli(`sub set mihomo ${shellQuote(name)} ${shellQuote(value)}`, `保存 ${name}`);
    await refreshSubs(true);
  });
}

async function copy(text: string, label: string): Promise<void> {
  if (!text) {
    state.output = `${label} 为空。`;
    return;
  }
  state.output = await copyText(text) ? `已复制 ${label}。` : `剪贴板不可用，${label} 未复制。`;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Subscriptions" title="订阅管理" description="这里只保存订阅链接和备份配置；节点选择交给内核 WebUI。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('refresh-subs')" @click="withAction('refresh-subs', () => refreshSubs())"><RefreshCw :size="17" />刷新</Button>
        <Button :loading="isRunning('update-all')" @click="withAction('update-all', async () => { await runCli('sub update-all', '更新全部订阅'); await refreshSubs(true); })"><DownloadCloud :size="17" />更新全部</Button>
      </div>
    </PageHeader>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 text-base font-semibold">sing-box 订阅</h3>
        <p class="text-sm leading-6 text-zinc-400">最多 5 个，一行一个，保存时自动去重。</p>
        <Textarea v-model="singBoxText" class="my-2 min-h-36" spellcheck="false" />
        <div class="flex flex-wrap items-center gap-2">
          <Button :loading="isRunning('save-singbox')" @click="saveSingBox"><Save :size="16" />保存</Button>
          <Button variant="outline" @click="copy(singBoxText, 'sing-box 订阅')"><Copy :size="16" />复制</Button>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">过滤免费节点</h3>
        <p class="text-sm leading-6 text-zinc-400">仅切换 MagicNet 订阅预处理开关，不进入节点管理。</p>
        <Button :variant="state.subscriptions.freeFilter ? 'default' : 'outline'" :loading="isRunning('free-filter')" @click="withAction('free-filter', async () => { await runCli(state.subscriptions.freeFilter ? 'sub filter-free off' : 'sub filter-free on', '切换免费节点过滤'); await refreshSubs(true); })">
          {{ state.subscriptions.freeFilter ? "已开启过滤" : "已关闭过滤" }}
        </Button>
      </Card>
    </div>

    <Card>
      <h3 class="mb-2 text-base font-semibold">mihomo providers</h3>
      <div class="grid gap-3">
        <label v-for="provider in state.subscriptions.mihomoProviders" :key="provider.name" class="grid gap-2">
          <span class="text-sm text-zinc-300">{{ provider.name }}</span>
          <Textarea v-model="provider.url" class="min-h-20" spellcheck="false" />
          <div class="flex flex-wrap items-center gap-2">
            <Button variant="secondary" :loading="isRunning(`save-provider-${provider.name}`)" @click="saveProvider(provider.name, provider.url)">保存</Button>
            <Button variant="outline" @click="copy(provider.url, provider.name)">复制</Button>
          </div>
        </label>
        <p v-if="!providerNames.length" class="text-sm leading-6 text-zinc-400">未读取到 mihomo provider。请先确认 config.yaml 的 proxy-providers。</p>
      </div>
    </Card>
  </div>
</template>
