<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";
import Eyebrow from "@/components/ui/Eyebrow.vue";

const props = withDefaults(
  defineProps<{
    overline?: string;
    title?: string;
    description?: string;
    size?: "md" | "lg";
    overlineTone?: "muted" | "faint" | "clay" | "inherit";
    class?: string;
  }>(),
  {
    size: "lg",
    overlineTone: "muted",
  },
);

const titleClass = computed(() =>
  cn(
    "mn-card-title break-words text-[var(--mn-ink)]",
    props.size === "lg"
      ? "text-lg leading-snug md:text-xl"
      : "text-base leading-snug",
  ),
);
</script>

<template>
  <div :class="cn('flex flex-wrap items-start justify-between gap-3', props.class)">
    <div class="min-w-0">
      <Eyebrow v-if="overline || $slots.overline" :tone="overlineTone" class="mb-1">
        <slot name="overline">{{ overline }}</slot>
      </Eyebrow>
      <h3 v-if="title || $slots.title" :class="titleClass">
        <slot name="title">{{ title }}</slot>
      </h3>
      <p
        v-if="description || $slots.description"
        class="mt-2 max-w-3xl text-sm leading-6 text-[var(--mn-ink-muted)]"
      >
        <slot name="description">{{ description }}</slot>
      </p>
    </div>
    <div v-if="$slots.default" class="flex max-w-full shrink-0 flex-wrap min-w-0 items-center gap-2">
      <slot />
    </div>
  </div>
</template>
