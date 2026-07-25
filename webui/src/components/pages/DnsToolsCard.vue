<script setup lang="ts">
import { computed, ref } from "vue";
import { Cloud, Copy, RadioTower, RefreshCw } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import { buildDnsProfilePlan, formatDnsProfilePlanReport, type DnsProfilePlan } from "./dnsProfilePlan";
import { dnsStatusTone, formatDnsTestReport, parseDnsTestSummary } from "./dnsTestSummary";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, runCli, refreshDns, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const testDomain = ref("www.gstatic.com");
const dnsTestOutput = ref("");
const dnsCopied = ref(false);
const testedDomain = ref("");
const runningDomain = ref("");
const pendingDnsAction = ref<PendingToolAction | null>(null);
const pendingDnsPlan = ref<DnsProfilePlan | null>(null);
const pendingDnsProfile = ref("");
const dnsPlanCopied = ref(false);
const quickDomains = ["www.gstatic.com", "cloudflare.com", "dns.google", "www.baidu.com"] as const;
const dnsSummary = computed(() => parseDnsTestSummary(dnsTestOutput.value, testedDomain.value));

async function runSetDnsProfile(profile: string): Promise<void> {
  await withAction(`dns-${profile}`, async () => {
    const text = await runCli(`dns set ${shellQuote(profile)}`, `切换 DNS ${profile}`);
    if (!text.includes("[error]")) await refreshDns(true);
  });
}

async function refreshDnsState(): Promise<void> {
  pendingDnsAction.value = null;
  pendingDnsPlan.value = null;
  pendingDnsProfile.value = "";
  dnsPlanCopied.value = false;
  await refreshDns();
}

function setDnsProfile(profile: string): void {
  pendingDnsProfile.value = profile;
  pendingDnsPlan.value = buildDnsProfilePlan(state.dns.profile, profile);
  dnsPlanCopied.value = false;
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
    runningDomain.value = domain;
    try {
      dnsTestOutput.value = await runCli(`dns test ${shellQuote(domain)}`, `DNS 测试 ${domain}`);
      testedDomain.value = domain;
      dnsCopied.value = false;
      state.output = dnsTestOutput.value;
    } finally {
      runningDomain.value = "";
    }
  });
}

async function testQuickDomain(domain: string): Promise<void> {
  testDomain.value = domain;
  await testDns();
}

async function copyDnsReport(): Promise<void> {
  const report = formatDnsTestReport(dnsSummary.value, state.dns.profile, state.dns.primary, state.dns.secondary, state.dns.transport, dnsTestOutput.value);
  dnsCopied.value = await copyText(report);
  state.output = dnsCopied.value ? "DNS 测试报告已复制。" : "剪贴板不可用，DNS 测试报告未复制。";
}

function cancelDnsAction(): void {
  pendingDnsAction.value = null;
  pendingDnsPlan.value = null;
  pendingDnsProfile.value = "";
  dnsPlanCopied.value = false;
}

async function confirmDnsAction(): Promise<void> {
  const action = pendingDnsAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingDnsAction.value = null;
    pendingDnsPlan.value = null;
    pendingDnsProfile.value = "";
    dnsPlanCopied.value = false;
  }
}

async function copyDnsProfilePlan(): Promise<void> {
  if (!pendingDnsPlan.value) return;
  dnsPlanCopied.value = await copyText(formatDnsProfilePlanReport(pendingDnsPlan.value));
  state.output = dnsPlanCopied.value ? "DNS 切换计划已复制。" : "剪贴板不可用，DNS 切换计划未复制。";
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
    <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">切换 MagicNet 内置 DNS profile；保存后会应用配置并重启当前 sing-box。</p>

    <ToolActionConfirmCard
      v-if="pendingDnsAction"
      :action="pendingDnsAction"
      :loading="isRunning(pendingDnsAction.key)"
      @cancel="cancelDnsAction"
      @confirm="confirmDnsAction"
    />
    <div v-if="pendingDnsPlan" class="grid gap-2 rounded-md mn-panel-warn p-3">
      <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-5">
        <span
          v-for="item in pendingDnsPlan.items"
          :key="item.label"
          class="rounded border px-2 py-1"
          :class="{
            'mn-chip-ok': item.tone === 'success',
            'mn-chip-warn': item.tone === 'warning',
            'border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] text-[var(--mn-danger)]': item.tone === 'danger',
            'mn-chip-neutral': item.tone === 'neutral',
          }"
        >
          {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
        </span>
      </div>
      <p v-if="pendingDnsPlan.warnings.length" class="text-xs leading-5 text-[var(--mn-warning)]/80">
        {{ pendingDnsPlan.warnings.join("；") }}
      </p>
      <Button size="sm" variant="outline" class="w-fit" @click="copyDnsProfilePlan">
        <Copy :size="15" />{{ dnsPlanCopied ? "已复制计划" : "复制切换计划" }}
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <select
        class="h-10 min-w-0 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 text-sm text-[var(--mn-ink)]"
        :value="pendingDnsProfile || state.dns.profile"
        @change="setDnsProfile(($event.target as HTMLSelectElement).value)"
      >
        <option value="default">默认 DNS</option>
        <option value="cloudflare-doh">Cloudflare DoH</option>
        <option value="cloudflare-dot">Cloudflare DoT</option>
        <option value="cloudflare-udp">Cloudflare UDP</option>
      </select>
      <Button variant="secondary" :loading="isRunning('dns-refresh')" @click="withAction('dns-refresh', refreshDnsState)">
        <RefreshCw :size="16" />刷新
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <Input v-model="testDomain" placeholder="www.gstatic.com" spellcheck="false" />
      <Button variant="outline" :loading="isRunning('dns-test')" @click="testDns">
        <RadioTower :size="16" />测试解析
      </Button>
    </div>
    <div class="flex flex-wrap gap-2">
      <Button
        v-for="domain in quickDomains"
        :key="domain"
        size="sm"
        variant="ghost"
        :loading="isRunning('dns-test') && runningDomain === domain"
        :disabled="isRunning('dns-test')"
        @click="testQuickDomain(domain)"
      >
        {{ domain }}
      </Button>
      <Button size="sm" variant="outline" :disabled="!dnsTestOutput" @click="copyDnsReport">
        <Copy :size="15" />{{ dnsCopied ? "已复制报告" : "复制报告" }}
      </Button>
    </div>

    <pre class="max-h-36 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">profile={{ state.dns.profile }}
primary={{ state.dns.primary }}
secondary={{ state.dns.secondary || "-" }}
transport={{ state.dns.transport }}</pre>

    <div v-if="dnsTestOutput" class="grid gap-2">
      <div class="rounded-md border p-3" :class="dnsStatusTone(dnsSummary.status)">
        <p class="text-sm font-semibold">DNS 测试摘要</p>
        <p class="mt-1 text-sm leading-6 opacity-80">{{ dnsSummary.summary }}</p>
      </div>
      <div class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
        <span>{{ dnsSummary.lineCount }} 行输出</span>
        <span>{{ dnsSummary.issueCount }} 条问题线索</span>
        <span>remote_ip={{ dnsSummary.remoteIp || "none" }}</span>
        <span>time={{ dnsSummary.timeTotalMillis ?? "none" }}ms</span>
      </div>
    </div>
    <pre v-if="dnsSummary.issueLines.length" class="max-h-28 overflow-auto rounded-md mn-panel-warn p-3 text-xs leading-5 text-[var(--mn-warning)] whitespace-pre-wrap">{{ dnsSummary.issueLines.join("\n") }}</pre>
    <pre v-if="dnsTestOutput" class="max-h-36 overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ dnsTestOutput }}</pre>
  </Card>
</template>
