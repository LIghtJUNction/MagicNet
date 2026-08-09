<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from "vue";
import { ArrowRight, CheckCircle2, DownloadCloud, Gauge, Stethoscope, Terminal, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";

type GuideTarget = "subs" | "control" | "health" | "output";

type Step = {
  eyebrow: string;
  title: string;
  summary: string;
  details: string[];
  target: GuideTarget;
  targetLabel: string;
  secondaryTarget?: GuideTarget;
  secondaryLabel?: string;
};

const emit = defineEmits<{
  dismiss: [];
  complete: [];
  navigate: [target: GuideTarget];
}>();

const dialog = ref<HTMLElement | null>(null);
const currentStep = ref(0);
let previousBodyOverflow = "";

const steps: Step[] = [
  {
    eyebrow: "步骤 1",
    title: "确认设备已经准备好走 TUN",
    summary: "MagicNet 当前主线只支持 sing-box + magicnet0 TUN。Root 模块安装完成后，再从 WebUI 开始配置。",
    details: [
      "Private DNS 需要保持关闭，避免域名请求绕过 MagicNet。",
      "不要寻找其他透明模式或系统 VPN slot。",
      "运行状态页能先帮你确认核心是否已经起来。",
    ],
    target: "control",
    targetLabel: "查看运行状态",
  },
  {
    eyebrow: "步骤 2",
    title: "添加你自己的订阅或本地文件",
    summary: "订阅页支持填写订阅 URL，也支持导入本地配置或订阅文件。MagicNet 不提供订阅链接、节点或账号。",
    details: [
      "把来源交给你自己的服务商或本地文件，不要期待 MagicNet 生成节点。",
      "URL、token、密码、账号和示例密钥都不应该写进截图、反馈或共享文档。",
      "本地导入会进入和 URL 一样的候选解析与校验流程。",
    ],
    target: "subs",
    targetLabel: "打开订阅页",
  },
  {
    eyebrow: "步骤 3",
    title: "让 MagicNet 校验、应用并选择节点",
    summary: "保存后由 MagicNet 拉取、解析、校验并应用运行配置；节点选择放在现有控制流程里完成。",
    details: [
      "失败时会保留上一次有效配置，不需要手工覆盖 runtime config。",
      "节点切换、自动组和当前运行状态都在现有控制入口处理。",
      "如果想看失败细节，直接去输出页，不要跳过校验流程。",
    ],
    target: "control",
    targetLabel: "打开控制页",
    secondaryTarget: "output",
    secondaryLabel: "查看输出",
  },
  {
    eyebrow: "步骤 4",
    title: "验证通过后再碰应用、Wi‑Fi、热点",
    summary: "把基础链路跑通后，再考虑分流和网络策略。先看运行状态与诊断，再决定是否调整进阶策略。",
    details: [
      "优先确认 sing-box 状态、transparent/TUN 状态和诊断结果。",
      "应用、Wi‑Fi、热点策略都建立在已经可用的 magicnet0 路径之上。",
      "诊断仍有异常时继续查输出，不要直接改底层运行文件。",
    ],
    target: "health",
    targetLabel: "打开诊断",
    secondaryTarget: "output",
    secondaryLabel: "查看输出",
  },
];

const activeStep = computed(() => steps[currentStep.value] ?? steps[0]);
const isFirstStep = computed(() => currentStep.value === 0);
const isLastStep = computed(() => currentStep.value === steps.length - 1);
const progressLabel = computed(() => `第 ${currentStep.value + 1} / ${steps.length} 步`);

function previous(): void {
  if (isFirstStep.value) return;
  currentStep.value -= 1;
}

function next(): void {
  if (isLastStep.value) return;
  currentStep.value += 1;
}

function trapFocus(event: KeyboardEvent): void {
  if (event.key !== "Tab" || !dialog.value) return;
  const focusable = Array.from(
    dialog.value.querySelectorAll<HTMLElement>(
      'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
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
  } else if (!event.shiftKey && (active === last || !dialog.value.contains(active))) {
    event.preventDefault();
    first.focus();
  }
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
  <div class="fixed inset-0 z-[70] grid place-items-end p-3 sm:place-items-center sm:p-6">
    <button
      class="absolute inset-0 size-full bg-[color-mix(in_srgb,var(--mn-ink)_42%,transparent)]"
      type="button"
      aria-label="关闭新手引导"
      @click="emit('dismiss')"
    />
    <section
      ref="dialog"
      class="mn-chrome relative z-10 grid max-h-[calc(100dvh-1.5rem)] w-full max-w-3xl gap-4 overflow-y-auto rounded-md p-1.5"
      role="dialog"
      aria-modal="true"
      aria-labelledby="onboarding-title"
      aria-describedby="onboarding-description"
      tabindex="-1"
      @keydown="trapFocus"
      @keydown.esc.prevent.stop="emit('dismiss')"
    >
      <div class="rounded-[5px] bg-[var(--mn-ivory)] p-4 sm:p-5">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <span class="inline-flex items-center gap-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--mn-clay-ink)]">
              <CheckCircle2 :size="14" /> 新手引导
            </span>
            <h2 id="onboarding-title" class="mt-2 text-xl font-semibold tracking-[-0.03em] text-[var(--mn-ink)]">
              第一次使用 MagicNet
            </h2>
            <p id="onboarding-description" class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
              跟着这 4 步完成首次配置：确认 TUN 前提、添加来源、让 MagicNet 校验并应用，再用运行状态与诊断确认链路。
            </p>
          </div>
          <Button data-dialog-initial-focus variant="ghost" size="icon" aria-label="关闭新手引导" @click="emit('dismiss')">
            <X :size="18" />
          </Button>
        </div>

        <div class="mt-4 grid gap-3 lg:grid-cols-[220px_minmax(0,1fr)]">
          <ol class="grid gap-2" aria-label="引导进度">
            <li
              v-for="(step, index) in steps"
              :key="step.title"
              :class="[
                'rounded-md border p-3 text-left',
                index === currentStep
                  ? 'border-[var(--mn-cactus)] bg-[color-mix(in_srgb,var(--mn-cactus)_12%,var(--mn-ivory))]'
                  : 'border-[var(--mn-border)] bg-[var(--mn-carrier)] text-[var(--mn-ink-soft)]',
              ]"
            >
              <div class="flex items-center justify-between gap-3">
                <strong class="text-sm font-semibold text-[var(--mn-ink)]">{{ index + 1 }}. {{ step.title }}</strong>
                <span class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--mn-clay-ink)]">
                  {{ index === currentStep ? "当前" : "待完成" }}
                </span>
              </div>
              <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ step.eyebrow }}</p>
            </li>
          </ol>

          <article class="rounded-md border border-[var(--mn-border)] bg-[var(--mn-carrier)] p-4 sm:p-5">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <span class="text-[10px] font-semibold uppercase tracking-[0.2em] text-[var(--mn-clay-ink)]">{{ progressLabel }}</span>
              <div class="flex items-center gap-2 text-xs text-[var(--mn-ink-muted)]">
                <span class="inline-flex size-2.5 rounded-full bg-[var(--mn-cactus)]" aria-hidden="true" />
                <span>可随时重新打开，不会修改现有运行状态</span>
              </div>
            </div>

            <div class="mt-4 flex items-start gap-3">
              <div class="grid size-11 shrink-0 place-items-center rounded-[0.85rem] bg-[color-mix(in_srgb,var(--mn-cactus)_18%,var(--mn-carrier))] text-[var(--mn-cactus-deep)]">
                <DownloadCloud v-if="activeStep.target === 'subs'" :size="20" />
                <Gauge v-else-if="activeStep.target === 'control'" :size="20" />
                <Stethoscope v-else-if="activeStep.target === 'health'" :size="20" />
                <Terminal v-else :size="20" />
              </div>
              <div class="min-w-0">
                <h3 class="text-lg font-semibold tracking-[-0.03em] text-[var(--mn-ink)]">{{ activeStep.title }}</h3>
                <p class="mt-2 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ activeStep.summary }}</p>
              </div>
            </div>

            <ul class="mt-4 grid gap-2 text-sm leading-6 text-[var(--mn-ink-muted)]">
              <li
                v-for="detail in activeStep.details"
                :key="detail"
                class="rounded-[0.85rem] bg-[var(--mn-ivory)] px-3 py-2.5"
              >
                {{ detail }}
              </li>
            </ul>

            <div class="mt-4 flex flex-col gap-2 sm:flex-row sm:flex-wrap">
              <Button class="sm:flex-none" @click="emit('navigate', activeStep.target)">
                {{ activeStep.targetLabel }} <ArrowRight :size="16" />
              </Button>
              <Button
                v-if="activeStep.secondaryTarget && activeStep.secondaryLabel"
                variant="outline"
                class="sm:flex-none"
                @click="emit('navigate', activeStep.secondaryTarget)"
              >
                {{ activeStep.secondaryLabel }}
              </Button>
            </div>
          </article>
        </div>

        <div class="mt-4 flex flex-col gap-3 border-t border-[var(--mn-border)] pt-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-xs leading-5 text-[var(--mn-ink-muted)]">
            MagicNet 不提供订阅 URL、节点、token、password 或账号。把敏感信息留在你自己的来源里。
          </p>
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Button variant="ghost" class="sm:flex-none" @click="emit('dismiss')">稍后再看</Button>
            <div class="flex gap-2">
              <Button class="flex-1 sm:flex-none" variant="outline" :disabled="isFirstStep" @click="previous">上一步</Button>
              <Button v-if="!isLastStep" class="flex-1 sm:flex-none" @click="next">下一步</Button>
              <Button v-else class="flex-1 sm:flex-none" @click="emit('complete')">完成引导</Button>
            </div>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
