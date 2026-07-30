<script setup lang="ts">
import { nextTick, onMounted, onUnmounted, ref } from "vue";
import { Bug, ShieldCheck, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import {
  ISSUE_KIND_OPTIONS,
  type IssueKind,
} from "@/composables/issueDrafts";

defineProps<{
  loading?: boolean;
}>();

const emit = defineEmits<{
  cancel: [];
  confirm: [kind: IssueKind];
}>();

const dialog = ref<HTMLElement | null>(null);
const selected = ref<IssueKind>("app-connectivity");
let previousBodyOverflow = "";

function confirm(): void {
  emit("confirm", selected.value);
}

function trapFocus(event: KeyboardEvent): void {
  if (event.key !== "Tab" || !dialog.value) return;
  const focusable = Array.from(
    dialog.value.querySelectorAll<HTMLElement>(
      'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((element) => element.getClientRects().length > 0);
  if (!focusable.length) {
    event.preventDefault();
    dialog.value.focus();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  const active = document.activeElement;
  if (event.shiftKey && (active === first || !dialog.value.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && active === last) {
    event.preventDefault();
    first.focus();
  }
}

onMounted(() => {
  previousBodyOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  void nextTick(() => {
    dialog.value?.querySelector<HTMLInputElement>('input[type="radio"]:checked')?.focus();
  });
});

onUnmounted(() => {
  document.body.style.overflow = previousBodyOverflow;
});
</script>

<template>
  <div class="fixed inset-0 z-[70] grid place-items-end p-3 sm:place-items-center sm:p-6">
    <button
      class="absolute inset-0 size-full bg-[color-mix(in_srgb,var(--mn-ink)_42%,transparent)]"
      type="button"
      aria-label="取消创建 Issue"
      @click="emit('cancel')"
    />
    <section
      ref="dialog"
      class="mn-chrome relative z-10 grid max-h-[calc(100dvh-1.5rem)] w-full max-w-2xl gap-4 overflow-y-auto rounded-md p-1.5"
      role="dialog"
      aria-modal="true"
      aria-labelledby="issue-reporter-title"
      aria-describedby="issue-reporter-description"
      tabindex="-1"
      @keydown="trapFocus"
      @keydown.esc.prevent.stop="emit('cancel')"
    >
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-4 sm:p-5">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <span class="inline-flex items-center gap-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--mn-clay)]">
              <Bug :size="14" /> Issue Context
            </span>
            <h2 id="issue-reporter-title" class="mt-2 text-xl font-semibold tracking-[-0.03em] text-[var(--mn-ink)]">
              你遇到了哪类问题？
            </h2>
            <p id="issue-reporter-description" class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
              选择一项后，MagicNet 只收集与该问题最相关的诊断上下文，并在打开 GitHub 前完成脱敏。
            </p>
          </div>
          <Button variant="ghost" size="icon" aria-label="取消创建 Issue" @click="emit('cancel')">
            <X :size="18" />
          </Button>
        </div>

        <fieldset class="mt-4 grid gap-2">
          <legend class="sr-only">问题类型</legend>
          <label
            v-for="option in ISSUE_KIND_OPTIONS"
            :key="option.value"
            :class="[
              'grid cursor-pointer grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 rounded-md border p-3 transition-colors',
              selected === option.value
                ? 'border-[var(--mn-cactus)] bg-[color-mix(in_srgb,var(--mn-cactus)_12%,var(--mn-ivory))]'
                : 'border-[var(--mn-border)] bg-[var(--mn-carrier)] hover:bg-[var(--mn-carrier-deep)]',
            ]"
          >
            <input
              v-model="selected"
              class="mt-1 size-4 accent-[var(--mn-cactus)]"
              type="radio"
              name="issue-kind"
              :value="option.value"
            />
            <span class="min-w-0">
              <strong class="block text-sm font-semibold text-[var(--mn-ink)]">{{ option.label }}</strong>
              <span class="mt-0.5 block text-xs leading-5 text-[var(--mn-ink-muted)]">{{ option.description }}</span>
              <span class="mt-1.5 block text-xs leading-5 text-[var(--mn-ink-soft)]">
                将收集：{{ option.context }}
              </span>
            </span>
          </label>
        </fieldset>

        <div class="mt-4 flex flex-col gap-3 border-t border-[var(--mn-border)] pt-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="inline-flex items-center gap-2 text-xs leading-5 text-[var(--mn-ink-muted)]">
            <ShieldCheck :size="16" class="shrink-0 text-[var(--mn-cactus-deep)]" />
            订阅地址、token、IP、目标域名和本地路径会被过滤。
          </p>
          <div class="flex gap-2 sm:shrink-0">
            <Button class="flex-1 sm:flex-none" variant="outline" @click="emit('cancel')">取消</Button>
            <Button class="flex-1 sm:flex-none" :loading="loading" @click="confirm">收集并创建</Button>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
