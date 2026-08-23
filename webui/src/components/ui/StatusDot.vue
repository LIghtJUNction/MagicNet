<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(
  defineProps<{
    tone?: "ok" | "stop" | "unknown" | "current";
    class?: string;
  }>(),
  { tone: "unknown" },
);

const classes = computed(() =>
  cn(
    "size-2.5 shrink-0 rounded-full",
    {
      ok: "mn-status-dot-ok",
      stop: "mn-status-dot-stop",
      unknown: "mn-status-dot-unknown",
      current: "bg-current opacity-70",
    }[props.tone],
    props.class,
  ),
);
</script>

<template>
  <span :class="classes" aria-hidden="true" />
</template>
