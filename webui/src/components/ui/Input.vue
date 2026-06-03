<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() => cn("w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 text-zinc-50 outline-none transition-colors placeholder:text-zinc-600 focus:border-zinc-300", props.class));
</script>

<template>
  <input v-model="model" :class="classes" />
</template>
