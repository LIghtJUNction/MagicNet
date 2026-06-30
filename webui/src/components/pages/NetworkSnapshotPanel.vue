<script setup lang="ts">
import { computed } from "vue";
import { FileLock } from "lucide-vue-next";
import Card from "@/components/ui/Card.vue";
import { parseNetworkSnapshotSummary } from "@/composables/parsers";

const props = defineProps<{
  topology: string;
  sysroute: string;
}>();

const snapshotText = computed(() => props.topology || props.sysroute);
const summary = computed(() => parseNetworkSnapshotSummary(snapshotText.value));
</script>

<template>
  <Card v-if="snapshotText">
    <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><FileLock :size="17" /> 当前网络快照</h3>
    <div class="grid gap-2 sm:grid-cols-4">
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">接口</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.interfaces }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">规则</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.ipRules }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">路由</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.routes }}</p>
      </div>
      <div class="rounded-md border border-white/10 bg-white/5 p-3">
        <p class="text-xs text-zinc-500">NAT</p>
        <p class="text-lg font-semibold text-zinc-100">{{ summary.natRules }}</p>
      </div>
    </div>
    <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ snapshotText }}</pre>
  </Card>
</template>
