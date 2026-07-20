<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const classes = computed(() =>
  cn(
    "magic-card min-w-0 rounded-md bg-[#0c0d0f]/96 p-4 text-zinc-50 md:p-5",
    props.class,
  ),
);
</script>

<template>
  <section :class="classes">
    <slot />
  </section>
</template>
