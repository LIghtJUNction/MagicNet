<script setup lang="ts">
import { computed, onActivated, onDeactivated, onMounted, onBeforeUnmount, reactive, ref } from "vue";
import { Download, RefreshCw } from "lucide-vue-next";
import { locale, t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { configureUpdateCommand, parseUpdateStatus, updateBytes, type UpdateStatus, type UpdateSettings } from "./updateState";

const { runCli, startBackgroundCli, state } = useMagicNet();
const snapshot = ref<UpdateStatus | null>(null);
const draft = reactive<UpdateSettings>({ enabled: false, interval_hours: 24, wifi_only: true });
const error = ref("");
const saving = ref(false);
const launching = ref(false);
let poller: ReturnType<typeof setInterval> | null = null;
let reading = false;
let visible = false;
let generation = 0;
const dirty = computed(() => Boolean(snapshot.value) && JSON.stringify(draft) !== JSON.stringify(snapshot.value?.settings));
const busy = computed(() => launching.value || snapshot.value?.running || state.backgroundTask.status === "running");
const pending = computed(() => Boolean(snapshot.value?.pending_version));
const phase = computed(() => {
  const labels: Record<string, string> = {
    idle: t("尚未检查"), checking: t("正在检查更新"), available: t("有可用更新"), current: t("已是最新版本"),
    preparing: t("正在准备组件"), installing: t("正在安装更新"), ready: t("组件已准备好"),
    pending_reboot: t("重启后生效"), waiting_wifi: t("等待 Wi-Fi"), interrupted: t("更新已中断，可重试"), error: t("更新失败"),
  };
  return labels[snapshot.value?.phase ?? "idle"];
});
function sourceLabel(source: string): string {
  return source === "installed" ? t("复用已安装") : source === "cache" ? t("复用缓存") : t("需要下载");
}
function timeLabel(epoch?: number): string {
  if (!epoch) return t("未安排");
  return new Intl.DateTimeFormat(locale.value, { dateStyle: "short", timeStyle: "short" }).format(new Date(epoch * 1000));
}
async function refresh(): Promise<void> {
  if (reading || !visible) return;
  reading = true;
  const request = generation;
  const editedBeforeRead = dirty.value;
  try {
    const output = await runCli("update status", t("读取更新状态"), true);
    if (!visible || request !== generation) return;
    const next = parseUpdateStatus(output);
    if (!next) { error.value = t("无法读取更新状态，请确认已安装支持自动更新的模块。"); return; }
    // Polling must not overwrite unsaved form edits, including edits made while
    // the status request was in flight.
    const preserveDraft = editedBeforeRead || dirty.value || saving.value;
    snapshot.value = next;
    if (!preserveDraft) Object.assign(draft, next.settings);
    error.value = "";
  } catch {
    if (visible && request === generation) error.value = t("无法读取更新状态，请确认已安装支持自动更新的模块。");
  } finally { reading = false; }
}
async function save(): Promise<void> {
  if (saving.value || !snapshot.value) return;
  let command: string;
  const submitted = { ...draft };
  try { command = configureUpdateCommand(submitted); } catch { error.value = t("检查间隔必须为 1 至 168 小时。"); return; }
  saving.value = true;
  generation++; // Discard status reads started before this settings change.
  try {
    const result = await runCli(command, t("保存更新设置"), true);
    if (/\[error\]|\[exec-timeout\]/i.test(result)) { error.value = t("更新设置未保存，请重试。"); return; }
    // Require a read-back receipt; an empty command response is not proof.
    const receipt = parseUpdateStatus(await runCli("update status", t("读取更新状态"), true));
    if (!receipt || JSON.stringify(receipt.settings) !== JSON.stringify(submitted)) { error.value = t("更新设置未保存，请重试。"); return; }
    snapshot.value = receipt;
    error.value = "";
  } catch { error.value = t("更新设置未保存，请重试。"); }
  finally { saving.value = false; }
}
async function launch(action: "check" | "apply"): Promise<void> {
  if (busy.value || pending.value || !snapshot.value) return;
  launching.value = true;
  try {
    const result = await startBackgroundCli(`update ${action}`, action === "check" ? t("检查更新") : t("下载并安装更新"));
    if (/\[error\]/i.test(result)) error.value = t("更新任务未启动，请重试。");
    await refresh();
  } catch { error.value = t("更新任务未启动，请重试。"); }
  finally { launching.value = false; }
}
function start(): void {
  if (visible) return;
  visible = true;
  void refresh();
  poller = setInterval(() => { if (document.visibilityState !== "hidden") void refresh(); }, 3000);
}
function stop(): void { visible = false; generation++; if (poller) clearInterval(poller); poller = null; }
onMounted(start);
onActivated(start);
onDeactivated(stop);
onBeforeUnmount(stop);
</script>

<template>
  <div class="updates-page space-y-5">
    <PageHeader :title="t('组件更新')" :description="t('只下载变化的组件，保留订阅和配置。')">
      <template #actions>
        <Button variant="outline" :disabled="!snapshot || busy || pending" @click="launch('check')"><RefreshCw :size="16" aria-hidden="true" />{{ t('检查更新') }}</Button>
      </template>
    </PageHeader>
    <p v-if="error" role="alert" class="text-sm text-[var(--mn-danger)]">{{ error }}</p>
    <Card class="space-y-4 p-5">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="min-w-0"><p class="text-sm text-[var(--mn-ink-muted)]">{{ snapshot?.current_version || '—' }}</p><h2 role="status" aria-live="polite" class="text-lg font-medium">{{ phase }}</h2></div>
        <Button v-if="snapshot?.plan && !pending" :disabled="busy || snapshot.phase === 'current'" @click="launch('apply')"><Download :size="16" aria-hidden="true" />{{ t('下载并安装更新') }}</Button>
      </div>
      <p v-if="pending" class="text-sm text-[var(--mn-ink-muted)]">{{ t('已暂存 {version}，不会自动重启手机。', {version:snapshot?.pending_version}) }}</p>
      <p v-if="snapshot?.error" role="alert" class="break-words text-sm text-[var(--mn-danger)]">{{ snapshot.error }}</p>
      <dl class="update-metrics">
        <div><dt>{{ t('上次检查') }}</dt><dd>{{ timeLabel(snapshot?.last_check) }}</dd></div>
        <div><dt>{{ t('下次检查') }}</dt><dd>{{ timeLabel(snapshot?.next_check) }}</dd></div>
        <div><dt>{{ t('本次已传输') }}</dt><dd>{{ updateBytes(snapshot?.transferred_bytes ?? 0) }}</dd></div>
      </dl>
    </Card>
    <Card class="p-5">
      <form class="space-y-4" @submit.prevent="save">
        <label class="update-switch"><span>{{ t('定时自动更新') }}</span><input v-model="draft.enabled" type="checkbox" :disabled="!snapshot" /></label>
        <label class="update-switch"><span>{{ t('仅 Wi-Fi 更新') }}</span><input v-model="draft.wifi_only" type="checkbox" :disabled="!snapshot" /></label>
        <label class="flex flex-wrap items-center justify-between gap-3"><span class="text-sm">{{ t('检查间隔（小时）') }}</span><input v-model.number="draft.interval_hours" type="number" min="1" max="168" step="1" :disabled="!snapshot" class="update-interval" /></label>
        <p class="text-xs leading-relaxed text-[var(--mn-ink-muted)]">{{ t('更新按兼容发行版成套暂存，下次重启生效。关闭页面不影响定时任务。') }}</p>
        <Button type="submit" :loading="saving" :disabled="!snapshot || !dirty">{{ t('保存更新设置') }}</Button>
      </form>
    </Card>
    <Card v-if="snapshot?.plan" class="space-y-4 p-5">
      <div class="flex flex-wrap items-baseline justify-between gap-2"><h2 class="font-medium">{{ snapshot.plan.version }}</h2><span class="text-xs text-[var(--mn-ink-muted)]">{{ t('待下载 {download} · 可复用 {reuse}', {download:updateBytes(snapshot.plan.download_bytes),reuse:updateBytes(snapshot.plan.reuse_bytes)}) }}</span></div>
      <ul class="divide-y divide-[var(--mn-border)]">
        <li v-for="component in snapshot.plan.components" :key="component.id" class="flex flex-wrap items-center justify-between gap-3 py-3">
          <div class="min-w-0"><p class="break-all text-sm font-medium">{{ component.id.replace(/^bin-/, '') }}</p><p class="text-xs text-[var(--mn-ink-muted)]">{{ component.sha256.slice(0,12) }}</p></div>
          <div class="text-right text-xs"><p>{{ sourceLabel(component.source) }}</p><p class="mt-1 text-[var(--mn-ink-muted)]">{{ updateBytes(component.size) }}</p></div>
        </li>
      </ul>
    </Card>
  </div>
</template>

<style scoped>
.update-metrics { display: grid; grid-template-columns: repeat(auto-fit,minmax(130px,1fr)); gap: 1rem; font-size: .75rem; }
.update-metrics dt { color: var(--mn-ink-muted); margin-bottom: .35rem; }
.update-metrics dd { overflow-wrap: anywhere; }
.update-switch { display: flex; align-items: center; justify-content: space-between; gap: 1rem; min-height: 48px; font-size: .875rem; }
.update-switch input { width: 24px; height: 24px; accent-color: var(--mn-primary); }
.update-interval { min-height: 48px; width: 6rem; border: 1px solid var(--mn-border); border-radius: var(--mn-radius-md); padding: .5rem .75rem; background: var(--mn-surface); color: var(--mn-ink); }
.update-interval:focus-visible, .update-switch input:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: 3px; }
</style>
