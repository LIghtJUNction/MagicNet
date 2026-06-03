<script setup lang="ts">
import { Github, RefreshCw, Save } from "lucide-vue-next";
import { onMounted } from "vue";
import type { ConfigEditorTarget } from "@/types";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";

const { state, loadConfig, saveConfig, openExternal, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();

function selectTarget(target: ConfigEditorTarget): void {
  if (state.config.target === target) return;
  state.config.target = target;
  state.config.text = "";
  state.config.dirty = false;
  state.config.path = target === "mihomo"
    ? "/data/adb/modules/MagicNet/.config/mihomo/config.yaml"
    : "/data/adb/modules/MagicNet/.config/sing-box/config.json";
  state.config.status = "已切换目标，点击加载配置";
}

onMounted(() => {
  if (state.runtime.selectedCore === "sing-box" && state.config.target !== "sing-box") {
    selectTarget("sing-box");
  }
});

function issueUrl(): string {
  const sanitized = state.config.text
    .replace(/https?:\/\/\S+/g, "[filtered-url]")
    .replace(/(password|token|secret|uuid)["':= ]+[^,\n]+/gi, "$1=[filtered]");
  const body = [
    "已尝试过滤 URL、token、secret、password 等敏感字段；创建前仍需人工检查，避免提交私有订阅或密钥。",
    "",
    "## Target",
    state.config.target,
    "",
    "## Sanitized Config",
    "```",
    sanitized.slice(0, 12000),
    "```"
  ].join("\n");
  return `${REPO}/issues/new?${new URLSearchParams({ title: `配置变更建议：${state.config.target}`, body }).toString()}`;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Validated Editor" title="配置编辑器" description="高级配置入口：sing-box 编辑 config.json，mihomo 编辑 config.yaml；订阅链接请到订阅页填写。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('load-config')" @click="withAction('load-config', () => loadConfig())"><RefreshCw :size="17" />{{ isRunning('load-config') ? '加载中' : '加载配置' }}</Button>
        <Button :loading="isRunning('save-config')" @click="withAction('save-config', () => saveConfig())"><Save :size="17" />{{ isRunning('save-config') ? '校验中' : '校验并保存' }}</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), '配置 Diff Issue')"><Github :size="17" />创建 Diff Issue</Button>
      </div>
    </PageHeader>

    <Card class="grid gap-3">
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-zinc-400">
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400" :class="{ 'bg-zinc-800 text-zinc-50': state.config.target === 'mihomo' }" @click="selectTarget('mihomo')">mihomo</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400" :class="{ 'bg-zinc-800 text-zinc-50': state.config.target === 'sing-box' }" @click="selectTarget('sing-box')">sing-box</button>
        </div>
        <input class="h-9 min-w-0 flex-1 rounded-md border border-zinc-800 bg-zinc-900 px-3 text-xs text-zinc-300" readonly :value="state.config.path">
        <span class="shrink-0">{{ state.config.status }}</span>
        <span v-if="state.config.dirty" class="shrink-0 rounded bg-amber-500/15 px-2 py-1 text-xs text-amber-200">未保存</span>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3 text-sm leading-6 text-zinc-400">
        <p v-if="state.config.target === 'sing-box'">sing-box 配置文件是 JSON。点击“加载配置”读取真实文件，修改后点“校验并保存”，会先执行 sing-box check，通过后才覆盖并应用。</p>
        <p v-else>mihomo 配置文件是 YAML。点击“加载配置”读取真实文件，修改后点“校验并保存”，会先执行 mihomo -t，通过后才覆盖并应用。</p>
      </div>
      <Textarea
        v-model="state.config.text"
        class="min-h-[58vh] overflow-auto whitespace-pre text-sm leading-6"
        spellcheck="false"
        placeholder="点击加载配置读取真实文件"
        @input="state.config.dirty = true"
      />
    </Card>
  </div>
</template>
