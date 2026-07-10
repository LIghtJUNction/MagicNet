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
  neutral: "bg-white/[0.06] text-zinc-300 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)]",
  success: "bg-emerald-400/10 text-emerald-300 shadow-[inset_0_0_0_1px_rgba(52,211,153,0.2)]",
  warning: "bg-amber-400/10 text-amber-200 shadow-[inset_0_0_0_1px_rgba(251,191,36,0.2)]",
  danger: "bg-rose-400/10 text-rose-200 shadow-[inset_0_0_0_1px_rgba(251,113,133,0.22)]"
}[props.tone]));

const classes = computed(() => cn("inline-flex min-h-7 items-center rounded-full px-3 text-[11px] font-semibold tracking-wide", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
