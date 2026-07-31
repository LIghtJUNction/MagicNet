<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() =>
  cn(
    "mn-field min-h-11 w-full rounded-[0.85rem] px-3.5 py-2.5 outline-none transition-[color,background-color,box-shadow] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)]",
    props.class,
  ),
);
</script>

<template>
  <input v-model="model" :class="classes" v-bind="$attrs" />
</template>
