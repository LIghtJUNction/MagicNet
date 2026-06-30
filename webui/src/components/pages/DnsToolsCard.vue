<script setup lang="ts">
import { ref } from "vue";
import { Cloud, RadioTower, RefreshCw } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, refreshDns, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const testDomain = ref("www.gstatic.com");
const dnsTestOutput = ref("");
const pendingDnsAction = ref<PendingToolAction | null>(null);

async function runSetDnsProfile(profile: string): Promise<void> {
  await withAction(`dns-${profile}`, async () => {
    const text = await runCli(`dns set ${shellQuote(profile)}`, `切换 DNS ${profile}`);
    if (!text.includes("[error]")) await refreshDns(true);
  });
}

function setDnsProfile(profile: string): void {
  pendingDnsAction.value = {
    key: `dns-${profile}`,
    title: `切换 DNS 到 ${profile}`,
    detail: "会应用 MagicNet DNS profile，并重启当前 sing-box 配置。",
    command: `dns set ${profile}`,
    run: () => runSetDnsProfile(profile)
  };
}

async function testDns(): Promise<void> {
  const domain = normalizeDomain(testDomain.value);
  if (!domain) {
    state.output = "DNS 测试域名必须是普通域名，例如 www.gstatic.com。";
    return;
  }
  await withAction("dns-test", async () => {
    dnsTestOutput.value = await runCli(`dns test ${shellQuote(domain)}`, `DNS 测试 ${domain}`);
    state.output = dnsTestOutput.value;
  });
}

function cancelDnsAction(): void {
  pendingDnsAction.value = null;
}

async function confirmDnsAction(): Promise<void> {
  const action = pendingDnsAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingDnsAction.value = null;
  }
}

function normalizeDomain(value: string): string {
  const domain = value.trim().replace(/\.$/, "").toLowerCase();
  if (!domain || domain.length > 253 || !domain.includes(".")) return "";
  const valid = domain.split(".").every((label) => (
    label.length > 0 &&
    label.length <= 63 &&
    !label.startsWith("-") &&
    !label.endsWith("-") &&
    /^[a-z0-9-]+$/.test(label)
  ));
  return valid ? domain : "";
}
</script>

<template>
  <Card class="grid gap-3">
    <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Cloud :size="17" /> 1.1.1.1 DNS</h3>
    <p class="text-sm leading-6 text-zinc-400">切换 MagicNet 内置 DNS profile；保存后会应用配置并重启当前 sing-box。</p>

    <ToolActionConfirmCard
      v-if="pendingDnsAction"
      :action="pendingDnsAction"
      :loading="isRunning(pendingDnsAction.key)"
      @cancel="cancelDnsAction"
      @confirm="confirmDnsAction"
    />

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <select
        class="h-10 min-w-0 rounded-md border border-zinc-800 bg-zinc-950 px-3 text-sm text-zinc-100"
        :value="state.dns.profile"
        @change="setDnsProfile(($event.target as HTMLSelectElement).value)"
      >
        <option value="default">默认 DNS</option>
        <option value="cloudflare-doh">Cloudflare DoH</option>
        <option value="cloudflare-dot">Cloudflare DoT</option>
        <option value="cloudflare-udp">Cloudflare UDP</option>
      </select>
      <Button variant="secondary" :loading="isRunning('dns-refresh')" @click="withAction('dns-refresh', () => refreshDns())">
        <RefreshCw :size="16" />刷新
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <Input v-model="testDomain" placeholder="www.gstatic.com" spellcheck="false" />
      <Button variant="outline" :loading="isRunning('dns-test')" @click="testDns">
        <RadioTower :size="16" />测试解析
      </Button>
    </div>

    <pre class="max-h-36 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">profile={{ state.dns.profile }}
primary={{ state.dns.primary }}
secondary={{ state.dns.secondary || "-" }}
transport={{ state.dns.transport }}</pre>

    <pre v-if="dnsTestOutput" class="max-h-36 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ dnsTestOutput }}</pre>
  </Card>
</template>
