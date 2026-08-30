<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { GitBranch, RefreshCw, Save, ShieldCheck, Trash2 } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import CardHeading from "@/components/ui/CardHeading.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import StatTile from "@/components/ui/StatTile.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { sanitizeNodeText } from "@/composables/nodeDelayParsers";
import { execFailed } from "@/utils";
import {
  buildProxyChainPlan,
  createProxyChainStatus,
  mergeProxyChainNodes,
  parseProxyChainStatus,
  parseProxyNodeList,
  type ProxyChainAction,
  type ProxyChainDraft,
  type ProxyChainPlan,
  type ProxyChainStatus,
  validateProxyChainDraft,
} from "./proxyChainPlan";

const { state, runCli, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const status = ref<ProxyChainStatus>(createProxyChainStatus());
const draft = ref<ProxyChainDraft>({
  enabled: false,
  mode: "manual",
  upstream: "",
  exit: "",
});
const nodes = ref<string[]>([]);
const loaded = ref(false);
const nodeLoadFailed = ref(false);
const pendingPlan = ref<ProxyChainPlan | null>(null);
const chainModes = ["manual", "auto"] as const;

const dirty = computed(() => (
  draft.value.enabled !== status.value.enabled
  || draft.value.mode !== status.value.mode
  || draft.value.upstream.trim() !== status.value.upstream.trim()
  || draft.value.exit.trim() !== status.value.exit.trim()
));
const availableNodes = computed(() => mergeProxyChainNodes(
  nodes.value,
  draft.value.upstream,
  draft.value.exit,
));
const validationErrors = computed(() => validateProxyChainDraft(draft.value, nodes.value));
const plan = computed(() => buildProxyChainPlan(status.value, draft.value));
const runtimeActive = computed(() => status.value.runtime.available && status.value.runtime.proxy === "chain");
const statusTone = computed(() => {
  if (!status.value.runtime.available && status.value.enabled) return "warning" as const;
  return status.value.enabled ? "success" as const : "neutral" as const;
});
const modeHint = computed(() => draft.value.mode === "auto"
  ? "自动模式使用 chain-auto URLTest 组选择落地出口；链路仍保持两跳，不会回落到直连。"
  : "手动模式固定使用 chain-exit 当前选择的落地出口；链路失败不会静默回落到直连。"
);

function syncDraft(next: ProxyChainStatus): void {
  draft.value = {
    enabled: next.enabled,
    mode: next.mode,
    upstream: next.upstream,
    exit: next.exit,
  };
}

function parseNodes(text: string): string[] {
  return parseProxyNodeList(text);
}

async function loadData(silent = false): Promise<boolean> {
  const [statusText, nodesText] = await Promise.all([
    runCli("chain status", "读取链式代理配置", silent),
    runCli("node list", "读取可用节点", true),
  ]);
  const statusFailed = execFailed(statusText);
  const nodesFailed = execFailed(nodesText);
  if (statusFailed) {
    state.phase = "error";
    state.notice = "读取链式代理配置失败";
    state.output = statusText;
    loaded.value = false;
    return false;
  }

  const hadDraftChanges = dirty.value;
  const next = parseProxyChainStatus(statusText);
  status.value = next;
  if (!hadDraftChanges) syncDraft(next);
  loaded.value = true;
  nodeLoadFailed.value = nodesFailed;
  if (!nodesFailed) nodes.value = parseNodes(nodesText);
  else if (!silent) state.output = "链式代理状态已读取，但可用节点列表读取失败；请稍后刷新。";
  return true;
}

async function refresh(): Promise<void> {
  await withAction("proxy-chain-refresh", () => loadData());
}

function setMode(mode: ProxyChainDraft["mode"]): void {
  draft.value.mode = mode;
}

function clearRole(role: "upstream" | "exit"): void {
  draft.value[role] = "";
}

function actionCommand(action: ProxyChainAction): string {
  switch (action.kind) {
    case "set-upstream": return `chain set-upstream ${shellQuote(action.value || "")}`;
    case "set-exit": return `chain set-exit ${shellQuote(action.value || "")}`;
    case "clear-upstream": return "chain clear-upstream";
    case "clear-exit": return "chain clear-exit";
    case "mode": return `chain mode ${action.value || "manual"}`;
    case "enable": return "chain enable";
    case "disable": return "chain disable";
  }
}

function actionDetail(action: ProxyChainAction): string {
  if (!action.value) return action.label;
  return `${action.label}：${sanitizeNodeText(action.value)}`;
}

function requestApply(): void {
  if (!loaded.value) {
    state.output = "链式代理状态尚未读取完成。";
    return;
  }
  if (validationErrors.value.length) {
    state.output = validationErrors.value.join("\n");
    return;
  }
  if (!plan.value.changed) {
    state.output = "链式代理配置没有变化。";
    return;
  }
  pendingPlan.value = plan.value;
}

function cancelApply(): void {
  pendingPlan.value = null;
}

async function confirmApply(): Promise<void> {
  const requested = pendingPlan.value;
  if (!requested) return;
  pendingPlan.value = null;
  await withAction("proxy-chain-apply", async () => {
    for (const action of requested.actions) {
      const output = await runCli(actionCommand(action), `链式代理：${action.label}`);
      if (execFailed(output)) {
        state.output = `链式代理配置未完成：${actionDetail(action)}\n${output}`;
        await loadData(true);
        return;
      }
    }
    state.output = "链式代理配置已保存并应用。";
    await loadData(true);
  });
}

onMounted(() => {
  void loadData(true);
});
</script>

<template>
  <div class="grid gap-4 md:gap-5">
    <PageHeader
      overline="Proxy Chain"
      title="链式代理"
      description="配置单进程 sing-box 的两跳链路：先经过中转节点，再到落地节点。"
    >
      <template #actions>
        <Button
          variant="outline"
          :loading="isRunning('proxy-chain-refresh')"
          @click="refresh"
        >
          <RefreshCw :size="16" />刷新状态
        </Button>
        <Badge :tone="statusTone">
          {{ status.enabled ? (runtimeActive ? "运行中" : "已启用") : "已停用" }}
        </Badge>
      </template>
    </PageHeader>

    <Card class="grid gap-4 !p-4 md:!p-6">
      <CardHeading
        overline="当前配置"
        description="页面只保存节点 tag；节点凭据继续由 sing-box 订阅配置管理。链路默认关闭，保存后会重新应用运行配置。"
      >
        <template #title>
          <span class="inline-flex items-center gap-2"><GitBranch :size="23" />两跳链路</span>
        </template>
        <Badge :tone="status.enabled ? 'success' : 'neutral'">策略：{{ status.enabled ? "启用" : "停用" }}</Badge>
        <Badge tone="neutral">{{ status.mode === "auto" ? "自动出口" : "手动出口" }}</Badge>
      </CardHeading>

      <label class="flex cursor-pointer items-start gap-3 rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] p-4">
        <input
          v-model="draft.enabled"
          type="checkbox"
          class="mt-1 size-5 shrink-0 accent-[var(--mn-cactus)]"
          :disabled="!loaded || isRunning('proxy-chain-apply')"
        />
        <span>
          <span class="block text-base font-semibold">启用链式代理</span>
          <span class="mt-1 block text-sm leading-6 text-[var(--mn-ink-muted)]">
            启用后，默认 <code>proxy</code> 出口切换到 <code>chain</code>；停用后恢复普通代理选择器，不会删除节点配置。
          </span>
        </span>
      </label>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatTile label="策略状态" :value="status.enabled ? '已启用' : '已停用'" />
        <StatTile label="运行 API" :value="status.runtime.available ? '可用' : '不可用'" />
        <StatTile label="proxy 当前出口" :value="status.runtime.proxy || '—'" mono />
        <StatTile label="当前链路出口" :value="status.runtime.exit || '—'" mono />
      </div>
    </Card>

    <Card class="grid gap-5 !p-4 md:!p-6">
      <CardHeading
        overline="链路角色"
        title="选择两跳节点"
        description="节点来自当前 sing-box 订阅缓存；订阅更新后请点击刷新重新读取。"
      >
        <Badge :tone="nodeLoadFailed ? 'warning' : 'neutral'">
          {{ nodeLoadFailed ? "节点读取失败" : `${nodes.length} 个可用节点` }}
        </Badge>
      </CardHeading>

      <div class="grid gap-4 lg:grid-cols-2">
        <label class="grid gap-2 text-sm font-medium">
          <span class="flex items-center justify-between gap-2">
            <span>中转节点 <span class="font-normal text-[var(--mn-ink-muted)]">· 第一跳</span></span>
            <button
              v-if="draft.upstream"
              type="button"
              class="inline-flex min-h-8 items-center gap-1 rounded-full px-2 text-xs font-medium text-[var(--mn-ink-muted)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_7%,transparent)] hover:text-[var(--mn-danger)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)]"
              aria-label="清除中转节点"
              @click="clearRole('upstream')"
            ><Trash2 :size="14" />清除</button>
          </span>
          <select
            v-model="draft.upstream"
            class="h-12 min-w-0 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-material-heavy)] px-3 text-sm text-[var(--mn-ink)] shadow-[inset_0_1px_0_var(--mn-material-edge)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)]"
            :disabled="!loaded || isRunning('proxy-chain-apply')"
          >
            <option value="">未选择中转节点</option>
            <option v-for="node in availableNodes" :key="`upstream-${node}`" :value="node">{{ sanitizeNodeText(node) }}</option>
          </select>
          <span class="text-xs leading-5 text-[var(--mn-ink-muted)]">连接先到中转节点，再由它转发到落地节点。</span>
        </label>

        <label class="grid gap-2 text-sm font-medium">
          <span class="flex items-center justify-between gap-2">
            <span>落地节点 <span class="font-normal text-[var(--mn-ink-muted)]">· 第二跳</span></span>
            <button
              v-if="draft.exit"
              type="button"
              class="inline-flex min-h-8 items-center gap-1 rounded-full px-2 text-xs font-medium text-[var(--mn-ink-muted)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_7%,transparent)] hover:text-[var(--mn-danger)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)]"
              aria-label="清除落地节点"
              @click="clearRole('exit')"
            ><Trash2 :size="14" />清除</button>
          </span>
          <select
            v-model="draft.exit"
            class="h-12 min-w-0 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-material-heavy)] px-3 text-sm text-[var(--mn-ink)] shadow-[inset_0_1px_0_var(--mn-material-edge)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)]"
            :disabled="!loaded || isRunning('proxy-chain-apply')"
          >
            <option value="">未选择落地节点</option>
            <option v-for="node in availableNodes" :key="`exit-${node}`" :value="node">{{ sanitizeNodeText(node) }}</option>
          </select>
          <span class="text-xs leading-5 text-[var(--mn-ink-muted)]">最终流量从落地节点访问目标站点。</span>
        </label>
      </div>

      <div class="grid gap-3">
        <div class="text-sm font-medium">落地选择模式</div>
        <div class="grid gap-3 sm:grid-cols-2">
          <button
            v-for="mode in chainModes"
            :key="mode"
            type="button"
            :aria-pressed="draft.mode === mode"
            :disabled="!loaded || isRunning('proxy-chain-apply')"
            :class="[
              'rounded-[2px] border border-transparent px-4 py-3 text-left transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)] disabled:cursor-not-allowed disabled:opacity-60',
              draft.mode === mode ? 'bg-[var(--mn-cactus)] text-[var(--mn-on-accent)]' : 'bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] text-[var(--mn-ink-soft)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_9%,transparent)]',
            ]"
            @click="setMode(mode)"
          >
            <span class="block font-semibold">{{ mode === 'manual' ? '手动模式' : '自动模式' }}</span>
            <span class="mt-1 block text-xs leading-5">{{ mode === 'manual' ? '固定使用 chain-exit 当前选择' : '使用 chain-auto URLTest 选择' }}</span>
          </button>
        </div>
        <p class="rounded-[var(--mn-radius-md)] bg-[var(--mn-ivory)] px-4 py-3 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ modeHint }}</p>
      </div>

      <div v-if="validationErrors.length" class="grid gap-1 rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] px-4 py-3 text-sm text-[var(--mn-warning)]" role="alert">
        <p v-for="error in validationErrors" :key="error">{{ error }}</p>
      </div>
      <div v-else-if="dirty" class="flex items-center gap-2 rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-cactus)_12%,transparent)] px-4 py-3 text-sm text-[var(--mn-success)]">
        <ShieldCheck :size="16" />配置已修改，点击保存后才会写入设备。
      </div>

      <Button
        :disabled="!loaded || !dirty || validationErrors.length > 0"
        :loading="isRunning('proxy-chain-apply')"
        @click="requestApply"
      ><Save :size="17" />保存并应用链式代理</Button>
    </Card>

    <Card class="grid gap-4 !p-4 md:!p-6">
      <CardHeading
        size="md"
        overline="应用预览"
        title="确认配置变更"
        description="每次保存会按顺序执行 CLI 配置操作；如果中途失败，页面会重新读取已落盘状态。"
      />
      <div v-if="pendingPlan" class="grid gap-3 rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-oat)_45%,var(--mn-carrier))] p-4" role="alert">
        <div class="flex items-start gap-3">
          <ShieldCheck class="mt-0.5 shrink-0 text-[var(--mn-warning)]" :size="18" />
          <div class="min-w-0">
            <p class="font-semibold text-[var(--mn-warning)]">{{ pendingPlan.summary }}</p>
            <ol class="mt-2 grid gap-1 text-sm leading-6 text-[var(--mn-ink-soft)]">
              <li v-for="(action, index) in pendingPlan.actions" :key="`${action.kind}-${index}`">{{ index + 1 }}. {{ actionDetail(action) }}</li>
            </ol>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button :loading="isRunning('proxy-chain-apply')" @click="confirmApply">确认保存</Button>
          <Button variant="outline" :disabled="isRunning('proxy-chain-apply')" @click="cancelApply">取消</Button>
        </div>
      </div>
      <p v-else class="rounded-[var(--mn-radius-md)] bg-[var(--mn-ivory)] px-4 py-3 text-sm text-[var(--mn-ink-muted)]">{{ dirty ? "保存按钮会在这里生成操作预览。" : "当前没有待应用的链式代理变更。" }}</p>
    </Card>

    <Card class="grid gap-3 !p-4 md:!p-6">
      <CardHeading size="md" overline="运行观察" title="链路选择器状态" />
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatTile
          v-for="item in [
            ['proxy', status.runtime.proxy],
            ['chain', status.runtime.chain],
            ['chain-hop1', status.runtime.hop1],
            ['chain-exit', status.runtime.exit],
          ]"
          :key="item[0]"
          :label="item[0]"
          :value="item[1] || '—'"
          mono
        />
      </div>
      <p class="text-xs leading-5 text-[var(--mn-ink-muted)]">
        这里显示的是设备当前 sing-box API 选择器状态；策略已启用但 API 不可用时，需要先检查 sing-box 和 <code>magicnet0</code>。
      </p>
    </Card>
  </div>
</template>
