<script setup lang="ts">
import { Copy, DownloadCloud, Github, ListFilter, Plus, RefreshCw } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import Input from "@/components/ui/Input.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import RemovableTag from "@/components/ui/RemovableTag.vue";
import SearchField from "@/components/ui/SearchField.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, redactedCliPreview } from "@/utils";
import { buildBlocklistSummary, filterBlocklistEntries } from "./blocklistInsights";

const { state, runCli, startBackgroundCli, refreshBlock, openExternal, shellQuote, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingBlockAction = ref<PendingBlockAction | null>(null);
const snapshotCopied = ref(false);
const blockQuery = ref("");
const allowRuleInput = ref("");
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
    const previousManual = [...state.blocklist.manual];
    state.blocklist.manual.push(domain);
    state.blocklist.newDomain = "";
    const text = await runCli(
      `block add-domain ${shellQuote(domain)}`,
      `添加黑名单 ${domain}`,
      true,
      redactedCliPreview("block add-domain [domain]"),
    );
    if (execFailed(text)) {
      state.blocklist.manual = previousManual;
      state.output = text;
      return;
    }
    if (!(await refreshBlock(true))) {
      state.blocklist.manual = previousManual;
      return;
    }
    state.output = `已添加黑名单：${domain}`;
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
    const text = await runCli(
      `block remove-domain ${shellQuote(domain)}`,
      `移除阻断 ${domain}`,
      true,
      redactedCliPreview("block remove-domain [domain]"),
    );
    if (execFailed(text)) {
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
    state.output = `正在加入广告放行白名单：${rule}`;
    const text = await runCli(
      `block allow-rule ${shellQuote(rule)}`,
      `广告放行 ${rule}`,
      true,
      redactedCliPreview("block allow-rule [rule]"),
    );
    if (execFailed(text)) {
      state.output = text;
      state.blocklist.allowRules = state.blocklist.allowRules.filter((item) => item !== rule);
      if (suffix !== rule) {
        if (!state.blocklist.communityDomains.includes(suffix)) state.blocklist.communityDomains.unshift(suffix);
      } else if (!state.blocklist.communityRules.includes(rule)) state.blocklist.communityRules.unshift(rule);
      return;
    }
    allowRuleInput.value = "";
    state.output = `已加入广告放行白名单：${rule}`;
  });
}

function normalizeAllowRule(input: string): string | null {
  const raw = input.trim();
  const match = raw.match(/^([^,]+),(.*)$/);
  const kind = (match?.[1] ?? "DOMAIN-SUFFIX").trim().toUpperCase();
  const value = (match?.[2] ?? raw).trim();
  if (!(["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"] as string[]).includes(kind) || !value) {
    state.output = "白名单格式不对。支持 example.com、http(s) URL、DOMAIN,example.com、DOMAIN-SUFFIX,example.com 或 DOMAIN-KEYWORD,example。";
    return null;
  }

  let normalizedValue = value.toLowerCase();
  if (kind === "DOMAIN-KEYWORD") {
    if (/\s/.test(value)) {
      state.output = "白名单格式不对：DOMAIN-KEYWORD 需要非空且不含空格的关键词。";
      return null;
    }
  } else {
    const scheme = value.match(/^([a-z][a-z0-9+.-]*):\/\//i);
    if (scheme && !/^https?$/i.test(scheme[1])) {
      state.output = `白名单格式不对：DOMAIN 和 DOMAIN-SUFFIX 仅支持 http/https URL，不能使用 ${scheme[1]}。`;
      return null;
    }
    if (scheme && !value.slice(scheme[0].length).split(/[/?#]/, 1)[0]) {
      state.output = "白名单格式不对：URL 缺少有效主机名。示例：https://forum.mobilism.org";
      return null;
    }
    try {
      const url = new URL(scheme ? value : `http://${value}`);
      normalizedValue = url.hostname.toLowerCase().replace(/\.+$/, "");
    } catch {
      state.output = "白名单格式不对：DOMAIN 和 DOMAIN-SUFFIX 需要有效域名或 http/https URL。示例：https://forum.mobilism.org";
      return null;
    }
    if (!normalizedValue) {
      state.output = "白名单格式不对：URL 缺少有效主机名。示例：https://forum.mobilism.org";
      return null;
    }
  }

  const rule = `${kind},${normalizedValue}`;
  if (state.blocklist.allowRules.includes(rule)) {
    state.output = `${rule} 已在广告放行白名单中。`;
    return null;
  }
  return rule;
}

function requestAddAllowRule(): void {
  const rule = normalizeAllowRule(allowRuleInput.value);
  if (!rule) return;
  pendingBlockAction.value = {
    key: `allow-${rule}`,
    command: `block allow-rule ${rule}`,
    message: `确认把 ${rule} 加入广告放行白名单？它会优先于所有广告阻断规则，并默认继承主策略；也可在 ad-allow 组手动选择 Direct 或 Proxy。`,
    run: () => allowRule(rule)
  };
}

function requestAllowRule(rule: string): void {
  pendingBlockAction.value = {
    key: `allow-${rule}`,
    command: `block allow-rule ${rule}`,
    message: `确认把社区规则 ${rule} 加入广告放行白名单？流量默认继承主策略，也可在 ad-allow 组手动选择 Direct 或 Proxy。`,
    run: () => allowRule(rule)
  };
}

async function removeAllowRule(rule: string): Promise<void> {
  await withAction(`unallow-${rule}`, async () => {
    state.blocklist.allowRules = state.blocklist.allowRules.filter((item) => item !== rule);
    state.output = `正在从广告放行白名单删除：${rule}`;
    const text = await runCli(
      `block unallow-rule ${shellQuote(rule)}`,
      `从广告放行白名单删除 ${rule}`,
      true,
      redactedCliPreview("block unallow-rule [rule]"),
    );
    if (execFailed(text)) {
      state.output = text;
      if (!state.blocklist.allowRules.includes(rule)) state.blocklist.allowRules.push(rule);
      return;
    }
    if (await refreshBlock(true)) state.output = `已从广告放行白名单删除：${rule}`;
  });
}

function requestRemoveAllowRule(rule: string): void {
  pendingBlockAction.value = {
    key: `unallow-${rule}`,
    command: `block unallow-rule ${rule}`,
    message: `确认从广告放行白名单删除 ${rule}？若规则来自社区库，删除后会回到社区库并恢复阻断；手工添加项则会从白名单消失。`,
    run: () => removeAllowRule(rule)
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
        const text = await runCli(command, "切换黑名单");
        if (execFailed(text)) return;
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
        const text = await runCli(command, "切换社区库");
        if (execFailed(text)) return;
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
    <PageHeader overline="规则" title="拦截规则">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('refresh-block')" @click="withAction('refresh-block', () => refreshBlock())"><RefreshCw :size="17" />读取</Button>
        <Button :loading="isRunning('update-block')" @click="requestUpdateCommunityBlocklist"><DownloadCloud :size="17" />更新社区库</Button>
        <Button variant="outline" :loading="isRunning('copy-blocklist-snapshot')" @click="withAction('copy-blocklist-snapshot', copyBlocklistSnapshot)"><Copy :size="17" />{{ snapshotCopied ? '已复制快照' : '复制快照' }}</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), '黑名单变更 Issue')"><Github :size="17" />创建 Issue</Button>
      </div>
    </PageHeader>

    <ConfirmPanel
      v-if="pendingBlockAction"
      title="确认拦截规则"
      :detail="pendingBlockAction.message"
      :command="pendingBlockAction.command"
      :loading="isRunning(pendingBlockAction.key)"
      confirm-label="应用更改"
      confirm-variant="default"
      @cancel="cancelBlockAction"
      @confirm="confirmBlockAction"
    />

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 class="text-base font-semibold">策略</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ blockSummary.summary }}</p>
        </div>
        <span
          class="rounded px-2 py-1 text-xs font-medium"
          :class="{
            'mn-tone-ok': blockSummary.status === 'active',
            'bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] text-[var(--mn-warning)]': blockSummary.status === 'partial',
            'bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]': blockSummary.status === 'empty',
            'bg-[var(--mn-carrier-deep)] text-[var(--mn-ink-soft)]': blockSummary.status === 'disabled',
          }"
        >
          {{ blockSummary.status === 'active' ? '完整启用' : blockSummary.status === 'partial' ? '部分启用' : blockSummary.status === 'empty' ? '无有效规则' : '已关闭' }}
        </span>
      </div>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
        <InsightChip
          v-for="item in blockSummary.insights"
          :key="item.label"
          :label="item.label"
          :value="item.value"
          :tone="item.tone"
        />
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
      <SearchField v-model="blockQuery" placeholder="过滤本地阻断、社区规则和广告放行白名单" />
    </Card>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 inline-flex items-center gap-2 text-base font-semibold"><ListFilter :size="16" />阻断</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="domain in visibleManualDomains"
            :key="domain"
            :disabled="isRunning(`remove-domain-${domain}`)"
            :remove-label="`移除 ${domain}`"
            @remove="requestRemoveDomain(domain)"
          >{{ domain }}</RemovableTag>
          <em v-if="!visibleManualDomains.length" class="mn-empty">{{ state.blocklist.manual.length ? '没有匹配项' : '暂无域名' }}</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">社区库缓存</h3>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="rule in visibleCommunityEntries.slice(0, 120)"
            :key="rule"
            :disabled="isRunning(`allow-${rule}`)"
            title="排除这条社区规则"
            @remove="requestAllowRule(rule)"
          >{{ rule }}</RemovableTag>
          <em v-if="!visibleCommunityEntries.length" class="mn-empty">{{ communityEntries.length ? '没有匹配项' : '未读取到社区规则' }}</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-1 text-base font-semibold">广告放行白名单</h3>
        <p class="mb-3 text-sm leading-6 text-[var(--mn-ink-muted)]">优先于内置、规则集和社区广告规则；ad-allow 默认继承主策略，也可手动选择 Direct 或 Proxy。</p>
        <div class="mb-3 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <Input v-model="allowRuleInput" placeholder="example.com 或 DOMAIN-SUFFIX,example.com" spellcheck="false" @keyup.enter="requestAddAllowRule" />
          <Button variant="secondary" :loading="isRunning(`allow-${allowRuleInput.trim()}`)" @click="requestAddAllowRule"><Plus :size="16" />加入白名单</Button>
        </div>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="rule in visibleAllowRules"
            :key="rule"
            remove-variant="danger"
            :disabled="isRunning(`unallow-${rule}`)"
            :title="`从广告放行白名单删除 ${rule}`"
            :remove-label="`从广告放行白名单删除 ${rule}`"
            @remove="requestRemoveAllowRule(rule)"
          >{{ rule }}</RemovableTag>
          <em v-if="!visibleAllowRules.length" class="mn-empty">{{ state.blocklist.allowRules.length ? '没有匹配项' : '暂无白名单规则' }}</em>
        </div>
      </Card>
    </div>
  </div>
</template>
