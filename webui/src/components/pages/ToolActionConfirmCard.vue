<script setup lang="ts">
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
    :title="action.title"
    :detail="action.detail"
    :command="action.command"
    :loading="loading"
    @cancel="$emit('cancel')"
    @confirm="$emit('confirm')"
  />
</template>
