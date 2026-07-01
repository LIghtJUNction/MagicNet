<script setup lang="ts">
import { ref } from "vue";
import { Network, RadioTower } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { runShell, runCli, state, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pcapIfname = ref("any");
const pcapFilter = ref("tcp port 443 or udp port 53");
const pendingAction = ref<PendingToolAction | null>(null);

async function runTcpdumpProbe(): Promise<void> {
  await runShell("timeout 10 tcpdump -i any -nn -c 30 'tcp port 443 or udp port 53 or tcp port 53 or tcp port 853 or udp port 853'", "tcpdump 快速抓包");
}

async function runEcaptureTlsCapture(): Promise<void> {
  await withAction("ecapture-tls-quick", async () => {
    state.output = await runCli("ecapture tls 8 all all", "eCapture TLS 短抓");
  });
}

async function runEcapturePcapCapture(command: string): Promise<void> {
  await withAction("ecapture-pcap-quick", async () => {
    state.output = await runCli(command, "eCapture PCAP 短抓");
  });
}

function tcpdumpProbe(): void {
  requestAction({
    key: "tcpdump-probe",
    title: "执行 tcpdump 探测",
    detail: "会短时间读取设备网络流量元数据，可能影响性能并暴露连接信息。",
    command: "timeout 10 tcpdump -i any -nn -c 30 ...",
    run: runTcpdumpProbe
  });
}

function ecaptureTlsCapture(): void {
  requestAction({
    key: "ecapture-tls-quick",
    title: "执行 eCapture TLS 短抓",
    detail: "会运行 8 秒无证书 TLS 文本抓取，可能输出连接域名、进程或明文片段，仅在排障时使用。",
    command: "ecapture tls 8 all all",
    run: runEcaptureTlsCapture
  });
}

function ecapturePcapCapture(): void {
  const command = buildPcapCommand();
  if (!command) return;
  requestAction({
    key: "ecapture-pcap-quick",
    title: "执行 eCapture PCAP 短抓",
    detail: "会运行 8 秒 PCAP 抓取并写入模块日志目录，适合复查握手与 DNS 流量。",
    command,
    run: () => runEcapturePcapCapture(command)
  });
}

function buildPcapCommand(): string {
  const ifname = pcapIfname.value.trim();
  if (!/^[A-Za-z0-9_.:-]{1,32}$/.test(ifname)) {
    state.output = "PCAP 网卡名只能包含字母、数字、点、下划线、冒号和短横线。";
    return "";
  }
  const tokens = pcapFilter.value.trim().split(/\s+/).filter(Boolean);
  if (tokens.length > 12 || tokens.some((token) => !/^[A-Za-z0-9_.:-]+$/.test(token))) {
    state.output = "PCAP 过滤器只能使用简单 tcp/udp/port/host 这类词元，最多 12 个。";
    return "";
  }
  return ["ecapture", "pcap", "8", shellQuote(ifname), ...tokens.map(shellQuote)].join(" ");
}

function requestAction(action: PendingToolAction): void {
  pendingAction.value = action;
}

function cancelAction(): void {
  pendingAction.value = null;
}

async function confirmAction(): Promise<void> {
  const action = pendingAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingAction.value = null;
  }
}
</script>

<template>
  <Card class="grid gap-3">
    <h3 class="inline-flex items-center gap-2 text-base font-semibold"><RadioTower :size="17" /> 无证书抓包</h3>

    <ToolActionConfirmCard
      v-if="pendingAction"
      :action="pendingAction"
      :loading="isRunning(pendingAction.key)"
      @cancel="cancelAction"
      @confirm="confirmAction"
    />

    <div class="grid gap-2 sm:grid-cols-2">
      <Button :loading="isRunning('ecapture-status')" @click="withAction('ecapture-status', () => runCli('ecapture status', '检查 eCapture'))">
        <RadioTower :size="16" />eCapture 状态
      </Button>
      <Button variant="secondary" :loading="isRunning('ecapture-version')" @click="withAction('ecapture-version', () => runCli('ecapture version', '查看 eCapture 版本'))">
        版本
      </Button>
      <Button variant="secondary" :loading="isRunning('tcpdump-probe')" @click="tcpdumpProbe">
        <Network :size="16" />tcpdump 探测
      </Button>
      <Button variant="outline" :loading="isRunning('ecapture-tls-quick')" @click="ecaptureTlsCapture">
        TLS 8s
      </Button>
      <Button variant="outline" :loading="isRunning('ecapture-help-tls')" @click="withAction('ecapture-help-tls', () => runCli('ecapture help tls', '查看 TLS 抓包帮助'))">
        TLS help
      </Button>
      <Button variant="outline" :loading="isRunning('ecapture-help-pcap')" @click="withAction('ecapture-help-pcap', () => runCli('ecapture help pcap', '查看 PCAP 抓包帮助'))">
        PCAP help
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[6rem_minmax(0,1fr)_auto]">
      <Input v-model="pcapIfname" placeholder="any" spellcheck="false" />
      <Input v-model="pcapFilter" placeholder="tcp port 443 or udp port 53" spellcheck="false" />
      <Button variant="outline" :loading="isRunning('ecapture-pcap-quick')" @click="ecapturePcapCapture">
        PCAP 8s
      </Button>
    </div>
  </Card>
</template>
