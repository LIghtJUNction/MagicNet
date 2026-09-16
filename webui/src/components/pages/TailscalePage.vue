<script setup lang="ts">
import { computed, onActivated, onDeactivated, onMounted, ref, watch } from "vue";
import { ArrowUpRight, Check, Copy, Globe, KeyRound, QrCode, RefreshCw, Trash2, XCircle } from "lucide-vue-next";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { generateQrSvgPath } from "@/lib/qrcode";
import {
  inspectTailscale, saveTailscale, removeTailscale, parseTailscaleLogin, TailscaleSetupError,
  TAILSCALE_KEYS_URL, TAILSCALE_MACHINES_URL,
  type SaveResult, type SetupErrorCode, type TailscaleSnapshot, type TailscaleClient,
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
const confirmRemove = ref(false);
const needsRestart = ref(false);
let readGeneration = 0;
let active = true;
let attemptedRead = false;
const loginMessage = ref("");
const loginUrl = ref("");
const isOnline = ref(false);
const copied = ref(false);
let loginTimer: ReturnType<typeof setTimeout> | undefined;
let loginGeneration = 0;

const qrInfo = computed(() => {
  if (!loginUrl.value) return null;
  try {
    return generateQrSvgPath(loginUrl.value);
  } catch {
    return null;
  }
});

function stopLoginPolling(): void {
  loginGeneration++;
  clearTimeout(loginTimer);
  loginUrl.value = "";
  loginMessage.value = "";
  isOnline.value = false;
}

function cancelLogin(): void {
  stopLoginPolling();
  loginMessage.value = t("已取消登录等待。");
}

async function copyAuthUrl(): Promise<void> {
  if (!loginUrl.value) return;
  try {
    await navigator.clipboard.writeText(loginUrl.value);
    copied.value = true;
    setTimeout(() => { copied.value = false; }, 2000);
  } catch {
    /* clipboard fallback */
  }
}

function startLoginPolling(autoOpen: boolean): void {
  if (!active) return;
  stopLoginPolling();
  const generation = loginGeneration;
  let attempts = 0;
  let opened = false;
  async function poll(): Promise<void> {
    if (generation !== loginGeneration || !snapshot.value || !active) return;
    if (document.hidden) { loginTimer = setTimeout(poll, 2000); return; }
    try {
      const response = await runPrivateCli(`api tailscale-status ${shellQuote(snapshot.value.tag)}`, t("读取 Tailscale 配置"), "api tailscale-status [private-output]");
      if (generation !== loginGeneration || !active) return;
      // A response begun while visible must not publish or launch a browser
      // after the WebView moves to the background. Resume by reading afresh.
      if (document.hidden) { loginTimer = setTimeout(poll, 2000); return; }
      if (!response.ok) throw new Error("status");
      const status = parseTailscaleLogin(response.stdout);
      loginUrl.value = status.authUrl;
      isOnline.value = status.online;
      if (status.state === "Running" && status.online) {
        loginUrl.value = "";
        loginMessage.value = t("Tailscale 已登录，正由 sing-box 连接。配置已自动生效。");
        return;
      }
      loginMessage.value = status.state === "Running"
        ? t("Tailscale 已登录，正在等待网络上线。")
        : t("等待 Tailscale 登录授权，请在浏览器完成后返回。");
      if (autoOpen && !opened && status.authUrl) {
        opened = true;
        await openExternal(status.authUrl, "Tailscale", { preferBrowser: false });
      }
    } catch {
      if (generation !== loginGeneration || !active) return;
      if (document.hidden) { loginTimer = setTimeout(poll, 2000); return; }
      loginUrl.value = "";
      isOnline.value = false;
      loginMessage.value = t("暂时无法读取 Tailscale 登录状态，请稍后刷新。");
    }
    if (generation !== loginGeneration) return;
    if (++attempts < 60) loginTimer = setTimeout(poll, 2000);
    else loginMessage.value = t("本次状态检查已结束，点击刷新登录状态继续。未确认上线。");
  }
  void poll();
}

const locked = computed(() => loading.value || saving.value || state.busy || !state.hasKsu);
const customControl = computed(() => Boolean(snapshot.value && snapshot.value.controlUrl.replace(/\/$/, "") !== "https://controlplane.tailscale.com"));
const saveDisabled = computed(() => locked.value || !snapshot.value || state.config.dirty || customControl.value);

function errorMessage(code?: SetupErrorCode): string {
  switch (code) {
    case "hostname": return t("设备名称需为 1–63 位字母、数字或短横线，首尾不能是短横线。");
    case "auth-key": return t("请填写以 tskey-auth- 开头的 Tailscale Auth key。");
    case "multiple": return t("检测到多个 Tailscale 节点，请使用配置编辑器管理，避免修改错误的网络。");
    case "custom-control": return t("当前节点使用自建控制服务器，此入口不会覆盖它或向它发送 Tailscale 密钥。");
    case "references": return t("仍有自定义规则引用此节点，请先在配置编辑器中处理。");
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
  if (!active || locked.value || edited.value) return;
  attemptedRead = true;
  const generation = ++readGeneration;
  loading.value = true;
  hasError.value = false;
  try {
    const result = await runPrivateCli("config-editor get sing-box", t("读取 Tailscale 配置"), "config-editor get sing-box [private-output]");
    if (generation !== readGeneration || !active || edited.value) return;
    if (!result.ok) throw new TailscaleSetupError("config");
    const current = inspectTailscale(result.stdout);
    snapshot.value = current;
    hostname.value = current.hostname;
    message.value = "";
    if (current.configured) startLoginPolling(false);
  } catch (cause) {
    if (generation !== readGeneration || !active) return;
    snapshot.value = null;
    hasError.value = true;
    message.value = errorMessage(cause instanceof TailscaleSetupError ? cause.code : undefined);
  } finally { if (generation === readGeneration) loading.value = false; }
}

function privateClient(label: string): TailscaleClient {
  const generation = readGeneration;
  return {
    run: (args) => runPrivateCli(args, label, args.startsWith("config-editor save-file")
      ? "config-editor save-file sing-box [private-payload]" : `${args} [private-output]`),
    stage: (text) => stagePrivatePayload("tmp", `tailscale-${Date.now()}-${Math.random().toString(36).slice(2, 10)}.json`, text, t("Tailscale 私密配置")),
    remove: (name) => removePrivatePayload("tmp", name, t("Tailscale 私密配置")),
    quote: shellQuote,
    canSave: () => active && generation === readGeneration && !state.config.dirty,
  };
}

function acceptTransactionResult(result: SaveResult, generation: number): boolean {
  if (active && generation === readGeneration) return true;
  if (result.saved) {
    snapshot.value = null;
    needsRestart.value = result.stage === "restart";
    if (!state.config.dirty) {
      state.config.text = "";
      state.config.status = t("Tailscale 已更新，请重新加载配置。");
      state.config.validation = { status: "idle", summary: state.config.status, checkedAt: "" };
    }
  }
  return false;
}

function applySavedSnapshot(result: SaveResult): void {
  if (!result.saved || !result.snapshot) return;
  snapshot.value = result.snapshot;
  hostname.value = result.snapshot.hostname;
  edited.value = false;
  if (!state.config.dirty) {
    state.config.text = "";
    state.config.status = t("Tailscale 已更新，请重新加载配置。");
    state.config.validation = { status: "idle", summary: state.config.status, checkedAt: "" };
  }
}

async function submit(mode: "key" | "browser" = "key"): Promise<void> {
  if (saveDisabled.value || !snapshot.value) return;
  // A configured login can be resumed without interrupting every application.
  if (mode === "browser" && snapshot.value.configured && snapshot.value.statusConfigured && !edited.value && !needsRestart.value) {
    startLoginPolling(true);
    return;
  }
  const generation = readGeneration;
  confirmRemove.value = false;
  saving.value = true;
  hasError.value = false;
  message.value = t("正在校验并接入 Tailscale…");
  stopLoginPolling();
  const draft = { hostname: hostname.value, authKey: mode === "browser" ? "" : authKey.value, mode };
  authKey.value = "";
  try {
    const result = await saveTailscale(privateClient(t("配置 Tailscale")), draft, snapshot.value);
    if (!acceptTransactionResult(result, generation)) return;
    applySavedSnapshot(result);
    message.value = resultMessage(result);
    hasError.value = result.stage !== "done";
    needsRestart.value = result.stage === "restart";
    if (result.stage === "done" || result.stage === "restart") await refreshStatus(undefined, false);
    if (result.stage === "done" && active && generation === readGeneration && !document.hidden) startLoginPolling(mode === "browser");
  } finally {
    draft.authKey = "";
    saving.value = false;
  }
}

async function disconnectTailscale(): Promise<void> {
  if (saveDisabled.value || !snapshot.value?.configured || !confirmRemove.value) return;
  const generation = readGeneration;
  confirmRemove.value = false;
  saving.value = true;
  hasError.value = false;
  message.value = t("正在移除 Tailscale 节点并重启核心…");
  authKey.value = "";
  stopLoginPolling();
  try {
    const result = await removeTailscale(privateClient(t("移除 Tailscale")), snapshot.value);
    if (!acceptTransactionResult(result, generation)) return;
    // Reading here would be skipped by the saving lock. The transaction's
    // confirmed snapshot is authoritative even when the restart fails.
    applySavedSnapshot(result);
    message.value = result.stage === "done"
      ? t("Tailscale 节点已移除，核心已重启。") : resultMessage(result);
    hasError.value = result.stage !== "done";
    needsRestart.value = result.stage === "restart";
    if (result.stage === "done" || result.stage === "restart") await refreshStatus(undefined, false);
  } finally { saving.value = false; }
}

async function retryRestart(): Promise<void> {
  if (!active || locked.value || !needsRestart.value) return;
  const generation = readGeneration;
  saving.value = true;
  try {
    const outcome = await runPrivateCli("service restart sing-box", t("重启核心"), "service restart sing-box");
    if (!acceptTransactionResult({ stage: outcome.ok ? "done" : "restart", saved: true }, generation)) return;
    message.value = resultMessage({ stage: outcome.ok ? "done" : "restart", saved: true });
    hasError.value = !outcome.ok;
    needsRestart.value = !outcome.ok;
    await refreshStatus(undefined, false);
  } finally { saving.value = false; }
}

function discardDraft(): void {
  authKey.value = "";
  edited.value = false;
  void read();
}

onMounted(() => { void read(); });
watch(() => state.busy, (busy) => { if (!busy && active && !attemptedRead) void read(); });
watch(saving, (busy) => { if (!busy && active && !snapshot.value && !edited.value) void read(); });
onDeactivated(() => { authKey.value = "";
  active = false; readGeneration++; loading.value = false;
  confirmRemove.value = false; stopLoginPolling();
});
onActivated(() => { active = true; if (!edited.value) void read(); });
</script>

<template>
  <div class="tailscale-page space-y-6">
    <PageHeader title="Tailscale">
      <Button variant="ghost" :disabled="locked || edited" :loading="loading" @click="read">
        <RefreshCw :size="16" aria-hidden="true" />{{ t("重新读取") }}
      </Button>
    </PageHeader>
    <p v-if="!state.hasKsu" class="text-sm text-[var(--mn-ink-muted)]">
      {{ t("请在支持 KernelSU 异步接口的真机 WebUI 中接入。") }}
    </p>

    <section v-if="snapshot" class="tailscale-panel space-y-4">
      <div class="flex items-start gap-3">
        <StatusDot :tone="snapshot.configured ? (isOnline ? 'ok' : 'current') : 'unknown'" />
        <div class="min-w-0">
          <h2 class="font-semibold text-base">{{ t(snapshot.configured ? (isOnline ? "已连接并在线" : "已配置") : "连接你的设备") }}</h2>
          <p class="mt-1 break-all text-sm text-[var(--mn-ink-muted)]">{{ snapshot.configured ? snapshot.hostname : t("使用自己的 Tailscale 账号") }}</p>
        </div>
      </div>
      <div class="tailscale-status-actions flex flex-wrap gap-2">
        <Button v-if="snapshot.configured" variant="ghost" size="sm" :disabled="locked" @click="startLoginPolling(false)">
          <RefreshCw :size="14" aria-hidden="true" />{{ t("刷新登录状态") }}
        </Button>
        <Button variant="outline" size="sm" @click="openExternal(TAILSCALE_MACHINES_URL)">
          <Globe :size="14" aria-hidden="true" />{{ t("设备后台") }}<ArrowUpRight :size="13" aria-hidden="true" />
        </Button>
        <Button v-if="snapshot.configured && !customControl" variant="ghost" size="sm"
          class="text-[var(--mn-danger)]" :disabled="saveDisabled" @click="confirmRemove = true">
          <Trash2 :size="14" aria-hidden="true" />{{ t("断开并移除节点") }}
        </Button>
      </div>
    </section>
    <ConfirmPanel v-if="confirmRemove" title="移除本机 Tailscale 配置？"
      detail="仅移除本机节点及自动生成的路由；不会注销账号或删除云端设备。"
      confirm-label="确认移除" confirm-variant="destructive" :loading="saving"
      @cancel="confirmRemove = false" @confirm="disconnectTailscale" />
    <p v-if="state.config.dirty" role="alert" class="text-sm text-[var(--mn-warning)]">
      {{ t("配置编辑器还有未保存的修改，请先处理后再接入。") }}
    </p>
    <p v-if="customControl" role="alert" class="text-sm text-[var(--mn-warning)]">{{ errorMessage("custom-control") }}</p>

    <div class="tailscale-device-name space-y-2">
      <label for="tailscale-hostname" class="block text-sm font-medium">{{ t("设备名称") }}</label>
      <Input id="tailscale-hostname" v-model="hostname" :disabled="locked || !snapshot || customControl"
        @input="edited = true" autocomplete="off" autocapitalize="none" :spellcheck="false" maxlength="63" required />
    </div>

    <section class="tailscale-panel space-y-4">
      <div class="tailscale-method-heading flex flex-wrap items-start justify-between gap-4">
        <div>
          <h3 class="font-medium">{{ t("网页授权登录（推荐）") }}</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("支持一键网页登录或使用其他设备扫码快速授权上线。") }}</p>
        </div>
        <Button :disabled="saveDisabled" :loading="saving" @click="submit('browser')">{{ t("登录 Tailscale 并自动配置") }}</Button>
      </div>
      <div v-if="loginUrl" class="tailscale-auth space-y-4">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <p class="min-w-0 flex-1 text-sm leading-6">{{ t("等待 Tailscale 登录授权，请在浏览器完成后返回。") }}</p>
          <Button variant="ghost" size="sm" @click="cancelLogin"><XCircle :size="14" aria-hidden="true" />{{ t("取消授权") }}</Button>
        </div>
        <div class="flex flex-col items-center gap-4 sm:flex-row">
          <div v-if="qrInfo" class="shrink-0 rounded-lg bg-white p-2">
            <svg :viewBox="`-4 -4 ${qrInfo.size + 8} ${qrInfo.size + 8}`" class="block size-36" role="img" aria-label="Tailscale Auth QR Code">
              <path :d="qrInfo.path" fill="#000" shape-rendering="crispEdges" />
            </svg>
          </div>
          <div class="min-w-0 space-y-3">
            <p class="flex items-start gap-2 text-xs leading-5 text-[var(--mn-ink-muted)]"><QrCode :size="14" class="shrink-0" aria-hidden="true" />{{ t("使用手机或其他设备扫码即可完成授权") }}</p>
            <div class="flex flex-wrap gap-2">
              <Button size="sm" variant="outline" :disabled="locked" @click="openExternal(loginUrl, 'Tailscale', { preferBrowser: false })">{{ t("继续 Tailscale 登录") }}<ArrowUpRight :size="13" aria-hidden="true" /></Button>
              <Button size="sm" variant="ghost" :disabled="locked" @click="copyAuthUrl"><component :is="copied ? Check : Copy" :size="13" aria-hidden="true" />{{ t(copied ? "已复制授权链接" : "复制授权链接") }}</Button>
            </div>
          </div>
        </div>
      </div>
      <p v-if="loginMessage && !loginUrl" role="status" class="text-sm leading-6">{{ loginMessage }}</p>
    </section>

    <section class="tailscale-panel space-y-4">
      <div>
        <h3 class="font-medium">{{ t("Auth Key 密钥接入") }}</h3>
        <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t("也可以直接填入从 Tailscale 控制台生成的预授权 Auth key。") }}</p>
      </div>
      <form class="max-w-xl space-y-5" @submit.prevent="submit('key')" @input="edited = true" @change="edited = true">
        <fieldset :disabled="locked || !snapshot || customControl" class="min-w-0 space-y-5">
          <div class="space-y-2">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <label for="tailscale-key" class="text-sm font-medium">Auth key</label>
              <Button variant="ghost" size="sm" @click="openExternal(TAILSCALE_KEYS_URL)"><KeyRound :size="15" aria-hidden="true" />{{ t("获取密钥") }}<ArrowUpRight :size="14" aria-hidden="true" /></Button>
            </div>
            <Input id="tailscale-key" v-model="authKey" type="password" autocomplete="new-password"
              autocapitalize="none" :spellcheck="false" maxlength="251" :required="!snapshot?.configured"
              placeholder="tskey-auth-…" aria-describedby="tailscale-key-note" />
            <p id="tailscale-key-note" class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ t(snapshot?.configured ? "留空保留当前登录。新密钥不会自动切换已登录账号。" : "使用你账号生成的 Auth key，不要使用 API access token。") }}</p>
          </div>
          <details class="border-t border-[var(--mn-border)] pt-3">
            <summary class="min-h-10 cursor-pointer content-center text-sm text-[var(--mn-ink-muted)]">{{ t("高级选项") }}</summary>
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
    </section>
    <div v-if="message" :role="hasError ? 'alert' : 'status'" aria-live="polite" class="text-sm leading-6"
      :class="hasError ? 'text-[var(--mn-danger)]' : 'text-[var(--mn-ink-muted)]'">{{ message }}</div>
    <Button v-if="needsRestart" variant="ghost" size="sm" :disabled="locked" @click="retryRestart">{{ t("重试重启核心") }}</Button>
  </div>
</template>

<style scoped>
.tailscale-page { max-width: 64rem; margin-inline: auto; }
.tailscale-page :deep(button) { overflow-wrap: anywhere; }
.tailscale-device-name { max-width: 32rem; }
.tailscale-panel { padding: 1.25rem; border: 1px solid var(--mn-border); border-radius: var(--mn-radius-lg); background: var(--mn-surface); }
.tailscale-auth { border-top: 1px solid var(--mn-border); padding-top: 1rem; }
.tailscale-method-heading > div { flex: 1 1 16rem; min-width: 0; }
.tailscale-status-actions { border-top: 1px solid var(--mn-border); padding-top: .75rem; }
@media (max-width: 480px) {
  .tailscale-method-heading > button { width: 100%; }
  .tailscale-panel { padding: 1rem; }
}
</style>
