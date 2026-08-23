<script setup lang="ts">
defineProps<{
  label: string;
  hint?: string;
  hintId?: string;
  required?: boolean;
  forId?: string;
}>();
</script>

<template>
  <label :for="forId" class="grid gap-1.5">
    <span class="text-sm font-semibold text-[var(--mn-ink)]">
      {{ label }}
      <span v-if="required" class="text-[var(--mn-clay-ink)]">*</span>
    </span>
    <slot />
    <p v-if="hint" :id="hintId" class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ hint }}</p>
  </label>
</template>
