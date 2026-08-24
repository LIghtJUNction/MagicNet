<script setup lang="ts">
import { Filter, Plus, Save, X } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, execFailed } from "@/utils";

const props = defineProps<{
  configured: boolean;
}>();

const { state, runCli, startBackgroundCli, refreshSubs } = useMagicNet();
const { isRunning, withAction } = useActionLock();

const filterInput = ref("");
const filterKeywords = ref<string[]>([]);
const filterDirty = ref(false);
const filterPresets = ["免费", "free", "HK", "香港", "TW", "台湾"] as const;

const normalizedFilters = computed(() => {
  const seen = new Set<string>();
  return filterKeywords.value
    .map((value) => value.trim())
    .filter((value) => {
      const folded = value.toLocaleLowerCase();
      if (!value || seen.has(folded)) return false;
      seen.add(folded);
      return true;
    });
});

const filterError = computed(() => {
  if (normalizedFilters.value.length > 32) return "最多设置 32 个关键词。";
  const oversized = normalizedFilters.value.find((value) => new TextEncoder().encode(value).length > 64);
  return oversized ? `“${oversized}”超过 64 字节。` : "";
});

const filtersChanged = computed(() => (
  normalizedFilters.value.join("\n") !== state.subscriptions.filters.join("\n")
));

watch(() => state.subscriptions.filters, (value) => {
  if (!filterDirty.value || value.join("\n") === normalizedFilters.value.join("\n")) {
    filterKeywords.value = [...value];
    filterDirty.value = false;
  }
}, { immediate: true, deep: true });

function hasFilter(value: string): boolean {
  const folded = value.toLocaleLowerCase();
  return normalizedFilters.value.some((item) => item.toLocaleLowerCase() === folded);
}

function toggleFilter(value: string): void {
  const folded = value.toLocaleLowerCase();
  const index = filterKeywords.value.findIndex((item) => item.toLocaleLowerCase() === folded);
  filterKeywords.value = index >= 0
    ? filterKeywords.value.filter((_, itemIndex) => itemIndex !== index)
    : [...filterKeywords.value, value];
  filterDirty.value = true;
}

function addFilter(): void {
  const value = filterInput.value.trim();
  if (!value) return;
  if (!hasFilter(value)) filterKeywords.value = [...filterKeywords.value, value];
  filterInput.value = "";
  filterDirty.value = true;
}

async function saveFilters(): Promise<void> {
  if (!filtersChanged.value || filterError.value) return;
  await withAction("save-subscription-filters", async () => {
    const value = normalizedFilters.value.join("\n");
    const encoded = value
      ? bytesToBase64(new TextEncoder().encode(`${value}\n`))
      : "";
    const result = await runCli(
      value ? `sub filter set ${encoded}` : "sub filter clear",
      value ? "保存订阅节点过滤词" : "清除订阅节点过滤词",
    );
    if (execFailed(result)) return;
    if (!(await refreshSubs(true))) return;
    filterDirty.value = false;
    if (props.configured) {
      await startBackgroundCli("sub update-all", "应用订阅节点过滤", "", "sub update-all");
    }
  });
}
</script>

<template>
  <Card>
    <div class="flex items-start gap-3">
      <Filter :size="18" class="mt-0.5 shrink-0 text-[var(--mn-ink-muted)]" />
      <div class="min-w-0">
        <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Node filter</span>
        <h3 class="mt-1 text-base font-semibold text-[var(--mn-ink)]">节点关键词过滤</h3>
        <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]">新安装默认过滤免费、香港和台湾节点；清空并保存即可关闭过滤。英文匹配忽略大小写。</p>
      </div>
    </div>

    <div class="mt-4 flex flex-wrap gap-2" aria-label="过滤词预设">
      <button
        v-for="preset in filterPresets"
        :key="preset"
        type="button"
        :aria-pressed="hasFilter(preset)"
        :class="[
          'min-h-8 rounded-sm px-2.5 text-xs ring-1 transition-colors',
          hasFilter(preset)
            ? 'bg-[color-mix(in_srgb,var(--mn-cactus)_28%,var(--mn-carrier))] text-[var(--mn-success)] ring-[color-mix(in_srgb,var(--mn-cactus)_45%,transparent)]'
            : 'bg-[var(--mn-ivory)] text-[var(--mn-ink-muted)] ring-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)]',
        ]"
        @click="toggleFilter(preset)"
      >
        {{ preset }}
      </button>
    </div>

    <div class="mt-3 flex gap-2">
      <Input
        v-model="filterInput"
        autocomplete="off"
        placeholder="自定义关键词"
        aria-label="自定义节点过滤关键词"
        @keydown.enter.prevent="addFilter"
      />
      <Button variant="outline" size="icon" aria-label="添加过滤关键词" @click="addFilter">
        <Plus :size="16" />
      </Button>
    </div>

    <div v-if="normalizedFilters.length" class="mt-3 flex flex-wrap gap-2">
      <button
        v-for="keyword in normalizedFilters"
        :key="keyword"
        type="button"
        class="inline-flex min-h-8 items-center gap-1 rounded-sm bg-[color-mix(in_srgb,var(--mn-heather)_28%,var(--mn-carrier))] px-2.5 text-xs text-[var(--mn-ink-soft)] ring-1 ring-[color-mix(in_srgb,var(--mn-heather)_42%,transparent)]"
        :aria-label="`移除过滤词 ${keyword}`"
        @click="toggleFilter(keyword)"
      >
        {{ keyword }}<X :size="13" />
      </button>
    </div>
    <p class="mt-3 text-xs leading-5" :class="filterError ? 'text-[var(--mn-danger)]' : 'text-[var(--mn-ink-muted)]'">
      {{ filterError || `当前 ${normalizedFilters.length}/32 个；保存后重新生成节点列表。` }}
    </p>
    <Button
      class="mt-4 w-full"
      :disabled="!filtersChanged || Boolean(filterError)"
      :loading="isRunning('save-subscription-filters')"
      @click="saveFilters"
    >
      <Save :size="16" />{{ configured ? '保存并刷新订阅' : '保存过滤词' }}
    </Button>
  </Card>
</template>
