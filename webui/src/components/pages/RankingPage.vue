<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Mail, Medal, RefreshCw, Trophy, Wallet } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

type RankingEntry = {
  rank?: number;
  name: string;
  amount?: string;
  message?: string;
  date?: string;
};

type RankingData = {
  updatedAt: string;
  title: string;
  description: string;
  contactEmail: string;
  payment: {
    wechatUrl: string;
    alipayUrl: string;
    wechatQr?: string;
    alipayQr?: string;
    note?: string;
  };
  entries: RankingEntry[];
};

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

const { openExternal } = useMagicNet();
const data = ref<RankingData>(fallbackData);
const loading = ref(false);
const error = ref("");

const topEntries = computed(() => data.value.entries.slice(0, 3));
const otherEntries = computed(() => data.value.entries.slice(3));

async function loadRanking(): Promise<void> {
  loading.value = true;
  error.value = "";
  try {
    const response = await fetch(`ranking.json?ts=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    data.value = await response.json() as RankingData;
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}

async function copyEmail(): Promise<void> {
  await copyText(data.value.contactEmail);
}

async function openPayment(url: string, label: string): Promise<void> {
  await openExternal(url, label, { preferBrowser: false });
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
      <Button variant="outline" size="sm" :loading="loading" @click="loadRanking">
        <RefreshCw :size="16" />刷新
      </Button>
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
    </Card>

    <div class="grid gap-3 md:grid-cols-3">
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

    <Card class="grid gap-3">
      <div>
        <p class="text-sm font-semibold">支持项目</p>
        <p class="mt-1 text-sm leading-6 text-zinc-400">{{ data.payment.note || "支付后可通过邮箱联系作者更新排行榜信息。" }}</p>
        <p class="mt-1 text-xs leading-5 text-zinc-500">收款码从 GitHub Release 资产读取；若图片未显示，可用下方按钮打开 App 或复制邮箱联系。</p>
      </div>
      <div class="grid gap-3 sm:grid-cols-2">
        <div class="rounded-md border border-zinc-800 bg-zinc-900 p-3">
          <p class="mb-2 text-sm font-semibold">微信收款码</p>
          <img class="aspect-square w-full rounded bg-white object-contain p-2" :src="data.payment.wechatQr" alt="微信收款码" loading="lazy">
        </div>
        <div class="rounded-md border border-zinc-800 bg-zinc-900 p-3">
          <p class="mb-2 text-sm font-semibold">支付宝收款码</p>
          <img class="aspect-square w-full rounded bg-white object-contain p-2" :src="data.payment.alipayQr" alt="支付宝收款码" loading="lazy">
        </div>
      </div>
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
