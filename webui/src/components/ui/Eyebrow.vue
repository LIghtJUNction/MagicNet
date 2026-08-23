<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(
  defineProps<{
    tone?: "muted" | "faint" | "clay" | "inherit";
    class?: string;
  }>(),
  { tone: "muted" },
);

const classes = computed(() =>
  cn(
    "mn-eyebrow",
    {
      muted: "mn-eyebrow-muted",
      faint: "mn-eyebrow-faint",
      clay: "mn-eyebrow-clay",
      inherit: "",
    }[props.tone],
    props.class,
  ),
);
</script>

<template>
  <span :class="classes"><slot /></span>
</template>
