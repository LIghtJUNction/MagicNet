<script setup lang="ts">
import { t } from "@/i18n";
</script>

<template>
  <details
    class="mn-chrome mt-5 rounded-[var(--mn-radius-md)] p-1.5 text-sm text-[var(--mn-ink-muted)]"
    :aria-label="t('MagicNet 开源支持说明')"
  >
    <summary
      class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded-[var(--mn-radius-md)] px-4 py-3 text-left text-[var(--mn-ink)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--mn-focus)]"
    >
      <span class="font-semibold">{{ t("支持项目") }}</span>
      <span class="shrink-0 text-xs text-[var(--mn-ink-muted)]">{{ t("展开") }}</span>
    </summary>

    <div class="border-t border-[var(--mn-border)] px-4 py-4 sm:px-5">
      <div class="max-w-3xl space-y-3 leading-6">
        <p>{{ t("MagicNet 由个人维护。提交 Issue、Pull Request、建议或测试结果，都能直接帮助项目。") }}</p>
        <p>{{ t("项目也提供独立的 AI API 服务。是否使用完全自愿，不使用不会影响 MagicNet 的任何功能；服务收入会用于项目维护。") }}</p>
        <a
          class="inline-flex min-h-11 items-center font-medium text-[var(--mn-primary-strong)] underline underline-offset-4"
          href="https://api.lmm.best/"
          target="_blank"
          rel="noopener noreferrer"
        >{{ t("了解外部服务") }}</a>
      </div>
    </div>
  </details>
</template>
