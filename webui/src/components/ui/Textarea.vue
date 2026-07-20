<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() => cn("min-h-28 w-full resize-y rounded-md bg-[#08090b] px-3.5 py-3 text-zinc-50 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.09),inset_0_0_0_5px_rgba(255,255,255,0.018)] outline-none transition-[color,background-color,box-shadow] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] placeholder:text-zinc-600 focus:bg-[#0b0d0f] focus:shadow-[inset_0_0_0_1px_rgba(52,211,153,0.65),inset_0_0_0_5px_rgba(52,211,153,0.055),0_0_0_3px_rgba(52,211,153,0.1)]", props.class));
</script>

<template>
  <textarea v-model="model" :class="classes" v-bind="$attrs" />
</template>
