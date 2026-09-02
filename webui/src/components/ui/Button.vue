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
  "mn-button group relative inline-flex max-w-full items-center justify-center whitespace-nowrap rounded-[var(--mn-radius-md)] border text-[13px] font-semibold transition-[transform,color,background-color,border-color,opacity] duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--mn-ivory)] active:translate-y-px disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-55 disabled:active:translate-y-0",
  {
    variants: {
      variant: {
        default:
          "border-[var(--mn-cactus)] bg-[var(--mn-cactus)] text-[var(--mn-on-accent)] hover:border-[var(--mn-cactus-deep)] hover:bg-[var(--mn-cactus-deep)]",
        secondary:
          "border-[var(--mn-border-strong)] bg-[var(--mn-surface-sunken)] text-[var(--mn-ink)] hover:border-[var(--mn-cactus)] hover:text-[var(--mn-cactus-deep)]",
        outline:
          "border-[var(--mn-border-strong)] bg-transparent text-[var(--mn-ink)] hover:border-[var(--mn-cactus)] hover:bg-[color-mix(in_srgb,var(--mn-cactus)_9%,transparent)]",
        ghost:
          "border-transparent bg-transparent text-[var(--mn-ink-muted)] hover:border-[var(--mn-border)] hover:bg-[var(--mn-surface-sunken)] hover:text-[var(--mn-ink)]",
        destructive:
          "border-[var(--mn-danger)] bg-[var(--mn-danger)] text-[var(--mn-on-danger)] hover:brightness-110",
      },
      size: {
        sm: "min-h-11 px-3.5",
        md: "min-h-11 px-4",
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
    :aria-busy="loading ? 'true' : undefined"
  >
    <span class="inline-flex min-w-0 items-center justify-center gap-2">
      <Loader2 v-if="loading" class="shrink-0 motion-safe:animate-spin" :size="size === 'sm' ? 14 : 16" aria-hidden="true" />
      <slot />
    </span>
  </button>
</template>
