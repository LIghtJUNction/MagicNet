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
  neutral: "bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] text-[var(--mn-ink-soft)] shadow-[inset_0_0_0_1px_var(--mn-border)]",
  success: "bg-[color-mix(in_srgb,var(--mn-cactus)_55%,white)] text-[var(--mn-success)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-cactus)_70%,transparent)]",
  warning: "bg-[color-mix(in_srgb,var(--mn-oat)_70%,white)] text-[var(--mn-warning)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-oat)_80%,transparent)]",
  danger: "bg-[color-mix(in_srgb,var(--mn-coral)_70%,white)] text-[var(--mn-danger)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-coral)_80%,transparent)]"
}[props.tone]));

const classes = computed(() => cn("inline-flex min-h-7 items-center rounded-full px-3 text-[11px] font-semibold tracking-wide", toneClass.value, props.class));
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
