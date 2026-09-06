<script setup lang="ts">
defineProps<{
  overline?: string;
  title: string;
  description?: string;
}>();
</script>

<template>
  <div class="mn-page-header">
    <div class="mn-page-heading min-w-0 max-w-3xl">
      <h2 class="text-[var(--mn-ink)]">{{ title }}</h2>
      <p v-if="description" class="mt-2 max-w-[62ch] text-sm leading-6 text-[var(--mn-ink-muted)]">{{ description }}</p>
    </div>
    <div v-if="$slots.default || $slots.actions" class="mn-page-actions md:justify-end">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
