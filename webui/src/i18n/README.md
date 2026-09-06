# WebUI translations

MagicNet supports `zh-CN`, `en`, and `ru`. On the first visit, the first supported
browser language is selected; unsupported languages fall back to Simplified
Chinese. A manual choice is stored as `magicnet.webui.locale`. Storage failures
never block the UI. The HTML `lang` attribute follows the active language.

Use `t` from `@/i18n` at the point where UI text is rendered. Chinese source text
is the key and fallback. Catalog entries contain `[English, Russian]`, with one
entry per line. Use a complete sentence and named parameters so translations can
change word order:

```ts
t('已选择 {count} 个', { count: selected.length })
```

Keep the same placeholders in each translation. Use `computed` for derived
messages; static options can retain source labels and render `t(option.label)`.
Do not save translated strings as keys for comparisons, filtering, privacy
redaction, or commands. Existing operation history is recorded in the language
used when the operation ran. Switching languages does not remount pages or
replace unsaved configuration content.

Command arguments, user data, configuration contents and raw device logs must
remain unchanged. Translate only explanatory UI text. Embedded third-party
panels have their own language settings.

`npm run check` validates locale behavior, catalog placeholders, static translation
keys, business regressions and the production build. `npm run test:ui` covers
browser detection, language persistence, unsaved drafts and all eleven pages in
English and Russian at mobile and desktop sizes.
