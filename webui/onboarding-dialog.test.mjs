import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const dialog = readFileSync(
  new URL("./src/components/OnboardingDialog.vue", import.meta.url),
  "utf8",
);
const focus = readFileSync(
  new URL("./src/lib/focus.ts", import.meta.url),
  "utf8",
);
const guide = readFileSync(
  new URL("../docs/user-guide.md", import.meta.url),
  "utf8",
);

for (const copy of [
  "第一次使用 MagicNet",
  "MagicNet 默认使用 sing-box magicnet0 TUN，也允许显式切换 eBPF",
  "MagicNet 不提供节点和账号",
  "校验没通过时，MagicNet 继续使用上一次可用的配置",
  "MagicNet 检查并应用配置后",
  "你可以从控制页打开 zashboard 选节点",
  "你在 zashboard 里切换节点和代理组",
  "去控制页",
  "链路正常后，再设置分流",
  "MagicNet 不提供订阅 URL、节点、token、password 或账号",
]) {
  assert.match(dialog, new RegExp(copy.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

assert.match(
  app,
  /const ONBOARDING_STORAGE_KEY = "magicnet\.webui\.onboarding\.v1"/,
);
assert.match(app, /window\.localStorage\.getItem\(ONBOARDING_STORAGE_KEY\)/);
assert.match(
  app,
  /window\.localStorage\.setItem\(ONBOARDING_STORAGE_KEY, value\)/,
);
assert.match(app, /if \(!readOnboardingPreference\(\)\)/);
assert.match(app, /<OnboardingDialog/);
assert.match(app, /@dismiss="closeOnboarding\(\)"/);
assert.match(app, /@complete="completeOnboarding"/);
assert.match(app, /@navigate="handleOnboardingNavigate"/);
assert.match(app, /closeUtilityMenu\(false\)/);
assert.match(app, /launchOnboarding\(utilityMenuTrigger\.value\)/);
assert.match(app, /restoreFocusAfterUpdate\(trigger\)/);
assert.match(app, /<ScrollText :size="16"[^>]*\/>引导/);
assert.match(app, /<ScrollText :size="18"[^>]*\/>新手引导/);

for (const invariant of [
  'role="dialog"',
  'aria-modal="true"',
  'aria-labelledby="onboarding-title"',
  'aria-describedby="onboarding-description"',
  "data-dialog-initial-focus",
  "@keydown.esc.prevent.stop",
  'document.body.style.overflow = "hidden"',
  "document.body.style.overflow = previousBodyOverflow",
  "trapFocusWithin(event, dialog.value)",
  "emit('navigate', activeStep.target)",
  "emit('complete')",
  "emit('dismiss')",
  "稍后再看",
  "完成引导",
]) {
  assert.ok(
    dialog.includes(invariant),
    `onboarding dialog missing ${invariant}`,
  );
}

assert.match(
  dialog,
  /type GuideTarget = "subs" \| "control" \| "health" \| "output"/,
);
assert.match(
  dialog,
  /第 \{\{ currentStep \+ 1 \}\} \/ \{\{ steps\.length \}\} 步|const progressLabel = computed/,
);
assert.match(
  focus,
  /if \(event\.shiftKey && \(active === first \|\| !root\.contains\(active\)\)\)/,
);
assert.match(
  focus,
  /else if \(!event\.shiftKey && \(active === last \|\| !root\.contains\(active\)\)\)/,
);
assert.match(focus, /restoreFocusAfterUpdate/);
assert.match(focus, /element\.isConnected/);

for (const target of ["subs", "control", "health", "output"]) {
  assert.match(
    dialog,
    new RegExp(`"${target}"`),
    `missing onboarding navigation target ${target}`,
  );
}

for (const required of [
  "## 第一次使用：跟着新手引导完成",
  "MagicNet 只允许显式 `sing-box` `tun|ebpf`，默认 TUN",
  "MagicNet 不提供订阅服务，也不生成节点",
  "不要手工改运行中的 `sing-box` 配置文件",
  "异常细节继续看“输出”",
]) {
  assert.match(
    guide,
    new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
  );
}

assert.match(dialog, /eBPF/);
assert.match(dialog, /tun\|ebpf/);

for (const forbidden of [
  /TProxy/,
  /ALLOW_MULTI/,
  /subscription url/i,
  /secret/i,
  /https?:\/\/example\.com/,
]) {
  assert.doesNotMatch(dialog, forbidden);
}

assert.match(guide, /ALLOW_MULTI/);
assert.match(guide, /eBPF/);

for (const forbidden of [
  /token[:：]\s*\S+/i,
  /password[:：]\s*\S+/i,
]) {
  assert.doesNotMatch(guide, forbidden);
}

console.log("onboarding dialog tests passed");
