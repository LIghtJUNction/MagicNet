<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Copy, Download, Mail, Medal, RefreshCw, Search, ShieldCheck, Trophy, Wallet } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, shellQuote } from "@/utils";
import { useActionLock } from "@/composables/useActionLock";
import { buildRankingInsights, filterRankingEntries, formatRankingSnapshot, normalizeRankingData, type RankingData } from "./rankingInsights";
import { buildPaymentAudit, formatPaymentAuditReport, validatePaymentOpen, validatePaymentQr, type PaymentQrKind } from "./rankingPaymentAudit";

const fallbackData: RankingData = {
  updatedAt: "unknown",
  title: "MagicNet 支持者排行榜",
  description: "排行榜文件尚未加载。",
  contactEmail: "LIghtJUNction.me@gmail.com",
  payment: {
    wechatUrl: "weixin://",
    alipayUrl: "alipays://platformapi/startapp?appId=20000067",
    wechatQr: "https://github.com/LIghtJUNction/lightjunction/releases/download/donate/wechat-pay.png",
    alipayQr: "https://github.com/LIghtJUNction/lightjunction/releases/download/donate/alipay-pay.png"
  },
  entries: []
};

const { state, openExternal, runShell } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const data = ref<RankingData>(fallbackData);
const loading = ref(false);
const error = ref("");
const saveStatus = ref("");
const rankingQuery = ref("");
const rankingCopied = ref(false);
const pendingQrAction = ref<PendingQrAction | null>(null);
let pressTimer = 0;

type PendingQrAction = {
  key: string;
  label: string;
  url: string;
  target: string;
  run: () => Promise<void>;
};

const rankingInsights = computed(() => buildRankingInsights(data.value));
const paymentAudit = computed(() => buildPaymentAudit(data.value));
const visibleEntries = computed(() => filterRankingEntries(data.value.entries, rankingQuery.value));
const topEntries = computed(() => visibleEntries.value.slice(0, 3));
const otherEntries = computed(() => visibleEntries.value.slice(3));

async function loadRanking(): Promise<void> {
  loading.value = true;
  error.value = "";
  try {
    const response = await fetch(`ranking.json?ts=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    data.value = normalizeRankingData(await response.json());
    rankingCopied.value = false;
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
    rankingCopied.value = false;
  } finally {
    loading.value = false;
  }
}

async function copyEmail(): Promise<void> {
  saveStatus.value = await copyText(data.value.contactEmail) ? "邮箱已复制。" : "剪贴板不可用，邮箱未复制。";
}

async function copyRankingSnapshot(): Promise<void> {
  rankingCopied.value = await copyText(`${formatRankingSnapshot(data.value, visibleEntries.value)}\n\n${formatPaymentAuditReport(data.value)}`);
  saveStatus.value = rankingCopied.value ? "排行榜快照已复制。" : "剪贴板不可用，排行榜快照未复制。";
}

async function openPayment(url: string, label: string): Promise<void> {
  const kind = label === "微信支付" ? "wechatUrl" : "alipayUrl";
  const validation = validatePaymentOpen(kind, url);
  if (!validation.ok) {
    saveStatus.value = validation.reason;
    return;
  }
  await openExternal(url, label, { preferBrowser: false });
}

function payImageName(kind: PaymentQrKind): string {
  return kind === "wechat" ? "微信收款码" : "支付宝收款码";
}

function payImageUrl(kind: PaymentQrKind): string {
  return kind === "wechat" ? data.value.payment.wechatQr || "" : data.value.payment.alipayQr || "";
}

function payImageTarget(kind: PaymentQrKind): string {
  return `/sdcard/Download/MagicNet/MagicNet-${kind}-pay.png`;
}

async function runSaveQr(kind: PaymentQrKind, url: string, target: string): Promise<void> {
  const label = payImageName(kind);
  await withAction(`save-${kind}`, async () => {
    saveStatus.value = `正在保存${label}...`;
    if (!state.hasKsu) {
      const copied = await copyText(url);
      saveStatus.value = copied ? `已复制${label}图片链接` : `${label}保存需要真机 WebUI 权限`;
      return;
    }
    const command = `mkdir -p /sdcard/Download/MagicNet && ((command -v curl >/dev/null 2>&1 && curl -L --fail --max-time 25 -o ${shellQuote(target)} ${shellQuote(url)}) || (command -v wget >/dev/null 2>&1 && wget -T 25 -O ${shellQuote(target)} ${shellQuote(url)})) && test -s ${shellQuote(target)} && chmod 0644 ${shellQuote(target)} && echo ${shellQuote(`已保存到 ${target}`)}`;
    const text = await runShell(command, `保存${label}`, true);
    if (/已保存到/.test(text)) {
      saveStatus.value = text.trim();
      return;
    }
    const copied = await copyText(url);
    saveStatus.value = copied ? `保存失败，已复制${label}链接` : `保存失败：${text || "无返回"}`;
  });
}

function requestSaveQr(kind: PaymentQrKind): void {
  const label = payImageName(kind);
  const url = payImageUrl(kind);
  const target = payImageTarget(kind);
  const validation = validatePaymentQr(kind, url);
  if (!validation.ok) {
    saveStatus.value = validation.reason;
    return;
  }
  pendingQrAction.value = {
    key: `save-${kind}`,
    label,
    url,
    target,
    run: () => runSaveQr(kind, url, target)
  };
}

function cancelSaveQr(): void {
  pendingQrAction.value = null;
}

async function confirmSaveQr(): Promise<void> {
  const action = pendingQrAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingQrAction.value = null;
  }
}

function startLongPress(kind: PaymentQrKind): void {
  stopLongPress();
  pressTimer = window.setTimeout(() => {
    pressTimer = 0;
    requestSaveQr(kind);
  }, 650);
}

function stopLongPress(): void {
  if (!pressTimer) return;
  window.clearTimeout(pressTimer);
  pressTimer = 0;
}

onMounted(() => {
  void loadRanking();
});
</script>

<template>
  <div class="space-y-4">
    <PageHeader
      overline="Ranking"
      :title="data.title"
      :description="data.description"
    >
      <div class="flex flex-wrap gap-2">
        <Button variant="outline" size="sm" :loading="loading" @click="loadRanking">
          <RefreshCw :size="16" />刷新
        </Button>
        <Button variant="outline" size="sm" :disabled="!data.entries.length" @click="copyRankingSnapshot">
          <Copy :size="16" />{{ rankingCopied ? '已复制快照' : '复制快照' }}
        </Button>
      </div>
    </PageHeader>

    <Card class="grid gap-3">
      <div class="flex items-start gap-3">
        <div class="grid size-11 shrink-0 place-items-center rounded-md bg-zinc-50 text-zinc-950">
          <Trophy :size="22" />
        </div>
        <div class="min-w-0 flex-1">
          <p class="text-sm font-semibold">排行榜数据</p>
          <input
            class="mt-2 h-10 w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 text-sm text-zinc-200"
            readonly
            :value="`ranking.json · updated ${data.updatedAt}`"
          >
          <p v-if="error" class="mt-2 text-sm text-red-300">加载失败：{{ error }}</p>
        </div>
      </div>
      <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-4">
        <span
          v-for="item in rankingInsights"
          :key="item.label"
          class="rounded border px-2 py-1"
          :class="{
            'border-emerald-500/30 text-emerald-200': item.tone === 'success',
            'border-amber-500/30 text-amber-200': item.tone === 'warning',
            'border-red-500/30 text-red-200': item.tone === 'danger',
            'border-zinc-800 text-zinc-400': item.tone === 'neutral',
          }"
        >
          {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
        </span>
      </div>
      <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-5">
        <span
          v-for="item in paymentAudit"
          :key="item.key"
          class="rounded border px-2 py-1"
          :class="{
            'border-emerald-500/30 text-emerald-200': item.tone === 'success',
            'border-amber-500/30 text-amber-200': item.tone === 'warning',
            'border-red-500/30 text-red-200': item.tone === 'danger',
            'border-zinc-800 text-zinc-400': item.tone === 'neutral',
          }"
          :title="item.detail"
        >
          {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
        </span>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
        <div class="relative">
          <Search class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-600" :size="16" />
          <Input v-model="rankingQuery" class="pl-9" placeholder="过滤名称、留言、金额或日期" spellcheck="false" />
        </div>
        <span class="text-sm text-zinc-500">{{ visibleEntries.length }} / {{ data.entries.length }} 命中</span>
      </div>
    </Card>

    <div v-if="topEntries.length" class="grid gap-3 md:grid-cols-3">
      <Card v-for="entry in topEntries" :key="`${entry.rank}-${entry.name}`" class="grid gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="grid size-10 place-items-center rounded-md bg-zinc-800">
            <Medal :size="20" />
          </div>
          <span class="text-2xl font-semibold">#{{ entry.rank }}</span>
        </div>
        <div>
          <h3 class="truncate text-lg font-semibold">{{ entry.name }}</h3>
          <p class="mt-1 text-sm text-zinc-400">{{ entry.amount || "感谢支持" }}</p>
        </div>
        <p class="text-sm leading-6 text-zinc-300">{{ entry.message || "感谢支持 MagicNet。" }}</p>
        <span class="text-xs text-zinc-500">{{ entry.date }}</span>
      </Card>
    </div>

    <Card v-if="otherEntries.length" class="grid gap-2">
      <div
        v-for="entry in otherEntries"
        :key="`${entry.rank}-${entry.name}`"
        class="grid grid-cols-[3rem_minmax(0,1fr)_auto] items-center gap-2 rounded-md border border-zinc-800 bg-zinc-900/60 px-3 py-2"
      >
        <span class="text-sm font-semibold text-zinc-400">#{{ entry.rank }}</span>
        <span class="truncate text-sm">{{ entry.name }}</span>
        <span class="text-xs text-zinc-500">{{ entry.date }}</span>
      </div>
    </Card>
    <Card v-else-if="data.entries.length && rankingQuery.trim()" class="text-sm text-zinc-500">
      没有匹配的排行榜条目。
    </Card>

    <Card class="grid gap-3">
      <div>
        <p class="flex items-center gap-2 text-sm font-semibold"><ShieldCheck :size="16" />支持项目</p>
        <p class="mt-1 text-sm leading-6 text-zinc-400">{{ data.payment.note || "支付后可通过邮箱联系作者更新排行榜信息。" }}</p>
        <p class="mt-1 text-xs leading-5 text-zinc-500">收款码从 GitHub Release 资产读取；若图片未显示，可用下方按钮打开 App 或复制邮箱联系。</p>
      </div>
      <div v-if="pendingQrAction" class="rounded-md border border-amber-500/40 bg-amber-500/10 p-3">
        <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
          <div class="min-w-0">
            <p class="text-sm font-semibold text-amber-100">确认保存{{ pendingQrAction.label }}</p>
            <p class="mt-1 break-all text-xs leading-5 text-amber-100/75">
              {{ state.hasKsu ? `将联网下载并覆盖 ${pendingQrAction.target}` : "当前没有真机 WebUI 权限，将复制图片链接。" }}
            </p>
          </div>
          <div class="flex gap-2">
            <Button size="sm" variant="secondary" :loading="isRunning(pendingQrAction.key)" @click="confirmSaveQr">确认</Button>
            <Button size="sm" variant="outline" @click="cancelSaveQr">取消</Button>
          </div>
        </div>
      </div>
      <div class="grid gap-3 sm:grid-cols-2">
        <div class="rounded-md border border-zinc-800 bg-zinc-900 p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <p class="text-sm font-semibold">微信收款码</p>
            <Button size="sm" variant="ghost" :loading="isRunning('save-wechat')" @click="requestSaveQr('wechat')">
              <Download :size="15" />保存
            </Button>
          </div>
          <button
            class="block w-full touch-manipulation rounded bg-white p-2 active:scale-[0.99]"
            type="button"
            aria-label="长按保存微信收款码"
            @pointerdown="startLongPress('wechat')"
            @pointerup="stopLongPress"
            @pointercancel="stopLongPress"
            @pointerleave="stopLongPress"
            @contextmenu.prevent="requestSaveQr('wechat')"
          >
            <img class="aspect-square w-full object-contain" :src="data.payment.wechatQr" alt="微信收款码" loading="lazy">
          </button>
          <input
            class="mt-2 h-9 w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 text-xs text-zinc-300"
            readonly
            :value="data.payment.wechatQr || ''"
          >
        </div>
        <div class="rounded-md border border-zinc-800 bg-zinc-900 p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <p class="text-sm font-semibold">支付宝收款码</p>
            <Button size="sm" variant="ghost" :loading="isRunning('save-alipay')" @click="requestSaveQr('alipay')">
              <Download :size="15" />保存
            </Button>
          </div>
          <button
            class="block w-full touch-manipulation rounded bg-white p-2 active:scale-[0.99]"
            type="button"
            aria-label="长按保存支付宝收款码"
            @pointerdown="startLongPress('alipay')"
            @pointerup="stopLongPress"
            @pointercancel="stopLongPress"
            @pointerleave="stopLongPress"
            @contextmenu.prevent="requestSaveQr('alipay')"
          >
            <img class="aspect-square w-full object-contain" :src="data.payment.alipayQr" alt="支付宝收款码" loading="lazy">
          </button>
          <input
            class="mt-2 h-9 w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 text-xs text-zinc-300"
            readonly
            :value="data.payment.alipayQr || ''"
          >
        </div>
      </div>
      <p class="text-xs leading-5 text-zinc-500">{{ saveStatus || "长按二维码或点保存，可保存到手机 Download/MagicNet 目录。" }}</p>
      <div class="grid gap-2 sm:grid-cols-3">
        <Button @click="openPayment(data.payment.wechatUrl, '微信支付')">
          <Wallet :size="16" />微信
        </Button>
        <Button variant="secondary" @click="openPayment(data.payment.alipayUrl, '支付宝支付')">
          <Wallet :size="16" />支付宝
        </Button>
        <Button variant="outline" @click="copyEmail">
          <Mail :size="16" />复制邮箱
        </Button>
      </div>
      <input
        class="h-10 w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 text-sm text-zinc-200"
        readonly
        :value="data.contactEmail"
      >
    </Card>
  </div>
</template>
