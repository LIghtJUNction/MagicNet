<script setup lang="ts">
import { t } from "@/i18n";
import { computed, ref, watch } from "vue";
import { Copy, FileLock } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { parseNetworkSnapshotSummary } from "@/composables/parsers";
import { copyText } from "@/utils";
import { buildNetworkSnapshotInsights, formatNetworkSnapshotReport, networkInsightTone } from "./networkSnapshotInsights";

const props = defineProps<{
  topology: string;
  sysroute: string;
}>();

const snapshotText = computed(() => [
  props.topology ? `[topology]\n${props.topology}` : "",
  props.sysroute ? `[sysroute]\n${props.sysroute}` : ""
].filter(Boolean).join("\n\n"));
const summary = computed(() => parseNetworkSnapshotSummary(snapshotText.value));
const insights = computed(() => buildNetworkSnapshotInsights(snapshotText.value));
const copied = ref(false);

watch(snapshotText, () => {
  copied.value = false;
});

async function copyNetworkReport(): Promise<void> {
  copied.value = await copyText(formatNetworkSnapshotReport(snapshotText.value, insights.value));
}
</script>

<template>
  <Card v-if="snapshotText">
    <div class="mb-2 flex flex-wrap items-start justify-between gap-2">
      <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" />{{ t("当前网络快照") }}</h3>
      <Button size="sm" variant="outline" @click="copyNetworkReport">
        <Copy :size="15" />{{ copied ? t("已复制报告") : t("复制报告") }}
      </Button>
    </div>
    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("接口") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ summary.interfaces }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("规则") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ summary.ipRules }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">{{ t("路由") }}</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ summary.routes }}</p>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-3">
        <p class="text-xs text-[var(--mn-ink-muted)]">NAT</p>
        <p class="text-lg font-semibold text-[var(--mn-ink)]">{{ summary.natRules }}</p>
      </div>
    </div>
    <div class="mt-2 grid gap-2 md:grid-cols-3">
      <div
        v-for="item in insights"
        :key="item.label"
        class="rounded-md border p-3"
        :class="networkInsightTone(item.tone)"
      >
        <p class="text-xs opacity-70">{{ item.label }}</p>
        <p class="mt-1 break-words text-sm font-semibold">{{ item.value }}</p>
        <p class="mt-1 break-words text-xs leading-5 opacity-70">{{ item.detail }}</p>
      </div>
    </div>
    <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ snapshotText }}</pre>
  </Card>
</template>
