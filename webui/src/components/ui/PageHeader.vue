<script setup lang="ts">
defineProps<{
  overline: string;
  title: string;
  description: string;
}>();
</script>

<template>
  <div class="flex min-w-0 flex-col gap-3 md:flex-row md:items-start md:justify-between">
    <div>
      <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">{{ overline }}</span>
      <h2 class="mt-1 text-2xl font-semibold">{{ title }}</h2>
      <p class="mt-1 text-sm leading-6 text-zinc-400">{{ description }}</p>
    </div>
    <div class="flex flex-wrap items-center gap-2">
      <slot name="actions">
        <slot />
      </slot>
    </div>
  </div>
</template>
