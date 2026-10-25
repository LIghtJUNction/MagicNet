<script setup lang="ts">
import { t } from "@/i18n";
import { computed, onMounted, ref } from "vue";
import { Network, RefreshCw, Save } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import type { DnsCaptureStatus, NetworkPolicyStatus } from "@/composables/machineStatus";
import { execFailed } from "@/utils";

const { state, runCli, refreshNetwork, refreshNetworkPreflight } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const configured = ref<NetworkPolicyStatus["configured"] | null>(null);
const dnsCapture = ref<DnsCaptureStatus | null>(null);
const readFailed = ref(false);
const ipv6Mode = ref("prefer_ipv4");
const mtu = ref("1400");
const udpTimeout = ref("5m");
const effectiveMode = ref("unavailable");
const effectiveStack = ref("unavailable");
const effectiveMtu = ref("unavailable");
const effectiveUdpTimeout = ref("unavailable");
const configuredDnsPort = ref("1053");
const configuredTunInet = ref("172.19.0.1/30");
const configuredTunInet6 = ref("fdfe:dcba:9876::1/126");
const effectiveDnsPort = ref("unavailable");
const effectiveTunInet = ref("unavailable");
const effectiveTunInet6 = ref("unavailable");
const busy = computed(() => isRunning("network-refresh") || isRunning("network-policy"));
const unavailable = computed(() => !state.hasKsu || !configured.value || readFailed.value);
const dirty = computed(() => configured.value !== null && (
  ipv6Mode.value !== configured.value.ipv6_mode ||
  mtu.value !== String(configured.value.mtu) ||
  udpTimeout.value !== configured.value.udp_timeout
));
const customMtus = computed(() => [...new Set([configured.value?.mtu, Number(mtu.value)])]
  .filter((value): value is number => value !== undefined && ![1280, 1400, 1500].includes(value)));

const modeHint = computed(() => {
  if (ipv6Mode.value === "ipv4_only") return t("兼容模式：屏蔽 IPv6，适合不支持 IPv6 的网络或代理节点。");
  if (ipv6Mode.value === "prefer_ipv6") return t("双栈模式：DNS 优先返回 IPv6；内核必须支持 IPv4 和 IPv6 DNS 捕获。");
  return t("推荐模式：保留完整双栈，DNS 优先返回 IPv4。");
});

const captureHint = computed(() => {
  const capture = dnsCapture.value;
  if (ipv6Mode.value !== "prefer_ipv6" || capture?.kernel_capture_required === false) return "";
  if (!capture) return t("无法确认 DNS 捕获能力，请检查 root 权限和 xtables 后再应用 IPv6 优先。");
  if (capture.blocker === "ipv6_nat_unavailable") return t("内核缺少 IPv6 NAT，无法启用严格 DNS 捕获。请选择 IPv4 优先，或补齐内核能力。");
  if (capture.blocker === "ipv4_nat_unavailable") return t("内核缺少 IPv4 NAT，无法启用严格 DNS 捕获。请选择 IPv4 优先，或补齐内核能力。");
  if (capture.blocker !== "none") return t("无法确认 DNS 捕获能力，请检查 root 权限和 xtables 后再应用 IPv6 优先。");
  return "";
});

async function readStatus(silent: boolean, acceptSaved: boolean): Promise<void> {
  const keepDraft = dirty.value && !acceptSaved;
  const status = await refreshNetwork(silent);
  readFailed.value = !status;
  dnsCapture.value = null;
  if (!status) return;
  configured.value = status.configured;
  if (!keepDraft) {
    ipv6Mode.value = status.configured.ipv6_mode;
    mtu.value = String(status.configured.mtu);
    udpTimeout.value = status.configured.udp_timeout;
  }
  effectiveMode.value = status.effective.ipv6_mode;
  effectiveStack.value = status.effective.stack;
  effectiveMtu.value = status.effective.mtu === null ? "unavailable" : String(status.effective.mtu);
  effectiveUdpTimeout.value = status.effective.udp_timeout;
  configuredDnsPort.value = status.configured.dns_capture_port === undefined
    ? "1053"
    : String(status.configured.dns_capture_port);
  configuredTunInet.value = status.configured.tun_inet ?? "172.19.0.1/30";
  configuredTunInet6.value = status.configured.tun_inet6 ?? "fdfe:dcba:9876::1/126";
  effectiveDnsPort.value = status.effective.dns_capture_port == null
    ? "unavailable"
    : String(status.effective.dns_capture_port);
  effectiveTunInet.value = status.effective.tun_inet ?? "unavailable";
  effectiveTunInet6.value = status.effective.tun_inet6 ?? "unavailable";
  dnsCapture.value = await refreshNetworkPreflight();
}

async function refreshStatus(silent = false, acceptSaved = false): Promise<void> {
  await withAction("network-refresh", () => readStatus(silent, acceptSaved));
}

async function applyPolicy(): Promise<void> {
  if (unavailable.value || busy.value) return;
  await withAction("network-policy", async () => {
    const command = `network set ${ipv6Mode.value} ${mtu.value} ${udpTimeout.value}`;
    const output = await runCli(command, t("应用 UDP / IPv6 策略"));
    if (!execFailed(output)) await refreshStatus(true, true);
  });
}

onMounted(() => void refreshStatus(true));
</script>

<template>
  <Card class="grid gap-3" :aria-busy="busy">
    <div class="flex items-center justify-between gap-3">
      <h3 class="inline-flex items-center gap-2 text-base font-semibold">
        <Network :size="17" /> UDP / IPv6
      </h3>
      <Button size="sm" variant="outline" :disabled="!state.hasKsu || isRunning('network-policy')" :loading="isRunning('network-refresh')" @click="refreshStatus()">
        <RefreshCw :size="15" />{{ t("刷新") }}
      </Button>
    </div>
    <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">
      {{ t("调整 TUN 双栈、MTU 和 UDP 会话保持时间。应用会重建 sing-box 运行配置。") }}
    </p>
    <p v-if="readFailed" role="alert" class="text-sm text-[var(--mn-danger)]">{{ t("读取 UDP / IPv6 策略失败") }}</p>
    <p v-if="dirty" role="status" class="text-xs text-[var(--mn-ink-muted)]">{{ t("有未保存的更改") }}</p>
    <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
      {{ t("IPv6 策略") }}
      <select v-model="ipv6Mode" :disabled="unavailable || busy" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
        <option value="prefer_ipv4">{{ t("双栈 · IPv4 优先（推荐）") }}</option>
        <option value="prefer_ipv6">{{ t("双栈 · IPv6 优先") }}</option>
        <option value="ipv4_only">{{ t("仅 IPv4 · 兼容模式") }}</option>
      </select>
    </label>
    <p class="rounded-md bg-[var(--mn-ivory)] px-3 py-2 text-xs leading-5 text-[var(--mn-ink-muted)]">
      {{ modeHint }}
    </p>
    <p v-if="captureHint" role="alert" class="rounded-md border border-[var(--mn-danger)] px-3 py-2 text-xs leading-5 text-[var(--mn-danger)]">{{ captureHint }}</p>
    <div class="grid gap-3 sm:grid-cols-2">
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
        TUN MTU
        <select v-model="mtu" :disabled="unavailable || busy" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
          <option v-for="customMtu in customMtus" :key="customMtu" :value="String(customMtu)">{{ customMtu }}</option>
          <option value="1280">{{ t("1280 · IPv6 最稳妥") }}</option>
          <option value="1400">{{ t("1400 · 推荐") }}</option>
          <option value="1500">{{ t("1500 · 标准以太网") }}</option>
        </select>
      </label>
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
        {{ t("UDP 会话超时") }}
        <select v-model="udpTimeout" :disabled="unavailable || busy" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
          <option value="1m">{{ t("1 分钟") }}</option>
          <option value="3m">{{ t("3 分钟") }}</option>
          <option value="5m">{{ t("5 分钟 · 推荐") }}</option>
          <option value="10m">{{ t("10 分钟") }}</option>
          <option value="15m">{{ t("15 分钟") }}</option>
          <option value="30m">{{ t("30 分钟") }}</option>
        </select>
      </label>
    </div>
    <Button :disabled="unavailable || busy" :loading="isRunning('network-policy')" @click="applyPolicy">
      <Save :size="16" />{{ t("保存并应用") }}
    </Button>
    <pre class="overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)]">effective_ipv6_mode={{ effectiveMode }}
effective_stack={{ effectiveStack }}
effective_mtu={{ effectiveMtu }}
effective_udp_timeout={{ effectiveUdpTimeout }}
configured_dns_capture_port={{ configuredDnsPort }}
configured_tun_inet={{ configuredTunInet }}
configured_tun_inet6={{ configuredTunInet6 }}
effective_dns_capture_port={{ effectiveDnsPort }}
effective_tun_inet={{ effectiveTunInet }}
effective_tun_inet6={{ effectiveTunInet6 }}</pre>
  </Card>
</template>
