<script setup lang="ts">
defineProps<{
  overline: string;
  title: string;
  description: string;
}>();
</script>

<template>
  <div class="flex min-w-0 flex-col gap-4 md:flex-row md:items-start md:justify-between">
    <div class="max-w-3xl">
      <span class="mn-pill inline-flex rounded-sm px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.18em]">{{ overline }}</span>
      <h2 class="mt-2.5 text-2xl font-semibold tracking-[-0.03em] text-[var(--mn-ink)] md:text-3xl">{{ title }}</h2>
      <p class="mt-2 text-sm leading-6 text-[var(--mn-ink-muted)] md:text-[15px]">{{ description }}</p>
    </div>
    <div class="flex flex-wrap items-center gap-2 md:justify-end">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
