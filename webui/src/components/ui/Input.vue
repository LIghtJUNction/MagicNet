<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() => cn("min-h-12 w-full rounded-[1.25rem] bg-[#08090b] px-4 py-3 text-zinc-50 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.09),inset_0_0_0_5px_rgba(255,255,255,0.018)] outline-none transition-[color,background-color,box-shadow] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] placeholder:text-zinc-600 focus:bg-[#0b0d0f] focus:shadow-[inset_0_0_0_1px_rgba(103,232,249,0.7),inset_0_0_0_5px_rgba(52,211,153,0.06),0_0_0_3px_rgba(52,211,153,0.12)]", props.class));
</script>

<template>
  <input v-model="model" :class="classes" v-bind="$attrs" />
</template>
