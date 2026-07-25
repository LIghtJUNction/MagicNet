<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";

type JsonSyntaxError = {
  message: string;
  line: number;
  column: number;
  position: number;
};

type JsonSyntaxState = {
  valid: boolean;
  error: JsonSyntaxError | null;
};

const model = defineModel<string>({ default: "" });
const emit = defineEmits<{
  syntaxState: [state: JsonSyntaxState];
}>();

const textarea = ref<HTMLTextAreaElement | null>(null);
const scrollTop = ref(0);
const scrollLeft = ref(0);

const syntaxState = computed<JsonSyntaxState>(() => validateJson(model.value));
const lineCount = computed(() => Math.max(1, model.value.split("\n").length));
const highlightedHtml = computed(() => highlightJson(model.value || " "));
const editorStatus = computed(() => {
  if (!model.value.trim()) return "Waiting for JSON";
  if (syntaxState.value.valid) return `${lineCount.value} lines · JSON syntax OK`;
  const error = syntaxState.value.error;
  if (!error) return "JSON syntax error";
  return `Line ${error.line}, column ${error.column}: ${error.message}`;
});

watch(syntaxState, (state) => emit("syntaxState", state), { immediate: true });

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
  if (!text.trim()) return { valid: true, error: null };
  try {
    JSON.parse(text);
    return { valid: true, error: null };
  } catch (error) {
    return {
      valid: false,
      error: parseJsonError(error, text)
    };
  }
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

function highlightJson(text: string): string {
  let output = "";
  let index = 0;

  while (index < text.length) {
    const char = text[index];

    if (/\s/.test(char)) {
      let end = index + 1;
      while (end < text.length && /\s/.test(text[end])) end += 1;
      output += escapeHtml(text.slice(index, end));
      index = end;
      continue;
    }

    if (char === "\"") {
      const token = readString(text, index);
      const className = token.closed
        ? isObjectKey(text, token.end) ? "json-token-key" : "json-token-string"
        : "json-token-error";
      output += wrapToken(className, text.slice(index, token.end));
      index = token.end;
      continue;
    }

    const numberMatch = text.slice(index).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (numberMatch) {
      output += wrapToken("json-token-number", numberMatch[0]);
      index += numberMatch[0].length;
      continue;
    }

    const wordMatch = text.slice(index).match(/^(true|false|null)\b/);
    if (wordMatch) {
      output += wrapToken(wordMatch[0] === "null" ? "json-token-null" : "json-token-boolean", wordMatch[0]);
      index += wordMatch[0].length;
      continue;
    }

    if ("{}[]:,".includes(char)) {
      output += wrapToken("json-token-punctuation", char);
      index += 1;
      continue;
    }

    output += wrapToken("json-token-error", char);
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

function wrapToken(className: string, value: string): string {
  return `<span class="${className}">${escapeHtml(value)}</span>`;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
</script>

<template>
  <div class="json-editor" :class="{ 'json-editor--invalid': !syntaxState.valid }">
    <div class="json-editor__body">
      <div class="json-editor__gutter" aria-hidden="true">
        <div
          class="json-editor__gutter-lines"
          :style="{ transform: `translateY(${-scrollTop}px)` }"
        >
          <span
            v-for="line in lineCount"
            :key="line"
            :class="{ 'json-editor__line--error': syntaxState.error?.line === line }"
          >{{ line }}</span>
        </div>
      </div>
      <div class="json-editor__stage">
        <pre
          class="json-editor__highlight"
          aria-hidden="true"
          :style="{ transform: `translate(${-scrollLeft}px, ${-scrollTop}px)` }"
        ><code v-html="highlightedHtml" /></pre>
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
    <div class="json-editor__status" :class="{ 'json-editor__status--error': !syntaxState.valid }">
      {{ editorStatus }}
    </div>
  </div>
</template>

<style scoped>
/* Dedicated code surface: always high-contrast dark canvas so JSON stays readable in both app themes */
.json-editor {
  overflow: hidden;
  border: 1px solid color-mix(in srgb, var(--mn-ink) 22%, transparent);
  border-radius: 8px;
  background: #141413;
  color: #f2f0e9;
  box-shadow: inset 0 0 0 1px color-mix(in srgb, #faf9f5 6%, transparent);
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
  border-right: 1px solid color-mix(in srgb, #faf9f5 12%, transparent);
  background: #1a1a18;
  color: #9a978d;
  font-family: ui-monospace, "SFMono-Regular", Consolas, monospace;
  font-size: 0.875rem;
  line-height: 1.5rem;
  user-select: none;
}

.json-editor__gutter-lines {
  padding: 0.75rem 0.75rem 0.75rem 0.5rem;
  text-align: right;
  will-change: transform;
}

.json-editor__gutter-lines span {
  display: block;
  height: 1.5rem;
}

.json-editor__line--error {
  color: #f0a090;
  font-weight: 700;
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
  color: #e8e6dc;
  will-change: transform;
}

.json-editor__textarea {
  resize: vertical;
  overflow: auto;
  outline: none;
  background: transparent;
  color: transparent;
  caret-color: #faf9f5;
}

.json-editor__textarea::selection {
  background: color-mix(in srgb, #bcd1ca 45%, transparent);
}

.json-editor__textarea::placeholder {
  color: #8f8c82;
  opacity: 1;
}

.json-editor__status {
  border-top: 1px solid color-mix(in srgb, #faf9f5 12%, transparent);
  background: #1a1a18;
  padding: 0.55rem 0.75rem;
  color: #c4c1b7;
  font-size: 0.75rem;
}

.json-editor__status--error {
  color: #f0c0b8;
  background: color-mix(in srgb, #9a342a 35%, #1a1a18);
}

:deep(.json-token-key) {
  color: #9bc0dc;
}

:deep(.json-token-string) {
  color: #9dccaa;
}

:deep(.json-token-number) {
  color: #e8c06a;
}

:deep(.json-token-boolean) {
  color: #b8b0e0;
}

:deep(.json-token-null) {
  color: #d4a0c8;
}

:deep(.json-token-punctuation) {
  color: #c4c1b7;
}

:deep(.json-token-error) {
  color: #f0a090;
  text-decoration: underline wavy color-mix(in srgb, #f0a090 80%, transparent);
}
</style>
