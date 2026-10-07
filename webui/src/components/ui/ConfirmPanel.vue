<script setup lang="ts">
import { t } from "@/i18n";
import { onBeforeUnmount, onMounted, nextTick, ref } from "vue";
import { trapFocusWithin } from "@/lib/focus";
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

const emit = defineEmits<{
  cancel: [];
  confirm: [];
}>();

const card = ref<HTMLElement | null>(null);
let trigger: HTMLElement | null = null;

function handleKeydown(event: KeyboardEvent): void {
  // The overview owns its custom dialog focus and Escape behavior.
  if (!props.autoFocus) return;
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    if (!props.loading) emit("cancel");
  } else if (card.value?.closest('[aria-modal="true"]')) {
    trapFocusWithin(event, card.value);
  }
}

onBeforeUnmount(() => {
  const ownsFocus = card.value?.contains(document.activeElement);
  if (!ownsFocus || !props.autoFocus) return;
  void nextTick(() => {
    if (document.activeElement === document.body && trigger?.isConnected && trigger.getClientRects().length) {
      trigger.focus({ preventScroll: true });
    }
  });
});

onMounted(() => {
  if (!props.autoFocus) return;
  trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const reduceMotion =
    window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  card.value?.scrollIntoView({
    block: "nearest",
    behavior: reduceMotion ? "auto" : "smooth",
  });
  card.value?.querySelector<HTMLButtonElement>(".mn-confirm-actions button:not(:disabled)")?.focus({ preventScroll: true });
});
</script>

<template>
  <div ref="card" tabindex="-1" :aria-busy="loading || undefined" @keydown="handleKeydown">
    <Card class="mn-panel-warn">
      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--mn-warning)]">{{ t(title) }}</h3>
          <p v-if="detail" class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
            {{ t(detail) }}
          </p>
          <code v-if="command" class="mn-confirm-code mt-2">{{ command }}</code>
          <slot />
        </div>
        <div class="mn-confirm-actions flex flex-wrap gap-2">
          <slot name="actions">
            <Button variant="outline" :disabled="loading" @click="$emit('cancel')">{{ t(cancelLabel) }}</Button>
            <Button :variant="confirmVariant" :loading="loading" @click="$emit('confirm')">
              {{ t(confirmLabel) }}
            </Button>
          </slot>
        </div>
      </div>
    </Card>
  </div>
</template>
