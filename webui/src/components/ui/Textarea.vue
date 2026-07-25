<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() =>
  cn(
    "min-h-28 w-full resize-y rounded-md bg-[var(--mn-ivory)] px-3.5 py-3 text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_var(--mn-border-strong)] outline-none transition-[color,background-color,box-shadow] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] placeholder:text-[var(--mn-ink-faint)] focus:bg-white focus:shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-cactus)_80%,var(--mn-ink)),0_0_0_3px_color-mix(in_srgb,var(--mn-cactus)_35%,transparent)]",
    props.class,
  ),
);
</script>

<template>
  <textarea v-model="model" :class="classes" v-bind="$attrs" />
</template>
