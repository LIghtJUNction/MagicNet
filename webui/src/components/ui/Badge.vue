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
  neutral: "mn-tone-neutral",
  success: "mn-fill-ok",
  warning: "mn-fill-warn",
  danger: "mn-fill-danger",
}[props.tone]));

const classes = computed(() => cn("inline-flex min-h-7 items-center rounded-full px-3 text-[11px] font-semibold tracking-wide", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
