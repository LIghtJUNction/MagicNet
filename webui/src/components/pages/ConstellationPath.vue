<script setup lang="ts">
import { computed } from "vue";
import { t } from "@/i18n";
import type { RuntimeState } from "@/types";
import { buildConstellation, type StarState } from "./constellationPath";

const props = defineProps<{ runtime: RuntimeState; hasDevice: boolean }>();

const model = computed(() => buildConstellation(props.runtime, props.hasDevice));
const summaryText = computed(() => ({
  flowing: t("流量经数据面进入 sing-box，按规则选择出口。实际联网请在诊断中确认。"),
  stopped: t("sing-box 已停止，MagicNet 当前没有接管流量。"),
  partial: t("路径部分就绪；虚线断开的位置就是需要检查的环节。"),
  unknown: t("状态未确认，路径不会按已接管显示。"),
}[model.value.summary]));

function stateText(state: StarState): string {
  return state === "ok" ? t("已就绪") : state === "off" ? t("未运行") : t("未确认");
}
</script>

<template>
  <figure class="mn-constellation" :data-summary="model.summary">
    <ol class="mn-constellation__path" :aria-label="t('流量路径')">
      <li
        v-for="(star, index) in model.stars"
        :key="star.key"
        class="mn-constellation__star"
        :data-state="star.state"
        :data-edge="index > 0 ? model.edges[index - 1] : undefined"
      >
        <span class="mn-constellation__mark" aria-hidden="true">
          <svg v-if="star.key === 'egress'" viewBox="0 0 24 24" width="16" height="16">
            <path d="M12 2.5l2.1 6.6 6.9.4-5.4 4.3 1.9 6.7L12 16.7l-5.5 3.8 1.9-6.7L3 9.5l6.9-.4z" />
          </svg>
        </span>
        <strong>{{ t(star.label) }}</strong>
        <small>{{ t(star.detail) }}</small>
        <span class="sr-only">{{ stateText(star.state) }}</span>
      </li>
    </ol>
    <figcaption>{{ summaryText }}</figcaption>
  </figure>
</template>

<style scoped>
.mn-constellation {
  margin: 0;
  padding: 18px 4px 4px;
}

.mn-constellation__path {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  margin: 0;
  padding: 0;
  list-style: none;
}

.mn-constellation__star {
  --star-size: 30px;
  --line: var(--mn-border-strong);
  position: relative;
  display: grid;
  min-width: 0;
  justify-items: center;
  align-content: start;
  gap: 2px;
  padding: 0 2px;
  text-align: center;
}

/* Edge from the previous star's centre to this one. */
.mn-constellation__star + .mn-constellation__star::before {
  position: absolute;
  z-index: 0;
  top: calc(var(--star-size) / 2 - 1px);
  right: calc(50% + var(--star-size) / 2 + 4px);
  left: calc(-50% + var(--star-size) / 2 + 4px);
  height: 2px;
  background-image: linear-gradient(90deg, var(--line) 55%, transparent 0);
  background-size: 9px 2px;
  content: "";
}

.mn-constellation__star[data-edge="flowing"]::before {
  --line: var(--mn-primary);
  animation: mn-constellation-flow 900ms linear infinite;
}

.mn-constellation__star[data-edge="idle"]::before {
  --line: color-mix(in srgb, var(--mn-ink-faint) 45%, transparent);
  background-size: 4px 2px;
}

.mn-constellation__mark {
  position: relative;
  z-index: 1;
  display: grid;
  width: var(--star-size);
  height: var(--star-size);
  margin-bottom: 8px;
  place-items: center;
  border: 1.5px dashed var(--mn-border-strong);
  border-radius: 999px;
  background: var(--mn-surface-raised);
  color: var(--mn-ink-faint);
  transition: background-color 240ms ease-out, border-color 240ms ease-out, box-shadow 240ms ease-out;
}

.mn-constellation__mark::after {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  background: currentColor;
  content: "";
  opacity: 0.55;
}

.mn-constellation__mark svg {
  fill: currentColor;
}

.mn-constellation__mark:has(svg)::after {
  display: none;
}

.mn-constellation__star[data-state="ok"] .mn-constellation__mark {
  border: 0;
  background: var(--mn-star);
  box-shadow: var(--mn-glow);
  color: var(--mn-ivory);
}

.mn-constellation__star[data-state="ok"] .mn-constellation__mark::after {
  opacity: 1;
}

.mn-constellation__star[data-key="egress"][data-state="ok"] .mn-constellation__mark,
.mn-constellation__star:last-child[data-state="ok"] .mn-constellation__mark {
  background: var(--mn-primary);
  color: var(--mn-on-accent);
  animation: mn-constellation-twinkle 2.8s ease-in-out infinite;
}

.mn-constellation__star[data-state="off"] .mn-constellation__mark {
  border-style: dotted;
  color: var(--mn-danger);
}

.mn-constellation__star strong {
  max-width: 100%;
  overflow-wrap: anywhere;
  color: var(--mn-ink);
  font-size: 13px;
  font-weight: 650;
  line-height: 1.25;
}

.mn-constellation__star small {
  max-width: 100%;
  overflow-wrap: anywhere;
  color: var(--mn-ink-muted);
  font-family: var(--font-mono);
  font-size: 10.5px;
  line-height: 1.35;
}

.mn-constellation__star[data-state="off"] strong,
.mn-constellation__star[data-state="unknown"] strong {
  color: var(--mn-ink-soft);
}

figcaption {
  margin: 16px 0 0;
  padding-top: 14px;
  border-top: 1px dashed var(--mn-border);
  color: var(--mn-ink-muted);
  font-size: 12.5px;
  line-height: 1.6;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
  white-space: nowrap;
}

@keyframes mn-constellation-flow {
  from { background-position-x: 0; }
  to { background-position-x: 9px; }
}

@keyframes mn-constellation-twinkle {
  0%, 100% { box-shadow: var(--mn-glow); }
  50% { box-shadow: 0 0 0 7px color-mix(in srgb, var(--mn-accent) 12%, transparent); }
}

@media (min-width: 640px) {
  .mn-constellation__star {
    --star-size: 36px;
  }

  .mn-constellation__star strong {
    font-size: 14px;
  }

  .mn-constellation__star small {
    font-size: 11.5px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .mn-constellation__star::before,
  .mn-constellation__mark {
    animation: none !important;
  }
}

@media (forced-colors: active) {
  .mn-constellation__star + .mn-constellation__star::before {
    background: CanvasText;
  }

  .mn-constellation__star[data-state="ok"] .mn-constellation__mark {
    background: Highlight;
    color: HighlightText;
  }
}
</style>
