<script setup lang="ts">
import { Activity, ArrowRight, CheckCircle2, Copy, Radio, Stethoscope } from "lucide-vue-next";
import { computed, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import CardHeading from "@/components/ui/CardHeading.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import StatTile from "@/components/ui/StatTile.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import {
  DATAPLANE_LABEL,
  dataPlaneFacts,
  firstRunSteps,
  formatAboutOverview,
  pathFlowNodes,
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
const pathNodes = pathFlowNodes();
const overview = computed(() => formatAboutOverview(facts, steps, checks));

const dataplaneLabel = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "sing-box 运行中";
  if (state.runtime.singBoxState === "stopped") return "已停止";
  return "状态未知";
});

const dataplaneTone = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "success" as const;
  if (state.runtime.singBoxState === "stopped") return "warning" as const;
  return "neutral" as const;
});

const pathState = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "active";
  if (state.runtime.singBoxState === "stopped") return "stopped";
  return "unknown";
});

const statusDotTone = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "ok" as const;
  if (state.runtime.singBoxState === "stopped") return "stop" as const;
  return "unknown" as const;
});

async function copyOverview(): Promise<void> {
  copied.value = await copyText(overview.value);
  state.notice = copied.value
    ? "流量路径已复制。"
    : "剪贴板不可用，未能复制流量路径。";
}
</script>

<template>
  <div class="mn-path-page grid gap-4 md:gap-5">
    <PageHeader
      overline="流量路径"
      title="流量路径"
    >
      <template #actions>
        <Button variant="outline" @click="copyOverview">
          <Copy :size="17" aria-hidden="true" />{{ copied ? "已复制说明" : "复制说明" }}
        </Button>
        <Badge :tone="dataplaneTone" class="gap-2">
          <StatusDot :tone="statusDotTone" />
          {{ dataplaneLabel }}
        </Badge>
      </template>
    </PageHeader>

    <div class="grid gap-3 sm:grid-cols-3">
      <StatTile label="数据面" :value="DATAPLANE_LABEL" hint="显式选择，不使用 auto" mono />
      <StatTile label="核心" value="sing-box" hint="不占用系统 VPN slot" />
      <StatTile
        label="验收"
        value="health + dataplane"
        hint="以 cli transparent status 与 cli health 为准"
      />
    </div>

    <Card class="mn-path-board !p-0">
      <div class="mn-path-board__head">
        <CardHeading
          overline="当前路径"
          title="当前流量经过这些环节"
          description="TUN 使用 magicnet0；eBPF 使用 cgroup 和 shared TC。"
        >
          <Radio :size="18" aria-hidden="true" />
        </CardHeading>
      </div>
      <ol class="mn-path-flow" :data-state="pathState" aria-label="MagicNet 透明代理数据面路径">
        <li
          v-for="(node, index) in pathNodes"
          :key="node.code"
          class="mn-path-flow__node"
          :style="{ '--mn-path-delay': `${index * 45}ms` }"
        >
          <span class="mn-path-flow__index" aria-hidden="true">{{ node.index }}</span>
          <div class="mn-path-flow__body">
            <strong>{{ node.label }}</strong>
          </div>
          <ArrowRight
            v-if="index < pathNodes.length - 1"
            class="mn-path-flow__arrow"
            :size="16"
            aria-hidden="true"
          />
        </li>
      </ol>
    </Card>

    <Card class="grid gap-4 !p-4 md:!p-6">
      <CardHeading
        overline="模式"
        title="可用的透明模式"
        description="MagicNet 支持 TUN 和 eBPF；切换失败会恢复原来的配置。"
      />
      <div class="mn-path-facts">
        <article
          v-for="fact in facts"
          :key="fact.code"
          class="mn-path-fact"
        >
          <h3>{{ fact.title }}</h3>
          <p>{{ fact.detail }}</p>
        </article>
      </div>
    </Card>

    <div class="grid gap-4 lg:grid-cols-2">
      <Card class="grid gap-4 !p-4 md:!p-6">
        <CardHeading
          overline="启动"
          title="确认运行正常"
          description="检查服务、透明代理和 DNS。"
        />
        <ol class="mn-path-steps">
          <li
            v-for="(step, index) in steps"
            :key="step.id"
            class="mn-path-step"
          >
            <span class="mn-path-step__index" aria-hidden="true">{{ String(index + 1).padStart(2, "0") }}</span>
            <div class="mn-path-step__body">
              <strong>{{ step.title }}</strong>
              <p>{{ step.detail }}</p>
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
          overline="验收"
          title="验收结果"
          description="以透明模式状态和健康检查结果为准。"
        />
        <ul class="mn-path-checks">
          <li
            v-for="check in checks"
            :key="check.command"
            class="mn-path-check"
          >
            <div class="mn-path-check__title">
              <CheckCircle2 :size="16" aria-hidden="true" />
              <code>{{ check.command }}</code>
              <InsightChip tone="ok" label="required" />
            </div>
            <p>{{ check.expect }}</p>
          </li>
        </ul>
        <Button variant="outline" @click="emit('goto-tab', 'control')">
          返回运行总览
        </Button>
      </Card>
    </div>
  </div>
</template>
