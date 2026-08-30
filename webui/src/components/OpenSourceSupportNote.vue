<template>
  <details
    class="mn-chrome mt-5 rounded-[var(--mn-radius-md)] p-1.5 text-sm text-[var(--mn-ink-muted)]"
    aria-label="MagicNet 开源支持说明"
  >
    <summary
      class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded-[var(--mn-radius-md)] bg-[color-mix(in_srgb,var(--mn-ink)_3%,transparent)] px-4 py-3 text-left text-[var(--mn-ink)] transition-[background-color,transform,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.99]"
    >
      <span class="min-w-0">
        <span class="mn-eyebrow mn-eyebrow-faint block tracking-[0.18em]">可选</span>
        <span class="mt-1 block text-sm font-semibold text-[var(--mn-ink)]">关于 MagicNet 的维护与支持</span>
      </span>
      <span
        class="shrink-0 rounded-full border border-[var(--mn-border)] bg-[var(--mn-carrier)] px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--mn-clay-ink)]"
      >
        展开
      </span>
    </summary>

    <div class="rounded-[var(--mn-radius-md)] bg-[var(--mn-carrier)] px-4 py-4 sm:px-5">
      <div class="max-w-3xl space-y-3">
        <p class="leading-6">
          如果你对 MagicNet 感兴趣，也许会想知道：这个项目一直由我个人持续维护。我是一名大学生，长期用自己的时间和精力处理真机兼容、TUN 链路、文档整理、用户反馈和问题排查。
        </p>
        <p class="leading-6">
          这些工作除了写代码，还包含长期测试、调试和反复验证。AI 辅助开发、持续调用、服务器开销和排障本身都会消耗真实的 Token、时间和资源。
        </p>
        <p class="leading-6">
          我不太想把它做成一段单纯的捐赠请求，所以开了一个 AI API 中转站：如果你刚好有实际使用需求，可以在那里购买 AI 使用额度，在满足自己需求的同时，也顺手支持 MagicNet 继续做开源维护。
          <a
            class="font-medium text-[var(--mn-sky-ink)] underline decoration-[color-mix(in_srgb,var(--mn-sky)_55%,transparent)] underline-offset-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))]"
            href="https://api.lmm.best/"
            target="_blank"
            rel="noopener noreferrer"
          >
            访问中转站
          </a>
        </p>
        <p class="leading-6">
          它是一个独立的外部服务，是否使用完全自愿，不使用也不会影响 MagicNet 的任何功能。其中一部分收入也会尽量继续投入到 MagicNet 这样的开源维护里。
        </p>
        <p class="leading-6">
          如果你不打算使用它，提交 Issue、Pull Request、建议，或者帮忙测试新版本，也都是很实际的支持。对愿意长期帮助项目的人，合适的时候我也会尽量提供一些使用额度回馈。
        </p>
      </div>
    </div>
  </details>
</template>
