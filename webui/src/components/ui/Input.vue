<script setup lang="ts">
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps<{ class?: string }>();
const model = defineModel<string>();
const classes = computed(() =>
  cn(
    "mn-field min-h-12 w-full rounded-[var(--mn-radius-md)] px-3.5 py-2.5 outline-none transition-[color,background-color,border-color,box-shadow] duration-150 ease-out",
    props.class,
  ),
);
</script>

<template>
  <input v-model="model" :class="classes" v-bind="$attrs" />
</template>
