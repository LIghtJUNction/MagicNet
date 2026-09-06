<script setup lang="ts">
import { t } from "@/i18n";
import { X } from "lucide-vue-next";
import { computed } from "vue";
import { cn } from "@/lib/utils";

const props = withDefaults(
  defineProps<{
    disabled?: boolean;
    title?: string;
    removeLabel?: string;
    variant?: "default" | "soft" | "dashed";
    removeVariant?: "default" | "danger" | "restore" | "ghost";
    class?: string;
  }>(),
  {
    variant: "default",
    removeVariant: "default",
  },
);

const emit = defineEmits<{
  remove: [event: MouseEvent];
}>();

const tagClass = computed(() =>
  cn(
    "mn-tag",
    {
      default: "",
      soft: "mn-tag-soft",
      dashed: "mn-tag-dashed",
    }[props.variant],
    props.class,
  ),
);

const removeClass = computed(() =>
  cn("mn-tag-remove", {
    default: "",
    danger: "mn-tag-remove-danger",
    restore: "mn-tag-remove-restore",
    ghost: "mn-tag-remove-ghost",
  }[props.removeVariant]),
);
</script>

<template>
  <span :class="tagClass">
    <span class="min-w-0 break-all"><slot /></span>
    <button
      :class="removeClass"
      :disabled="disabled"
      :title="title ? t(title) : undefined"
      :aria-label="t(removeLabel || title || '移除')"
      type="button"
      @click="emit('remove', $event)"
    >
      <slot name="icon">
        <X :size="14" />
      </slot>
    </button>
  </span>
</template>
