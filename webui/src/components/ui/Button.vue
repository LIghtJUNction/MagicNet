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
  "group inline-flex max-w-full items-center justify-center gap-2 whitespace-nowrap rounded-full text-sm font-semibold transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/70 focus-visible:ring-offset-2 focus-visible:ring-offset-[#070809] active:scale-[0.975] disabled:pointer-events-none disabled:cursor-progress disabled:opacity-45 disabled:active:scale-100",
  {
    variants: {
      variant: {
        default:
          "bg-gradient-to-r from-emerald-300 to-cyan-300 text-[#06110e] shadow-[inset_0_1px_0_rgba(255,255,255,0.55),0_10px_30px_rgba(52,211,153,0.12)] hover:from-emerald-200 hover:to-cyan-200",
        secondary:
          "bg-white/[0.08] text-zinc-50 shadow-[inset_0_1px_0_rgba(255,255,255,0.08),inset_0_0_0_1px_rgba(255,255,255,0.06)] hover:bg-white/[0.12]",
        outline:
          "bg-[#0b0c0e] text-zinc-200 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.12),inset_0_1px_0_rgba(255,255,255,0.05)] hover:bg-white/[0.07] hover:text-white",
        ghost: "bg-transparent text-zinc-300 hover:bg-white/[0.07] hover:text-white",
        destructive:
          "bg-gradient-to-r from-rose-500 to-red-400 text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.25)] hover:from-rose-400 hover:to-red-300",
      },
      size: {
        sm: "min-h-[49px] px-4",
        md: "min-h-[49px] px-5",
        icon: "size-[49px] shrink-0 p-0",
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
    <Loader2 v-if="loading" class="motion-safe:animate-spin" :size="16" />
    <slot />
  </button>
</template>
