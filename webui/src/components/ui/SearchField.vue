<script setup lang="ts">
import { Search } from "lucide-vue-next";
import { computed } from "vue";
import Input from "@/components/ui/Input.vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = defineProps<{
  placeholder?: string;
  class?: string;
}>();

const model = defineModel<string>();
const wrapClass = computed(() => cn("relative min-w-0 flex-1", props.class));
</script>

<template>
  <div :class="wrapClass">
    <Search
      class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--mn-ink-faint)]"
      :size="16"
    />
    <Input
      v-model="model"
      class="pl-9"
      :placeholder="placeholder"
      spellcheck="false"
      v-bind="$attrs"
    />
  </div>
</template>
