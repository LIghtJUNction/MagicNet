<script setup lang="ts">
import { ChevronDown } from "lucide-vue-next";
defineProps<{ title: string }>();
</script>

<template>
  <details class="mn-section-disclosure">
    <summary>
      <span class="min-w-0">{{ title }}</span>
      <ChevronDown :size="18" aria-hidden="true" />
    </summary>
    <div class="mn-section-disclosure__body"><slot /></div>
  </details>
</template>

<style scoped>
.mn-section-disclosure { min-width: 0; border-bottom: 1px solid var(--mn-border); }
summary { display: flex; align-items: center; justify-content: space-between; gap: 1rem; min-height: 68px; padding: 1rem 0; cursor: pointer; list-style: none; font-size: 15px; font-weight: 550; }
summary::-webkit-details-marker { display: none; }
summary > svg { flex: none; color: var(--mn-ink-muted); transition: transform 160ms ease; }
details[open] > summary > svg { transform: rotate(180deg); }
summary:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: 3px; border-radius: var(--mn-radius-sm); }
.mn-section-disclosure__body { min-width: 0; padding: .25rem 0 1.5rem; }
.mn-section-disclosure__body :deep(> .mn-card) { border-top: 0; padding-top: 0; }
@media (prefers-reduced-motion: reduce) { summary > svg { transition: none; } }
</style>
