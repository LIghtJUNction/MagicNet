<script setup lang="ts">
defineProps<{
  overline: string;
  title: string;
  description: string;
}>();
</script>

<template>
  <div class="flex min-w-0 flex-col gap-4">
    <div class="max-w-3xl">
      <span class="mn-pill inline-flex rounded-full px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.16em]">{{ overline }}</span>
      <h2 class="mt-2.5 text-[clamp(1.75rem,4vw,2.25rem)] font-semibold leading-[1.08] tracking-[-0.04em] text-[var(--mn-ink)]">{{ title }}</h2>
      <p class="mt-2 max-w-[68ch] text-sm leading-6 text-[var(--mn-ink-muted)] md:text-[15px] md:leading-7">{{ description }}</p>
    </div>
    <div v-if="$slots.default || $slots.actions" class="mn-page-actions md:justify-end">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
