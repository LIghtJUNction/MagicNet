<script setup lang="ts">
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
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
  <Card class="border-amber-500/40 bg-amber-500/5">
    <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
      <div class="min-w-0">
        <h3 class="text-sm font-semibold text-amber-100">{{ action.title }}</h3>
        <p class="mt-1 text-sm leading-6 text-amber-100/75">{{ action.detail }}</p>
        <code class="mt-2 block break-all rounded-md bg-black/50 px-3 py-2 text-xs text-amber-50">{{ action.command }}</code>
      </div>
      <div class="flex flex-wrap gap-2">
        <Button variant="outline" @click="$emit('cancel')">取消</Button>
        <Button :loading="loading" @click="$emit('confirm')">确认执行</Button>
      </div>
    </div>
  </Card>
</template>
