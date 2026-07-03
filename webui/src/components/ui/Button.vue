<script setup lang="ts">
import { Loader2 } from "lucide-vue-next";
import { cva } from "class-variance-authority";
import { computed } from "vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });

const props = withDefaults(
  defineProps<{
    variant?: "default" | "secondary" | "outline" | "ghost" | "destructive";
    size?: "sm" | "md" | "icon";
    loading?: boolean;
    disabled?: boolean;
    type?: "button" | "submit" | "reset";
    class?: string;
  }>(),
  {
    variant: "default",
    size: "md",
    loading: false,
    disabled: false,
    type: "button",
  },
);

const buttonVariants = cva(
  "inline-flex max-w-full items-center justify-center gap-2 whitespace-nowrap rounded-md border border-transparent text-sm font-semibold transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-lime-400/70 disabled:pointer-events-none disabled:cursor-progress disabled:opacity-55",
  {
    variants: {
      variant: {
        default: "bg-lime-300 text-zinc-950 hover:bg-lime-200",
        secondary: "bg-zinc-800/90 text-zinc-50 hover:bg-zinc-700",
        outline:
          "border-zinc-700/90 bg-[#151511] text-zinc-100 hover:bg-zinc-800",
        ghost: "bg-transparent text-zinc-100 hover:bg-zinc-800/70",
        destructive: "bg-red-500 text-white hover:bg-red-400",
      },
      size: {
        sm: "h-9 px-3",
        md: "h-10 px-4",
        icon: "size-10",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "md",
    },
  },
);

const classes = computed(() =>
  cn(buttonVariants({ variant: props.variant, size: props.size }), props.class),
);
</script>

<template>
  <button
    v-bind="$attrs"
    :type="type"
    :class="classes"
    :disabled="loading || disabled"
  >
    <Loader2 v-if="loading" class="animate-spin" :size="16" />
    <slot />
  </button>
</template>
