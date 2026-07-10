<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const classes = computed(() =>
  cn(
    "magic-card min-w-0 rounded-[2rem] bg-[#0c0d0f]/96 p-5 text-zinc-50 md:p-6",
    props.class,
  ),
);
</script>

<template>
  <section :class="classes">
    <slot />
  </section>
</template>
