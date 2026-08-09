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
  "group inline-flex max-w-full items-center justify-center gap-2 whitespace-nowrap rounded-[0.85rem] text-sm font-semibold tracking-[-0.01em] transition-[transform,color,background-color,opacity,box-shadow,filter] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--mn-ivory)] active:scale-[0.97] active:duration-75 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100",
  {
    variants: {
      variant: {
        default:
          "bg-[var(--mn-cactus)] text-[var(--mn-on-accent)] shadow-[inset_0_1px_0_color-mix(in_srgb,#fff_45%,transparent),inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_12%,transparent),0_4px_12px_color-mix(in_srgb,var(--mn-cactus-deep)_18%,transparent)] hover:bg-[color-mix(in_srgb,var(--mn-cactus)_72%,var(--mn-cactus-deep))] active:shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_14%,transparent)]",
        secondary:
          "bg-[color-mix(in_srgb,var(--mn-ink)_7%,transparent)] text-[var(--mn-ink)] shadow-[inset_0_1px_0_var(--mn-material-edge),inset_0_0_0_1px_var(--mn-border)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_11%,transparent)]",
        outline:
          "bg-[var(--mn-material-heavy)] text-[var(--mn-ink)] shadow-[inset_0_1px_0_var(--mn-material-edge),inset_0_0_0_1px_var(--mn-border),0_2px_7px_color-mix(in_srgb,var(--mn-ink)_5%,transparent)] hover:bg-[color-mix(in_srgb,var(--mn-carrier-deep)_72%,var(--mn-material-heavy))]",
        ghost:
          "bg-transparent text-[var(--mn-ink-soft)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_8%,transparent)] hover:text-[var(--mn-ink)]",
        destructive:
          "bg-[var(--mn-clay)] text-[var(--mn-on-accent)] shadow-[inset_0_1px_0_color-mix(in_srgb,#fff_28%,transparent),inset_0_0_0_1px_color-mix(in_srgb,var(--mn-ink)_12%,transparent),0_4px_12px_color-mix(in_srgb,var(--mn-clay)_20%,transparent)] hover:brightness-105",
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
