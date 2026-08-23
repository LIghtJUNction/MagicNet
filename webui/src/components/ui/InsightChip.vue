<script setup lang="ts">
import { computed } from "vue";
import { statusChipClasses } from "@/lib/statusTone";
import { cn } from "@/lib/utils";

const props = withDefaults(
  defineProps<{
    label?: string;
    value?: string | number;
    tone?: string;
    class?: string;
  }>(),
  { tone: "neutral" },
);

const classes = computed(() =>
  cn("mn-insight-chip text-xs", statusChipClasses(props.tone), props.class),
);
</script>

<template>
  <span :class="classes">
    <slot>
      <template v-if="label != null">
        {{ label }}<template v-if="value != null">: <b class="font-medium">{{ value }}</b></template>
      </template>
    </slot>
  </span>
</template>
