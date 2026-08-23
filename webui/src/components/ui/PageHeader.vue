<script setup lang="ts">
defineProps<{
  overline: string;
  title: string;
  description: string;
}>();
</script>

<template>
  <div class="contents">
    <div class="max-w-3xl">
      <div class="mn-page-title-row">
        <h2 class="text-[clamp(1.45rem,6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-[var(--mn-ink)]">{{ title }}</h2>
        <span class="mn-page-kicker">[ {{ overline }} ]</span>
      </div>
      <p class="mt-2 max-w-[68ch] text-sm leading-6 text-[var(--mn-ink-muted)] md:text-[15px] md:leading-7">{{ description }}</p>
    </div>
    <div v-if="$slots.default || $slots.actions" class="mn-page-actions md:justify-end">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
