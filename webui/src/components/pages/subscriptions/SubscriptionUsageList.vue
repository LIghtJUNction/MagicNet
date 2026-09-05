<script setup lang="ts">
import { FileText, Globe2 } from "lucide-vue-next";
import type { SubscriptionUsageRow } from "@/composables/subscriptionUsage";

defineProps<{
  rows: SubscriptionUsageRow[];
  local: boolean;
}>();
</script>

<template>
  <section class="subscription-usage" aria-label="订阅用量">
    <div v-if="local" class="local-source">
      <FileText :size="22" aria-hidden="true" />
      <div>
        <h3>本地订阅文件</h3>
        <p>已从文件导入。流量额度与到期时间需向服务商查询。</p>
      </div>
    </div>
    <article v-for="row in rows" v-else :key="row.id" class="usage-source" :data-tone="row.tone">
      <header class="usage-heading">
        <div class="source-identity">
          <Globe2 :size="20" aria-hidden="true" />
          <div class="source-name">
            <h3>{{ row.hostname || row.name }}</h3>
            <span>{{ row.name }}</span>
          </div>
        </div>
        <span class="source-state" :data-state="row.state">{{ row.stateLabel }}</span>
      </header>

      <div class="quota-heading">
        <div class="remaining-quota">
          <span class="usage-label">剩余流量</span>
          <strong>{{ row.remainingLabel }}</strong>
        </div>
        <div class="used-quota">
          <span>已用 <strong>{{ row.usedLabel }}</strong></span>
          <span>总额度 <strong>{{ row.totalLabel }}</strong></span>
        </div>
      </div>
      <progress
        v-if="row.progressPercent !== null"
        class="quota-progress"
        max="100"
        :value="row.progressPercent"
        :aria-label="`${row.hostname || row.name} 已用流量比例`"
      />
      <p v-else class="quota-unavailable">服务商未提供完整的流量额度信息</p>

      <footer class="usage-dates">
        <div>
          <span class="usage-label">到期时间</span>
          <span class="expiry-value">{{ row.expiryLabel }}</span>
          <span v-if="row.daysRemaining !== null && row.expiryHint" class="expiry-hint">{{ row.expiryHint }}</span>
        </div>
        <div class="last-sync">
          <span class="usage-label">最近同步</span>
          <span>{{ row.updatedLabel }}</span>
          <span v-if="row.state === 'cached'" class="cached-note">上次成功获取的数据</span>
        </div>
      </footer>
    </article>
  </section>
</template>

<style scoped>
.subscription-usage { min-width: 0; }
.usage-source { min-width: 0; padding: 26px 0; border-bottom: 1px solid var(--mn-border); }
.usage-source:first-child { padding-top: 8px; }
.usage-source:last-child { border-bottom: 0; }
.usage-heading, .source-identity, .quota-heading { display: flex; align-items: center; gap: 16px; min-width: 0; }
.usage-heading, .quota-heading { justify-content: space-between; }
.source-identity > svg { flex-shrink: 0; color: var(--mn-ink-muted); }
.source-name { min-width: 0; }
.source-name h3, .local-source h3 { margin: 0; font-size: 1rem; font-weight: 600; line-height: 1.5; overflow-wrap: anywhere; }
.source-name > span, .source-state { font-size: .8125rem; color: var(--mn-ink-muted); }
.source-state { flex-shrink: 0; }
.source-state[data-state="cached"], .cached-note { color: var(--mn-warning); }
.quota-heading { align-items: flex-end; margin-top: 24px; }
.remaining-quota, .used-quota { display: grid; gap: 5px; }
.usage-label { color: var(--mn-ink-muted); font-size: .8125rem; }
.remaining-quota > strong { font-size: clamp(1.65rem, 6vw, 2.1rem); font-weight: 500; letter-spacing: -.035em; line-height: 1.2; font-variant-numeric: tabular-nums; }
.used-quota { text-align: right; font-size: .8125rem; color: var(--mn-ink-muted); }
.used-quota strong { margin-left: 6px; font-weight: 500; color: var(--mn-ink-soft); font-variant-numeric: tabular-nums; }
.quota-progress { display: block; appearance: none; width: 100%; height: 4px; margin-top: 15px; border: 0; border-radius: 2px; overflow: hidden; background: var(--mn-carrier); color: var(--mn-ink); }
.quota-progress::-webkit-progress-bar { background: var(--mn-carrier); border-radius: 2px; }
.quota-progress::-webkit-progress-value { background: var(--mn-ink-soft); border-radius: 2px; }
.quota-progress::-moz-progress-bar { background: var(--mn-ink-soft); border-radius: 2px; }
[data-tone="warning"] .quota-progress::-webkit-progress-value { background: var(--mn-warning); }
[data-tone="danger"] .quota-progress::-webkit-progress-value { background: var(--mn-danger); }
[data-tone="warning"] .quota-progress::-moz-progress-bar { background: var(--mn-warning); }
[data-tone="danger"] .quota-progress::-moz-progress-bar { background: var(--mn-danger); }
.quota-unavailable { margin: 14px 0 0; font-size: .8125rem; color: var(--mn-ink-muted); }
.usage-dates { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 18px; font-size: .875rem; color: var(--mn-ink-soft); }
.usage-dates > div { display: flex; flex-wrap: wrap; align-content: start; gap: 3px 8px; min-width: 0; overflow-wrap: anywhere; }
.usage-dates .usage-label { flex-basis: 100%; }
.last-sync { justify-content: flex-end; text-align: right; }
.expiry-hint, .cached-note { font-size: .8125rem; }
.expiry-hint { color: var(--mn-ink-muted); }
[data-tone="danger"] .expiry-hint { color: var(--mn-danger); }
[data-tone="warning"] .expiry-hint { color: var(--mn-warning); }
.local-source { display: flex; gap: 16px; align-items: flex-start; padding: 24px 0; }
.local-source > svg { flex-shrink: 0; color: var(--mn-ink-muted); }
.local-source p { margin: 8px 0 0; font-size: .875rem; line-height: 1.65; color: var(--mn-ink-muted); }
@media (max-width: 400px) {
  .usage-heading { flex-wrap: wrap; gap: 6px 12px; }
  .source-state { margin-left: 36px; }
  .quota-heading { flex-wrap: wrap; align-items: flex-start; }
  .used-quota { text-align: left; }
}
@media (forced-colors: active) {
  .quota-progress { appearance: auto; border: 1px solid CanvasText; }
}
</style>
