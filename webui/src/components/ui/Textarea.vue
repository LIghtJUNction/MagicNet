<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() =>
  cn(
    "mn-field min-h-28 w-full resize-y rounded-[2px] px-3.5 py-3 outline-none transition-[color,background-color,border-color,box-shadow] duration-150 ease-out",
    props.class,
  ),
);
</script>

<template>
  <textarea v-model="model" :class="classes" v-bind="$attrs" />
</template>
