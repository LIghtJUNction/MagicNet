<script setup lang="ts">
import { DownloadCloud, Github, Plus, RefreshCw, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, runCli, startBackgroundCli, refreshBlock, openExternal, shellQuote, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();

async function addDomain(): Promise<void> {
  await withAction("add-domain", async () => {
    const domain = state.blocklist.newDomain.trim();
    if (!/^[A-Za-z0-9*_.-]+\.[A-Za-z0-9*_.-]+$/.test(domain)) {
      state.output = "域名后缀格式不对。示例：malware.example.com";
      return;
    }
    if (state.blocklist.manual.includes(domain)) {
      state.output = `${domain} 已存在，已自动去重。`;
      state.blocklist.newDomain = "";
      return;
    }
    state.blocklist.manual.push(domain);
    state.blocklist.newDomain = "";
    await runCli(`block add-domain ${shellQuote(domain)}`, `添加黑名单 ${domain}`, true);
    await refreshBlock(true);
  });
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

async function allowRule(rule: string): Promise<void> {
  await withAction(`allow-${rule}`, async () => {
    state.blocklist.communityRules = state.blocklist.communityRules.filter((item) => item !== rule);
    if (!state.blocklist.allowRules.includes(rule)) state.blocklist.allowRules.push(rule);
    state.output = `正在加入本地排除：${rule}`;
    const text = await runCli(`block allow-rule ${shellQuote(rule)}`, `本地排除 ${rule}`, true);
    if (text.includes("[error]")) {
      state.output = text;
      state.blocklist.allowRules = state.blocklist.allowRules.filter((item) => item !== rule);
      if (!state.blocklist.communityRules.includes(rule)) state.blocklist.communityRules.unshift(rule);
      return;
    }
    state.output = `已加入本地排除：${rule}`;
  });
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

async function updateCommunityBlocklist(): Promise<void> {
  await startBackgroundCli("block update", "更新社区库");
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Community Banlist" title="联 ban 黑名单" description="本地规则和社区库排除都在这里。X 是排除社区规则，+ 是恢复阻断。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('refresh-block')" @click="withAction('refresh-block', () => refreshBlock())"><RefreshCw :size="17" />读取</Button>
        <Button :loading="isRunning('update-block')" @click="withAction('update-block', updateCommunityBlocklist)"><DownloadCloud :size="17" />更新社区库</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), '黑名单变更 Issue')"><Github :size="17" />创建 Issue</Button>
      </div>
    </PageHeader>

    <Card class="grid gap-3">
      <h3 class="text-base font-semibold">策略</h3>
      <div class="grid gap-2 sm:grid-cols-2">
        <Button :variant="state.blocklist.enabled ? 'default' : 'outline'" :loading="isRunning('toggle-block')" @click="withAction('toggle-block', async () => { await runCli(state.blocklist.enabled ? 'block disable' : 'block enable', '切换黑名单'); await refreshBlock(true); })">
          {{ isRunning('toggle-block') ? '切换中' : state.blocklist.enabled ? "黑名单已启用" : "黑名单已关闭" }}
        </Button>
        <Button :variant="state.blocklist.community ? 'default' : 'outline'" :loading="isRunning('toggle-community')" @click="withAction('toggle-community', async () => { await runCli(state.blocklist.community ? 'block community off' : 'block community on', '切换社区库'); await refreshBlock(true); })">
          {{ isRunning('toggle-community') ? '切换中' : state.blocklist.community ? "社区库已启用" : "社区库已关闭" }}
        </Button>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
        <Input v-model="state.blocklist.newDomain" placeholder="malware.example.com" spellcheck="false" />
        <Button variant="secondary" :loading="isRunning('add-domain')" @click="addDomain"><Plus :size="16" />添加</Button>
      </div>
    </Card>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 text-base font-semibold">阻断</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="domain in state.blocklist.manual" :key="domain" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ domain }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-domain-${domain}`)" type="button" @click="removeDomain(domain)"><X :size="14" /></button>
          </span>
          <em v-if="!state.blocklist.manual.length" class="text-sm not-italic text-zinc-500">暂无域名</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">社区库缓存</h3>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <span v-for="rule in state.blocklist.communityRules.slice(0, 120)" :key="rule" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ rule }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`allow-${rule}`)" type="button" title="排除这条社区规则" @click="allowRule(rule)"><X :size="14" /></button>
          </span>
          <em v-if="!state.blocklist.communityRules.length" class="text-sm not-italic text-zinc-500">未读取到社区规则</em>
        </div>
      </Card>

      <Card>
        <h3 class="mb-2 text-base font-semibold">本地排除</h3>
        <div class="flex max-h-[26rem] flex-wrap gap-2 overflow-auto">
          <span v-for="rule in state.blocklist.allowRules" :key="rule" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ rule }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`unallow-${rule}`)" type="button" title="恢复阻断" @click="unallowRule(rule)"><Plus :size="14" /></button>
          </span>
          <em v-if="!state.blocklist.allowRules.length" class="text-sm not-italic text-zinc-500">暂无排除规则</em>
        </div>
      </Card>
    </div>
  </div>
</template>
