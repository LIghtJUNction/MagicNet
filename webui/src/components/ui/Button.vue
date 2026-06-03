<script setup lang="ts">
import { Loader2 } from "lucide-vue-next";
import { cva } from "class-variance-authority";
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(defineProps<{
  variant?: "default" | "secondary" | "outline" | "ghost" | "destructive";
  size?: "sm" | "md" | "icon";
  loading?: boolean;
  class?: string;
}>(), {
  variant: "default",
  size: "md",
  loading: false
});

const buttonVariants = cva(
  "inline-flex max-w-full items-center justify-center gap-2 whitespace-nowrap rounded-md border border-transparent text-sm font-semibold transition-colors disabled:pointer-events-none disabled:cursor-progress disabled:opacity-55",
  {
  variants: {
    variant: {
      default: "bg-zinc-50 text-zinc-950 hover:bg-zinc-200",
      secondary: "bg-zinc-800 text-zinc-50 hover:bg-zinc-700",
      outline: "border-zinc-800 bg-transparent text-zinc-50 hover:bg-zinc-900",
      ghost: "bg-transparent text-zinc-50 hover:bg-zinc-900",
      destructive: "bg-red-500 text-white hover:bg-red-400"
    },
    size: {
      sm: "h-9 px-3",
      md: "h-10 px-4",
      icon: "size-10"
    }
  },
  defaultVariants: {
    variant: "default",
    size: "md"
  }
}
);

const classes = computed(() => cn(buttonVariants({ variant: props.variant, size: props.size }), props.class));
</script>

<template>
  <button :class="classes" :disabled="loading || $attrs.disabled === true">
    <Loader2 v-if="loading" class="animate-spin" :size="16" />
    <slot />
  </button>
</template>
