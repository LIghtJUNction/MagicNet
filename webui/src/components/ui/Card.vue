<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const classes = computed(() => cn("min-w-0 rounded-md border border-zinc-800/80 bg-[#181713]/95 p-4 text-zinc-50 shadow-sm shadow-black/20", props.class));
</script>

<template>
  <section :class="classes">
    <slot />
  </section>
</template>
