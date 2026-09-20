<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Check, Copy, Play, RefreshCw, RotateCcw, Save } from "lucide-vue-next";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfigCodeEditor from "@/components/ConfigCodeEditor.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { decodeMachineData, machineErrorCode } from "@/composables/machineStatus";
import { copyText, shellQuote } from "@/utils";

const { runPrivateCli, stagePrivatePayload, removePrivatePayload, refreshStatus } = useMagicNet();
const text = ref("{}\n");
const savedText = ref("{}\n");
const revision = ref<number | null>(null);
const pending = ref(false);
const busy = ref("");
const message = ref("");
const failed = ref(false);
const syntaxValid = ref(true);
const reloadRequested = ref(false);
const dirty = computed(() => text.value !== savedText.value);
const loaded = computed(() => revision.value !== null);

function fail(code = "override.invalid_response"): never {
  throw new Error(code);
}
async function request(action: string, payload?: Record<string, unknown>) {
  let staged: Awaited<ReturnType<typeof stagePrivatePayload>> = null;
  try {
    let command = `--json override ${action}`;
    if (payload) {
      staged = await stagePrivatePayload("tmp", `override-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.json`, JSON.stringify(payload), t("配置覆写"));
      if (!staged) fail("override.staging_failed");
      command += ` ${shellQuote(staged.path)}`;
    }
    const outcome = await runPrivateCli(command, t("配置覆写"), `--json override ${action} [private-payload]`);
    const result = decodeMachineData(outcome.stdout, `override.${action.replace(/-file$/, "")}`);
    if (!outcome.ok || !result) fail(machineErrorCode(outcome.stdout) || "override.request_failed");
    return result;
  } finally {
    if (staged) await removePrivatePayload("tmp", staged.basename, t("配置覆写"));
  }
}
function acceptStatus(data: Record<string, unknown>): void {
  if (!Number.isSafeInteger(data.configured_revision) || typeof data.pending !== "boolean") fail();
  revision.value = data.configured_revision as number;
  pending.value = data.pending;
}
async function action(name: string, work: () => Promise<void>) {
  if (busy.value) return;
  busy.value = name;
  failed.value = false;
  message.value = "";
  try { await work(); }
  catch (error) {
    failed.value = true;
    const code = error instanceof Error && /^override\.[a-z_]+$/.test(error.message) ? error.message : "override.request_failed";
    message.value = code === "override.conflict" ? t("配置已被其他操作修改。请先复制你的草稿，再重新读取。") : t("操作失败：{value}", { value: code });
  } finally { busy.value = ""; }
}
function requestReload() {
  if (dirty.value) { reloadRequested.value = true; return; }
  void load();
}
async function discardAndReload() {
  reloadRequested.value = false;
  await load();
}
async function copyDraft() {
  const copied = Boolean(navigator.clipboard?.writeText) && await copyText(text.value);
  failed.value = !copied;
  message.value = copied ? t("已复制草稿") : t("复制失败，请手动选择并复制编辑器内容。");
}
async function load() {
  await action("load", async () => {
    const data = await request("inspect");
    if (!data.patch || typeof data.patch !== "object" || Array.isArray(data.patch)) fail();
    acceptStatus(data);
    text.value = `${JSON.stringify(data.patch, null, 2)}\n`;
    savedText.value = text.value;
    message.value = t("已读取覆写配置");
  });
}
function patch(): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(text.value);
    if (!value || typeof value !== "object" || Array.isArray(value)) fail("override.invalid_patch");
    return value as Record<string, unknown>;
  } catch { return fail("override.invalid_json"); }
}
async function preview() {
  await action("preview", async () => {
    const data = await request("preview-file", { patch: patch() });
    if (data.valid !== true || !Number.isSafeInteger(data.changed_section_count)) fail();
    message.value = t("校验通过，影响 {value} 个配置分区。", { value: String(data.changed_section_count) });
  });
}
async function save(applyNow: boolean) {
  await action(applyNow ? "apply" : "save", async () => {
    const submittedText = text.value;
    const data = await request("set-file", { expected_revision: revision.value, patch: patch() });
    acceptStatus(data);
    savedText.value = submittedText;
    message.value = t("覆写已保存，等待应用。");
    if (applyNow) {
      const applied = await request("apply-file", { expected_revision: revision.value });
      if (applied.configured_revision !== revision.value) fail("override.conflict");
      acceptStatus(applied);
      await refreshStatus();
      message.value = applied.service_running === true ? t("覆写已应用") : applied.service_running === false ? t("覆写已生成，服务保持停止状态。") : t("覆写已生成，运行状态待确认。");
    }
  });
}
async function reset() {
  await action("reset", async () => {
    acceptStatus(await request("reset-file", { expected_revision: revision.value }));
    text.value = "{}\n";
    savedText.value = text.value;
    pending.value = true;
    acceptStatus(await request("apply-file", { expected_revision: revision.value }));
    await refreshStatus();
    message.value = t("覆写已重置，订阅和其他设置已保留。");
  });
}
onMounted(load);
</script>

<template>
  <Card class="override-card">
    <header class="override-heading">
      <div><h2>{{ t("配置覆写") }}</h2><p>{{ t("订阅更新后仍保留你的 JSON 修改。") }}</p></div>
      <span v-if="loaded" class="override-state">{{ t(dirty ? "未保存" : pending ? "等待应用" : "已保存") }}</span>
    </header>
    <p class="override-help">{{ t("对象按字段合并，数组整体替换，null 删除字段。透明代理入口、热点策略和本地管理接口由 MagicNet 管理。") }}</p>
    <fieldset :disabled="Boolean(busy)" class="override-editor"><ConfigCodeEditor v-model="text" :label="t('覆写 JSON 编辑器')" min-height="18rem" @syntax-state="syntaxValid = $event.valid && !$event.checking" /></fieldset>
    <div class="override-actions">
      <Button :disabled="Boolean(busy) || !loaded || !syntaxValid" @click="save(true)"><Play :size="16" aria-hidden="true" />{{ t(busy === 'apply' ? "应用中…" : "保存并应用") }}</Button>
      <Button variant="secondary" :disabled="Boolean(busy) || !loaded || !syntaxValid" @click="preview"><Check :size="16" aria-hidden="true" />{{ t("校验预览") }}</Button>
      <Button variant="ghost" :disabled="Boolean(busy) || !loaded || !syntaxValid || !dirty" @click="save(false)"><Save :size="16" aria-hidden="true" />{{ t("仅保存") }}</Button>
    </div>
    <div class="override-secondary">
      <Button variant="ghost" :disabled="Boolean(busy)" @click="copyDraft"><Copy :size="15" aria-hidden="true" />{{ t("复制草稿") }}</Button>
      <Button variant="ghost" :disabled="Boolean(busy)" @click="requestReload"><RefreshCw :size="15" aria-hidden="true" />{{ t("重新读取") }}</Button>
      <Button variant="ghost" :disabled="Boolean(busy) || !loaded" @click="reset"><RotateCcw :size="15" aria-hidden="true" />{{ t("一键重置覆写") }}</Button>
    </div>
    <div v-if="reloadRequested" class="override-reload" role="alert">
      <p>{{ t("重新读取会丢弃未保存的草稿。") }}</p>
      <div class="override-actions">
        <Button variant="secondary" @click="reloadRequested = false">{{ t("保留草稿") }}</Button>
        <Button :disabled="Boolean(busy)" @click="discardAndReload">{{ t("放弃草稿并重新读取") }}</Button>
      </div>
    </div>
    <p v-if="message" :role="failed ? 'alert' : 'status'" class="override-message" :class="{ 'override-error': failed }">{{ message }}</p>
  </Card>
</template>

<style scoped>
.override-editor { min-width: 0; border: 0; padding: 0; margin: 0; }
.override-heading { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; }
.override-heading h2 { font-size: 20px; font-weight: 500; }
.override-heading p, .override-help { color: var(--mn-ink-muted); font-size: 13px; line-height: 1.7; }
.override-heading p { margin-top: 6px; }
.override-state { flex-shrink: 0; font-size: 12px; color: var(--mn-ink-muted); }
.override-help { margin: 16px 0; max-width: 70ch; }
.override-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 20px; }
.override-secondary { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; margin-top: 12px; }
.override-reload { margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--mn-border); font-size: 14px; }
.override-message { margin-top: 12px; color: var(--mn-ink-soft); font-size: 13px; }
.override-error { color: var(--mn-danger); }
</style>
