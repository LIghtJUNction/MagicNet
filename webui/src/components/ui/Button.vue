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
  "group inline-flex max-w-full items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-semibold transition-[transform,color,background-color,opacity,box-shadow] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--mn-ivory)] active:scale-[0.975] disabled:pointer-events-none disabled:cursor-progress disabled:opacity-45 disabled:active:scale-100",
  {
    variants: {
      variant: {
        default:
          "bg-[var(--mn-cactus)] text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_10%,transparent)] hover:bg-[var(--mn-cactus-deep)]",
        secondary:
          "bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] text-[var(--mn-ink)] shadow-[inset_0_0_0_1px_var(--mn-border)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)]",
        outline:
          "bg-[var(--mn-carrier)] text-[var(--mn-ink-soft)] shadow-[inset_0_0_0_1px_var(--mn-border-strong)] hover:bg-[var(--mn-carrier-deep)] hover:text-[var(--mn-ink)]",
        ghost:
          "bg-transparent text-[var(--mn-ink-muted)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] hover:text-[var(--mn-ink)]",
        destructive:
          "bg-[var(--mn-clay)] text-[var(--mn-ivory)] shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_12%,transparent)] hover:brightness-105",
      },
      size: {
        sm: "min-h-11 px-4",
        md: "min-h-11 px-5",
        icon: "size-11 shrink-0 p-0",
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
