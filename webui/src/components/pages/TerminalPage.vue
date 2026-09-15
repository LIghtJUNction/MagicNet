<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { Check, Copy, Play, RotateCcw, Terminal, Trash2 } from "lucide-vue-next";
import { t } from "@/i18n";
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
  loadTerminalHistory,
} from "./terminalHistory";

type ExecutedEntry = {
  id: string;
  command: string;
  output: string;
  durationMs: number;
  ok: boolean;
  time: string;
};

const { runCli, runShell, shellQuote } = useMagicNet();

const inputCommand = ref("");
const history = ref<string[]>([]);
const historyIndex = ref(-1);
const draftInput = ref("");
const executing = ref(false);
const executedList = ref<ExecutedEntry[]>([]);
const copiedAll = ref(false);
const copiedId = ref<string | null>(null);

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
  await clearTerminalHistory(runShell);
  history.value = [];
  historyIndex.value = -1;
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
    e.preventDefault();
    handleTab();
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
  inputCommand.value = cmd;
  await submitCommand();
}

async function submitCommand(): Promise<void> {
  const trimmed = inputCommand.value.trim();
  if (!trimmed || executing.value) return;

  // Handle local terminal helper commands
  if (trimmed === "clear" || trimmed === "cls") {
    clearScreen();
    inputCommand.value = "";
    return;
  }

  // Record history
  history.value = await appendTerminalHistory(
    trimmed,
    history.value,
    runShell,
    shellQuote,
  );
  historyIndex.value = -1;
  draftInput.value = "";

  const commandToRun = trimmed;
  inputCommand.value = "";
  executing.value = true;
  scrollToBottom();

  const startTime = Date.now();
  const timeString = new Date().toLocaleTimeString();
  const cleanArgs = commandToRun.replace(/^(?:cli|magicnet-cli)\s+/i, "");

  let outputText = "";
  let success = true;

  try {
    outputText = await runCli(cleanArgs, `cli ${cleanArgs}`);
    success = !outputText.includes("[error]") && !outputText.includes("[exec-timeout]");
  } catch (error) {
    success = false;
    outputText = error instanceof Error ? error.message : String(error);
  } finally {
    const duration = Date.now() - startTime;
    executedList.value.push({
      id: `entry_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
      command: commandToRun,
      output: outputText || t("完成"),
      durationMs: duration,
      ok: success,
      time: timeString,
    });
    executing.value = false;
    scrollToBottom();
    void nextTick(focusInput);
  }
}

function formatOutput(text: string): string {
  // Strip common control characters if present
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

onMounted(() => {
  void loadTerminalHistory(runShell).then((loaded) => {
    history.value = loaded;
  });
  focusInput();
});

watch(executedList, () => {
  scrollToBottom();
});
</script>

<template>
  <div class="terminal-page space-y-4">
    <PageHeader title="终端">
      <div class="flex flex-wrap items-center gap-2">
        <Button
          variant="ghost"
          size="sm"
          :disabled="executedList.length === 0"
          @click="copyAllOutput"
        >
          <component :is="copiedAll ? Check : Copy" :size="14" aria-hidden="true" />
          {{ t(copiedAll ? "已复制全部输出" : "复制全部") }}
        </Button>
        <Button
          variant="ghost"
          size="sm"
          :disabled="executedList.length === 0"
          @click="clearScreen"
        >
          <RotateCcw :size="14" aria-hidden="true" />
          {{ t("清屏") }}
        </Button>
        <Button
          variant="ghost"
          size="sm"
          :disabled="history.length === 0"
          @click="handleClearHistory"
        >
          <Trash2 :size="14" aria-hidden="true" />
          {{ t("清空历史") }}
        </Button>
      </div>
    </PageHeader>

    <!-- Quick Commands Chips -->
    <div class="flex flex-wrap items-center gap-2 pb-1 text-xs">
      <span class="text-[var(--mn-ink-muted)] flex items-center gap-1 font-medium">
        <Terminal :size="13" aria-hidden="true" />
        {{ t("快捷命令") }}:
      </span>
      <button
        v-for="cmd in quickCommands"
        :key="cmd"
        type="button"
        class="px-2.5 py-1 rounded-md font-mono bg-[var(--mn-surface)] border border-[var(--mn-border)] text-[var(--mn-ink)] hover:bg-[var(--mn-surface-elevated)] hover:border-[var(--mn-ink-muted)] transition-colors cursor-pointer"
        @click="runCommandDirect(cmd)"
      >
        {{ cmd }}
      </button>
    </div>

    <!-- Main Terminal Card -->
    <div
      class="rounded-xl border border-zinc-800 bg-[#0d1117] text-zinc-200 shadow-2xl flex flex-col overflow-hidden h-[600px] max-h-[78vh]"
      @click="focusInput"
    >
      <!-- Terminal Window Bar -->
      <div class="flex items-center justify-between px-4 py-2.5 bg-[#161b22] border-b border-zinc-800 text-xs select-none">
        <div class="flex items-center gap-2">
          <span class="w-3 h-3 rounded-full bg-[#ff5f56] inline-block"></span>
          <span class="w-3 h-3 rounded-full bg-[#ffbd2e] inline-block"></span>
          <span class="w-3 h-3 rounded-full bg-[#27c93f] inline-block"></span>
          <span class="ml-2 font-mono text-zinc-400 font-medium tracking-wide">
            magicnet-cli
          </span>
        </div>
        <div class="flex items-center gap-2 text-zinc-400 font-mono">
          <StatusDot :tone="executing ? 'current' : 'ok'" />
          <span>{{ t(executing ? "执行中…" : "就绪") }}</span>
        </div>
      </div>

      <!-- Terminal Output & Prompt Area -->
      <div
        ref="terminalBodyRef"
        class="flex-1 p-4 overflow-y-auto font-mono text-sm space-y-4"
      >
        <!-- Welcome Banner -->
        <div class="text-xs leading-5 text-zinc-500 pb-2 border-b border-zinc-800/60 select-none">
          <p class="font-bold text-zinc-400">MagicNet Interactive CLI Terminal</p>
          <p>{{ t("按 Tab 或点击补全，按上下键切换历史") }} · 输入 clear 清屏</p>
        </div>

        <div v-if="executedList.length === 0" class="text-xs text-zinc-600 italic py-2">
          {{ t("暂无命令执行记录，输入命令或点击上方快捷命令开始。") }}
        </div>

        <!-- Executed Command Blocks -->
        <div
          v-for="entry in executedList"
          :key="entry.id"
          class="space-y-1.5 group"
        >
          <!-- Command line header -->
          <div class="flex items-baseline justify-between text-xs font-mono text-zinc-400">
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="text-emerald-400 font-bold">magicnet</span>
              <span class="text-zinc-600">:</span>
              <span class="text-blue-400 font-semibold">~</span>
              <span class="text-zinc-500">$</span>
              <span class="text-zinc-100 font-semibold">cli {{ entry.command.replace(/^(?:cli|magicnet-cli)\s+/i, '') }}</span>
            </div>
            <div class="flex items-center gap-2 text-zinc-500 opacity-80 group-hover:opacity-100 transition-opacity">
              <span>{{ entry.time }}</span>
              <span>{{ entry.durationMs }}ms</span>
              <button
                type="button"
                class="hover:text-zinc-200 cursor-pointer p-0.5"
                :title="t('复制')"
                @click.stop="copyEntryOutput(entry)"
              >
                <component :is="copiedId === entry.id ? Check : Copy" :size="12" />
              </button>
            </div>
          </div>

          <!-- Command output -->
          <pre
            class="text-xs p-2.5 rounded bg-[#161b22]/70 text-zinc-300 border border-zinc-800/50 whitespace-pre-wrap break-all leading-relaxed"
            :class="{ 'text-red-400 border-red-900/40': !entry.ok }"
          >{{ formatOutput(entry.output) }}</pre>
        </div>

        <!-- Current Active Prompt Row with Ghost Text Background -->
        <div class="pt-2">
          <div class="flex items-center gap-1.5">
            <span class="text-emerald-400 font-bold select-none">magicnet</span>
            <span class="text-zinc-600 select-none">:</span>
            <span class="text-blue-400 font-semibold select-none">~</span>
            <span class="text-zinc-500 select-none">$</span>

            <!-- Ghost Text & Input Container -->
            <div class="relative flex-1 min-w-0">
              <!-- Ghost text displayed directly behind input -->
              <div
                class="pointer-events-none absolute inset-0 select-none whitespace-pre flex items-center font-mono text-sm leading-normal overflow-hidden"
                aria-hidden="true"
              >
                <span class="invisible">{{ inputCommand }}</span>
                <span class="text-zinc-500 opacity-60">{{ ghostText }}</span>
              </div>

              <!-- Real interactive input -->
              <input
                ref="inputRef"
                v-model="inputCommand"
                type="text"
                class="relative z-10 w-full bg-transparent text-zinc-100 outline-none font-mono text-sm leading-normal caret-emerald-400 placeholder:text-zinc-600"
                :placeholder="t('执行命令…')"
                spellcheck="false"
                autocomplete="off"
                autocapitalize="none"
                :disabled="executing"
                @keydown="handleKeyDown"
              />
            </div>

            <!-- Enter button for touch devices -->
            <Button
              variant="ghost"
              size="sm"
              class="h-7 px-2 text-zinc-400 hover:text-white"
              :disabled="!inputCommand.trim() || executing"
              @click.stop="submitCommand"
            >
              <Play :size="13" aria-hidden="true" />
            </Button>
          </div>

          <!-- Autocomplete Suggestion Dropdown/Chips -->
          <div
            v-if="suggestions.length > 0"
            class="mt-2.5 p-2 rounded-lg bg-[#161b22] border border-zinc-800 space-y-1.5 shadow-lg"
          >
            <div class="text-[11px] text-zinc-500 font-sans flex items-center justify-between px-1">
              <span>{{ t("补全建议") }}</span>
              <span class="text-zinc-600 font-mono">Tab ⇥</span>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-1">
              <button
                v-for="item in suggestions"
                :key="item.command"
                type="button"
                class="flex items-center justify-between gap-2 px-2 py-1 rounded text-xs font-mono text-left text-zinc-300 hover:bg-[#21262d] hover:text-white transition-colors cursor-pointer"
                @click.stop="selectSuggestion(item)"
              >
                <div class="flex items-center gap-1.5 truncate">
                  <span class="text-emerald-400 font-semibold">{{ item.display }}</span>
                  <span v-if="item.syntax" class="text-zinc-500 text-[11px] truncate">
                    {{ item.syntax }}
                  </span>
                </div>
                <span v-if="item.description" class="text-[11px] text-zinc-500 truncate max-w-[140px]">
                  {{ item.description }}
                </span>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Mobile / Quick Touch Bar -->
      <div class="flex items-center justify-between px-3 py-2 bg-[#161b22] border-t border-zinc-800 text-xs">
        <div class="flex items-center gap-1.5">
          <button
            type="button"
            class="px-2 py-1 rounded font-mono bg-[#21262d] hover:bg-[#30363d] text-zinc-300 transition-colors cursor-pointer select-none text-xs"
            @click.stop="handleTab"
          >
            Tab
          </button>
          <button
            type="button"
            class="px-2 py-1 rounded font-mono bg-[#21262d] hover:bg-[#30363d] text-zinc-300 transition-colors cursor-pointer select-none text-xs"
            @click.stop="historyUp"
          >
            ↑
          </button>
          <button
            type="button"
            class="px-2 py-1 rounded font-mono bg-[#21262d] hover:bg-[#30363d] text-zinc-300 transition-colors cursor-pointer select-none text-xs"
            @click.stop="historyDown"
          >
            ↓
          </button>
          <button
            type="button"
            class="px-2 py-1 rounded font-mono bg-[#21262d] hover:bg-[#30363d] text-zinc-300 transition-colors cursor-pointer select-none text-xs"
            @click.stop="clearScreen"
          >
            {{ t("清屏") }}
          </button>
        </div>
        <div class="text-[11px] text-zinc-500 font-mono">
          <span>{{ history.length }} {{ t("历史记录") }}</span>
        </div>
      </div>
    </div>
  </div>
</template>
