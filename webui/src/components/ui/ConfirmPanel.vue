<script setup lang="ts">
import { onMounted, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";

const props = withDefaults(
  defineProps<{
    title: string;
    detail?: string;
    command?: string;
    loading?: boolean;
    confirmLabel?: string;
    cancelLabel?: string;
    autoFocus?: boolean;
    confirmVariant?: "default" | "secondary" | "destructive";
  }>(),
  {
    loading: false,
    confirmLabel: "确认执行",
    cancelLabel: "取消",
    autoFocus: true,
    confirmVariant: "default",
  },
);

defineEmits<{
  cancel: [];
  confirm: [];
}>();

const card = ref<HTMLElement | null>(null);

onMounted(() => {
  if (!props.autoFocus) return;
  const reduceMotion =
    window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  card.value?.scrollIntoView({
    block: "nearest",
    behavior: reduceMotion ? "auto" : "smooth",
  });
  card.value?.querySelector<HTMLButtonElement>("button:last-of-type")?.focus();
});
</script>

<template>
  <div ref="card" tabindex="-1">
    <Card class="mn-panel-warn">
      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--mn-warning)]">{{ title }}</h3>
          <p v-if="detail" class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
            {{ detail }}
          </p>
          <code v-if="command" class="mn-confirm-code mt-2">{{ command }}</code>
          <slot />
        </div>
        <div class="flex flex-wrap gap-2">
          <slot name="actions">
            <Button variant="outline" @click="$emit('cancel')">{{ cancelLabel }}</Button>
            <Button :variant="confirmVariant" :loading="loading" @click="$emit('confirm')">
              {{ confirmLabel }}
            </Button>
          </slot>
        </div>
      </div>
    </Card>
  </div>
</template>
