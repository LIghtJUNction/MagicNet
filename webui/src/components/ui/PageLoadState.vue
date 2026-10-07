<script setup lang="ts">
import { t } from "@/i18n";
import Button from "@/components/ui/Button.vue";

defineOptions({ inheritAttrs: false });
defineProps<{ failed?: boolean }>();
defineEmits<{ retry: [] }>();
</script>

<template>
  <div class="mn-page-load-state" :data-failed="failed || undefined">
    <template v-if="failed">
      <div role="alert">
        <h2>{{ t("页面未能加载") }}</h2>
        <p>{{ t("可以重试或切换页面。其他页面的未保存内容会保留。") }}</p>
      </div>
      <Button variant="outline" @click="$emit('retry')">{{ t("重新加载此页") }}</Button>
    </template>
    <p v-else role="status" aria-live="polite">{{ t("正在加载…") }}</p>
  </div>
</template>

<style scoped>
.mn-page-load-state { min-height: 180px; display: grid; align-content: start; justify-items: start; gap: 20px; padding-block: 24px; overflow-wrap: anywhere; }
h2 { margin: 0 0 8px; color: var(--mn-ink); font-size: 1.25rem; font-weight: 500; }
p { margin: 0; max-width: 44ch; color: var(--mn-ink-muted); font-size: .9375rem; line-height: 1.7; }
</style>
