<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{
  label: string;
  value?: string | number;
  hint?: string;
  mono?: boolean;
  class?: string;
}>();

const classes = computed(() => cn("mn-stat-tile", props.class));
</script>

<template>
  <div :class="classes">
    <p class="text-xs text-[var(--mn-ink-faint)]">{{ label }}</p>
    <p :class="['mt-1 break-all text-base font-semibold text-[var(--mn-ink)]', mono ? 'font-mono' : '']">
      <slot>{{ value ?? "—" }}</slot>
    </p>
    <p v-if="hint || $slots.hint" class="mt-1 truncate text-xs text-[var(--mn-ink-muted)]">
      <slot name="hint">{{ hint }}</slot>
    </p>
  </div>
</template>
