<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from "vue";
import { Bug, ShieldCheck, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Eyebrow from "@/components/ui/Eyebrow.vue";
import Field from "@/components/ui/Field.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { trapFocusWithin } from "@/lib/focus";
import {
  ISSUE_KIND_OPTIONS,
  type IssueKind,
  type IssueReportInput,
} from "@/composables/issueDrafts";

defineProps<{
  loading?: boolean;
}>();

const emit = defineEmits<{
  cancel: [];
  confirm: [report: IssueReportInput];
}>();

const dialog = ref<HTMLElement | null>(null);
const selected = ref<IssueKind>("app-connectivity");
const summary = ref("");
const reproduction = ref("");
const expected = ref("");
const actual = ref("");
const frequency = ref("");
const canConfirm = computed(() => summary.value.trim().length >= 3);
let previousBodyOverflow = "";

function confirm(): void {
  if (!canConfirm.value) return;
  emit("confirm", {
    kind: selected.value,
    summary: summary.value.trim(),
    reproduction: reproduction.value.trim(),
    expected: expected.value.trim(),
    actual: actual.value.trim(),
    frequency: frequency.value.trim(),
  });
}

function trapFocus(event: KeyboardEvent): void {
  trapFocusWithin(event, dialog.value);
}

onMounted(() => {
  previousBodyOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  void nextTick(() => {
    dialog.value?.querySelector<HTMLTextAreaElement>("textarea")?.focus();
  });
});

onUnmounted(() => {
  document.body.style.overflow = previousBodyOverflow;
});
</script>

<template>
  <div class="fixed inset-0 z-[70] grid place-items-end p-3 sm:place-items-center sm:p-6">
    <button
      class="mn-overlay absolute inset-0 size-full"
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
            <Eyebrow tone="clay" class="inline-flex items-center gap-2">
              <Bug :size="14" /> Issue Context
            </Eyebrow>
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
              'mn-choice grid cursor-pointer grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 rounded-md p-3 transition-colors',
              selected === option.value
                ? 'mn-choice-active'
                : 'hover:bg-[var(--mn-carrier-deep)]',
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

        <div class="mt-4 grid gap-3 border-t border-[var(--mn-border)] pt-4">
          <Field
            label="问题概述"
            hint="用一句话说明看到的现象；这是必填项。"
            hint-id="issue-summary-hint"
            required
            for-id="issue-summary"
          >
            <Textarea
              id="issue-summary"
              v-model="summary"
              class="min-h-20"
              maxlength="240"
              placeholder="例如：更新订阅后节点数量变成 0，sing-box 没有启动"
              aria-describedby="issue-summary-hint"
              @keydown.ctrl.enter="confirm"
            />
          </Field>

          <div class="grid gap-3 sm:grid-cols-2">
            <Field label="复现步骤">
              <Textarea
                v-model="reproduction"
                maxlength="1200"
                placeholder="1. 做了什么操作？&#10;2. 何时开始异常？&#10;3. 是否每次都能复现？"
              />
            </Field>
            <Field label="期望结果">
              <Textarea
                v-model="expected"
                maxlength="600"
                placeholder="例如：订阅应导入节点并启动 sing-box。"
              />
            </Field>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <Field label="实际结果">
              <Textarea
                v-model="actual"
                class="min-h-24"
                maxlength="800"
                placeholder="例如：报告 last_reason=no_supported_nodes，核心 stopped。"
              />
            </Field>
            <Field label="发生频率 / 影响范围">
              <Textarea
                v-model="frequency"
                class="min-h-24"
                maxlength="400"
                placeholder="例如：仅 Android 15、只影响某个订阅、每次更新都会发生。"
              />
            </Field>
          </div>
        </div>

        <div class="mt-4 flex flex-col gap-3 border-t border-[var(--mn-border)] pt-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="inline-flex items-center gap-2 text-xs leading-5 text-[var(--mn-ink-muted)]">
            <ShieldCheck :size="16" class="shrink-0 text-[var(--mn-cactus-deep)]" />
            描述和诊断都会脱敏；请勿直接粘贴订阅地址、token、IP、目标域名或本地路径。
          </p>
          <div class="flex gap-2 sm:shrink-0">
            <Button class="flex-1 sm:flex-none" variant="outline" @click="emit('cancel')">取消</Button>
            <Button class="flex-1 sm:flex-none" :loading="loading" :disabled="!canConfirm" @click="confirm">收集并创建</Button>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
