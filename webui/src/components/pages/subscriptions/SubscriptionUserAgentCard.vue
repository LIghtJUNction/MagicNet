<script setup lang="ts">
import { Save, ShieldCheck } from "lucide-vue-next";
import { computed, ref, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { bytesToBase64, execFailed } from "@/utils";
import { subscriptionUserAgentPresets } from "../subscriptionUserAgent";

const props = defineProps<{
  configured: boolean;
}>();

const { state, runCli, startBackgroundCli, refreshSubs } = useMagicNet();
const { isRunning, withAction } = useActionLock();

const userAgentText = ref("");
const userAgentDirty = ref(false);

const normalizedUserAgent = computed(() => userAgentText.value.trim());
const userAgentBytes = computed(() => new TextEncoder().encode(normalizedUserAgent.value).length);
const userAgentError = computed(() => {
  if (/[\u0000-\u001f\u007f]/.test(normalizedUserAgent.value)) return "User-Agent 不能包含控制字符。";
  if (userAgentBytes.value > 256) return "User-Agent 最多 256 字节。";
  return "";
});
const userAgentChanged = computed(() => normalizedUserAgent.value !== state.subscriptions.userAgent);

watch(() => state.subscriptions.userAgent, (value) => {
  if (!userAgentDirty.value || value === normalizedUserAgent.value) {
    userAgentText.value = value;
    userAgentDirty.value = false;
  }
}, { immediate: true });

function selectUserAgent(value: string): void {
  userAgentText.value = value;
  userAgentDirty.value = true;
}

async function persistUserAgent(): Promise<boolean> {
  if (userAgentError.value) {
    state.output = userAgentError.value;
    return false;
  }
  if (!userAgentChanged.value) return true;
  const value = normalizedUserAgent.value;
  const encoded = value
    ? bytesToBase64(new TextEncoder().encode(value))
    : "";
  const command = value
    ? `sub user-agent set ${encoded}`
    : "sub user-agent clear";
  const result = await runCli(command, value ? "保存订阅 User-Agent" : "清除订阅 User-Agent");
  if (execFailed(result)) return false;
  if (!(await refreshSubs(true))) return false;
  userAgentDirty.value = false;
  return true;
}

async function saveUserAgent(): Promise<void> {
  if (!userAgentChanged.value || userAgentError.value) return;
  await withAction("save-user-agent", async () => {
    if (!(await persistUserAgent())) return;
    const value = normalizedUserAgent.value;
    if (props.configured) {
      await startBackgroundCli(
        "sub update-all",
        value ? "使用自定义 User-Agent 刷新订阅" : "使用默认 User-Agent 刷新订阅",
        "",
        "sub update-all",
      );
    } else {
      state.output = value
        ? "自定义 User-Agent 已保存，将在首次拉取订阅时使用。"
        : "自定义 User-Agent 已清除，后续拉取将使用下载器默认值。";
    }
  });
}

defineExpose({
  persistUserAgent,
  userAgentChanged,
  userAgentError,
});
</script>

<template>
  <Card>
    <div class="flex items-start gap-3">
      <ShieldCheck :size="18" class="mt-0.5 shrink-0 text-[var(--mn-ink-muted)]" />
      <div class="min-w-0">
        <h3 class="mt-1 text-base font-semibold text-[var(--mn-ink)]">订阅 User-Agent</h3>
      </div>
    </div>

    <div class="mt-4 flex flex-wrap gap-2" aria-label="User-Agent 预设">
      <button
        v-for="preset in subscriptionUserAgentPresets"
        :key="preset.label"
        type="button"
        :aria-pressed="normalizedUserAgent === preset.value"
        :class="[
          'min-h-11 rounded-sm px-3 text-sm ring-1 transition-colors',
          normalizedUserAgent === preset.value
            ? 'bg-[var(--mn-ink)] text-[var(--mn-surface-raised)] ring-[var(--mn-ink)]'
            : 'bg-[var(--mn-ivory)] text-[var(--mn-ink-muted)] ring-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)]',
        ]"
        @click="selectUserAgent(preset.value)"
      >
        {{ preset.label }}
      </button>
    </div>

    <label class="mt-4 block text-xs font-medium text-[var(--mn-ink-muted)]" for="subscription-user-agent">自定义值</label>
    <Input
      id="subscription-user-agent"
      v-model="userAgentText"
      class="mt-2"
      autocomplete="off"
      spellcheck="false"
      placeholder="留空使用下载器默认值"
      aria-describedby="subscription-user-agent-help"
      @input="userAgentDirty = true"
    />
    <p id="subscription-user-agent-help" class="mt-2 text-xs leading-5" :class="userAgentError ? 'text-[var(--mn-danger)]' : 'text-[var(--mn-ink-muted)]'">
      {{ userAgentError || `可填写 sing-box、mihomo 或服务商要求的完整值；${userAgentBytes}/256 字节。` }}
    </p>

    <Button
      class="mt-4 w-full"
      :disabled="!userAgentChanged || Boolean(userAgentError)"
      :loading="isRunning('save-user-agent')"
      @click="saveUserAgent"
    >
      <Save :size="16" />{{ configured ? '保存并刷新订阅' : '保存 User-Agent' }}
    </Button>
  </Card>
</template>
