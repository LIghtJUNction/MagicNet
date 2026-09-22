<script setup lang="ts">
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref, watch } from "vue";
import { ArrowUpRight, Globe, LogOut, Network, Power, RefreshCw } from "lucide-vue-next";
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { TAILSCALE_MACHINES_URL } from "./tailscaleSetup";
import { parseTailscaleControl, transitionConfirmed, type TailscaleAction, type TailscaleControlState } from "./tailscaleControl";

const props = defineProps<{ disabled: boolean; online: boolean; hostname: string; refreshKey: string }>();
const emit = defineEmits<{ busy: [value: boolean]; changed: []; observed: [value: TailscaleControlState | null] }>();
const { state, runPrivateCli, shellQuote, openExternal, refreshStatus } = useMagicNet();
const control = ref<TailscaleControlState | null>(null);
const loading = ref(false);
const pending = ref(false);
const confirmLogout = ref(false);
const message = ref("");
const failed = ref(false);
let active = true;
let generation = 0;
const locked = computed(() => props.disabled || loading.value || pending.value || state.busy || !state.hasKsu);
const canLogout = computed(() => control.value && (control.value.enabled || control.value.resumable
  || control.value.logout_pending || control.value.local_identity !== false));
const connected = computed(() => control.value?.enabled && control.value.core === "running" && props.online);
const title = computed(() => {
  if (!control.value) return "连接状态未确认";
  if (control.value.logout_pending) return "已禁用，登出待完成";
  if (connected.value) return "已连接并在线";
  if (control.value.enabled) return "Tailscale 已启用";
  return control.value.resumable ? "Tailscale 已暂停" : "Tailscale 未启用";
});

async function fetchControl(): Promise<TailscaleControlState> {
  const result = await runPrivateCli("--json tailscale status", t("读取连接状态"), "--json tailscale status");
  if (!result.ok) throw new Error("tailscale.status_failed");
  return parseTailscaleControl(result.stdout);
}

async function read(): Promise<void> {
  if (!active || pending.value || !state.hasKsu) return;
  const current = ++generation;
  loading.value = true;
  try {
    const result = await fetchControl();
    if (active && current === generation) { control.value = result; emit("observed", result); }
  } catch {
    if (active && current === generation) { control.value = null; emit("observed", null); }
  } finally { if (current === generation) loading.value = false; }
}

async function change(action: TailscaleAction): Promise<void> {
  if (locked.value || !control.value || (action === "logout" && !confirmLogout.value)) return;
  if (action === "enable" && (!control.value.resumable || control.value.logout_pending)) return;
  const revision = control.value.revision;
  const current = ++generation;
  pending.value = true;
  confirmLogout.value = false;
  message.value = "";
  failed.value = false;
  emit("busy", true);
  try {
    const outcome = await runPrivateCli(`tailscale ${action} ${shellQuote(revision)}`, t("更新 Tailscale 连接"), `tailscale ${action} [revision]`);
    const observed = await fetchControl();
    if (!active || current !== generation) return;
    control.value = observed;
    emit("observed", observed);
    failed.value = !outcome.ok || !transitionConfirmed(action, observed);
    message.value = failed.value ? t("操作未完整完成，已重新读取状态。请检查诊断后重试。")
      : action === "logout" ? t("已登出此设备。再次连接需要重新授权。")
        : action === "disable" ? t("已禁用 Tailscale，登录信息保留。")
          : observed.core === "stopped" ? t("已恢复配置，核心保持关闭。") : t("已恢复配置，正在检查连接。") ;
    await refreshStatus(undefined, false);
  } catch {
    if (active && current === generation) {
      control.value = null;
      emit("observed", null);
      failed.value = true;
      message.value = t("未能确认操作结果，请重新读取状态。不要重复授权。");
    }
  } finally {
    pending.value = false;
    emit("busy", false);
    if (active && current === generation) emit("changed");
  }
}

function deactivate(): void {
  active = false;
  generation++;
  loading.value = false;
  confirmLogout.value = false;
}
onMounted(() => { void read(); });
onActivated(() => { active = true; void read(); });
onDeactivated(deactivate);
onUnmounted(deactivate);
watch(() => props.refreshKey, () => { void read(); });
watch(() => props.disabled, (disabled) => { if (!disabled) void read(); });
</script>

<template>
  <section class="tailscale-control" :class="{ 'is-connected': connected }" aria-label="Tailscale">
    <div class="control-heading">
      <div class="control-icon"><Network :size="23" aria-hidden="true" /></div>
      <div class="control-identity">
        <div class="control-status"><StatusDot :tone="connected ? 'ok' : control?.enabled ? 'current' : 'unknown'" /><h2>{{ t(title) }}</h2></div>
        <p v-if="control?.enabled && hostname" class="control-host">{{ hostname }}</p>
        <p v-else>{{ t(control?.resumable ? "登录信息保留，随时可以恢复。" : "按需连接你的设备。") }}</p>
      </div>
      <Button v-if="control && (control.enabled || control.resumable)" :variant="control.enabled ? 'outline' : 'default'"
        :disabled="locked || control.logout_pending" :loading="pending" class="control-toggle"
        @click="change(control.enabled ? 'disable' : 'enable')">
        <Power :size="16" aria-hidden="true" />{{ t(control.enabled ? "禁用 Tailscale" : "恢复连接") }}
      </Button>
    </div>
    <p v-if="control?.enabled" class="control-note">{{ t("禁用只暂停连接，不会登出账号。") }}</p>
    <p v-if="control?.core === 'stopped'" class="control-note">{{ t("核心当前关闭，修改不会自动启动核心。") }}</p>
    <p v-if="control?.logout_pending" class="control-warning" role="alert">{{ t("本机身份清理尚未完成，不能恢复旧登录。请重试登出。") }}</p>
    <div class="control-actions">
      <Button variant="ghost" size="sm" :disabled="locked" :loading="loading" @click="read">
        <RefreshCw :size="14" aria-hidden="true" />{{ t("读取连接状态") }}
      </Button>
      <Button variant="ghost" size="sm" @click="openExternal(TAILSCALE_MACHINES_URL)">
        <Globe :size="14" aria-hidden="true" />{{ t("设备后台") }}<ArrowUpRight :size="12" aria-hidden="true" />
      </Button>
      <Button v-if="canLogout" variant="ghost" size="sm" class="control-logout" :disabled="locked" @click="confirmLogout = true">
        <LogOut :size="14" aria-hidden="true" />{{ t("登出此设备") }}
      </Button>
    </div>
    <ConfirmPanel v-if="confirmLogout" title="登出此设备？"
      detail="停止本机 Tailscale 并清除本机登录信息。云端设备记录保留，可在设备后台删除。"
      confirm-label="确认登出" confirm-variant="destructive" :loading="pending"
      @cancel="confirmLogout = false" @confirm="change('logout')" />
    <p v-if="message" :role="failed ? 'alert' : 'status'" class="control-message" :class="{ 'control-warning': failed }">{{ message }}</p>
  </section>
</template>

<style scoped>
.tailscale-control { padding: 1.5rem; border: 1px solid var(--mn-border); border-radius: var(--mn-radius-lg); background: var(--mn-surface-raised); }
.control-heading { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.control-icon { display: grid; place-items: center; width: 3rem; height: 3rem; flex: 0 0 auto; border-radius: 1rem; background: var(--mn-surface-sunken); color: var(--mn-ink-muted); }
.is-connected .control-icon { color: var(--mn-primary); background: color-mix(in srgb, var(--mn-primary) 10%, var(--mn-surface-raised)); }
.control-identity { min-width: 0; flex: 1 1 10rem; }
.control-status { display: flex; align-items: center; gap: .5rem; }
.control-status h2 { margin: 0; font-size: 1rem; font-weight: 600; overflow-wrap: anywhere; }
.control-identity p, .control-note { margin-top: .4rem; font-size: .8125rem; line-height: 1.7; color: var(--mn-ink-muted); overflow-wrap: anywhere; }
.control-host { font-family: var(--mn-font-mono, monospace); }
.control-toggle { margin-left: auto; }
.control-note { margin-top: 1rem; }
.control-actions { display: flex; align-items: center; flex-wrap: wrap; gap: .25rem; margin-top: 1.25rem; padding-top: .75rem; border-top: 1px solid var(--mn-border); }
.control-logout { margin-left: auto; color: var(--mn-danger); }
.control-message, .control-warning { margin-top: .75rem; font-size: .8125rem; line-height: 1.7; }
.control-warning { color: var(--mn-danger); }
@media (max-width: 480px) {
  .tailscale-control { padding: 1rem; }
  .control-toggle { width: 100%; margin-top: .25rem; }
  .control-actions { gap: .25rem; }
  .control-logout { margin-left: 0; }
}
</style>
