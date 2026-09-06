<script setup lang="ts">
import { t } from "@/i18n";
import { ArrowRight, ChevronDown, ChevronUp, RefreshCw } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import {
  appPolicyModeSummary,
  appPolicyRouteDefinitions,
  type AppPolicyMode,
} from "./appPolicyRouteModel.ts";

const props = withDefaults(
  defineProps<{
    mode: AppPolicyMode;
    reapplyLoading?: boolean;
  }>(),
  { reapplyLoading: false },
);

defineEmits<{ reapply: [] }>();

const expanded = ref(false);
const modeSummary = computed(() => appPolicyModeSummary(props.mode));
</script>

<template>
  <section class="grid gap-3 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-surface-sunken)] p-3" aria-labelledby="app-route-guide-title">
    <div class="flex flex-wrap items-start justify-between gap-2">
      <div class="min-w-0">
        <h3 id="app-route-guide-title" class="text-sm font-semibold">{{ t('流量如何处理？') }}</h3>
        <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ modeSummary }}</p>
      </div>
      <Button
        variant="ghost"
        size="sm"
        :aria-expanded="expanded"
        aria-controls="app-route-guide-details"
        @click="expanded = !expanded"
      >
        <ChevronUp v-if="expanded" :size="15" />
        <ChevronDown v-else :size="15" />
        {{ expanded ? t('收起详细差异') : t('查看详细差异') }}
      </Button>
    </div>

    <div class="grid gap-px overflow-hidden rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-border)] lg:grid-cols-3">
      <article
        v-for="route in appPolicyRouteDefinitions"
        :key="route.id"
        class="grid min-w-0 gap-2 bg-[var(--mn-surface-raised)] p-3"
      >
        <strong class="text-sm">{{ route.label }}</strong>
        <div class="flex min-w-0 flex-wrap items-center gap-1 text-xs text-[var(--mn-ink-soft)]" :aria-label="t('{value} 流量路径：{value2}', { value: route.label, value2: route.steps.map((step) => t(step)).join(t(' 到 ')) })">
          <template v-for="(step, index) in route.steps" :key="`${route.id}-${step}`">
            <span class="rounded border border-[var(--mn-border)] bg-[var(--mn-surface-sunken)] px-1.5 py-1 font-mono">{{ t(step) }}</span>
            <ArrowRight v-if="index < route.steps.length - 1" class="shrink-0 text-[var(--mn-ink-faint)]" :size="13" aria-hidden="true" />
          </template>
        </div>
        <span class="text-xs text-[var(--mn-ink-muted)]">DNS：{{ t(route.dnsShort) }}</span>
        <div v-if="expanded" class="grid gap-1 border-t border-[var(--mn-border)] pt-2 text-xs leading-5 text-[var(--mn-ink-muted)]">
          <p><strong class="text-[var(--mn-ink-soft)]">{{ t('数据：') }}</strong>{{ t(route.traffic) }}</p>
          <p><strong class="text-[var(--mn-ink-soft)]">DNS：</strong>{{ t(route.dns) }}</p>
          <p><strong class="text-[var(--mn-ink-soft)]">{{ t('适合：') }}</strong>{{ t(route.useCase) }}</p>
        </div>
      </article>
    </div>

    <div v-show="expanded" id="app-route-guide-details" class="flex flex-wrap items-center justify-between gap-3 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-surface-raised)] p-3">
      <p class="min-w-0 flex-1 text-xs leading-5 text-[var(--mn-ink-muted)]">
        {{ t('名单修改会自动解析 UID、套用配置并重启当前核心。只有应用重装、新增工作资料／Android 用户或 UID 改变后，才需要手动重新解析。') }}
      </p>
      <Button variant="outline" size="sm" :loading="reapplyLoading" @click="$emit('reapply')">
        <RefreshCw :size="15" />{{ t('重新解析 App UID') }}
      </Button>
    </div>
  </section>
</template>
