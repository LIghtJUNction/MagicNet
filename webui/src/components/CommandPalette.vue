<script setup lang="ts">
import { CornerDownLeft, Search, Sparkles } from "lucide-vue-next";
import { computed, nextTick, onMounted, ref, watch, type Component } from "vue";
import { t } from "@/i18n";
import { trapFocusWithin } from "@/lib/focus";
import { rankPaletteEntries, type PaletteEntry } from "@/components/commandPalette";

export type PaletteItem = PaletteEntry & {
  icon: Component;
  run: () => void;
};

const props = defineProps<{ items: readonly PaletteItem[] }>();
const emit = defineEmits<{ (e: "close"): void }>();

const query = ref("");
const activeIndex = ref(0);
const dialog = ref<HTMLElement | null>(null);
const input = ref<HTMLInputElement | null>(null);
const list = ref<HTMLElement | null>(null);

const results = computed(() => rankPaletteEntries(props.items, query.value, t));
const activeItem = computed(() => results.value[activeIndex.value]);
const groups = computed(() => {
  const ordered: Array<{ group: string; entries: Array<{ item: PaletteItem; index: number }> }> = [];
  results.value.forEach((item, index) => {
    const group = ordered.find((entry) => entry.group === item.group);
    if (group) group.entries.push({ item, index });
    else ordered.push({ group: item.group, entries: [{ item, index }] });
  });
  return ordered;
});

watch(query, () => {
  activeIndex.value = 0;
});

function optionId(index: number): string {
  return `mn-palette-option-${index}`;
}

function move(delta: number): void {
  const count = results.value.length;
  if (!count) return;
  activeIndex.value = (activeIndex.value + delta + count) % count;
  void nextTick(() => {
    list.value?.querySelector(`#${optionId(activeIndex.value)}`)?.scrollIntoView({ block: "nearest" });
  });
}

function choose(item: PaletteItem | undefined): void {
  if (!item) return;
  emit("close");
  // Let the dialog unmount and restore focus before the action moves it.
  void nextTick(() => item.run());
}

function handleKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    emit("close");
    return;
  }
  if (event.key === "ArrowDown") {
    event.preventDefault();
    move(1);
    return;
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    move(-1);
    return;
  }
  if (event.key === "Home" && event.target !== input.value) {
    event.preventDefault();
    activeIndex.value = 0;
    return;
  }
  if (event.key === "Enter" && !event.isComposing) {
    event.preventDefault();
    choose(activeItem.value);
    return;
  }
  if (event.key === "Tab") trapFocusWithin(event, dialog.value);
}

onMounted(() => {
  input.value?.focus();
});
</script>

<template>
  <div class="mn-sheet-layer mn-palette-layer">
    <button class="mn-overlay" type="button" tabindex="-1" :aria-label="t('关闭快速跳转')" @click="emit('close')" />
    <div
      ref="dialog"
      class="mn-palette"
      role="dialog"
      aria-modal="true"
      :aria-label="t('快速跳转')"
      @keydown="handleKeydown"
    >
      <div class="mn-palette__search">
        <Search :size="18" aria-hidden="true" />
        <input
          ref="input"
          v-model="query"
          type="text"
          role="combobox"
          aria-autocomplete="list"
          :aria-expanded="results.length > 0"
          aria-controls="mn-palette-results"
          :aria-activedescendant="activeItem ? optionId(activeIndex) : undefined"
          :aria-label="t('搜索页面和操作')"
          :placeholder="t('搜索页面和操作…')"
          autocomplete="off"
          spellcheck="false"
          enterkeyhint="go"
        />
        <kbd aria-hidden="true">Esc</kbd>
      </div>

      <div id="mn-palette-results" ref="list" class="mn-palette__results" role="listbox" :aria-label="t('搜索结果')">
        <template v-for="group in groups" :key="group.group">
          <p class="mn-palette__group" role="presentation">{{ t(group.group) }}</p>
          <div
            v-for="{ item, index } in group.entries"
            :id="optionId(index)"
            :key="item.id"
            class="mn-palette__option"
            role="option"
            :aria-selected="index === activeIndex"
            @pointermove="activeIndex = index"
            @click="choose(item)"
          >
            <span class="mn-palette__icon" aria-hidden="true"><component :is="item.icon" :size="17" /></span>
            <span class="mn-palette__label">
              <span>{{ t(item.label) }}</span>
              <small v-if="item.hint">{{ t(item.hint) }}</small>
            </span>
            <CornerDownLeft v-if="index === activeIndex" class="mn-palette__enter" :size="15" aria-hidden="true" />
          </div>
        </template>
        <p v-if="!results.length" class="mn-palette__empty" role="status">
          <Sparkles :size="18" aria-hidden="true" />{{ t("没有匹配的页面或操作") }}
        </p>
      </div>

      <footer class="mn-palette__foot" aria-hidden="true">
        <span><kbd>↑</kbd><kbd>↓</kbd>{{ t("选择") }}</span>
        <span><kbd>↵</kbd>{{ t("打开") }}</span>
        <span><kbd>Ctrl</kbd><kbd>K</kbd>{{ t("随时唤出") }}</span>
      </footer>
    </div>
  </div>
</template>

<style scoped>
.mn-palette-layer {
  z-index: 60;
}

.mn-palette {
  position: absolute;
  top: max(12px, env(safe-area-inset-top));
  right: 12px;
  left: 12px;
  display: grid;
  max-width: 620px;
  max-height: calc(100dvh - 24px - env(safe-area-inset-top));
  grid-template-rows: auto minmax(0, 1fr) auto;
  margin-inline: auto;
  overflow: hidden;
  border: 1px solid var(--mn-border);
  border-radius: var(--mn-radius-lg);
  background: var(--mn-surface-raised);
  box-shadow: var(--mn-shadow-float);
}

.mn-palette__search {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 12px 6px 16px;
  border-bottom: 1px dashed var(--mn-border-strong);
  color: var(--mn-ink-muted);
}

.mn-palette__search input {
  min-width: 0;
  flex: 1;
  min-height: 52px;
  border: 0;
  background: transparent;
  color: var(--mn-ink);
  font-size: 16px;
  outline: none;
}

.mn-palette__search input::placeholder {
  color: var(--mn-ink-faint);
}

.mn-palette__results {
  overflow-y: auto;
  overscroll-behavior: contain;
  padding: 6px 8px 10px;
}

.mn-palette__group {
  margin: 10px 10px 4px;
  color: var(--mn-ink-faint);
  font-size: 10.5px;
  font-weight: 650;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}

.mn-palette__option {
  display: flex;
  min-height: 52px;
  align-items: center;
  gap: 12px;
  padding: 8px 10px;
  border-radius: 12px;
  color: var(--mn-ink);
  cursor: pointer;
}

.mn-palette__option[aria-selected="true"] {
  background: var(--mn-accent-soft);
}

.mn-palette__icon {
  display: grid;
  width: 34px;
  height: 34px;
  flex: none;
  place-items: center;
  border: 1px solid var(--mn-border);
  border-radius: 10px;
  background: var(--mn-surface-sunken);
  color: var(--mn-ink-muted);
}

.mn-palette__option[aria-selected="true"] .mn-palette__icon {
  border-color: transparent;
  background: var(--mn-primary);
  color: var(--mn-on-accent);
}

.mn-palette__label {
  display: grid;
  min-width: 0;
  flex: 1;
  font-size: 14px;
}

.mn-palette__label small {
  overflow: hidden;
  color: var(--mn-ink-muted);
  font-size: 12px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.mn-palette__enter {
  color: var(--mn-primary-strong);
}

.mn-palette__empty {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  margin: 0;
  padding: 32px 12px;
  color: var(--mn-ink-muted);
  font-size: 13px;
}

.mn-palette__foot {
  display: none;
  gap: 18px;
  padding: 10px 16px;
  border-top: 1px solid var(--mn-border);
  background: var(--mn-surface-sunken);
  color: var(--mn-ink-faint);
  font-size: 11.5px;
}

.mn-palette__foot span {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

@media (min-width: 640px) {
  .mn-palette {
    top: 12vh;
  }

  .mn-palette__foot {
    display: flex;
  }
}

@media (forced-colors: active) {
  .mn-palette__option[aria-selected="true"] {
    outline: 2px solid Highlight;
  }
}
</style>
