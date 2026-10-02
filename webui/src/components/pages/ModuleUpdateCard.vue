<script setup lang="ts">
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref, watch } from "vue";
import { ArrowDownToLine, RefreshCw } from "lucide-vue-next";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { createModuleUpdateClient, moduleUpdateCanInstall, ModuleUpdateError, type ModuleUpdateSnapshot } from "@/composables/moduleUpdate";

const { state, runMachineCli, openExternal, REPO } = useMagicNet();
const client = createModuleUpdateClient(args => runMachineCli(args, t("MagicNet 更新")));
const snapshot = ref<ModuleUpdateSnapshot | null>(null);
const availability = ref<"loading" | "device" | "unsupported" | "ready">("loading");
const action = ref("");
const failure = ref("");
const fresh = ref(false);
let active = false;
const reading = ref(false);
const uncertainRequestId = ref("");
let timer: number | undefined;
const activePhases = ["checking", "downloading", "verifying", "installing"];
const working = computed(() => Boolean(action.value || reading.value || snapshot.value?.busy || activePhases.includes(snapshot.value?.phase ?? "")));
const canInstall = computed(() => fresh.value && !working.value && !uncertainRequestId.value && failure.value !== "module-update.conflict" && moduleUpdateCanInstall(snapshot.value));
const canCheck = computed(() => fresh.value && availability.value === "ready" && Boolean(snapshot.value?.supported) &&
  !working.value && !uncertainRequestId.value && !snapshot.value?.reboot_required && !snapshot.value?.recovery_required);
const phaseLabel = computed(() => {
  if (availability.value === "device") return t("请在模块管理器中打开");
  if (availability.value === "unsupported") return t("当前版本暂不支持内置更新");
  if (!snapshot.value) return action.value ? t("读取中…") : t("更新状态未确认");
  if (!fresh.value) return t("更新状态未确认");
  if (snapshot.value.recovery_required) return t("需要先处理未完成的更新");
  if (snapshot.value.reboot_required) return t("已安装，等待重启");
  switch (snapshot.value.phase) {
    case "checking": return t("正在检查更新…");
    case "available": return t("有新版本");
    case "up_to_date": return t("已是最新版本");
    case "downloading": return t("正在下载更新…");
    case "verifying": return t("正在校验更新…");
    case "installing": return t("正在安装更新…");
    case "failed": return t("更新未完成");
    default: return snapshot.value.supported ? t("检查是否有新版本") : t("当前管理器不支持内置安装");
  }
});
const errorMessage = computed(() => {
  const code = failure.value || snapshot.value?.error_code;
  if (!code) return "";
  switch (code) {
    case "module-update.busy": return t("已有更新任务在进行，请等待完成。");
    case "module-update.conflict": return t("版本信息已变化，请重新检查更新。");
    case "module-update.no_release": return t("暂无可用的正式版本，请稍后检查。");
    case "module-update.no_space":
    case "module-update.insufficient_space": return t("设备空间不足，清理空间后重试。");
    case "module-update.pending_conflict":
    case "module-update.pending_update":
    case "module-update.recovery_required": return t("有未完成的安装，请先在模块管理器中处理，再重新读取状态。");
    case "module-update.unsupported_manager":
    case "module-update.unavailable": return t("当前无法内置安装，请从 GitHub 下载后使用模块管理器安装。");
    case "module-update.request_unconfirmed": return t("尚未确认任务是否已启动，正在重新读取状态。请勿重复安装。");
    case "module-update.download_failed": return t("下载未完成，检查网络后重试。");
    case "module-update.network": return t("下载未完成，检查网络后重试。");
    case "module-update.verification_failed":
    case "module-update.invalid_artifact": return t("安装包校验未通过，请重新检查更新。");
    case "module-update.integrity":
    case "module-update.invalid_release":
    case "module-update.invalid_archive": return t("安装包校验未通过，请重新检查更新。");
    case "module-update.incompatible": return t("这个版本不适用于当前设备，请使用模块管理器检查兼容性。");
    case "module-update.disabled": return t("模块已被停用，请先在模块管理器中启用，再重新检查。");
    case "module-update.not_root": return t("没有获得安装权限，请在模块管理器中允许 root 权限后重试。");
    case "module-update.interrupted":
    case "module-update.staging_unverified": return t("上次安装未确认完成，请先在模块管理器中检查，再重新读取状态。");
    case "module-update.install_failed": return t("安装未完成，请查看模块管理器后重试。");
    default: return t("无法确认更新状态，请重新读取后再试。");
  }
});
const statusTone = computed(() => {
  if (!fresh.value || !snapshot.value) return "neutral";
  if (failure.value || snapshot.value.phase === "failed" || snapshot.value.recovery_required) return "danger";
  if (snapshot.value.reboot_required) return "warning";
  return "neutral";
});
const installLabel = computed(() => t("安装更新至 {version}", { version: snapshot.value?.latest.version ?? "" }));

function stopPolling() {
  if (timer !== undefined) window.clearTimeout(timer);
  timer = undefined;
}
function schedule() {
  stopPolling();
  if (active && !document.hidden && availability.value === "ready" &&
    (snapshot.value?.busy || activePhases.includes(snapshot.value?.phase ?? "") || uncertainRequestId.value)) {
    timer = window.setTimeout(() => void readStatus(), 2000);
  }
}
function codeOf(error: unknown): string {
  return error instanceof ModuleUpdateError ? error.code : "module-update.request_failed";
}
async function readStatus() {
  if (reading.value || action.value || !active || document.hidden || availability.value !== "ready") return;
  reading.value = true;
  try {
    snapshot.value = await client.read();
    fresh.value = true;
    // A successful device observation resolves an uncertain launch; the phase
    // itself remains the only evidence of completion.
    if (uncertainRequestId.value && snapshot.value.request_id === uncertainRequestId.value) { uncertainRequestId.value = ""; failure.value = ""; }
  } catch (error) {
    fresh.value = false;
    if (!uncertainRequestId.value) failure.value = codeOf(error);
  } finally { reading.value = false; schedule(); }
}
async function reload() {
  if (reading.value || action.value || !active || document.hidden) return;
  stopPolling();
  fresh.value = false;
  if (!uncertainRequestId.value) failure.value = "";
  if (!state.hasKsu) { availability.value = "device"; snapshot.value = null; return; }
  action.value = "load";
  try {
    availability.value = await client.discover() ? "ready" : "unsupported";
    if (availability.value === "ready") {
      snapshot.value = await client.read();
      fresh.value = true;
      if (uncertainRequestId.value && snapshot.value.request_id === uncertainRequestId.value) { uncertainRequestId.value = ""; failure.value = ""; }
    } else snapshot.value = null;
  } catch (error) { if (!uncertainRequestId.value) failure.value = codeOf(error); }
  finally { action.value = ""; schedule(); }
}
function newRequestId() {
  return `webui_${Date.now()}_${Math.random().toString(36).slice(2, 12)}`;
}
async function mutate(name: "check" | "install") {
  if (reading.value || (name === "check" ? !canCheck.value : !canInstall.value)) return;
  const observed = snapshot.value;
  if (!observed) return;
  stopPolling();
  action.value = name;
  failure.value = "";
  const id = newRequestId();
  try {
    snapshot.value = name === "check" ? await client.check(id) : await client.install(observed, id);
    fresh.value = true;
  } catch (error) {
    failure.value = codeOf(error);
    if (failure.value === "module-update.request_unconfirmed") uncertainRequestId.value = id;
    fresh.value = false;
    try {
      snapshot.value = await client.read(); fresh.value = true;
      if (uncertainRequestId.value && snapshot.value.request_id === uncertainRequestId.value) { uncertainRequestId.value = ""; failure.value = ""; }
    } catch { /* Keep the failure and prevent writes. */ }
  } finally { action.value = ""; schedule(); }
}
function enter() { active = true; void reload(); }
function leave() { active = false; stopPolling(); }
function visibilityChanged() {
  if (document.hidden) stopPolling();
  else if (active) void reload();
}
onMounted(() => { document.addEventListener("visibilitychange", visibilityChanged); enter(); });
onActivated(enter);
onDeactivated(leave);
onUnmounted(() => { leave(); document.removeEventListener("visibilitychange", visibilityChanged); });
watch(() => state.hasKsu, () => { if (active) void reload(); });
</script>

<template>
  <section class="mn-module-update" :data-phase="fresh ? snapshot?.phase : snapshot || availability === 'ready' ? 'unknown' : availability" :data-tone="statusTone" :aria-label="t('MagicNet 更新')">
    <div class="mn-module-update__heading">
      <h3>{{ t("MagicNet 更新") }}</h3>
      <p>{{ t("当前版本") }} <span>{{ snapshot?.installed.version ?? t("未确认") }}</span></p>
    </div>
    <div class="mn-module-update__body">
      <div class="mn-module-update__copy" role="status" aria-live="polite" aria-atomic="true">
        <p class="mn-module-update__status">{{ phaseLabel }}</p>
        <p v-if="snapshot?.reboot_required" class="mn-module-update__detail">{{ t("{version} 将在重启设备后生效。请在方便时手动重启。", { version: snapshot.latest.version ?? t('新版本') }) }}</p>
        <p v-else-if="snapshot?.busy || action === 'install'" class="mn-module-update__detail">{{ t("更新会在后台继续，关闭面板后也能重新查看进度。") }}</p>
        <p v-else-if="canInstall" class="mn-module-update__detail">{{ t("下载并安装正式发布的模块；完成后需重启设备。") }}</p>
        <p v-else-if="availability === 'unsupported' || (snapshot && !snapshot.supported)" class="mn-module-update__detail">{{ t("请从 GitHub 下载后使用模块管理器安装。") }}</p>
        <p v-if="errorMessage" class="mn-module-update__error">{{ errorMessage }}</p>
      </div>
      <div class="mn-module-update__actions">
        <Button v-if="availability === 'unsupported' || (snapshot && !snapshot.supported)" @click="openExternal(`${REPO}/releases/latest`, t('从 GitHub 下载'))">{{ t("从 GitHub 下载") }}</Button>
        <Button v-if="canInstall || action === 'install'" :loading="action === 'install'" :disabled="!canInstall" @click="mutate('install')">
          <ArrowDownToLine :size="17" aria-hidden="true" />{{ installLabel }}
        </Button>
        <Button v-if="availability === 'ready' && fresh && !uncertainRequestId && !snapshot?.reboot_required && !snapshot?.recovery_required" :variant="canInstall ? 'outline' : 'default'" :loading="action === 'check'" :disabled="!canCheck" @click="mutate('check')">
          <RefreshCw :size="17" aria-hidden="true" />{{ t("检查更新") }}
        </Button>
        <Button v-else-if="availability !== 'device'" variant="outline" :loading="action === 'load'" :disabled="Boolean(action) || reading" @click="reload">
          <RefreshCw :size="17" aria-hidden="true" />{{ t("重新读取") }}
        </Button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.mn-module-update { padding-block: 24px; border-block-start: 1px solid var(--mn-border); }
.mn-module-update__heading { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px 24px; margin-block-end: 16px; }
.mn-module-update__heading h3 { margin: 0; font-size: 18px; font-weight: 500; }
.mn-module-update__heading > p { margin: 0; color: var(--mn-ink-muted); font-size: 14px; }
.mn-module-update__heading span { margin-inline-start: 8px; color: var(--mn-ink); }
.mn-module-update__body { display: flex; align-items: center; justify-content: space-between; gap: 16px 24px; }
.mn-module-update__copy { min-width: 0; max-width: 65ch; }
.mn-module-update__status { margin: 0; font-size: 16px; }
.mn-module-update__detail, .mn-module-update__error { margin: 6px 0 0; color: var(--mn-ink-muted); font-size: 14px; line-height: 1.6; overflow-wrap: anywhere; }
.mn-module-update__error, [data-tone="danger"] .mn-module-update__status { color: var(--mn-danger); }
[data-tone="warning"] .mn-module-update__status { color: var(--mn-warning); }
.mn-module-update__actions { display: flex; flex-wrap: wrap; flex-shrink: 0; gap: 8px; }
@media (max-width: 639px) {
  .mn-module-update__body { flex-direction: column; align-items: stretch; }
  .mn-module-update__actions > button { flex: 1 1 auto; }
}
@media (forced-colors: active) { .mn-module-update__error { color: CanvasText; } }
</style>
