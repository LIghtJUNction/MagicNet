<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Network, RefreshCw, Save } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { execFailed } from "@/utils";

const { state, runCli } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const ipv6Mode = ref("prefer_ipv4");
const mtu = ref("1400");
const udpTimeout = ref("5m");
const effectiveMode = ref("unavailable");
const effectiveStack = ref("unavailable");
const effectiveMtu = ref("unavailable");
const effectiveUdpTimeout = ref("unavailable");

const modeHint = computed(() => {
  if (ipv6Mode.value === "ipv4_only") return "兼容模式：屏蔽 IPv6，适合不支持 IPv6 的网络或代理节点。";
  if (ipv6Mode.value === "prefer_ipv6") return "双栈模式：DNS 优先返回 IPv6，IPv4 仍可回退。";
  return "推荐模式：保留完整双栈，DNS 优先返回 IPv4。";
});

function parseStatus(text: string): void {
  const values = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const separator = line.indexOf("=");
    if (separator > 0) values.set(line.slice(0, separator), line.slice(separator + 1));
  }
  ipv6Mode.value = values.get("ipv6_mode") || "prefer_ipv4";
  mtu.value = values.get("mtu") || "1400";
  udpTimeout.value = values.get("udp_timeout") || "5m";
  effectiveMode.value = values.get("effective_ipv6_mode") || "unavailable";
  effectiveStack.value = values.get("effective_stack") || "unavailable";
  effectiveMtu.value = values.get("effective_mtu") || "unavailable";
  effectiveUdpTimeout.value = values.get("effective_udp_timeout") || "unavailable";
}

async function refreshStatus(silent = false): Promise<void> {
  const output = await runCli("network status", "读取 UDP / IPv6 策略", silent);
  if (execFailed(output)) {
    state.phase = "error";
    state.notice = "读取 UDP / IPv6 策略失败";
    state.output = output;
    return;
  }
  parseStatus(output);
}

async function applyPolicy(): Promise<void> {
  await withAction("network-policy", async () => {
    const command = `network set ${ipv6Mode.value} ${mtu.value} ${udpTimeout.value}`;
    const output = await runCli(command, "应用 UDP / IPv6 策略");
    state.output = output;
    if (!execFailed(output)) await refreshStatus(true);
  });
}

onMounted(() => void refreshStatus(true));
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex items-center justify-between gap-3">
      <h3 class="inline-flex items-center gap-2 text-base font-semibold">
        <Network :size="17" /> UDP / IPv6
      </h3>
      <Button size="sm" variant="outline" :loading="isRunning('network-refresh')" @click="withAction('network-refresh', () => refreshStatus())">
        <RefreshCw :size="15" />刷新
      </Button>
    </div>
    <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">
      调整 TUN 双栈、MTU 和 UDP 会话保持时间。应用会重建 sing-box 运行配置。
    </p>
    <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
      IPv6 策略
      <select v-model="ipv6Mode" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
        <option value="prefer_ipv4">双栈 · IPv4 优先（推荐）</option>
        <option value="prefer_ipv6">双栈 · IPv6 优先</option>
        <option value="ipv4_only">仅 IPv4 · 兼容模式</option>
      </select>
    </label>
    <p class="rounded-md bg-[var(--mn-ivory)] px-3 py-2 text-xs leading-5 text-[var(--mn-ink-muted)]">
      {{ modeHint }}
    </p>
    <div class="grid gap-3 sm:grid-cols-2">
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
        TUN MTU
        <select v-model="mtu" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
          <option value="1280">1280 · IPv6 最稳妥</option>
          <option value="1400">1400 · 推荐</option>
          <option value="1500">1500 · 标准以太网</option>
        </select>
      </label>
      <label class="grid gap-1 text-xs text-[var(--mn-ink-muted)]">
        UDP 会话超时
        <select v-model="udpTimeout" class="h-10 rounded-md border bg-transparent px-3 text-sm text-[var(--mn-ink)]">
          <option value="1m">1 分钟</option>
          <option value="3m">3 分钟</option>
          <option value="5m">5 分钟 · 推荐</option>
          <option value="10m">10 分钟</option>
          <option value="15m">15 分钟</option>
          <option value="30m">30 分钟</option>
        </select>
      </label>
    </div>
    <Button :loading="isRunning('network-policy')" @click="applyPolicy">
      <Save :size="16" />保存并应用
    </Button>
    <pre class="overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)]">effective_ipv6_mode={{ effectiveMode }}
effective_stack={{ effectiveStack }}
effective_mtu={{ effectiveMtu }}
effective_udp_timeout={{ effectiveUdpTimeout }}</pre>
  </Card>
</template>
