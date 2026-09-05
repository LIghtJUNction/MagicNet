<script setup lang="ts">
defineProps<{
  overline?: string;
  title: string;
  description?: string;
}>();
</script>

<template>
  <div class="mn-page-header">
    <div class="min-w-0 max-w-3xl">
      <h2 class="mn-page-title">{{ title }}</h2>
      <p v-if="description" class="mn-page-description">{{ description }}</p>
    </div>
    <div v-if="$slots.default || $slots.actions" class="mn-page-actions md:justify-end">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
