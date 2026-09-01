<script setup lang="ts">
import { nextTick, onMounted, onUnmounted, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { trapFocusWithin } from "@/lib/focus";

const emit = defineEmits<{
  dismiss: [];
  submit: [value: string];
}>();

const dialog = ref<HTMLElement | null>(null);
const value = ref("");
let previousBodyOverflow = "";

function submit(): void {
  const trimmed = value.value.trim();
  if (trimmed) emit("submit", trimmed);
}

function trapFocus(event: KeyboardEvent): void {
  trapFocusWithin(event, dialog.value);
}

onMounted(() => {
  previousBodyOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  void nextTick(() => {
    dialog.value?.querySelector<HTMLElement>("[data-dialog-initial-focus]")?.focus();
  });
});

onUnmounted(() => {
  document.body.style.overflow = previousBodyOverflow;
});
</script>

<template>
  <div class="fixed inset-0 z-[70] grid place-items-center p-3 sm:p-6">
    <button class="mn-overlay absolute inset-0 size-full" type="button" aria-label="关闭" @click="emit('dismiss')" />
    <section
      ref="dialog"
      class="mn-chrome relative z-10 w-full max-w-xl rounded-md p-1.5"
      role="dialog"
      aria-modal="true"
      aria-labelledby="onboarding-title"
      tabindex="-1"
      @keydown="trapFocus"
      @keydown.esc.prevent.stop="emit('dismiss')"
    >
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-4 sm:p-5">
        <div class="flex items-center justify-between gap-3">
          <h2 id="onboarding-title" class="text-lg font-semibold text-[var(--mn-ink)]">订阅链接</h2>
          <Button data-dialog-initial-focus variant="ghost" size="icon" aria-label="关闭" @click="emit('dismiss')">×</Button>
        </div>
        <Textarea
          v-model="value"
          class="mt-4 min-h-44"
          spellcheck="false"
          autocomplete="off"
          placeholder="每行一个 HTTPS 订阅链接"
          aria-label="订阅链接"
          @keydown.ctrl.enter.prevent="submit"
          @keydown.meta.enter.prevent="submit"
        />
        <div class="mt-3 flex justify-end gap-2">
          <Button variant="ghost" @click="emit('dismiss')">取消</Button>
          <Button :disabled="!value.trim()" @click="submit">打开订阅</Button>
        </div>
      </div>
    </section>
  </div>
</template>
