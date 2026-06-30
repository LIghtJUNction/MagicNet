<script setup lang="ts">
import { Box, Copy, DownloadCloud, RefreshCw, Save } from "lucide-vue-next";
import { ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, copyText, execFailed } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, startBackgroundCli, refreshSubs, shellQuote, uniqueNonEmpty } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");
const pendingSubscriptionAction = ref<PendingToolAction | null>(null);

watch(() => state.subscriptions.singBoxUrls, (urls) => {
  singBoxText.value = urls.join("\n");
}, { immediate: true });

function requestSubscriptionAction(action: PendingToolAction): void {
  pendingSubscriptionAction.value = action;
}

function cancelSubscriptionAction(): void {
  pendingSubscriptionAction.value = null;
}

async function confirmSubscriptionAction(): Promise<void> {
  const action = pendingSubscriptionAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingSubscriptionAction.value = null;
  }
}

function normalizedSingBoxUrls(): string[] | null {
  const raw = singBoxText.value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const lines = uniqueNonEmpty(raw).slice(0, 5);
  if (lines.some((line) => !/^https?:\/\/\S+$/i.test(line))) {
    state.output = "sing-box 订阅格式不对，必须一行一个 http(s) URL。";
    return null;
  }
  if (!lines.length) {
    state.output = "请至少填写一个 sing-box 订阅 URL。";
    return null;
  }
  if (raw.length !== lines.length) state.output = `将自动去重/裁剪：${raw.length} -> ${lines.length}`;
  return lines;
}

async function runSaveSingBox(lines: string[]): Promise<void> {
  await withAction("save-singbox", async () => {
    singBoxText.value = lines.join("\n");
    const encoded = bytesToBase64(new TextEncoder().encode(`${lines.join("\n")}\n`));
    const text = await runCli(`sub set-file sing-box ${shellQuote(encoded)}`, "保存 sing-box 订阅");
    if (execFailed(text)) return;
    await startBackgroundCli("sub update sing-box", "更新 sing-box 节点");
    state.output += "\n\n已开始后台拉取并导入 sing-box 节点。完成后进入 sing-box WebUI 查看节点。";
    await refreshSubs(true);
  });
}

function saveSingBox(): void {
  const lines = normalizedSingBoxUrls();
  if (!lines) return;
  requestSubscriptionAction({
    key: "save-singbox",
    title: "保存并更新 sing-box 订阅",
    detail: `会保存 ${lines.length} 个订阅 URL，并立即后台联网拉取、解析和写入节点配置。`,
    command: "sub set-file sing-box <encoded-urls> && sub update sing-box",
    run: () => runSaveSingBox(lines),
  });
}

async function runUpdateAll(): Promise<void> {
  await withAction("update-all", async () => {
    await startBackgroundCli("sub update-all", "更新全部订阅");
    window.setTimeout(() => void refreshSubs(true), 1200);
  });
}

function updateAll(): void {
  const count = state.subscriptions.singBoxUrls.length;
  requestSubscriptionAction({
    key: "update-all",
    title: "更新全部订阅",
    detail: `会后台联网更新全部订阅来源。当前 sing-box 订阅数量：${count}。`,
    command: "sub update-all",
    run: runUpdateAll,
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
    <PageHeader overline="Subscriptions" title="订阅管理" description="这里只保存订阅链接和备份配置；节点选择交给 sing-box WebUI。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('refresh-subs')" @click="withAction('refresh-subs', () => refreshSubs())"><RefreshCw :size="17" />刷新</Button>
        <Button :loading="isRunning('update-all')" @click="updateAll"><DownloadCloud :size="17" />更新全部</Button>
      </div>
    </PageHeader>

    <ToolActionConfirmCard
      v-if="pendingSubscriptionAction"
      :action="pendingSubscriptionAction"
      :loading="isRunning(pendingSubscriptionAction.key)"
      @cancel="cancelSubscriptionAction"
      @confirm="confirmSubscriptionAction"
    />

    <div class="grid gap-3">
      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><Box :size="17" />sing-box 订阅</h3>
        <p class="text-sm leading-6 text-zinc-400">最多 5 个，一行一个。保存后会在后台拉取、解析并写入 sing-box config.json；节点选择仍在 sing-box WebUI。</p>
        <Textarea v-model="singBoxText" class="my-2 min-h-36" spellcheck="false" />
        <div class="flex flex-wrap items-center gap-2">
          <Button :loading="isRunning('save-singbox')" @click="saveSingBox"><Save :size="16" />保存</Button>
          <Button variant="outline" @click="copy(singBoxText, 'sing-box 订阅')"><Copy :size="16" />复制</Button>
        </div>
      </Card>

    </div>
  </div>
</template>
