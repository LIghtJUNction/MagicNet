<script setup lang="ts">
import hljs from "highlight.js/lib/core";
import json from "highlight.js/lib/languages/json";
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import {
  lineColumnToPosition,
  parseJsonSyntaxError,
  positionToLineColumn,
  type JsonSyntaxError,
} from "@/components/configEditorNavigation";
import { shouldHighlightJson } from "@/components/configEditorRendering";

hljs.registerLanguage("json", json);

const props = withDefaults(defineProps<{
  modelValue: string;
  label?: string;
  placeholder?: string;
  minHeight?: string;
}>(), {
  label: "配置 JSON 编辑器",
  placeholder: "加载或导入 JSON 后开始编辑",
  minHeight: "30rem",
});

const emit = defineEmits<{
  "update:modelValue": [value: string];
  "syntax-state": [state: { valid: boolean; error: JsonSyntaxError | null; checking: boolean }];
}>();

const editor = ref<HTMLTextAreaElement | null>(null);
const highlight = ref<HTMLElement | null>(null);
const deferredText = ref(props.modelValue);
const checking = ref(false);
const currentLine = ref(1);
const currentColumn = ref(1);
const editorScrollTop = ref(0);
const editorViewportHeight = ref(480);
const editorLineHeight = ref(24);
const editorPaddingTop = ref(12);
let debounceTimer: number | undefined;
let editorResizeObserver: ResizeObserver | undefined;

const model = computed({
  get: () => props.modelValue,
  set: (value: string) => emit("update:modelValue", value),
});

const lineCount = computed(() => Math.max(1, props.modelValue.split("\n").length));
const highlightEnabled = computed(() => shouldHighlightJson(deferredText.value));
const highlightedJson = computed(() => {
  if (!deferredText.value || !highlightEnabled.value) return "";
  return `${hljs.highlight(deferredText.value, { language: "json" }).value}\n`;
});
const plainJson = computed(() => `${deferredText.value}\n`);

const syntaxState = computed(() => {
  if (checking.value) return { valid: false, error: null, checking: true };
  const error = parseJsonSyntaxError(deferredText.value);
  return { valid: error === null, error, checking: false };
});
const errorLine = computed(() => syntaxState.value.error?.line ?? null);

const visibleLines = computed(() => {
  const lineHeight = Math.max(1, editorLineHeight.value);
  const first = Math.max(1, Math.floor(Math.max(0, editorScrollTop.value - editorPaddingTop.value) / lineHeight) + 1 - 2);
  const count = Math.ceil(editorViewportHeight.value / lineHeight) + 5;
  const last = Math.min(lineCount.value, first + count);
  return Array.from({ length: last - first + 1 }, (_, index) => first + index);
});

function lineTop(line: number): string {
  return `${editorPaddingTop.value + (line - 1) * editorLineHeight.value - editorScrollTop.value}px`;
}

function lineMarkerStyle(line: number | null): Record<string, string> | undefined {
  if (!line) return undefined;
  const top = editorPaddingTop.value + (line - 1) * editorLineHeight.value - editorScrollTop.value;
  if (top < -editorLineHeight.value || top > editorViewportHeight.value) return { display: "none" };
  return { top: `${top}px`, height: `${editorLineHeight.value}px` };
}

const activeLineStyle = computed(() => lineMarkerStyle(currentLine.value));
const errorLineStyle = computed(() => lineMarkerStyle(errorLine.value));

function updateEditorMetrics(): void {
  const target = editor.value;
  if (!target) return;
  const styles = window.getComputedStyle(target);
  editorViewportHeight.value = target.clientHeight;
  editorLineHeight.value = Number.parseFloat(styles.lineHeight) || 24;
  editorPaddingTop.value = Number.parseFloat(styles.paddingTop) || 12;
}

function updateSelection(target: HTMLTextAreaElement | null = editor.value): void {
  if (!target) return;
  const position = positionToLineColumn(props.modelValue, target.selectionStart);
  currentLine.value = position.line;
  currentColumn.value = position.column;
}

function syncScrollLayers(event: Event): void {
  const target = event.currentTarget as HTMLTextAreaElement;
  editorScrollTop.value = target.scrollTop;
  if (highlight.value) {
    highlight.value.scrollTop = target.scrollTop;
    highlight.value.scrollLeft = target.scrollLeft;
  }
}

async function handleEditorInput(): Promise<void> {
  await nextTick();
  updateSelection();
}

async function jumpToLine(line: number, column = 1): Promise<void> {
  const target = editor.value;
  if (!target) return;
  const position = lineColumnToPosition(props.modelValue, line, column);
  target.focus({ preventScroll: true });
  target.setSelectionRange(position, position);
  const top = editorPaddingTop.value + (Math.max(1, line) - 1) * editorLineHeight.value;
  target.scrollTop = Math.max(0, top - target.clientHeight / 2 + editorLineHeight.value / 2);
  syncScrollLayers({ currentTarget: target } as unknown as Event);
  updateSelection(target);
  await nextTick();
  target.focus({ preventScroll: true });
}

watch(
  () => props.modelValue,
  (value) => {
    checking.value = true;
    if (debounceTimer !== undefined) window.clearTimeout(debounceTimer);
    debounceTimer = window.setTimeout(() => {
      deferredText.value = value;
      checking.value = false;
      debounceTimer = undefined;
    }, 180);
  },
);

watch(
  syntaxState,
  (state) => emit("syntax-state", state),
  { immediate: true },
);

onMounted(() => {
  updateEditorMetrics();
  updateSelection();
  if (typeof ResizeObserver !== "undefined" && editor.value) {
    editorResizeObserver = new ResizeObserver(updateEditorMetrics);
    editorResizeObserver.observe(editor.value);
  }
});

onBeforeUnmount(() => {
  if (debounceTimer !== undefined) window.clearTimeout(debounceTimer);
  editorResizeObserver?.disconnect();
});
</script>

<template>
  <div class="json-editor" :class="{ 'json-editor--plain': !highlightEnabled }">
    <div class="json-editor__toolbar">
      <span>JSON</span>
      <span v-if="checking" role="status">正在检查</span>
      <span v-else-if="syntaxState.error" class="json-editor__status--error" role="status">发现语法错误</span>
      <span v-else class="json-editor__status--valid" role="status">语法正确</span>
    </div>

    <div class="json-editor__shell" :style="{ minHeight }">
      <nav class="json-editor__gutter" aria-label="行号。点击可跳转到对应行">
        <button
          v-for="line in visibleLines"
          :key="line"
          type="button"
          :style="{ top: lineTop(line), height: `${editorLineHeight}px` }"
          :class="{
            'is-current': line === currentLine,
            'is-error': line === errorLine,
          }"
          :aria-label="`跳到第 ${line} 行`"
          :aria-current="line === currentLine ? 'location' : undefined"
          @click="jumpToLine(line)"
        >
          {{ line }}
        </button>
      </nav>

      <div class="json-editor__stage">
        <div class="json-editor__active-line" :style="activeLineStyle" aria-hidden="true" />
        <div v-if="errorLine" class="json-editor__error-line" :style="errorLineStyle" aria-hidden="true" />
        <pre
          ref="highlight"
          class="json-editor__highlight"
          :class="{ 'json-editor__highlight--checking': checking }"
          aria-hidden="true"
        ><code v-if="highlightEnabled" class="hljs language-json" v-html="highlightedJson" /><code v-else class="json-editor__plain-text">{{ plainJson }}</code></pre>
        <textarea
          ref="editor"
          v-model="model"
          class="json-editor__textarea"
          :aria-label="label"
          :aria-invalid="syntaxState.error ? 'true' : 'false'"
          :aria-describedby="syntaxState.error ? 'json-editor-error' : 'json-editor-position'"
          :placeholder="placeholder"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          wrap="off"
          @scroll="syncScrollLayers"
          @select="updateSelection()"
          @click="updateSelection()"
          @keyup="updateSelection()"
          @input="handleEditorInput"
        />
      </div>
    </div>

    <div class="json-editor__footer">
      <button
        v-if="syntaxState.error"
        id="json-editor-error"
        type="button"
        class="json-editor__error-jump"
        @click="jumpToLine(syntaxState.error.line, syntaxState.error.column)"
      >
        跳到第 {{ syntaxState.error.line }} 行，第 {{ syntaxState.error.column }} 列
      </button>
      <span v-else id="json-editor-position">第 {{ currentLine }} 行，第 {{ currentColumn }} 列</span>
      <span v-if="!highlightEnabled">大文件模式</span>
    </div>
  </div>
</template>

<style scoped>
.json-editor {
  overflow: hidden;
  border: 1px solid var(--mn-border);
  border-radius: var(--mn-radius-lg);
  background: var(--mn-code-bg);
  box-shadow: 0 1px 2px rgb(10 18 32 / 8%);
}

.json-editor:focus-within {
  border-color: var(--mn-focus);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--mn-focus) 18%, transparent);
}

.json-editor__toolbar,
.json-editor__footer {
  display: flex;
  min-height: 38px;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 7px 12px;
  border-bottom: 1px solid var(--mn-border);
  background: var(--mn-surface-sunken);
  color: var(--mn-ink-muted);
  font-size: 12px;
}

.json-editor__toolbar > span:first-child {
  color: var(--mn-ink-soft);
  font-weight: 700;
}

.json-editor__footer {
  min-height: 34px;
  border-top: 1px solid var(--mn-border);
  border-bottom: 0;
}

.json-editor__status--valid {
  color: var(--mn-success);
}

.json-editor__status--error {
  color: var(--mn-danger);
}

.json-editor__shell {
  display: grid;
  min-height: 30rem;
  grid-template-columns: 4.25rem minmax(0, 1fr);
}

.json-editor__gutter {
  position: relative;
  z-index: 3;
  overflow: hidden;
  border-right: 1px solid var(--mn-border);
  background: var(--mn-surface-sunken);
  user-select: none;
}

.json-editor__gutter button {
  position: absolute;
  right: 0;
  left: 0;
  display: block;
  width: 100%;
  padding: 0 12px 0 6px;
  border: 0;
  background: transparent;
  color: var(--mn-ink-faint);
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: inherit;
  text-align: right;
}

.json-editor__gutter button:hover {
  background: color-mix(in srgb, var(--mn-primary) 9%, transparent);
  color: var(--mn-ink);
}

.json-editor__gutter button.is-current {
  background: color-mix(in srgb, var(--mn-primary) 13%, transparent);
  color: var(--mn-primary);
  font-weight: 700;
}

.json-editor__gutter button.is-error {
  box-shadow: inset 3px 0 var(--mn-danger);
  color: var(--mn-danger);
}

.json-editor__stage {
  position: relative;
  min-width: 0;
  min-height: inherit;
  overflow: hidden;
  background: var(--mn-code-bg);
}

.json-editor__highlight,
.json-editor__textarea {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  overflow: auto;
  border: 0;
  padding: 0.75rem 1rem;
  font-family: var(--font-mono);
  font-size: 13px;
  font-variant-ligatures: none;
  line-height: 1.5rem;
  tab-size: 2;
  white-space: pre;
  word-break: normal;
  overflow-wrap: normal;
}

.json-editor__highlight {
  z-index: 1;
  pointer-events: none;
  scrollbar-width: none;
  transition: opacity 100ms ease-out;
}

.json-editor__highlight::-webkit-scrollbar {
  display: none;
}

.json-editor__highlight--checking {
  opacity: 0;
}

.json-editor__textarea {
  z-index: 2;
  resize: none;
  outline: none;
  background: transparent;
  color: transparent;
  caret-color: var(--mn-ink);
  -webkit-text-fill-color: transparent;
}

.json-editor__textarea::placeholder {
  color: var(--mn-ink-faint);
  -webkit-text-fill-color: var(--mn-ink-faint);
}

.json-editor__textarea::selection {
  background: color-mix(in srgb, var(--mn-primary) 34%, transparent);
  color: transparent;
  -webkit-text-fill-color: transparent;
}

.json-editor__active-line,
.json-editor__error-line {
  position: absolute;
  z-index: 0;
  right: 0;
  left: 0;
  pointer-events: none;
}

.json-editor__active-line {
  background: color-mix(in srgb, var(--mn-primary) 7%, transparent);
}

.json-editor__error-line {
  border-bottom: 1px solid color-mix(in srgb, var(--mn-danger) 65%, transparent);
  background: color-mix(in srgb, var(--mn-danger) 7%, transparent);
}

.json-editor--plain .json-editor__textarea,
.json-editor__highlight--checking + .json-editor__textarea {
  color: var(--mn-ink-soft);
  -webkit-text-fill-color: var(--mn-ink-soft);
}

.json-editor__plain-text {
  color: var(--mn-ink-soft);
}

.json-editor__error-jump {
  min-height: 44px;
  border: 0;
  border-radius: var(--mn-radius-sm);
  background: transparent;
  color: var(--mn-danger);
  font-weight: 700;
  text-align: left;
  text-decoration: underline;
  text-underline-offset: 3px;
}

.json-editor__error-jump:hover {
  color: color-mix(in srgb, var(--mn-danger) 82%, white);
}

:deep(.hljs) {
  display: block;
  min-height: 100%;
  background: transparent;
  color: var(--mn-ink-soft);
}

:deep(.hljs-attr) {
  color: var(--mn-syntax-key, #60a5fa);
}

:deep(.hljs-string) {
  color: var(--mn-syntax-string, #4ade80);
}

:deep(.hljs-number),
:deep(.hljs-literal) {
  color: var(--mn-syntax-value, #fbbf24);
}

:deep(.hljs-punctuation) {
  color: var(--mn-ink-faint);
}

@media (max-width: 639px) {
  .json-editor__shell {
    grid-template-columns: 3.4rem minmax(0, 1fr);
  }

  .json-editor__gutter button {
    padding-right: 8px;
  }

  .json-editor__highlight,
  .json-editor__textarea {
    padding-inline: 0.75rem;
    font-size: 12px;
  }
}

@media (forced-colors: active) {
  .json-editor__gutter button.is-current,
  .json-editor__gutter button.is-error {
    border-left: 3px solid Highlight;
  }

  .json-editor__active-line,
  .json-editor__error-line {
    border: 1px solid Highlight;
    background: transparent;
  }
}
</style>
