<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(defineProps<{
  tone?: "neutral" | "success" | "warning" | "danger" | "info";
  class?: string;
}>(), {
  tone: "neutral"
});

const toneClass = computed(() => ({
  neutral: "mn-tone-neutral",
  success: "mn-fill-ok",
  warning: "mn-fill-warn",
  danger: "mn-fill-danger",
  info: "mn-fill-info",
}[props.tone]));

const classes = computed(() => cn("inline-flex min-h-7 items-center rounded-[2px] border px-2.5 font-mono text-[11px] font-semibold tracking-[0.06em]", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
