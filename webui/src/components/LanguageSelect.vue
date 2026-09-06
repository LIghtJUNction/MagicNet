<script setup lang="ts">
import { Languages } from "lucide-vue-next";
import { languages, locale, setLocale, t } from "@/i18n";
</script>

<template>
  <label class="mn-language-select">
    <Languages :size="17" aria-hidden="true" />
    <span class="sr-only">{{ t('语言') }}</span>
    <select :value="locale" :aria-label="t('语言')" @change="setLocale(($event.target as HTMLSelectElement).value)">
      <option v-for="language in languages" :key="language.value" :value="language.value" :lang="language.value">
        {{ language.label }}
      </option>
    </select>
  </label>
</template>
