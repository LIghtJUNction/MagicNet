<script setup lang="ts">
import { t } from "@/i18n";
import PageHeader from "@/components/ui/PageHeader.vue";
import ProxyGroupsPanel from "./ProxyGroupsPanel.vue";
import NodeDelayPanel from "./NodeDelayPanel.vue";
</script>

<template>
  <div class="grid gap-6">
    <PageHeader :title="t('节点与代理组')" :description="t('为各类流量选择已有出口，或测速后切换节点。')" />
    <ProxyGroupsPanel />
    <details class="mn-disclosure"><summary>{{ t("节点测速") }}</summary><NodeDelayPanel /></details>
  </div>
</template>
