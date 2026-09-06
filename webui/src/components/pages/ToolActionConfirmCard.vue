<script setup lang="ts">
import { t } from "@/i18n";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import type { PendingToolAction } from "./toolActions";

defineProps<{
  action: PendingToolAction;
  loading: boolean;
}>();

defineEmits<{
  cancel: [];
  confirm: [];
}>();
</script>

<template>
  <ConfirmPanel
    :title="t(action.title)"
    :detail="t(action.detail)"
    :command="action.command"
    :loading="loading"
    @cancel="$emit('cancel')"
    @confirm="$emit('confirm')"
  />
</template>
