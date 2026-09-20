<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onDeactivated, onMounted, ref, watch } from "vue";
import { ArrowDown, ArrowUp, Check, Copy, CornerDownLeft, Play, RotateCcw, Terminal, Trash2 } from "lucide-vue-next";
import { t } from "@/i18n";
import { compactCommand, compactOutput, execFailed } from "@/utils";
import Button from "@/components/ui/Button.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  applyTabCompletion,
  getCompletions,
  type CompletionItem,
} from "./terminalCompleter";
import {
  appendTerminalHistory,
  clearTerminalHistory,
  MAX_TERMINAL_ENTRIES,
} from "./terminalHistory";

type ExecutedEntry = {
  id: string;
  command: string;
  output: string;
  durationMs: number;
  ok: boolean;
  time: string;
};

const { runCli, runShell } = useMagicNet();

const inputCommand = ref("");
const history = ref<string[]>([]);
const historyIndex = ref(-1);
const draftInput = ref("");
const executing = ref(false);
const executedList = ref<ExecutedEntry[]>([]);
const copiedAll = ref(false);
const copiedId = ref<string | null>(null);
const clearingHistory = ref(false);
const historyClearFailed = ref(false);
let sessionRevision = 0;

const inputRef = ref<HTMLInputElement | null>(null);
const terminalBodyRef = ref<HTMLElement | null>(null);

const quickCommands = [
  "health",
  "service status",
  "node list",
  "dns status",
  "transparent status",
  "help",
];

const completionResult = computed(() =>
  getCompletions(inputCommand.value, history.value),
);

const suggestions = computed<CompletionItem[]>(() =>
  inputCommand.value.trim().length > 0 ? completionResult.value.suggestions.slice(0, 6) : [],
);

const ghostText = computed(() =>
  inputCommand.value ? completionResult.value.ghostText : "",
);

function scrollToBottom(): void {
  void nextTick(() => {
    if (terminalBodyRef.value) {
      terminalBodyRef.value.scrollTop = terminalBodyRef.value.scrollHeight;
    }
  });
}

function focusInput(): void {
  inputRef.value?.focus();
}

async function copyAllOutput(): Promise<void> {
  if (executedList.value.length === 0) return;
  const fullText = executedList.value
    .map((item) => `$ ${item.command}\n${item.output}`)
    .join("\n\n");
  try {
    await navigator.clipboard.writeText(fullText);
    copiedAll.value = true;
    setTimeout(() => {
      copiedAll.value = false;
    }, 2000);
  } catch {
    /* ignore clipboard failure */
  }
}

async function copyEntryOutput(entry: ExecutedEntry): Promise<void> {
  try {
    await navigator.clipboard.writeText(entry.output);
    copiedId.value = entry.id;
    setTimeout(() => {
      if (copiedId.value === entry.id) copiedId.value = null;
    }, 2000);
  } catch {
    /* ignore clipboard failure */
  }
}

function clearScreen(): void {
  executedList.value = [];
  focusInput();
}

async function handleClearHistory(): Promise<void> {
  if (clearingHistory.value || executing.value) return;
  clearingHistory.value = true;
  resetSession();
  const revision = sessionRevision;
  try {
    const cleared = await clearTerminalHistory(runShell);
    if (revision === sessionRevision) historyClearFailed.value = !cleared;
  } finally {
    clearingHistory.value = false;
  }
}

function resetSession(): void {
  sessionRevision += 1;
  inputCommand.value = "";
  draftInput.value = "";
  history.value = [];
  historyIndex.value = -1;
  executedList.value = [];
  copiedAll.value = false;
  copiedId.value = null;
  historyClearFailed.value = false;
  // Keep execution admission locked until an already running command settles.
}

function handleTab(): void {
  const { completed, changed } = applyTabCompletion(
    inputCommand.value,
    history.value,
  );
  if (changed) {
    inputCommand.value = completed;
    void nextTick(() => {
      if (inputRef.value) {
        inputRef.value.selectionStart = inputRef.value.selectionEnd = completed.length;
      }
    });
  }
}

function selectSuggestion(item: CompletionItem): void {
  inputCommand.value = item.command;
  focusInput();
}

function historyUp(): void {
  if (history.value.length === 0) return;
  if (historyIndex.value === -1) {
    draftInput.value = inputCommand.value;
    historyIndex.value = history.value.length - 1;
  } else if (historyIndex.value > 0) {
    historyIndex.value -= 1;
  }
  inputCommand.value = history.value[historyIndex.value] ?? "";
  void nextTick(() => {
    if (inputRef.value) {
      inputRef.value.selectionStart = inputRef.value.selectionEnd = inputCommand.value.length;
    }
  });
}

function historyDown(): void {
  if (historyIndex.value === -1) return;
  if (historyIndex.value < history.value.length - 1) {
    historyIndex.value += 1;
    inputCommand.value = history.value[historyIndex.value] ?? "";
  } else {
    historyIndex.value = -1;
    inputCommand.value = draftInput.value;
  }
  void nextTick(() => {
    if (inputRef.value) {
      inputRef.value.selectionStart = inputRef.value.selectionEnd = inputCommand.value.length;
    }
  });
}

function handleKeyDown(e: KeyboardEvent): void {
  if (e.key === "Tab") {
    if (!e.shiftKey && inputCommand.value.trim() && applyTabCompletion(inputCommand.value, history.value).changed) {
      e.preventDefault();
      handleTab();
    }
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    historyUp();
  } else if (e.key === "ArrowDown") {
    e.preventDefault();
    historyDown();
  } else if (e.key === "Enter") {
    e.preventDefault();
    void submitCommand();
  } else if (e.key === "ArrowRight") {
    // If at the end of input, right arrow accepts ghost suggestion
    if (
      ghostText.value &&
      inputRef.value &&
      inputRef.value.selectionStart === inputCommand.value.length
    ) {
      e.preventDefault();
      handleTab();
    }
  }
}

async function runCommandDirect(cmd: string): Promise<void> {
  if (executing.value || clearingHistory.value) return;
  inputCommand.value = cmd;
  await submitCommand();
}

async function submitCommand(): Promise<void> {
  const trimmed = inputCommand.value.trim();
  if (!trimmed || executing.value || clearingHistory.value) return;

  // Handle local terminal helper commands
  if (trimmed === "clear" || trimmed === "cls") {
    clearScreen();
    inputCommand.value = "";
    return;
  }

  // Admission must be synchronous: rapid Enter/taps cannot start two writes.
  executing.value = true;
  const revision = sessionRevision;
  history.value = appendTerminalHistory(trimmed, history.value);
  historyIndex.value = -1;
  draftInput.value = "";

  const commandToRun = trimmed;
  inputCommand.value = "";
  scrollToBottom();

  const startTime = Date.now();
  const timeString = new Date().toLocaleTimeString();
  const cleanArgs = commandToRun.replace(/^(?:cli|magicnet-cli)\s+/i, "");

  let outputText = "";
  let success = true;

  try {
    outputText = await runCli(cleanArgs, `cli ${cleanArgs}`);
    success = !execFailed(outputText);
  } catch (error) {
    success = false;
    outputText = error instanceof Error ? error.message : String(error);
  } finally {
    const duration = Date.now() - startTime;
    executing.value = false;
    if (revision === sessionRevision) {
      executedList.value = [...executedList.value, {
        id: `entry_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
        command: compactCommand(commandToRun),
        output: compactOutput(outputText || t("完成")),
        durationMs: duration,
        ok: success,
        time: timeString,
      }].slice(-MAX_TERMINAL_ENTRIES);
      scrollToBottom();
      void nextTick(focusInput);
    }
  }
}

function formatOutput(text: string): string {
  // Strip common control characters if present
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

onMounted(() => {
  if (window.matchMedia("(pointer: fine)").matches) focusInput();
});
onDeactivated(resetSession);
onBeforeUnmount(resetSession);

watch(executedList, () => {
  scrollToBottom();
});
</script>

<template>
  <div class="terminal-page">
    <PageHeader :title="t('终端')">
      <div class="terminal-actions">
        <Button variant="ghost" size="sm" :disabled="executedList.length === 0" @click="copyAllOutput">
          <component :is="copiedAll ? Check : Copy" :size="16" aria-hidden="true" />
          {{ t(copiedAll ? "已复制全部输出" : "复制全部") }}
        </Button>
        <Button variant="ghost" size="sm" :disabled="executedList.length === 0" @click="clearScreen">
          <RotateCcw :size="16" aria-hidden="true" />{{ t("清屏") }}
        </Button>
      </div>
    </PageHeader>

    <section class="terminal-workspace" :aria-label="t('终端')">
      <header class="terminal-toolbar">
        <div class="terminal-identity"><Terminal :size="18" aria-hidden="true" /><span>magicnet-cli</span></div>
        <span class="terminal-status" role="status"><StatusDot v-if="executing" tone="current" /><span v-else class="terminal-neutral-dot" aria-hidden="true"></span>{{ t(executing ? "执行中…" : "就绪") }}</span>
      </header>

      <div ref="terminalBodyRef" class="terminal-output" :aria-label="t('命令输出')" tabindex="0" :aria-busy="executing">
        <div v-if="executedList.length === 0 && !executing" class="terminal-empty">
          <Terminal :size="28" :stroke-width="1.4" aria-hidden="true" />
          <h2>{{ t("从一条命令开始") }}</h2>
          <p>{{ t("输入命令，或选择下方的快捷命令。") }}</p>
          <code>cli health</code>
        </div>
        <article v-for="entry in executedList" :key="entry.id" class="terminal-entry" :class="{ 'terminal-entry-failed': !entry.ok }">
          <header class="terminal-entry-heading">
            <div class="terminal-command"><span aria-hidden="true">›</span><code>cli {{ entry.command.replace(/^(?:cli|magicnet-cli)\s+/i, '') }}</code></div>
            <div class="terminal-entry-meta">
              <span class="terminal-result">{{ t(entry.ok ? "完成" : "失败") }}</span>
              <time>{{ entry.time }}</time><span>{{ entry.durationMs }}ms</span>
              <button type="button" class="terminal-icon-button" :aria-label="t('复制输出')" :title="t('复制输出')" @click="copyEntryOutput(entry)">
                <component :is="copiedId === entry.id ? Check : Copy" :size="16" aria-hidden="true" />
              </button>
            </div>
          </header>
          <pre>{{ formatOutput(entry.output) }}</pre>
        </article>
        <div v-if="executing" class="terminal-pending" role="status">
          <span class="terminal-pending-mark" aria-hidden="true"></span>
          <span>{{ t("命令执行中，正在等待输出…") }}</span>
        </div>
      </div>

      <div class="terminal-composer">
        <div v-if="suggestions.length > 0" class="terminal-suggestions" :aria-label="t('补全建议')">
          <button v-for="item in suggestions" :key="item.command" type="button" :disabled="executing || clearingHistory" @click="selectSuggestion(item)">
            <code>{{ item.display }} <span v-if="item.syntax">{{ item.syntax }}</span></code>
            <span v-if="item.description">{{ item.description }}</span>
          </button>
        </div>
        <label class="terminal-input-label" for="terminal-command">{{ t("命令") }}</label>
        <div class="terminal-input-row">
          <span class="terminal-input-prefix" aria-hidden="true">cli</span>
          <div class="terminal-input-wrap">
            <div class="terminal-ghost" aria-hidden="true"><span class="invisible">{{ inputCommand }}</span><span>{{ ghostText }}</span></div>
            <input id="terminal-command" ref="inputRef" v-model="inputCommand" type="text" :placeholder="t('输入命令…')" spellcheck="false" autocomplete="off" autocapitalize="none" :disabled="executing || clearingHistory" @keydown="handleKeyDown" />
          </div>
          <Button class="terminal-run" :disabled="!inputCommand.trim() || executing || clearingHistory" @click="submitCommand">
            <Play :size="16" aria-hidden="true" />{{ t(executing ? "执行中…" : "执行") }}
          </Button>
        </div>
        <div class="terminal-input-tools">
          <div class="terminal-keyboard-tools">
            <button type="button" :disabled="executing || clearingHistory" :aria-label="t('补全命令')" @click="handleTab"><CornerDownLeft :size="15" aria-hidden="true" /><span>Tab</span></button>
            <button type="button" :disabled="executing || clearingHistory || history.length === 0" :aria-label="t('上一条命令')" @click="historyUp"><ArrowUp :size="16" aria-hidden="true" /></button>
            <button type="button" :disabled="executing || clearingHistory || historyIndex === -1" :aria-label="t('下一条命令')" @click="historyDown"><ArrowDown :size="16" aria-hidden="true" /></button>
          </div>
          <span class="terminal-history-count">{{ history.length }} {{ t("历史记录") }}</span>
        </div>
      </div>
    </section>

    <div class="terminal-quick">
      <span>{{ t("快捷命令") }}</span>
      <div><button v-for="cmd in quickCommands" :key="cmd" type="button" :disabled="executing || clearingHistory" @click="runCommandDirect(cmd)"><code>{{ cmd }}</code></button></div>
    </div>
    <footer class="terminal-footer">
      <p>{{ t("历史仅保留在当前页面，离开后清除；不再写入文件或浏览器存储。") }}</p>
      <Button variant="ghost" size="sm" :disabled="executing || clearingHistory" @click="handleClearHistory"><Trash2 :size="15" aria-hidden="true" />{{ t("清空历史") }}</Button>
    </footer>
    <p v-if="historyClearFailed" role="alert" class="terminal-error">{{ t("旧历史记录未完全清除，请重试。") }}</p>
  </div>
</template>

<style scoped>
.terminal-page { display: grid; gap: 24px; }
.terminal-actions, .terminal-identity, .terminal-status, .terminal-entry-meta, .terminal-keyboard-tools { display: flex; align-items: center; gap: 10px; }
.terminal-workspace { min-width: 0; border: 1px solid var(--mn-border); border-radius: 12px; background: var(--mn-surface-raised); overflow: hidden; }
.terminal-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 16px 20px; border-bottom: 1px solid var(--mn-border); }
.terminal-identity { font-size: 14px; font-weight: 500; }
.terminal-neutral-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--mn-ink-muted); }
.terminal-status { color: var(--mn-ink-muted); font-size: 13px; }
.terminal-output { height: clamp(240px, 40dvh, 460px); overflow: auto; padding: 8px 24px; scrollbar-color: var(--mn-border-strong) transparent; scrollbar-width: thin; }
.terminal-output:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: -3px; }
.terminal-empty { min-height: 100%; display: flex; flex-direction: column; justify-content: center; align-items: flex-start; gap: 12px; padding: 32px 8px; color: var(--mn-ink-muted); }
.terminal-empty h2 { color: var(--mn-ink); font-size: 22px; font-weight: 500; }
.terminal-empty p { margin: 0; font-size: 14px; }
.terminal-empty code { margin-top: 4px; font-size: 13px; }
.terminal-entry { padding: 18px 0; border-bottom: 1px solid var(--mn-border); }
.terminal-entry:last-child { border-bottom: 0; }
.terminal-entry-heading { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 4px 16px; }
.terminal-command { display: flex; align-items: baseline; gap: 10px; min-width: 0; color: var(--mn-ink); }
.terminal-command > span { color: var(--mn-ink-muted); }
.terminal-command code { overflow-wrap: anywhere; font-size: 14px; font-weight: 500; }
.terminal-entry-meta { flex-wrap: wrap; gap: 10px; font-size: 12px; color: var(--mn-ink-muted); font-variant-numeric: tabular-nums; }
.terminal-result { color: var(--mn-success); }
.terminal-entry-failed .terminal-result { color: var(--mn-danger); }
.terminal-entry pre { margin: 8px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; line-height: 1.8; color: var(--mn-ink-soft); }
.terminal-entry-failed pre { color: var(--mn-danger); }
.terminal-icon-button { display: inline-flex; align-items: center; justify-content: center; min-width: 48px; min-height: 48px; border-radius: 8px; }
.terminal-composer { padding: 16px 20px 8px; border-top: 1px solid var(--mn-border); background: var(--mn-surface); }
.terminal-input-label { display: block; margin-bottom: 8px; color: var(--mn-ink-muted); font-size: 13px; }
.terminal-input-row { display: flex; align-items: center; gap: 12px; padding: 4px 4px 4px 14px; border: 1px solid var(--mn-border-strong); border-radius: 8px; background: var(--mn-surface-input); }
.terminal-input-row:focus-within { border-color: var(--mn-focus); outline: 2px solid var(--mn-focus); outline-offset: 2px; }
.terminal-input-prefix { color: var(--mn-ink-muted); font: 14px var(--font-mono); }
.terminal-input-wrap { position: relative; flex: 1; min-width: 0; }
.terminal-input-wrap input { position: relative; z-index: 1; width: 100%; min-height: 48px; border: 0; outline: none; background: transparent; color: var(--mn-ink); font: 16px/1.5 var(--font-mono); caret-color: var(--mn-primary); }
.terminal-input-wrap input::placeholder { color: var(--mn-ink-muted); }
.terminal-ghost { position: absolute; inset: 0; display: flex; align-items: center; overflow: hidden; white-space: pre; pointer-events: none; font: 16px/1.5 var(--font-mono); color: var(--mn-ink-muted); }
.terminal-run { flex-shrink: 0; min-height: 48px; }
.terminal-input-tools { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.terminal-keyboard-tools { gap: 2px; }
.terminal-keyboard-tools button { min-width: 48px; min-height: 48px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; border-radius: 8px; font-size: 13px; color: var(--mn-ink-soft); }
.terminal-history-count { color: var(--mn-ink-muted); font-size: 12px; }
.terminal-quick { display: grid; grid-template-columns: auto 1fr; align-items: baseline; gap: 12px 20px; }
.terminal-quick > span { font-size: 13px; color: var(--mn-ink-muted); }
.terminal-quick > div { display: flex; flex-wrap: wrap; gap: 6px; }
.terminal-quick button { min-height: 48px; padding: 0 12px; border: 1px solid var(--mn-border); border-radius: 8px; color: var(--mn-ink-soft); font-size: 12px; }
.terminal-footer { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.terminal-footer p { max-width: 60ch; margin: 0; color: var(--mn-ink-muted); font-size: 12px; line-height: 1.7; }
.terminal-footer > button { flex-shrink: 0; }
.terminal-error { color: var(--mn-danger); font-size: 13px; }
.terminal-suggestions { margin-bottom: 16px; border-bottom: 1px solid var(--mn-border); padding-bottom: 8px; }
.terminal-suggestions button { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 4px 16px; width: 100%; min-height: 48px; padding: 8px 10px; border-radius: 8px; text-align: left; }
.terminal-suggestions code { font-size: 13px; overflow-wrap: anywhere; }
.terminal-suggestions code span, .terminal-suggestions button > span { color: var(--mn-ink-muted); font-size: 12px; }
.terminal-pending { display: flex; align-items: center; gap: 10px; padding: 24px 0; color: var(--mn-ink-muted); font-size: 13px; }
.terminal-pending-mark { width: 6px; height: 6px; background: var(--mn-ink-muted); border-radius: 50%; animation: terminal-pulse 1.4s ease-in-out infinite; }
.terminal-page button { cursor: pointer; }
.terminal-page button:disabled { cursor: default; opacity: .45; }
.terminal-page button:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: 2px; }
.terminal-page ::selection { background: var(--mn-carrier-deep); color: var(--mn-ink); }
@media (hover: hover) { .terminal-keyboard-tools button:not(:disabled):hover, .terminal-icon-button:hover, .terminal-quick button:not(:disabled):hover, .terminal-suggestions button:not(:disabled):hover { background: var(--mn-surface-sunken); } }
@media (max-width: 600px) {
  .terminal-page { gap: 20px; }
  .terminal-toolbar { padding: 14px 16px; }
  .terminal-output { padding: 4px 16px; height: clamp(220px, 34dvh, 340px); }
  .terminal-composer { padding: 14px 12px 4px; }
  .terminal-empty { padding: 24px 0; }
  .terminal-input-row { gap: 8px; padding-left: 10px; }
  .terminal-quick { grid-template-columns: 1fr; gap: 10px; }
  .terminal-footer { align-items: flex-start; }
  .terminal-entry-heading { display: block; }
  .terminal-entry-meta { margin-top: 2px; }
}
@keyframes terminal-pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .terminal-pending-mark { animation: none; } }
</style>
