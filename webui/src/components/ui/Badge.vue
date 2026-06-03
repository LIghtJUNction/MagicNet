<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(defineProps<{
  tone?: "neutral" | "success" | "warning" | "danger";
  class?: string;
}>(), {
  tone: "neutral"
});

const toneClass = computed(() => ({
  neutral: "border-zinc-800 text-zinc-300",
  success: "border-green-500/40 text-green-400",
  warning: "border-amber-500/40 text-amber-400",
  danger: "border-red-500/40 text-red-400"
}[props.tone]));

const classes = computed(() => cn("inline-flex min-h-6 items-center rounded-full border px-2 text-xs font-bold", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
