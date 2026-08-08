import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");
const dialog = readFileSync(new URL("./src/components/OnboardingDialog.vue", import.meta.url), "utf8");
const guide = readFileSync(new URL("../docs/user-guide.md", import.meta.url), "utf8");

for (const copy of [
  "第一次使用 MagicNet",
  "MagicNet 当前主线只支持 sing-box + magicnet0 TUN",
  "MagicNet 不提供订阅链接、节点或账号",
  "不需要手工覆盖 runtime config",
  "验证通过后再碰应用、Wi‑Fi、热点",
  "MagicNet 不提供订阅 URL、节点、token、password 或账号",
]) {
  assert.match(dialog, new RegExp(copy.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

assert.match(app, /const ONBOARDING_STORAGE_KEY = "magicnet\.webui\.onboarding\.v1"/);
assert.match(app, /window\.localStorage\.getItem\(ONBOARDING_STORAGE_KEY\)/);
assert.match(app, /window\.localStorage\.setItem\(ONBOARDING_STORAGE_KEY, value\)/);
assert.match(app, /if \(!readOnboardingPreference\(\)\)/);
assert.match(app, /<OnboardingDialog/);
assert.match(app, /@dismiss="closeOnboarding\(\)"/);
assert.match(app, /@complete="completeOnboarding"/);
assert.match(app, /@navigate="handleOnboardingNavigate"/);
assert.match(app, /closeAdvancedNav\(false\)/);
assert.match(app, /launchOnboarding\(advancedNavTrigger\.value\)/);
assert.match(app, /trigger instanceof HTMLElement/);
assert.match(app, /trigger\.isConnected/);
assert.match(app, /trigger\.focus\(\)/);
assert.match(app, /<ScrollText :size="16" \/><span>新手引导<\/span>/);
assert.match(app, /<ScrollText :size="18" \/>新手引导/);

for (const invariant of [
  'role="dialog"',
  'aria-modal="true"',
  'aria-labelledby="onboarding-title"',
  'aria-describedby="onboarding-description"',
  "data-dialog-initial-focus",
  "@keydown.esc.prevent.stop",
  "document.body.style.overflow = \"hidden\"",
  "document.body.style.overflow = previousBodyOverflow",
  "event.key !== \"Tab\"",
  "event.shiftKey",
  "!dialog.value.contains(active)",
  "emit('navigate', activeStep.target)",
  "emit('complete')",
  "emit('dismiss')",
  "稍后再看",
  "完成引导",
]) {
  assert.ok(dialog.includes(invariant), `onboarding dialog missing ${invariant}`);
}

assert.match(dialog, /type GuideTarget = "subs" \| "control" \| "health" \| "output"/);
assert.match(dialog, /第 \{\{ currentStep \+ 1 \}\} \/ \{\{ steps\.length \}\} 步|const progressLabel = computed/);
assert.match(dialog, /if \(event\.shiftKey && \(active === first \|\| !dialog\.value\.contains\(active\)\)\)/);
assert.match(dialog, /else if \(!event\.shiftKey && \(active === last \|\| !dialog\.value\.contains\(active\)\)\)/);

for (const target of ["subs", "control", "health", "output"]) {
  assert.match(dialog, new RegExp(`"${target}"`), `missing onboarding navigation target ${target}`);
}

for (const required of [
  "## 第一次使用：跟着新手引导完成",
  "MagicNet 只走 `sing-box` + `magicnet0` TUN",
  "MagicNet 不提供订阅服务，也不生成节点",
  "不要手工改运行中的 `sing-box` 配置文件",
  "异常细节继续看“输出”",
]) {
  assert.match(guide, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

for (const forbidden of [
  /TProxy/,
  /eBPF/,
  /ALLOW_MULTI/,
  /subscription url/i,
  /secret/i,
  /https?:\/\/example\.com/,
]) {
  assert.doesNotMatch(dialog, forbidden);
}

for (const forbidden of [
  /ALLOW_MULTI/,
  /token[:：]\s*\S+/i,
  /password[:：]\s*\S+/i,
]) {
  assert.doesNotMatch(guide, forbidden);
}

console.log("onboarding dialog tests passed");
