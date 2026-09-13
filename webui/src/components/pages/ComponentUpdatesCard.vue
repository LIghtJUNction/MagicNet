<script setup lang="ts">
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue';
import { DownloadCloud, RefreshCw, Save } from 'lucide-vue-next';
import { t } from '@/i18n';
import Card from '@/components/ui/Card.vue';
import Button from '@/components/ui/Button.vue';
import { useMagicNet } from '@/composables/useMagicNet';
import { redactSensitiveText, execFailed } from '@/utils';
import { parseUpdateSnapshot, updateSettingsArgs, updateBytes, type UpdateSettings, type UpdateSnapshot } from './componentUpdates';

const { state, runPrivateCli, runCli, startBackgroundCli } = useMagicNet();
const snapshot = ref<UpdateSnapshot | null>(null);
const draft = ref<UpdateSettings>({ enabled: false, interval_hours: 24, wifi_only: true, auto_install: true });
const dirty = ref(false);
const saving = ref(false);
const reading = ref(false);
const error = ref('');
const confirmInstall = ref(false);
let timer: ReturnType<typeof setTimeout> | undefined;
let generation = 0;
let active = false;
const busy = computed(() => saving.value || ['checking', 'downloading', 'installing'].includes(snapshot.value?.phase ?? '')
  || (state.backgroundTask.args.startsWith('update ') && state.backgroundTask.status === 'running'));
const phaseLabel = computed(() => { const labels: Record<string, string> = {
  idle: t('尚未检查'), checking: t('正在检查组件'), available: t('有可用更新'), downloading: t('正在下载变化组件'),
  installing: t('正在暂存更新'), 'pending-reboot': t('已暂存，重启后生效'), 'up-to-date': t('组件已是最新'),
  'waiting-wifi': t('等待 Wi-Fi'), error: t('更新失败'),
}; return labels[snapshot.value?.phase ?? 'idle']; });
const sourceLabel = (source: string): string => { const labels: Record<string, string> = { installed: t('复用已安装'), cache: t('复用缓存'), pending: t('已暂存'), download: t('需要下载') }; return labels[source] ?? source; };
const when = (seconds: number): string => seconds ? new Date(seconds * 1000).toLocaleString() : '—';

async function refresh(token = generation): Promise<void> {
  if (reading.value) return;
  reading.value = true;
  try {
    const result = await runPrivateCli('update status', t('读取组件更新状态'), 'update status');
    if (token !== generation) return;
    if (!result.ok) throw new Error('unavailable');
    const next = parseUpdateSnapshot(result.stdout);
    snapshot.value = next;
    if (!dirty.value && !saving.value) draft.value = { ...next.settings };
    error.value = next.error ? redactSensitiveText(next.error).slice(0, 800) : '';
  } catch {
    if (token === generation) error.value = t('无法读取更新状态，请确认已安装支持智能更新的模块。');
  } finally { reading.value = false; }
}
function stop(): void { active = false; generation++; clearTimeout(timer); }
function begin(): void {
  if (active) return;
  active = true; const token = generation;
  async function poll(): Promise<void> {
    await refresh(token);
    if (token === generation) timer = setTimeout(poll, busy.value ? 2000 : 15000);
  }
  void poll();
}
onMounted(begin); onActivated(begin); onDeactivated(stop); onUnmounted(stop);
async function save(): Promise<void> {
  if (saving.value) return;
  let args: string;
  try { args = updateSettingsArgs(draft.value); } catch { error.value = t('检查间隔应为 1–168 小时。'); return; }
  saving.value = true;
  try {
    const result = await runCli(args, t('保存自动更新设置'));
    if (execFailed(result)) { error.value = t('自动更新设置未保存。'); return; }
    dirty.value = false;
  } finally { saving.value = false; }
  await refresh();
}
async function start(apply: boolean): Promise<void> {
  confirmInstall.value = false;
  await startBackgroundCli(apply ? 'update apply' : 'update check', apply ? t('安装组件更新') : t('检查组件更新'));
  stop(); begin();
}
</script>

<template>
  <Card class="grid gap-5" data-testid="component-updates">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div><h3 class="text-base font-semibold">{{ t('智能更新') }}</h3><p class="mt-1 text-sm opacity-70" role="status">{{ phaseLabel }}</p></div>
      <Button variant="outline" :disabled="busy" @click="start(false)"><RefreshCw :size="17" />{{ t('检查组件更新') }}</Button>
    </div>
    <div class="grid gap-3 sm:grid-cols-2">
      <label class="flex min-h-12 items-center gap-3"><input v-model="draft.enabled" type="checkbox" :disabled="saving" @change="dirty = true" />{{ t('定时自动更新') }}</label>
      <label class="flex min-h-12 items-center gap-3"><input v-model="draft.wifi_only" type="checkbox" :disabled="saving" @change="dirty = true" />{{ t('仅在 Wi-Fi 下自动更新') }}</label>
      <label class="flex min-h-12 items-center gap-3"><input v-model="draft.auto_install" type="checkbox" :disabled="saving" @change="dirty = true" />{{ t('自动下载并暂存安装') }}</label>
      <label class="flex flex-wrap items-center gap-3">{{ t('检查间隔（小时）') }}<input v-model.number="draft.interval_hours" type="number" min="1" max="168" step="1" class="min-h-12 w-24 rounded-lg border bg-transparent px-3" :disabled="saving" @input="dirty = true" /></label>
    </div>
    <div class="flex flex-wrap items-center justify-between gap-3">
      <p class="text-sm opacity-70">{{ t('不会强制重启。更新由模块管理器暂存，重启后生效。') }}</p>
      <Button variant="outline" :loading="saving" :disabled="!dirty || !snapshot" @click="save"><Save :size="17" />{{ t('保存自动更新设置') }}</Button>
    </div>
    <p v-if="snapshot" class="text-xs opacity-70">{{ t('上次检查') }}: {{ when(snapshot.last_check) }} · {{ t('下次检查') }}: {{ draft.enabled ? when(snapshot.next_check) : '—' }}</p>
    <template v-if="snapshot?.plan">
      <div class="grid grid-cols-2 gap-3 rounded-xl border p-4">
        <div><span class="text-xs opacity-70">{{ t('本次下载量') }}</span><p class="mt-1 text-lg font-semibold">{{ updateBytes(snapshot.plan.download_bytes) }}</p></div>
        <div><span class="text-xs opacity-70">{{ t('相较完整包节省') }}</span><p class="mt-1 text-lg font-semibold">{{ updateBytes(snapshot.plan.saved_bytes) }}</p></div>
      </div>
      <details class="rounded-xl border p-4">
        <summary class="cursor-pointer">{{ t('组件明细') }} · {{ snapshot.plan.version }}</summary>
        <div v-for="part in snapshot.plan.components" :key="part.id" class="mt-3 grid grid-cols-[minmax(0,1fr)_auto] gap-3 border-t pt-3 text-sm">
          <span class="break-all">{{ part.id }}</span><span class="text-right">{{ sourceLabel(part.source) }}<span v-if="part.bytes" class="block text-xs opacity-70">{{ updateBytes(part.bytes) }}</span></span>
        </div>
      </details>
      <Button v-if="snapshot.plan.needed" :disabled="busy" @click="confirmInstall = true"><DownloadCloud :size="17" />{{ t('安装组件更新') }}</Button>
    </template>
    <div v-if="confirmInstall" class="grid gap-3 rounded-xl border p-4" role="group" :aria-label="t('确认安装更新')">
      <p>{{ t('仅下载缺失或变化的组件，保留订阅和用户配置。确认暂存安装？') }}</p>
      <div class="flex gap-3"><Button :disabled="busy" @click="start(true)">{{ t('确认安装更新') }}</Button><Button variant="outline" @click="confirmInstall = false">{{ t('取消') }}</Button></div>
    </div>
    <p v-if="error" role="alert" class="break-words text-sm">{{ error }}</p>
  </Card>
</template>
