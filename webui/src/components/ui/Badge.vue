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

const classes = computed(() => cn("inline-flex min-h-7 items-center rounded-[var(--mn-radius-sm)] border px-2.5 text-xs font-semibold", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
