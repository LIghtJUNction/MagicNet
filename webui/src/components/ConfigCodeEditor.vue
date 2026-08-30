<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";

type JsonSyntaxError = {
  message: string;
  line: number;
  column: number;
  position: number;
};

type JsonSyntaxState = {
  valid: boolean;
  error: JsonSyntaxError | null;
  checking: boolean;
};

type JsonToken = {
  value: string;
  className?: string;
};

const model = defineModel<string>({ default: "" });
const emit = defineEmits<{
  syntaxState: [state: JsonSyntaxState];
}>();

const ANALYSIS_DELAY_MS = 180;
const MAX_HIGHLIGHT_CHARACTERS = 120_000;
const MAX_GUTTER_LINES = 20_000;
const JSON_NUMBER_PATTERN = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;
const JSON_WORD_PATTERN = /(?:true|false|null)\b/y;

const textarea = ref<HTMLTextAreaElement | null>(null);
const scrollTop = ref(0);
const scrollLeft = ref(0);
const deferredText = ref(model.value);
const checking = ref(false);
let analysisTimer: ReturnType<typeof setTimeout> | undefined;

const syntaxState = computed<JsonSyntaxState>(() => checking.value
  ? { valid: false, error: null, checking: true }
  : validateJson(deferredText.value));
const lineCount = computed(() => countLines(deferredText.value));
const lineNumbers = computed(() => lineCount.value <= MAX_GUTTER_LINES
  ? Array.from({ length: lineCount.value }, (_, index) => index + 1).join("\n")
  : "");
const highlightedTokens = computed(() => {
  const text = deferredText.value || " ";
  return text.length > MAX_HIGHLIGHT_CHARACTERS ? [{ value: text }] : tokenizeJson(text);
});
const editorStatus = computed(() => {
  if (checking.value) return "正在检查 JSON…";
  if (!deferredText.value.trim()) return "等待 JSON";
  if (syntaxState.value.valid) {
    const highlightMode = deferredText.value.length > MAX_HIGHLIGHT_CHARACTERS ? " · 大文件纯文本显示" : "";
    return `${lineCount.value} 行 · JSON 语法正常${highlightMode}`;
  }
  const error = syntaxState.value.error;
  if (!error) return "JSON 语法错误";
  return `第 ${error.line} 行，第 ${error.column} 列：${error.message}`;
});

watch(model, (text) => {
  checking.value = true;
  if (analysisTimer !== undefined) window.clearTimeout(analysisTimer);
  analysisTimer = window.setTimeout(() => {
    deferredText.value = text;
    checking.value = false;
    analysisTimer = undefined;
  }, ANALYSIS_DELAY_MS);
});
watch(syntaxState, (state) => emit("syntaxState", state), { immediate: true });
onBeforeUnmount(() => {
  if (analysisTimer !== undefined) window.clearTimeout(analysisTimer);
});

function syncScroll(event: Event): void {
  const target = event.target as HTMLTextAreaElement;
  scrollTop.value = target.scrollTop;
  scrollLeft.value = target.scrollLeft;
}

async function insertTab(event: KeyboardEvent): Promise<void> {
  const target = event.target as HTMLTextAreaElement;
  const start = target.selectionStart;
  const end = target.selectionEnd;
  const text = model.value;
  model.value = `${text.slice(0, start)}  ${text.slice(end)}`;
  await nextTick();
  target.selectionStart = start + 2;
  target.selectionEnd = start + 2;
}

function validateJson(text: string): JsonSyntaxState {
  if (!text.trim()) return { valid: true, error: null, checking: false };
  try {
    JSON.parse(text);
    return { valid: true, error: null, checking: false };
  } catch (error) {
    return {
      valid: false,
      error: parseJsonError(error, text),
      checking: false,
    };
  }
}

function countLines(text: string): number {
  let count = 1;
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] === "\n") count += 1;
  }
  return count;
}

function parseJsonError(error: unknown, text: string): JsonSyntaxError {
  const rawMessage = error instanceof Error ? error.message : String(error);
  const message = rawMessage.replace(/^JSON\.parse:\s*/i, "");
  const lineColumn = message.match(/line\s+(\d+)\s+column\s+(\d+)/i);
  if (lineColumn) {
    const line = Number(lineColumn[1]);
    const column = Number(lineColumn[2]);
    return {
      message,
      line,
      column,
      position: lineColumnToPosition(text, line, column)
    };
  }

  const positionMatch = message.match(/position\s+(\d+)/i);
  const position = positionMatch ? Number(positionMatch[1]) : Math.max(0, text.length - 1);
  const { line, column } = positionToLineColumn(text, position);
  return { message, line, column, position };
}

function positionToLineColumn(text: string, position: number): { line: number; column: number } {
  const clipped = Math.max(0, Math.min(position, text.length));
  let line = 1;
  let lineStart = 0;
  for (let index = 0; index < clipped; index += 1) {
    if (text[index] === "\n") {
      line += 1;
      lineStart = index + 1;
    }
  }
  return { line, column: clipped - lineStart + 1 };
}

function lineColumnToPosition(text: string, line: number, column: number): number {
  let currentLine = 1;
  let position = 0;
  while (position < text.length && currentLine < line) {
    if (text[position] === "\n") currentLine += 1;
    position += 1;
  }
  return Math.min(text.length, position + Math.max(0, column - 1));
}

function tokenizeJson(text: string): JsonToken[] {
  const output: JsonToken[] = [];
  let index = 0;

  while (index < text.length) {
    const char = text[index];

    if (/\s/.test(char)) {
      let end = index + 1;
      while (end < text.length && /\s/.test(text[end])) end += 1;
      output.push({ value: text.slice(index, end) });
      index = end;
      continue;
    }

    if (char === "\"") {
      const token = readString(text, index);
      const className = token.closed
        ? isObjectKey(text, token.end) ? "json-token-key" : "json-token-string"
        : "json-token-error";
      output.push({ value: text.slice(index, token.end), className });
      index = token.end;
      continue;
    }

    JSON_NUMBER_PATTERN.lastIndex = index;
    const numberMatch = JSON_NUMBER_PATTERN.exec(text);
    if (numberMatch) {
      output.push({ value: numberMatch[0], className: "json-token-number" });
      index = JSON_NUMBER_PATTERN.lastIndex;
      continue;
    }

    JSON_WORD_PATTERN.lastIndex = index;
    const wordMatch = JSON_WORD_PATTERN.exec(text);
    if (wordMatch) {
      output.push({
        value: wordMatch[0],
        className: wordMatch[0] === "null" ? "json-token-null" : "json-token-boolean",
      });
      index = JSON_WORD_PATTERN.lastIndex;
      continue;
    }

    if ("{}[]:,".includes(char)) {
      output.push({ value: char, className: "json-token-punctuation" });
      index += 1;
      continue;
    }

    output.push({ value: char, className: "json-token-error" });
    index += 1;
  }

  return output;
}

function readString(text: string, start: number): { end: number; closed: boolean } {
  let escaped = false;
  for (let index = start + 1; index < text.length; index += 1) {
    const char = text[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "\"") return { end: index + 1, closed: true };
    if (char === "\n" || char === "\r") return { end: index, closed: false };
  }
  return { end: text.length, closed: false };
}

function isObjectKey(text: string, end: number): boolean {
  for (let index = end; index < text.length; index += 1) {
    const char = text[index];
    if (/\s/.test(char)) continue;
    return char === ":";
  }
  return false;
}

</script>

<template>
  <div
    class="json-editor"
    :class="{
      'json-editor--invalid': !checking && !syntaxState.valid,
      'json-editor--checking': checking,
    }"
  >
    <div class="json-editor__body">
      <div class="json-editor__gutter" aria-hidden="true">
        <pre
          v-if="lineNumbers"
          class="json-editor__gutter-lines"
          :style="{ transform: `translateY(${-scrollTop}px)` }"
        >{{ lineNumbers }}</pre>
        <span v-else class="json-editor__gutter-summary">{{ lineCount }} lines</span>
      </div>
      <div class="json-editor__stage">
        <pre
          class="json-editor__highlight"
          aria-hidden="true"
          :style="{ transform: `translate(${-scrollLeft}px, ${-scrollTop}px)` }"
        ><code><span
            v-for="(token, index) in highlightedTokens"
            :key="index"
            :class="token.className"
          >{{ token.value }}</span></code></pre>
        <textarea
          ref="textarea"
          v-model="model"
          class="json-editor__textarea"
          wrap="off"
          spellcheck="false"
          autocapitalize="off"
          autocomplete="off"
          autocorrect="off"
          placeholder="Click load config to read the live JSON file"
          @scroll="syncScroll"
          @keydown.tab.prevent="insertTab"
        />
      </div>
    </div>
    <div class="json-editor__status" :class="{ 'json-editor__status--error': !checking && !syntaxState.valid }">
      {{ editorStatus }}
    </div>
  </div>
</template>

<style scoped>
/* Dedicated code surface: inherit the active phosphor theme instead of carrying a second palette. */
.json-editor {
  overflow: hidden;
  border: 1px solid var(--mn-border-strong);
  border-radius: var(--mn-radius-sm);
  background: var(--mn-code-bg);
  color: var(--mn-ink);
}

.json-editor--invalid {
  border-color: color-mix(in srgb, var(--mn-danger) 70%, transparent);
}

.json-editor__body {
  display: grid;
  grid-template-columns: 3.75rem minmax(0, 1fr);
  min-height: 58vh;
  max-height: 72vh;
}

.json-editor__gutter {
  position: relative;
  overflow: hidden;
  border-right: 1px solid var(--mn-border);
  background: var(--mn-surface-sunken);
  color: var(--mn-ink-faint);
  font-family: var(--font-mono);
  font-size: 0.875rem;
  line-height: 1.5rem;
  user-select: none;
}

.json-editor__gutter-lines {
  margin: 0;
  padding: 0.75rem 0.75rem 0.75rem 0.5rem;
  font: inherit;
  line-height: inherit;
  text-align: right;
  white-space: pre;
  will-change: transform;
}

.json-editor__gutter-summary {
  display: block;
  padding: 0.75rem 0.35rem;
  font-size: 0.65rem;
  text-align: center;
  writing-mode: vertical-rl;
}

.json-editor__stage {
  position: relative;
  min-width: 0;
  min-height: 58vh;
  max-height: 72vh;
  overflow: hidden;
}

.json-editor__highlight,
.json-editor__textarea {
  position: absolute;
  inset: 0;
  margin: 0;
  min-width: 100%;
  min-height: 100%;
  padding: 0.75rem;
  border: 0;
  font-family: ui-monospace, "SFMono-Regular", Consolas, monospace;
  font-size: 0.875rem;
  line-height: 1.5rem;
  tab-size: 2;
  white-space: pre;
}

.json-editor__highlight {
  pointer-events: none;
  color: var(--mn-ink-soft);
  will-change: transform;
}

.json-editor--checking .json-editor__highlight {
  opacity: 0;
}

.json-editor__textarea {
  resize: vertical;
  overflow: auto;
  outline: none;
  background: transparent;
  color: transparent;
  caret-color: var(--mn-cactus);
}

.json-editor--checking .json-editor__textarea {
  color: var(--mn-ink-soft);
}

.json-editor__textarea::selection {
  background: color-mix(in srgb, var(--mn-cactus) 38%, transparent);
}

.json-editor__textarea::placeholder {
  color: var(--mn-ink-faint);
  opacity: 1;
}

.json-editor__status {
  border-top: 1px solid var(--mn-border);
  background: var(--mn-surface-sunken);
  padding: 0.55rem 0.75rem;
  color: var(--mn-ink-muted);
  font-size: 0.75rem;
}

.json-editor__status--error {
  color: var(--mn-danger);
  background: var(--mn-tone-danger-bg);
}

:deep(.json-token-key) {
  color: var(--mn-info);
}

:deep(.json-token-string) {
  color: var(--mn-success);
}

:deep(.json-token-number) {
  color: var(--mn-warning);
}

:deep(.json-token-boolean) {
  color: var(--mn-cactus-deep);
}

:deep(.json-token-null) {
  color: var(--mn-clay-ink);
}

:deep(.json-token-punctuation) {
  color: var(--mn-ink-muted);
}

:deep(.json-token-error) {
  color: var(--mn-danger);
  text-decoration: underline wavy color-mix(in srgb, var(--mn-danger) 80%, transparent);
}
</style>
