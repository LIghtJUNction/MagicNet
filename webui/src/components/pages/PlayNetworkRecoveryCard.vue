<script setup lang="ts">
import { ref } from "vue";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { decodeMachineData, machineErrorCode } from "@/composables/machineStatus";
import { redactedCliPreview } from "@/utils";
import { availableRecoveryActions, checkedPolicy, parsePlayPolicies, recoveryCommand, type PlayPolicy, type RecoveryAction } from "./playNetworkRecovery";

const { runPrivateCli } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const rows = ref<PlayPolicy[]>([]);
const message = ref("");
const pending = ref<{ row: PlayPolicy; action: RecoveryAction } | null>(null);
const labels: Record<RecoveryAction, string> = { repair: "解除联网限制", reapply: "重新解除限制", rollback: "恢复原限制" };
const policyLabels: Record<string, string> = {
  reject_mobile: "移动网络被禁止", reject_wifi: "Wi-Fi 被禁止", reject_all: "所有网络被禁止",
  reject_metered_background: "计费网络后台访问被禁止", original_policy: "系统仍记录原限制",
  recovered_policy: "系统策略已解除", policy_conflict: "策略已被其他程序修改", unknown: "无法确认当前策略",
};
let supported = false;
async function privateCommand(args: string) {
  return runPrivateCli(args, t("Play 商店联网修复"), redactedCliPreview("network-access [private-output]"));
}
async function inspect(): Promise<void> {
  rows.value = [];
  const capabilities = await privateCommand("--json capabilities");
  const data = capabilities.ok ? decodeMachineData(capabilities.stdout, "machine.capabilities") : null;
  const commands = data?.commands;
  supported = Array.isArray(commands) && ["repair", "check", "reapply", "rollback"].every(action => commands.includes(`network-access.${action}`));
  if (!supported) { message.value = t("请先更新模块，当前版本不支持联网修复。"); return; }
  const outcome = await privateCommand("--json network-access inspect");
  const parsed = outcome.ok ? parsePlayPolicies(outcome.stdout) : null;
  if (!parsed) { message.value = t("无法读取系统联网策略，请稍后重试。"); return; }
  // Query original journals explicitly: configured API readback is separate from app/DNS acceptance.
  for (const row of parsed.rows) if (row.phase !== "new") {
    const check = await privateCommand(recoveryCommand("check", row.candidate));
    row.observed = check.ok ? checkedPolicy(check.stdout, row.candidate) : "unknown";
  }
  rows.value = parsed.rows;
  message.value = parsed.rows.length ? t("选择需要解除的限制；共享身份会影响下面列出的全部应用。")
    : parsed.observed ? t("未发现 Play / GMS 的已知联网限制。")
      : t("当前平台没有已验证的厂商策略接口，无法确认 Play 的联网限制。");
}
async function refresh() {
  if (isRunning("play-recovery")) return;
  pending.value = null;
  await withAction("play-recovery", inspect);
}
async function confirm() {
  const request = pending.value;
  if (!request || !supported || isRunning("play-recovery")) return;
  pending.value = null;
  await withAction("play-recovery", async () => {
    const result = await privateCommand(recoveryCommand(request.action, request.row.candidate));
    const data = result.ok ? decodeMachineData(result.stdout, `network-access.${request.action}`) : null;
    const verified = data?.candidate === request.row.candidate && data.configured_verified === true;
    const code = machineErrorCode(result.stdout);
    await inspect();
    message.value = verified
      ? request.action === "rollback" ? t("已恢复原联网策略。") : t("系统策略已回读确认。现在打开 Play 商店，测试搜索和下载。")
      : t("操作未确认成功，请重新检查。") + (code ? ` (${code})` : "");
  });
}
</script>

<template>
  <Card class="grid gap-3">
    <p class="text-sm text-[var(--mn-ink-muted)]">{{ t("检查 Play 商店和 Google 服务的系统联网限制。") }}</p>
    <Button variant="outline" :loading="isRunning('play-recovery')" @click="refresh">{{ t("检查联网限制") }}</Button>
    <p v-if="message" role="status" class="text-sm leading-6">{{ message }}</p>
    <div v-for="row in rows" :key="row.candidate" class="grid gap-2 rounded-md border p-3">
      <p class="text-sm">{{ t(policyLabels[row.observed] || policyLabels[row.configured] || '无法确认当前策略') }}</p>
      <ul class="break-all text-xs text-[var(--mn-ink-muted)]"><li v-for="name in row.packages" :key="name">{{ name }}</li></ul>
      <div class="flex flex-wrap gap-2">
        <Button v-for="action in availableRecoveryActions(row)" :key="action" size="sm" variant="outline" :disabled="isRunning('play-recovery')" @click="pending = { row, action }">{{ t(labels[action]) }}</Button>
      </div>
    </div>
    <ConfirmPanel v-if="pending" :title="t(labels[pending.action])" :detail="t('会更改下面全部应用的系统联网策略；可恢复原策略。')" :loading="isRunning('play-recovery')" @cancel="pending = null" @confirm="confirm">
      <ul class="mt-2 break-all text-xs"><li v-for="name in pending.row.packages" :key="name">{{ name }}</li></ul>
    </ConfirmPanel>
  </Card>
</template>
