<script setup lang="ts">
import { Copy, DownloadCloud, Github, ListFilter, Plus, RefreshCw, Search, X } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import { buildBlocklistSummary, filterBlocklistEntries } from "./blocklistInsights";

const { state, runCli, startBackgroundCli, refreshBlock, openExternal, shellQuote, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingBlockAction = ref<PendingBlockAction | null>(null);
const snapshotCopied = ref(false);
const blockQuery = ref("");
const COMMUNITY_SNAPSHOT_LIMIT = 40;

type PendingBlockAction = {
  key: string;
  command: string;
  message: string;
  run: () => Promise<void>;
};

const blockSummary = computed(() => buildBlocklistSummary(state.blocklist));
const communityEntries = computed(() => blockSummary.value.communityEntries);
const visibleManualDomains = computed(() => filterBlocklistEntries(state.blocklist.manual, blockQuery.value));
const visibleCommunityEntries = computed(() => filterBlocklistEntries(communityEntries.value, blockQuery.value));
const visibleAllowRules = computed(() => filterBlocklistEntries(state.blocklist.allowRules, blockQuery.value));

function validateBlockDomain(domain: string): boolean {
  if (!/^[A-Za-z0-9*_.-]+\.[A-Za-z0-9*_.-]+$/.test(domain)) {
    state.output = "域名后缀格式不对。示例：malware.example.com";
    return false;
  }
  if (state.blocklist.manual.includes(domain)) {
    state.output = `${domain} 已存在，已自动去重。`;
    state.blocklist.newDomain = "";
    return false;
  }
  return true;
}

async function addDomain(domain: string): Promise<void> {
  await withAction(`add-domain-${domain}`, async () => {
    state.blocklist.manual.push(domain);
    state.blocklist.newDomain = "";
    await runCli(`block add-domain ${shellQuote(domain)}`, `添加黑名单 ${domain}`, true);
    await refreshBlock(true);
  });
}

function requestAddDomain(): void {
  const domain = state.blocklist.newDomain.trim();
  if (!validateBlockDomain(domain)) return;
  pendingBlockAction.value = {
    key: `add-domain-${domain}`,
    command: `block add-domain ${domain}`,
    message: `确认添加本地阻断域名 ${domain}？匹配流量会被黑名单规则阻断。`,
    run: () => addDomain(domain)
  };
}

async function removeDomain(domain: string): Promise<void> {
  await withAction(`remove-domain-${domain}`, async () => {
    state.blocklist.manual = state.blocklist.manual.filter((item) => item !== domain);
    state.output = `正在移除阻断：${domain}`;
    const text = await runCli(`block remove-domain ${shellQuote(domain)}`, `移除阻断 ${domain}`, true);
    if (text.includes("[error]")) {
      state.output = text;
      state.blocklist.manual.unshift(domain);
      return;
    }
    state.output = `已移除阻断：${domain}`;
  });
}

function requestRemoveDomain(domain: string): void {
  pendingBlockAction.value = {
    key: `remove-domain-${domain}`,
    command: `block remove-domain ${domain}`,
    message: `确认移除本地阻断域名 ${domain}？`,
    run: () => removeDomain(domain)
  };
}

async function allowRule(rule: string): Promise<void> {
  await withAction(`allow-${rule}`, async () => {
    state.blocklist.communityRules = state.blocklist.communityRules.filter((item) => item !== rule);
    const suffix = rule.replace(/^DOMAIN-SUFFIX,/, "");
    if (suffix !== rule) state.blocklist.communityDomains = state.blocklist.communityDomains.filter((item) => item !== suffix);
    if (!state.blocklist.allowRules.includes(rule)) state.blocklist.allowRules.push(rule);
    state.output = `正在加入本地排除：${rule}`;
    const text = await runCli(`block allow-rule ${shellQuote(rule)}`, `本地排除 ${rule}`, true);
    if (text.includes("[error]")) {
      state.output = text;
      state.blocklist.allowRules = state.blocklist.allowRules.filter((item) => item !== rule);
      if (suffix !== rule) {
        if (!state.blocklist.communityDomains.includes(suffix)) state.blocklist.communityDomains.unshift(suffix);
      } else if (!state.blocklist.communityRules.includes(rule)) state.blocklist.communityRules.unshift(rule);
      return;
    }
    state.output = `已加入本地排除：${rule}`;
  });
}

function requestAllowRule(rule: string): void {
  pendingBlockAction.value = {
    key: `allow-${rule}`,
    command: `block allow-rule ${rule}`,
    message: `确认把社区规则 ${rule} 加入本地排除？`,
    run: () => allowRule(rule)
  };
}

async function unallowRule(rule: string): Promise<void> {
  await withAction(`unallow-${rule}`, async () => {
    state.blocklist.allowRules = state.blocklist.allowRules.filter((item) => item !== rule);
    if (!state.blocklist.communityRules.includes(rule)) state.blocklist.communityRules.unshift(rule);
    state.output = `正在恢复阻断：${rule}`;
    const text = await runCli(`block unallow-rule ${shellQuote(rule)}`, `恢复阻断 ${rule}`, true);
    if (text.includes("[error]")) {
      state.output = text;
      state.blocklist.communityRules = state.blocklist.communityRules.filter((item) => item !== rule);
      if (!state.blocklist.allowRules.includes(rule)) state.blocklist.allowRules.push(rule);
      return;
    }
    state.output = `已恢复阻断：${rule}`;
  });
}

function requestUnallowRule(rule: string): void {
  pendingBlockAction.value = {
    key: `unallow-${rule}`,
    command: `block unallow-rule ${rule}`,
    message: `确认恢复阻断 ${rule}？`,
    run: () => unallowRule(rule)
  };
}

function issueUrl(): string {
  const body = [
    "## MagicNet blocklist diff",
    "",
    "### Manual",
    ...state.blocklist.manual.map((item) => `- ${item}`),
    "",
    "### Local allow",
    ...state.blocklist.allowRules.map((item) => `- ${item}`)
  ].join("\n");
  return `${REPO}/issues/new?${new URLSearchParams({ title: "MagicNet 黑名单变更建议", body }).toString()}`;
}

async function copyBlocklistSnapshot(): Promise<void> {
  const report = [
    "MagicNet blocklist snapshot",
    `enabled=${state.blocklist.enabled ? 1 : 0}`,
    `community=${state.blocklist.community ? 1 : 0}`,
    `manual_count=${state.blocklist.manual.length}`,
    `allow_count=${state.blocklist.allowRules.length}`,
    `community_cache_raw_count=${state.blocklist.communityRules.length}`,
    `community_cache_effective_count=${communityEntries.value.length}`,
    `community_sample_count=${Math.min(COMMUNITY_SNAPSHOT_LIMIT, communityEntries.value.length)}`,
    "",
    "[manual]",
    ...state.blocklist.manual,
    "",
    "[allow]",
    ...state.blocklist.allowRules,
    "",
    "[community_sample]",
    ...communityEntries.value.slice(0, COMMUNITY_SNAPSHOT_LIMIT)
  ].join("\n").trim();
  snapshotCopied.value = await copyText(report);
  state.output = snapshotCopied.value ? "黑名单快照已复制。" : "剪贴板不可用，黑名单快照未复制。";
}

async function updateCommunityBlocklist(): Promise<void> {
  await startBackgroundCli("block update", "更新社区库");
}

function requestUpdateCommunityBlocklist(): void {
  pendingBlockAction.value = {
    key: "update-block",
    command: "block update",
    message: "确认更新社区黑名单？更新会改写社区规则缓存。",
    run: updateCommunityBlocklist
  };
}

function requestToggleBlocklist(): void {
  const command = state.blocklist.enabled ? "block disable" : "block enable";
  pendingBlockAction.value = {
    key: "toggle-block",
    command,
    message: state.blocklist.enabled ? "确认关闭黑名单？阻断规则将不再生效。" : "确认启用黑名单？阻断规则会立即生效。",
    run: async () => {
      await withAction("toggle-block", async () => {
        await runCli(command, "切换黑名单");
        await refreshBlock(true);
      });
    }
  };
}

function requestToggleCommunity(): void {
  const command = state.blocklist.community ? "block community off" : "block community on";
  pendingBlockAction.value = {
    key: "toggle-community",
    command,
    message: state.blocklist.community ? "确认关闭社区库？社区阻断规则将不再生效。" : "确认启用社区库？社区阻断规则会立即生效。",
    run: async () => {
      await withAction("toggle-community", async () => {
        await runCli(command, "切换社区库");
        await refreshBlock(true);
      });
    }
  };
}

function cancelBlockAction(): void {
  pendingBlockAction.value = null;
}

async function confirmBlockAction(): Promise<void> {
  const action = pendingBlockAction.value;
  if (!action) return;
  pendingBlockAction.value = null;
  await action.run();
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Community Banlist" title="联 ban 黑名单" description="本地规则和社区库排除都在这里。X 是排除社区规则，+ 是恢复阻断。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('refresh-block')" @click="withAction('refresh-block', () => refreshBlock())"><RefreshCw :size="17" />读取</Button>
        <Button :loading="isRunning('update-block')" @click="requestUpdateCommunityBlocklist"><DownloadCloud :size="17" />更新社区库</Button>
        <Button variant="outline" :loading="isRunning('copy-blocklist-snapshot')" @click="withAction('copy-blocklist-snapshot', copyBlocklistSnapshot)"><Copy :size="17" />{{ snapshotCopied ? '已复制快照' : '复制快照' }}</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), '黑名单变更 Issue')"><Github :size="17" />创建 Issue</Button>
      </div>
    </PageHeader>

    <Card v-if="pendingBlockAction" class="grid gap-3 border border-amber-500/40 bg-amber-500/10">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <span class="text-[11px] font-bold uppercase tracking-wide text-amber-300">Confirm blocklist</span>
          <p class="mt-1 text-sm leading-6 text-amber-100">{{ pendingBlockAction.message }}</p>
          <code class="mt-2 block break-all rounded-md bg-zinc-950/60 px-3 py-2 text-xs text-zinc-100">{{ pendingBlockAction.command }}</code>
        </div>
        <div class="flex shrink-0 gap-2">
          <Button variant="secondary" :loading="isRunning(pendingBlockAction.key)" @click="confirmBlockAction">确认</Button>
          <Button variant="outline" @click="cancelBlockAction">取消</Button>
        </div>
      </div>
    </Card>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 class="text-base font-semibold">策略</h3>
          <p class="mt-1 text-sm leading-6 text-zinc-500">{{ blockSummary.summary }}</p>
        </div>
        <span
          class="rounded px-2 py-1 text-xs font-medium"
          :class="{
            'bg-emerald-500/15 text-emerald-200': blockSummary.status === 'active',
            'bg-amber-500/15 text-amber-200': blockSummary.status === 'partial',
            'bg-red-500/15 text-red-200': blockSummary.status === 'empty',
            'bg-zinc-800 text-zinc-300': blockSummary.status === 'disabled',
          }"
        >
          {{ blockSummary.status === 'active' ? '完整启用' : blockSummary.status === 'partial' ? '部分启用' : blockSummary.status === 'empty' ? '无有效规则' : '已关闭' }}
        </span>
      </div>
      <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-5">
        <span
          v-for="item in blockSummary.insights"
          :key="item.label"
          class="rounded border px-2 py-1"
          :class="{
            'border-emerald-500/30 text-emerald-200': item.tone === 'success',
            'border-amber-500/30 text-amber-200': item.tone === 'warning',
            'border-red-500/30 text-red-200': item.tone === 'danger',
            'border-zinc-800 text-zinc-400': item.tone === 'neutral',
          }"
        >
          {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
        </span>
      </div>
      <div class="grid gap-2 sm:grid-cols-2">
        <Button :variant="state.blocklist.enabled ? 'default' : 'outline'" :loading="isRunning('toggle-block')" @click="requestToggleBlocklist">
          {{ isRunning('toggle-block') ? '切换中' : state.blocklist.enabled ? "黑名单已启用" : "黑名单已关闭" }}
        </Button>
        <Button :variant="state.blocklist.community ? 'default' : 'outline'" :loading="isRunning('toggle-community')" @click="requestToggleCommunity">
          {{ isRunning('toggle-community') ? '切换中' : state.blocklist.community ? "社区库已启用" : "社区库已关闭" }}
        </Button>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
        <Input v-model="state.blocklist.newDomain" placeholder="malware.example.com" spellcheck="false" />
        <Button variant="secondary" :loading="isRunning(`add-domain-${state.blocklist.newDomain.trim()}`)" @click="requestAddDomain"><Plus :size="16" />添加</Button>
      </div>
      <div class="relative">
        <Search class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-600" :size="16" />
        <Input v-model="blockQuery" class="pl-9" placeholder="过滤本地阻断、社区规则和排除规则" spellcheck="false" />
      </div>
    </Card>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><ListFilter :size="16" />阻断</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="domain in visibleManualDomains" :key="domain" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ domain }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-domain-${domain}`)" type="button" @click="requestRemoveDomain(domain)"><X :size="14" /></button>
          </span>
          <em v-if="!visibleManualDomains.length" class="text-sm not-italic text-zinc-500">{{ state.blocklist.manual.length ? '没有匹配项' : '暂无域名' }}</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">社区库缓存</h3>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <span v-for="rule in visibleCommunityEntries.slice(0, 120)" :key="rule" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ rule }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`allow-${rule}`)" type="button" title="排除这条社区规则" @click="requestAllowRule(rule)"><X :size="14" /></button>
          </span>
          <em v-if="!visibleCommunityEntries.length" class="text-sm not-italic text-zinc-500">{{ communityEntries.length ? '没有匹配项' : '未读取到社区规则' }}</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">本地排除</h3>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <span v-for="rule in visibleAllowRules" :key="rule" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ rule }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`unallow-${rule}`)" type="button" title="恢复阻断" @click="requestUnallowRule(rule)"><Plus :size="14" /></button>
          </span>
          <em v-if="!visibleAllowRules.length" class="text-sm not-italic text-zinc-500">{{ state.blocklist.allowRules.length ? '没有匹配项' : '暂无排除规则' }}</em>
        </div>
      </Card>
    </div>
  </div>
</template>
