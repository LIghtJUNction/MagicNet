<script setup lang="ts">
import { Search, X } from "lucide-vue-next";
import { computed, nextTick, ref } from "vue";
import { t } from "@/i18n";
import Input from "@/components/ui/Input.vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = defineProps<{
  placeholder?: string;
  class?: string;
  disabled?: boolean;
  readonly?: boolean;
}>();

const model = defineModel<string>();
const wrapClass = computed(() => cn("relative min-w-0 flex-1", props.class));
const field = ref<HTMLElement | null>(null);

async function clearSearch(): Promise<void> {
  model.value = "";
  await nextTick();
  field.value?.querySelector<HTMLInputElement>("input")?.focus();
}
</script>

<template>
  <div ref="field" :class="wrapClass">
    <Search
      class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--mn-ink-faint)]"
      :size="16"
      aria-hidden="true"
    />
    <Input
      v-model="model"
      class="mn-search-input pl-9 pr-12"
      type="search"
      :placeholder="placeholder"
      :aria-label="$attrs['aria-label'] || placeholder || t('搜索')"
      :disabled="disabled"
      :readonly="readonly"
      spellcheck="false"
      v-bind="$attrs"
    />
    <button
      v-if="model && !readonly"
      class="mn-search-clear absolute right-0 top-1/2 inline-flex size-12 -translate-y-1/2 items-center justify-center rounded-[var(--mn-radius-md)] text-[var(--mn-ink-muted)] hover:text-[var(--mn-ink)] disabled:opacity-55"
      type="button"
      :aria-label="t('清除搜索')"
      :disabled="disabled"
      @click="clearSearch"
    >
      <X :size="17" aria-hidden="true" />
    </button>
  </div>
</template>

<style scoped>
.mn-search-input::-webkit-search-cancel-button { -webkit-appearance: none; }
</style>
