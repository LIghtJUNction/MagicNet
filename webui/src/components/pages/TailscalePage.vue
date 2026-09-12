<script setup lang="ts">
import { computed, onDeactivated, onMounted, ref, watch } from "vue";
import { ArrowUpRight, KeyRound, RefreshCw } from "lucide-vue-next";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  inspectTailscale, saveTailscale, TailscaleSetupError,
  TAILSCALE_KEYS_URL, TAILSCALE_MACHINES_URL,
  type SaveResult, type SetupErrorCode, type TailscaleSnapshot,
} from "./tailscaleSetup";

const { state, runPrivateCli, stagePrivatePayload, removePrivatePayload, shellQuote, openExternal, refreshStatus } = useMagicNet();
const snapshot = ref<TailscaleSnapshot | null>(null);
const hostname = ref("magicnet-phone");
const authKey = ref("");
const loading = ref(false);
const saving = ref(false);
const edited = ref(false);
const message = ref("");
const hasError = ref(false);
let attemptedRead = false;
const locked = computed(() => loading.value || saving.value || state.busy || !state.hasKsu);
const customControl = computed(() => Boolean(snapshot.value && snapshot.value.controlUrl.replace(/\/$/, "") !== "https://controlplane.tailscale.com"));
const saveDisabled = computed(() => locked.value || !snapshot.value || state.config.dirty || customControl.value);

function errorMessage(code?: SetupErrorCode): string {
  switch (code) {
    case "hostname": return t("设备名称需为 1–63 位字母、数字或短横线，首尾不能是短横线。");
    case "auth-key": return t("请填写以 tskey-auth- 开头的 Tailscale Auth key。");
    case "multiple": return t("检测到多个 Tailscale 节点，请使用配置编辑器管理，避免修改错误的网络。");
    case "custom-control": return t("当前节点使用自建控制服务器，此入口不会覆盖它或向它发送 Tailscale 密钥。");
    case "conflict": return t("配置已在其他位置修改，请重新读取后再保存。");
    default: return t("无法读取有效的 sing-box 配置，请先检查核心配置。");
  }
}
function resultMessage(result: SaveResult): string {
  if (result.error) return errorMessage(result.error);
  switch (result.stage) {
    case "done": return t("配置已保存，核心已重启。请在设备后台确认授权和在线状态。");
    case "restart": return t("配置已保存，但核心重启失败。可重试重启，无需再次填写密钥。");
    case "cleanup": return result.saved
      ? t("配置已保存，但私密临时文件清理未确认，未重启核心。")
      : t("私密临时文件清理未确认，请检查设备状态后重试。");
    case "conflict": return errorMessage("conflict");
    case "stage": return t("私密数据传输失败，配置未保存。");
    case "validate": return t("配置保存未确认，未重启。请检查内核是否支持 Tailscale。");
    default: return errorMessage();
  }
}
async function read(): Promise<void> {
  if (locked.value || edited.value) return;
  attemptedRead = true;
  loading.value = true;
  hasError.value = false;
  try {
    const result = await runPrivateCli("config-editor get sing-box", t("读取 Tailscale 配置"), "config-editor get sing-box [private-output]");
    if (!result.ok) throw new TailscaleSetupError("config");
    const current = inspectTailscale(result.stdout);
    snapshot.value = current;
    hostname.value = current.hostname;
    message.value = "";
  } catch (cause) {
    snapshot.value = null;
    hasError.value = true;
    message.value = errorMessage(cause instanceof TailscaleSetupError ? cause.code : undefined);
  } finally { loading.value = false; }
}
async function submit(): Promise<void> {
  if (saveDisabled.value || !snapshot.value) return;
  saving.value = true;
  hasError.value = false;
  message.value = t("正在校验并接入 Tailscale…");
  const draft = { hostname: hostname.value, authKey: authKey.value };
  authKey.value = "";
  try {
    const result = await saveTailscale({
      run: (args) => runPrivateCli(args, t("配置 Tailscale"), args.startsWith("config-editor save-file")
        ? "config-editor save-file sing-box [private-payload]" : `${args} [private-output]`),
      stage: (text) => stagePrivatePayload("tmp", `tailscale-${Date.now()}-${Math.random().toString(36).slice(2, 10)}.json`, text, t("Tailscale 私密配置")),
      remove: (name) => removePrivatePayload("tmp", name, t("Tailscale 私密配置")),
      quote: shellQuote,
      canSave: () => !state.config.dirty,
    }, draft, snapshot.value);
    if (result.saved && result.snapshot) {
      snapshot.value = result.snapshot;
      edited.value = false;
      // An inactive, clean JSON editor must not later save a stale copy over
      // the endpoint. Never discard an unsaved editor draft.
      if (!state.config.dirty) {
        state.config.text = "";
        state.config.status = t("Tailscale 已更新，请重新加载配置。");
        state.config.validation = { status: "idle", summary: state.config.status, checkedAt: "" };
      }
    }
    message.value = resultMessage(result);
    hasError.value = result.stage !== "done";
    if (result.stage === "done" || result.stage === "restart") await refreshStatus(true);
  } finally {
    draft.authKey = "";
    saving.value = false;
  }
}
async function retryRestart(): Promise<void> {
  if (locked.value) return;
  saving.value = true;
  try {
    const outcome = await runPrivateCli("service restart sing-box", t("重启核心"), "service restart sing-box");
    message.value = resultMessage({ stage: outcome.ok ? "done" : "restart", saved: true });
    hasError.value = !outcome.ok;
    await refreshStatus(true);
  } finally { saving.value = false; }
}
function discardDraft(): void {
  authKey.value = "";
  edited.value = false;
  void read();
}
onMounted(() => { void read(); });
watch(() => state.busy, (busy) => { if (!busy && !attemptedRead) void read(); });
// KeepAlive retains the page, but never retains a password when leaving it.
onDeactivated(() => { authKey.value = ""; });
</script>

<template>
  <div class="tailscale-page space-y-8">
    <PageHeader title="Tailscale">
      <Button variant="ghost" :disabled="locked || edited" :loading="loading" @click="read">
        <RefreshCw :size="16" aria-hidden="true" />{{ t("重新读取") }}
      </Button>
    </PageHeader>
    <p v-if="!state.hasKsu" class="text-sm text-[var(--mn-ink-muted)]">{{ t("请在支持 KernelSU 异步接口的真机 WebUI 中接入。") }}</p>
    <div v-if="snapshot" class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
      <span class="text-xl font-medium">{{ t(snapshot.configured ? "已配置" : "连接你的设备") }}</span>
      <span class="text-sm text-[var(--mn-ink-muted)]">{{ snapshot.configured ? snapshot.hostname : t("使用自己的 Tailscale 账号") }}</span>
    </div>
    <p v-if="state.config.dirty" role="alert" class="text-sm text-[var(--mn-warning)]">{{ t("配置编辑器还有未保存的修改，请先处理后再接入。") }}</p>
    <p v-if="customControl" role="alert" class="text-sm text-[var(--mn-warning)]">{{ errorMessage("custom-control") }}</p>
    <form class="max-w-xl space-y-7" @submit.prevent="submit" @input="edited = true" @change="edited = true">
      <fieldset :disabled="locked || !snapshot || customControl" class="min-w-0 space-y-7">
        <div class="space-y-2">
          <label for="tailscale-hostname" class="block text-sm font-medium">{{ t("设备名称") }}</label>
          <Input id="tailscale-hostname" v-model="hostname" autocomplete="off" autocapitalize="none" :spellcheck="false" maxlength="63" required />
        </div>
        <div class="space-y-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <label for="tailscale-key" class="text-sm font-medium">Auth key</label>
            <Button variant="ghost" size="sm" @click="openExternal(TAILSCALE_KEYS_URL)">
              <KeyRound :size="15" aria-hidden="true" />{{ t("获取密钥") }}<ArrowUpRight :size="14" aria-hidden="true" />
            </Button>
          </div>
          <Input id="tailscale-key" v-model="authKey" type="password" autocomplete="new-password" autocapitalize="none" :spellcheck="false" maxlength="251" :required="!snapshot?.configured" placeholder="tskey-auth-…" aria-describedby="tailscale-key-note" />
          <p id="tailscale-key-note" class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ t(snapshot?.configured ? "留空保留当前登录。新密钥不会自动切换已登录账号。" : "使用你账号生成的 Auth key，不要使用 API access token。") }}</p>
        </div>
        <details class="border-t border-[var(--mn-border)] pt-3">
          <summary class="min-h-12 cursor-pointer content-center text-sm">{{ t("高级选项") }}</summary>
          <dl v-if="snapshot" class="mt-3 space-y-3 text-xs leading-5 text-[var(--mn-ink-muted)]">
            <div><dt>{{ t("节点标识") }}</dt><dd class="break-all font-mono">{{ snapshot.tag }}</dd></div>
            <div><dt>{{ t("控制服务器") }}</dt><dd class="break-all font-mono">{{ snapshot.controlUrl }}</dd></div>
          </dl>
        </details>
      </fieldset>
      <div class="flex flex-wrap gap-3">
        <Button type="submit" :disabled="saveDisabled" :loading="saving">{{ t(snapshot?.configured ? "保存并重启" : "接入并重启") }}</Button>
        <Button v-if="edited" variant="ghost" :disabled="locked" @click="discardDraft">{{ t("放弃修改并重新读取") }}</Button>
      </div>
      <p class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ t("重启会短暂中断现有连接。配置保留在本机。") }}</p>
    </form>
    <div v-if="message" :role="hasError ? 'alert' : 'status'" aria-live="polite" class="max-w-xl text-sm leading-6" :class="hasError ? 'text-[var(--mn-danger)]' : 'text-[var(--mn-ink-muted)]'">
      {{ message }}
    </div>
    <div class="flex flex-wrap gap-3 border-t border-[var(--mn-border)] pt-5">
      <Button variant="outline" @click="openExternal(TAILSCALE_MACHINES_URL)">{{ t("设备后台") }}<ArrowUpRight :size="16" aria-hidden="true" /></Button>
      <Button v-if="snapshot?.configured && !customControl" variant="ghost" :disabled="locked" @click="retryRestart">{{ t("重试重启核心") }}</Button>
    </div>
  </div>
</template>
