<script setup lang="ts">
import { Activity, CheckCircle2, Copy, Radio, Stethoscope } from "lucide-vue-next";
import { computed, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import CardHeading from "@/components/ui/CardHeading.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import StatTile from "@/components/ui/StatTile.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import {
  DATAPLANE_IFACE,
  dataPlaneFacts,
  firstRunSteps,
  formatAboutOverview,
  successChecks,
} from "./aboutOverview";

const emit = defineEmits<{
  (e: "goto-tab", tab: "control" | "subs" | "health"): void;
}>();

const { state } = useMagicNet();
const copied = ref(false);

const facts = dataPlaneFacts();
const steps = firstRunSteps();
const checks = successChecks();
const overview = computed(() => formatAboutOverview(facts, steps, checks));

const tunLabel = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "sing-box 运行中";
  if (state.runtime.singBoxState === "stopped") return "已停止";
  return "状态未知";
});

const tunTone = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "success" as const;
  if (state.runtime.singBoxState === "stopped") return "warning" as const;
  return "neutral" as const;
});

async function copyOverview(): Promise<void> {
  copied.value = await copyText(overview.value);
  state.notice = copied.value
    ? "路径速览已复制。"
    : "剪贴板不可用，路径速览未复制。";
}
</script>

<template>
  <div class="grid gap-4 md:gap-5">
    <PageHeader
      overline="Data Plane"
      title="路径速览"
      description="一眼看清 MagicNet 当前只走 sing-box magicnet0 TUN，以及怎样用健康检查证明接管成功。"
    >
      <template #actions>
        <Button variant="outline" @click="copyOverview">
          <Copy :size="17" aria-hidden="true" />{{ copied ? "已复制说明" : "复制说明" }}
        </Button>
        <Badge :tone="tunTone">{{ tunLabel }}</Badge>
      </template>
    </PageHeader>

    <div class="grid gap-3 sm:grid-cols-3">
      <StatTile label="数据面" :value="DATAPLANE_IFACE" hint="唯一透明接口" mono />
      <StatTile label="核心" value="sing-box TUN" hint="不占用系统 VPN slot" />
      <StatTile
        label="验收"
        value="health + TUN"
        hint="以 cli 与 magicnet0 为准"
      />
    </div>

    <Card class="grid gap-4 !p-4 md:!p-6">
      <CardHeading
        overline="PATH"
        title="Android root → magicnet0 → sing-box"
        description="这是模块 WebUI 要先证明的真实路径。节点选择仍由 sing-box 面板负责。"
      >
        <Radio :size="18" aria-hidden="true" />
      </CardHeading>
      <div class="grid gap-3 md:grid-cols-3">
        <div
          v-for="fact in facts"
          :key="fact.code"
          class="grid gap-2 rounded-[2px] border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3"
        >
          <code class="text-[11px] tracking-[0.08em] text-[var(--mn-ink-faint)]">{{ fact.code }}</code>
          <h3 class="text-base font-semibold text-[var(--mn-ink)]">{{ fact.title }}</h3>
          <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ fact.detail }}</p>
        </div>
      </div>
    </Card>

    <div class="grid gap-4 lg:grid-cols-2">
      <Card class="grid gap-4 !p-4 md:!p-6">
        <CardHeading
          overline="START"
          title="首次成功运行"
          description="三步就能确认设备已经被 TUN 接管。"
        />
        <ol class="grid gap-3">
          <li
            v-for="(step, index) in steps"
            :key="step.id"
            class="grid gap-1 rounded-[2px] border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 sm:grid-cols-[auto_minmax(0,1fr)] sm:items-start sm:gap-3"
          >
            <span class="font-mono text-xs text-[var(--mn-ink-faint)]">{{ String(index + 1).padStart(2, "0") }}</span>
            <div class="grid gap-1">
              <strong class="text-sm text-[var(--mn-ink)]">{{ step.title }}</strong>
              <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ step.detail }}</p>
            </div>
          </li>
        </ol>
        <div class="flex flex-wrap gap-2">
          <Button variant="secondary" @click="emit('goto-tab', 'subs')">
            <Activity :size="17" aria-hidden="true" />去订阅
          </Button>
          <Button variant="secondary" @click="emit('goto-tab', 'health')">
            <Stethoscope :size="17" aria-hidden="true" />去健康检查
          </Button>
        </div>
      </Card>

      <Card class="grid gap-4 !p-4 md:!p-6">
        <CardHeading
          overline="ACCEPT"
          title="成功判据"
          description="不要寻找已删除的旁路。主线只支持 sing-box magicnet0 TUN。"
        />
        <ul class="grid gap-3">
          <li
            v-for="check in checks"
            :key="check.command"
            class="grid gap-1 rounded-[2px] border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3"
          >
            <div class="flex items-center gap-2">
              <CheckCircle2 :size="16" aria-hidden="true" />
              <code class="text-sm text-[var(--mn-ink)]">{{ check.command }}</code>
            </div>
            <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ check.expect }}</p>
          </li>
        </ul>
        <Button variant="outline" @click="emit('goto-tab', 'control')">
          返回运行总览
        </Button>
      </Card>
    </div>
  </div>
</template>
