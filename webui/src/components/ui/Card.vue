<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const classes = computed(() =>
  cn(
    "magic-card min-w-0 text-[var(--mn-ink)]",
    props.class,
  ),
);
</script>

<template>
  <section :class="classes">
    <slot />
  </section>
</template>
