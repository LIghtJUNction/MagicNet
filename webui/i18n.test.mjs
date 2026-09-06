import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { computed, isReadonly } from "vue";
import { parse as parseSfc } from "@vue/compiler-sfc";
import { parse as parseTemplate } from "@vue/compiler-dom";
import ts from "./node_modules/typescript/lib/typescript.js";
import {
  LOCALE_STORAGE_KEY, bootstrapLocale, locale, resolveLocale, setLocale, t,
} from "./src/i18n/index.ts";
import { messages } from "./src/i18n/messages.ts";

const root = dirname(fileURLToPath(import.meta.url));
const sourceRoot = join(root, "src");
const placeholders = (value) => [...value.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();

function sourceFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : /\.(?:ts|vue)$/.test(entry.name) ? [path] : [];
  });
}

function parseTypescript(source, filename) {
  return ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
}

function translatorBindings(ast) {
  const names = new Set();
  for (const node of ast.statements) {
    if (!ts.isImportDeclaration(node) || !ts.isStringLiteral(node.moduleSpecifier)) continue;
    if (!/(?:^|\/)i18n(?:\/index(?:\.ts)?)?$/.test(node.moduleSpecifier.text)) continue;
    const bindings = node.importClause?.namedBindings;
    if (bindings && ts.isNamedImports(bindings)) {
      for (const binding of bindings.elements) {
        if ((binding.propertyName ?? binding.name).text === "t") names.add(binding.name.text);
      }
    }
  }
  return names;
}

function staticKeys(expression) {
  if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) return [expression.text];
  if (ts.isConditionalExpression(expression)) return [...staticKeys(expression.whenTrue), ...staticKeys(expression.whenFalse)];
  if (ts.isParenthesizedExpression(expression)) return staticKeys(expression.expression);
  return [];
}

function collectCalls(ast, names, onKey) {
  function visit(node) {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)
      && names.has(node.expression.text) && node.arguments.length) {
      for (const key of staticKeys(node.arguments[0])) onKey(key);
    }
    ts.forEachChild(node, visit);
  }
  visit(ast);
}

function collectSourceKeys(source, filename, onKey) {
  if (!filename.endsWith(".vue")) {
    const ast = parseTypescript(source, filename);
    collectCalls(ast, translatorBindings(ast), onKey);
    return;
  }
  const { descriptor, errors } = parseSfc(source, { filename });
  assert.deepEqual(errors, [], `Invalid SFC: ${filename}`);
  const scripts = [descriptor.script, descriptor.scriptSetup].filter(Boolean)
    .map((script) => parseTypescript(script.content, filename + ".ts"));
  const bindings = new Set(scripts.flatMap((script) => [...translatorBindings(script)]));
  for (const script of scripts) collectCalls(script, bindings, onKey);
  if (!descriptor.template || !bindings.size) return;
  function expression(source) {
    collectCalls(parseTypescript(`(${source})`, filename + ".template.ts"), bindings, onKey);
  }
  function visit(node) {
    if (node.type === 5) expression(node.content.content);
    for (const prop of node.props ?? []) if (prop.type === 7 && prop.exp) expression(prop.exp.content);
    for (const child of node.children ?? []) visit(child);
  }
  visit(parseTemplate(descriptor.template.content));
}

test("every catalog provides two nonempty translations with matching placeholders", async () => {
  const directory = join(sourceRoot, "i18n", "catalogs");
  const catalogs = readdirSync(directory).filter((name) => name.endsWith(".ts"));
  assert.ok(catalogs.length > 0);
  let count = 0;
  for (const name of catalogs) {
    const { default: catalog } = await import(pathToFileURL(join(directory, name)).href);
    for (const [key, translations] of Object.entries(catalog)) {
      const context = `${name}: ${key}`;
      assert.equal(translations.length, 2, context);
      assert.ok(Object.hasOwn(messages, key), `Catalog is not included in messages: ${context}`);
      for (const [index, translation] of translations.entries()) {
        assert.equal(typeof translation, "string", context);
        assert.ok(translation.trim(), `Empty ${index === 0 ? "English" : "Russian"} translation: ${context}`);
        assert.deepEqual(placeholders(translation), placeholders(key), `Placeholder mismatch: ${context}`);
      }
      count += 1;
    }
  }
  assert.ok(count > 0);
});

test("all literal translation keys in shipped TS and Vue expressions have catalogs", () => {
  const missing = new Set();
  let calls = 0;
  for (const filename of sourceFiles(sourceRoot)) {
    collectSourceKeys(readFileSync(filename, "utf8"), filename, (key) => {
      calls += 1;
      if (!Object.hasOwn(messages, key)) missing.add(`${relative(root, filename)}: ${key}`);
    });
  }
  assert.ok(calls > 0, "Coverage scanner must find actual translator calls");
  assert.deepEqual([...missing], [], "Missing static translation keys");
});

test("coverage scanner parses translated attributes and ignores comments and unrelated functions", () => {
  const keys = [];
  collectSourceKeys(`<script setup lang="ts">
    import { t as translate } from '@/i18n';
    // translate('comment only')
    const result = translate('script key');
    function t(value: string) { return value; }
    t('unrelated function');
  </script><template><p :title="translate('attribute key')">{{ translate(ok ? 'true key' : 'false key') }}</p></template>`, "fixture.vue", (key) => keys.push(key));
  assert.deepEqual(keys, ["script key", "attribute key", "true key", "false key"]);
});

test("language negotiation respects region variants and preference order", () => {
  for (const language of ["zh", "zh-CN", "zh-Hans-CN", "zh_TW", "ZH-hk"]) assert.equal(resolveLocale([language]), "zh-CN");
  for (const language of ["en", "en-US", "EN_gb"]) assert.equal(resolveLocale([language]), "en");
  for (const language of ["ru", "ru-RU", "RU_by"]) assert.equal(resolveLocale([language]), "ru");
  assert.equal(resolveLocale(["fr-FR", "ru-RU", "en-US"]), "ru");
  assert.equal(resolveLocale(["en-US", "zh-CN", "ru"]), "en");
  assert.equal(resolveLocale(["de", "zh-CN", "en"]), "zh-CN");
  assert.equal(resolveLocale(["de", "ja"]), "zh-CN");
  assert.equal(resolveLocale([]), "zh-CN");
});

test("translation interpolates values once and falls back safely", () => {
  try {
    for (const language of ["zh-CN", "en", "ru"]) {
      setLocale(language);
      assert.equal(t("__missing__ {first} {second}", { first: "{second}", second: "$&" }), "__missing__ {second} $&");
      assert.equal(t("__missing__ {count} {absent}", { count: 0 }), "__missing__ 0 {absent}");
      assert.equal(t("__missing__ {empty} {unset}", { empty: null, unset: undefined }), "__missing__  ");
      assert.equal(t("__missing__ {inherited}", Object.create({ inherited: "must not be used" })), "__missing__ {inherited}");
      assert.equal(t("toString"), "toString");
      assert.equal(t("__proto__"), "__proto__");
      const expected = language === "zh-CN" ? "已选 {count} 个" : messages["已选 {count} 个"][language === "en" ? 0 : 1];
      assert.equal(t("已选 {count} 个", { count: 3 }), expected.replace("{count}", "3"));
    }
  } finally { setLocale("zh-CN"); }
});

test("locale is readonly and computed text updates immediately without reloading", () => {
  assert.equal(isReadonly(locale), true);
  const label = computed(() => t("应用策略"));
  try {
    for (const language of ["en", "ru", "zh-CN"]) {
      setLocale(language);
      assert.equal(locale.value, language);
      assert.equal(label.value, language === "zh-CN" ? "应用策略" : messages["应用策略"][language === "en" ? 0 : 1]);
    }
    setLocale("ru");
    for (const invalid of ["", "fr", "RU", "ru-RU", "__proto__"]) {
      setLocale(invalid);
      assert.equal(locale.value, "ru", `Unexpected locale accepted: ${invalid}`);
    }
  } finally { setLocale("zh-CN"); }
});

test("storage failures do not prevent initial negotiation or subsequent selection", async () => {
  const originalWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const originalDocument = Object.getOwnPropertyDescriptor(globalThis, "document");
  const documentStub = { documentElement: { lang: "" } };
  try {
    Object.defineProperty(globalThis, "window", { configurable: true, value: {
      navigator: { languages: ["fr", "ru-RU"], language: "en-US" },
      get localStorage() { throw new Error("Storage access blocked"); },
    } });
    Object.defineProperty(globalThis, "document", { configurable: true, value: documentStub });
    const isolated = await import("./src/i18n/index.ts?blocked-storage-test");
    assert.equal(isolated.locale.value, "ru");
    isolated.bootstrapLocale();
    assert.equal(documentStub.documentElement.lang, "ru");
    assert.doesNotThrow(() => isolated.setLocale("en"));
    assert.equal(isolated.locale.value, "en");
    assert.equal(documentStub.documentElement.lang, "en");

    const writes = [];
    Object.defineProperty(globalThis, "window", { configurable: true, value: {
      navigator: { languages: ["ru"], language: "ru" },
      localStorage: {
        getItem(key) { assert.equal(key, LOCALE_STORAGE_KEY); return "en"; },
        setItem(...args) { writes.push(args); },
      },
    } });
    const stored = await import("./src/i18n/index.ts?stored-locale-test");
    assert.equal(stored.locale.value, "en", "Saved preference must take precedence over browser language");
    stored.setLocale("zh-CN");
    assert.deepEqual(writes, [[LOCALE_STORAGE_KEY, "zh-CN"]]);
    assert.equal(documentStub.documentElement.lang, "zh-CN");
  } finally {
    if (originalWindow) Object.defineProperty(globalThis, "window", originalWindow); else delete globalThis.window;
    if (originalDocument) Object.defineProperty(globalThis, "document", originalDocument); else delete globalThis.document;
    bootstrapLocale();
  }
});
