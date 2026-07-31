<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const classes = computed(() =>
  cn(
    "magic-card min-w-0 rounded-[1.25rem] p-4 text-[var(--mn-ink)] md:p-5",
    props.class,
  ),
);
</script>

<template>
  <section :class="classes">
    <slot />
  </section>
</template>
