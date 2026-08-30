<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from "vue";
import { ArrowRight, CheckCircle2, DownloadCloud, Gauge, Stethoscope, Terminal, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Eyebrow from "@/components/ui/Eyebrow.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { trapFocusWithin } from "@/lib/focus";

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
    title: "先确认 TUN 能运行",
    summary: "MagicNet 只走 sing-box 的 magicnet0 TUN。装好 Root 模块后，在控制页查看运行状态。",
    details: [
      "请关闭 Private DNS，否则 DNS 请求可能绕过 MagicNet。",
      "MagicNet 不使用其他透明代理模式，也不占用系统 VPN slot。",
      "你可以在控制页确认 sing-box 和 TUN 是否已启动。",
    ],
    target: "control",
    targetLabel: "去控制页",
  },
  {
    eyebrow: "步骤 2",
    title: "添加订阅或本地文件",
    summary: "在订阅页填入你自己的订阅 URL，或导入本地文件。MagicNet 不提供节点和账号。",
    details: [
      "请使用自己的服务商订阅或本地文件。",
      "截图和反馈里不要出现 URL、token、密码或账号。",
      "MagicNet 会先解析并校验本地文件，确认可用后才会应用。",
    ],
    target: "subs",
    targetLabel: "去订阅页",
  },
  {
    eyebrow: "步骤 3",
    title: "应用配置，再去 zashboard 选节点",
    summary: "MagicNet 检查并应用配置后，你可以从控制页打开 zashboard 选节点。",
    details: [
      "校验没通过时，MagicNet 继续使用上一次可用的配置。",
      "你在 zashboard 里切换节点和代理组，也可以测速。",
      "MagicNet 把失败原因写到输出页。",
    ],
    target: "control",
    targetLabel: "去控制页",
    secondaryTarget: "output",
    secondaryLabel: "看输出",
  },
  {
    eyebrow: "步骤 4",
    title: "链路正常后，再设置分流",
    summary: "先看运行状态和诊断。链路正常后，再调整应用、Wi‑Fi 或热点策略。",
    details: [
      "确认 sing-box 已运行，magicnet0 存在，诊断没有报错。",
      "应用、Wi‑Fi 和热点策略都依赖 magicnet0。",
      "还有报错就去输出页查看原因，不要手改运行文件。",
    ],
    target: "health",
    targetLabel: "跑一次诊断",
    secondaryTarget: "output",
    secondaryLabel: "看输出",
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
  <div class="fixed inset-0 z-[70] grid place-items-end p-3 sm:place-items-center sm:p-6">
    <button
      class="mn-overlay absolute inset-0 size-full"
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
            <h2 id="onboarding-title" class="flex items-center gap-2 text-xl font-semibold tracking-[-0.025em] text-[var(--mn-ink)]">
              <CheckCircle2 :size="18" aria-hidden="true" />第一次使用 MagicNet
            </h2>
            <p id="onboarding-description" class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">
              先确认 TUN 能运行，再添加配置。配置生效后去 zashboard 选节点，最后跑一次诊断。
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
                'mn-choice rounded-md p-3 text-left',
                index === currentStep ? 'mn-choice-active' : 'text-[var(--mn-ink-soft)]',
              ]"
            >
              <div class="flex items-center justify-between gap-3">
                <strong class="text-sm font-semibold text-[var(--mn-ink)]">{{ index + 1 }}. {{ step.title }}</strong>
                <Eyebrow tone="clay" class="shrink-0 whitespace-nowrap tracking-[0.16em]">
                  {{ index === currentStep ? "当前" : "待完成" }}
                </Eyebrow>
              </div>
              <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ step.eyebrow }}</p>
            </li>
          </ol>

          <article class="rounded-md border border-[var(--mn-border)] bg-[var(--mn-carrier)] p-4 sm:p-5">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <Eyebrow tone="clay">{{ progressLabel }}</Eyebrow>
              <div class="flex items-center gap-2 text-xs text-[var(--mn-ink-muted)]">
                <StatusDot tone="ok" />
                <span>可随时重新打开，不会修改现有运行状态</span>
              </div>
            </div>

            <div class="mt-4 flex items-start gap-3">
              <div class="grid size-11 shrink-0 place-items-center rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-cactus)_18%,var(--mn-carrier))] text-[var(--mn-cactus-deep)]">
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
                class="rounded-[var(--mn-radius-md)] bg-[var(--mn-ivory)] px-3 py-2.5"
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
