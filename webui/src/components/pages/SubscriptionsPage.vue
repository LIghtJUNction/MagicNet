<script setup lang="ts">
import { Box, ClipboardPaste, Copy, DownloadCloud, RefreshCw, Save, ShieldCheck } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, copyText, execFailed, readClipboardText } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, startBackgroundCli, refreshSubs, shellQuote, uniqueNonEmpty } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");
const pendingSubscriptionAction = ref<PendingToolAction | null>(null);
type SubscriptionPreview = {
  key: string;
  index: number;
  label: string;
  status: "ok" | "duplicate" | "invalid" | "over-limit";
  notes: string[];
};
const inputSummary = computed(() => {
  const raw = singBoxText.value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const valid = raw.filter((line) => /^https?:\/\/\S+$/i.test(line));
  return {
    raw: raw.length,
    valid: valid.length,
    duplicate: Math.max(0, raw.length - uniqueNonEmpty(raw).length),
    overLimit: Math.max(0, uniqueNonEmpty(raw).length - 5)
  };
});
const subscriptionPreview = computed<SubscriptionPreview[]>(() => {
  const seen = new Set<string>();
  return singBoxText.value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line, index) => previewSubscriptionLine(line, index, seen))
    .slice(0, 8);
});

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

function previewSubscriptionLine(line: string, index: number, seen: Set<string>): SubscriptionPreview {
  try {
    const url = new URL(line);
    const normalized = url.toString();
    const duplicate = seen.has(normalized);
    seen.add(normalized);
    const protocolOk = url.protocol === "http:" || url.protocol === "https:";
    const notes = [
      url.search || url.hash ? "含参数，界面已隐藏" : "无 query/hash",
      url.pathname.length > 1 ? "含路径，界面已隐藏" : "无路径",
      url.protocol === "http:" ? "非 HTTPS" : ""
    ].filter(Boolean);
    return {
      key: `${index}-${url.hostname}`,
      index: index + 1,
      label: protocolOk ? `${url.protocol}//${url.hostname}` : "协议不支持",
      status: !protocolOk ? "invalid" : index >= 5 ? "over-limit" : duplicate ? "duplicate" : "ok",
      notes
    };
  } catch {
    return {
      key: `${index}-invalid`,
      index: index + 1,
      label: "无法解析 URL",
      status: "invalid",
      notes: ["必须是一行一个 http(s) URL"]
    };
  }
}

function previewTone(status: SubscriptionPreview["status"]): string {
  if (status === "ok") return "border-emerald-500/20 bg-emerald-500/10 text-emerald-100";
  if (status === "duplicate") return "border-amber-500/20 bg-amber-500/10 text-amber-100";
  return "border-red-500/20 bg-red-500/10 text-red-100";
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

function normalizeSingBoxInput(): void {
  const rawCount = singBoxText.value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).length;
  const lines = normalizedSingBoxUrls();
  if (!lines) return;
  singBoxText.value = lines.join("\n");
  state.output = `已规范化 sing-box 订阅输入：${rawCount} -> ${lines.length}。`;
}

async function pasteSingBox(): Promise<void> {
  await withAction("paste-singbox", async () => {
    const text = (await readClipboardText()).trim();
    if (!text) {
      state.output = "剪贴板为空或不可读取。";
      return;
    }
    singBoxText.value = text;
    state.output = `已从剪贴板读取 ${text.split(/\r?\n/).filter((line) => line.trim()).length} 行订阅文本。`;
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
        <div class="mb-2 grid gap-2 text-xs text-zinc-500 sm:grid-cols-4">
          <span>输入 {{ inputSummary.raw }} 行</span>
          <span>有效 {{ inputSummary.valid }} 个</span>
          <span>重复 {{ inputSummary.duplicate }} 个</span>
          <span>超限 {{ inputSummary.overLimit }} 个</span>
        </div>
        <div class="mb-3 grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3">
          <div class="flex items-center gap-2 text-sm font-medium text-zinc-200">
            <ShieldCheck :size="16" class="text-zinc-500" />
            安全预览
          </div>
          <p class="text-xs leading-5 text-zinc-500">
            仅显示协议和主机；路径、query、hash 不在界面回显。
          </p>
          <div v-if="subscriptionPreview.length" class="grid gap-2">
            <div
              v-for="item in subscriptionPreview"
              :key="item.key"
              class="grid gap-1 rounded-md border px-2 py-2 text-xs"
              :class="previewTone(item.status)"
            >
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <span class="text-zinc-500">#{{ item.index }}</span>
                <span class="min-w-0 break-words font-medium">{{ item.label }}</span>
                <span v-if="item.status === 'duplicate'" class="rounded bg-amber-950/70 px-1.5 py-0.5">重复</span>
                <span v-if="item.status === 'over-limit'" class="rounded bg-red-950/70 px-1.5 py-0.5">超出前 5 个</span>
                <span v-if="item.status === 'invalid'" class="rounded bg-red-950/70 px-1.5 py-0.5">无效</span>
              </div>
              <p class="break-words text-zinc-500">{{ item.notes.join(" · ") }}</p>
            </div>
          </div>
          <p v-else class="text-xs text-zinc-500">暂无订阅输入。</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Button :loading="isRunning('save-singbox')" @click="saveSingBox"><Save :size="16" />保存</Button>
          <Button variant="secondary" :loading="isRunning('paste-singbox')" @click="pasteSingBox"><ClipboardPaste :size="16" />读剪切板</Button>
          <Button variant="outline" @click="normalizeSingBoxInput">规范化</Button>
          <Button variant="outline" @click="copy(singBoxText, 'sing-box 订阅')"><Copy :size="16" />复制</Button>
        </div>
      </Card>

    </div>
  </div>
</template>
