<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from "vue";
import { Plus, RefreshCw, Trash2, Check, Undo2, Pencil } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Input from "@/components/ui/Input.vue";
import { t } from "@/i18n";
import { useMagicNet } from "@/composables/useMagicNet";
import { decodeMachineData, machineErrorCode } from "@/composables/machineStatus";
import { shellQuote } from "@/utils";
import { proxyDisplayName } from "./proxyGroupView";
import { object, parseOverlay, parseTargets, ROUTING_KEY, validRoutingValue, type RoutingOverlay, type RoutingTarget, type RoutingOutbound } from "./routingEditor";

const { runPrivateCli, stagePrivatePayload, removePrivatePayload, refreshStatus, refreshPackages, state } = useMagicNet();
const overlay = ref<RoutingOverlay>({ schema: 1, rules: [], outbounds: [] });
const basePatch = ref<Record<string, unknown>>({});
const targets = ref<RoutingTarget[]>([]);
const revision = ref<number | null>(null);
const saved = ref("");
const validated = ref("");
const busy = ref("");
const message = ref("");
const failed = ref(false);
const pending = ref(false);
const reloadRequested = ref(false);
const previous = ref<RoutingOverlay | null>(null);
const rule = reactive<{ kind: "domain" | "app"; value: string; outbound: string }>({ kind: "domain", value: "", outbound: "proxy" });
const endpoint = reactive({ type: "selector", tag: "", members: "proxy, direct", server: "", port: "1080", username: "", password: "", uuid: "", method: "aes-128-gcm", tls: true, sni: "" });
const serialized = computed(() => JSON.stringify(overlay.value));
const dirty = computed(() => saved.value !== serialized.value);
const baseTargets = computed(() => { const owned = new Set(parseOverlay(basePatch.value[ROUTING_KEY])?.outbounds.map((item) => item.tag)); return targets.value.filter((item) => !owned.has(item.tag)); });
const choices = computed(() => Array.from(new Map([...baseTargets.value, ...overlay.value.outbounds].map((item) => [item.tag, item])).values()));
watch(choices, (items) => { if (!items.some((item) => item.tag === rule.outbound)) rule.outbound = items[0]?.tag || ""; });
const formValid = computed(() => validRoutingValue(rule.kind, rule.kind === "domain" ? rule.value.trim().toLowerCase() : rule.value.trim()) && choices.value.some((item) => item.tag === rule.outbound));

function fail(code: string): never { throw new Error(code); }
async function request(action: string, payload?: Record<string, unknown>) {
  let staged: Awaited<ReturnType<typeof stagePrivatePayload>> = null;
  try {
    let args = `--json override ${action}`;
    if (payload) {
      staged = await stagePrivatePayload("tmp", `routing-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.json`, JSON.stringify(payload), t("分流编辑"));
      if (!staged) fail("override.staging_failed");
      args += ` ${shellQuote(staged.path)}`;
    }
    const result = await runPrivateCli(args, t("分流编辑"), `--json override ${action} [private-payload]`);
    const data = decodeMachineData(result.stdout, `override.${action.replace(/-file$/, "")}`);
    if (!result.ok || !data) fail(machineErrorCode(result.stdout) || "override.request_failed");
    return data;
  } finally { if (staged) await removePrivatePayload("tmp", staged.basename, t("分流编辑")); }
}
async function action(name: string, work: () => Promise<void>) {
  if (busy.value) return;
  busy.value = name; failed.value = false; message.value = "";
  try { await work(); } catch (error) {
    failed.value = true;
    const code = error instanceof Error && /^override\.[a-z_]+$/.test(error.message) ? error.message : "override.request_failed";
    message.value = code === "override.conflict" ? t("配置已被其他操作修改。请先复制你的草稿，再重新读取。") : t("操作失败：{value}", { value: code });
  } finally { busy.value = ""; }
}
function accept(data: Record<string, unknown>) {
  if (typeof data.configured_revision !== "number" || !Number.isSafeInteger(data.configured_revision) || typeof data.pending !== "boolean") fail("override.invalid_response");
  revision.value = data.configured_revision; pending.value = data.pending;
}
async function load() {
  await action("load", async () => {
    const capability = await runPrivateCli("--json capabilities", t("分流编辑"), "--json capabilities");
    const features = decodeMachineData(capability.stdout, "machine.capabilities")?.features;
    if (!capability.ok || !Array.isArray(features) || !features.includes("additive_routing_overlay")) fail("override.routing_unsupported");
    const data = await request("inspect");
    if (!object(data.patch)) fail("override.invalid_response");
    const parsed = parseOverlay(data.patch[ROUTING_KEY]); const available = parseTargets(data.routing_targets);
    if (!parsed || !available) fail("override.invalid_response");
    accept(data); basePatch.value = data.patch; overlay.value = parsed; targets.value = available;
    saved.value = serialized.value; validated.value = ""; reloadRequested.value = false; previous.value = null;
  });
}
function reload() { if (dirty.value) reloadRequested.value = true; else void load(); }
function addRule() {
  if (!formValid.value) return;
  const value = rule.kind === "domain" ? rule.value.trim().toLowerCase() : rule.value.trim();
  const next = { ...rule, value };
  const index = overlay.value.rules.findIndex((item) => item.kind === rule.kind && item.value === value);
  if (index >= 0) overlay.value.rules[index] = next; else overlay.value.rules.push(next);
  rule.value = "";
}
function addOutbound() {
  const tag = endpoint.tag.trim();
  if (!tag || tag.length > 128 || /[\x00-\x1f\x7f]/.test(tag) || baseTargets.value.some((item) => item.tag === tag)) { message.value = t("出口名称为空或与已有项目冲突。"); failed.value = true; return; }
  const existing = overlay.value.outbounds.find((item) => item.tag === tag);
  const item: RoutingOutbound = existing?.type === endpoint.type ? { ...existing } : { tag, type: endpoint.type };
  if (["selector", "urltest"].includes(endpoint.type)) {
    const members = [...new Set(endpoint.members.split(",").map((v) => v.trim()).filter(Boolean))];
    if (!members.length || members.includes(tag) || members.some((v) => !choices.value.some((target) => target.tag === v))) { message.value = t("请选择存在的组成员，不能引用自身。"); failed.value = true; return; }
    item.outbounds = members;
    if (endpoint.type === "selector") item.default = typeof item.default === "string" && members.includes(item.default) ? item.default : members[0];
    else { item.url = "https://www.gstatic.com/generate_204"; item.interval = "3m"; }
  } else {
    const port = Number(endpoint.port);
    if (!endpoint.server.trim() || !Number.isInteger(port) || port < 1 || port > 65535) { message.value = t("请填写服务器与有效端口。"); failed.value = true; return; }
    item.server = endpoint.server.trim(); item.server_port = port;
    for (const key of ["username", "password", "uuid", "method"]) delete item[key];
    if (endpoint.username) item.username = endpoint.username;
    if (endpoint.password) item.password = endpoint.password;
    if (endpoint.type === "shadowsocks") item.method = endpoint.method;
    if (endpoint.type === "vless") item.uuid = endpoint.uuid;
    if (endpoint.tls && ["http", "trojan", "vless"].includes(endpoint.type)) {
      const tls = object(item.tls) ? { ...item.tls } : {}; delete tls.server_name;
      item.tls = { ...tls, enabled: true, ...(endpoint.sni ? { server_name: endpoint.sni } : {}) };
    } else delete item.tls;
  }
  const index = overlay.value.outbounds.findIndex((own) => own.tag === tag);
  if (index >= 0) overlay.value.outbounds[index] = item; else overlay.value.outbounds.push(item);
  endpoint.tag = ""; endpoint.password = ""; endpoint.uuid = ""; message.value = ""; failed.value = false;
}
function editOutbound(item: RoutingOutbound) {
  const text = (value: unknown, fallback = "") => typeof value === "string" ? value : fallback;
  const tls = object(item.tls) ? item.tls : {};
  Object.assign(endpoint, { type: item.type, tag: item.tag,
    members: Array.isArray(item.outbounds) ? item.outbounds.filter((v): v is string => typeof v === "string").join(", ") : "proxy, direct",
    server: text(item.server), port: String(item.server_port || 1080), username: text(item.username), password: text(item.password), uuid: text(item.uuid), method: text(item.method, "aes-128-gcm"), tls: tls.enabled === true, sni: text(tls.server_name) });
}
function patch() { return { ...basePatch.value, [ROUTING_KEY]: { schema: 1, rules: overlay.value.rules.map((item) => ({ ...item })), outbounds: overlay.value.outbounds.map((item) => ({ ...item })) } }; }
async function preview() { await action("preview", async () => { const data = await request("preview-file", { patch: patch() }); if (data.valid !== true) fail("override.invalid_response"); validated.value = serialized.value; message.value = t("分流预览通过。确认列表后保存并应用。"); }); }
async function save() {
  await action("save", async () => {
    if (validated.value !== serialized.value) fail("override.preview_required");
    const prior = parseOverlay(basePatch.value[ROUTING_KEY]);
    const submitted = serialized.value; const nextPatch = patch();
    accept(await request("set-file", { expected_revision: revision.value, patch: nextPatch }));
    saved.value = submitted; basePatch.value = nextPatch;
    const data = await request("apply-file", { expected_revision: revision.value }); accept(data);
    previous.value = prior;
    await refreshStatus();
    message.value = data.service_running === false ? t("覆写已生成，服务保持停止状态。") : data.service_running === true ? t("分流已应用。") : t("覆写已生成，运行状态待确认。");
  });
}
function undo() { if (previous.value) { overlay.value = previous.value; previous.value = null; validated.value = ""; message.value = t("已生成撤销草稿，预览后保存并应用。"); } }
onMounted(load);
</script>

<template>
  <section class="routing-editor" :aria-label="t('分流编辑')">
    <header class="routing-header"><div><p class="routing-eyebrow">{{ t("你的网络规则") }}</p><h2>{{ t("应用、域名与出口") }}</h2><p>{{ t("只添加你的规则，保留订阅和系统策略。") }}</p></div><span class="routing-state">{{ t(revision === null ? '未连接' : dirty ? '未保存' : pending ? '等待应用' : '已保存') }}</span></header>
    <fieldset :disabled="Boolean(busy) || revision === null">
      <form class="routing-form" @submit.prevent="addRule">
        <label>{{ t("匹配类型") }}<select :aria-label="t('匹配类型')" v-model="rule.kind" class="mn-field"><option value="domain">{{ t("域名") }}</option><option value="app">{{ t("应用包名") }}</option></select></label>
        <label class="routing-wide">{{ t(rule.kind === 'domain' ? '域名' : '应用包名') }}<Input v-model="rule.value" :placeholder="rule.kind === 'domain' ? 'example.com' : 'com.example.app'" :list="rule.kind === 'app' ? 'routing-packages' : undefined" autocomplete="off" /></label>
        <label>{{ t("目标出口") }}<select :aria-label="t('目标出口')" v-model="rule.outbound" class="mn-field"><option v-for="item in choices" :key="item.tag" :value="item.tag">{{ proxyDisplayName(item.tag) }}</option></select></label>
        <Button type="submit" :disabled="!formValid"><Plus :size="16" />{{ t("加入草稿") }}</Button>
      </form>
      <datalist id="routing-packages"><option v-for="item in state.packages" :key="item.packageName" :value="item.packageName" :label="item.appLabel" /></datalist>
      <Button variant="ghost" @click="state.packageQuery = ''; refreshPackages()">{{ t("读取已安装应用") }}</Button>
      <ol class="routing-rules"><li v-for="(item, index) in overlay.rules" :key="`${item.kind}:${item.value}`"><span class="routing-kind">{{ t(item.kind === 'domain' ? '域名' : '应用包名') }}</span><div><strong>{{ item.value }}</strong><span>→ {{ proxyDisplayName(item.outbound) }}</span></div><Button variant="ghost" :aria-label="t('修改规则')" @click="Object.assign(rule, item)"><Pencil :size="16" /></Button><Button variant="ghost" :aria-label="t('删除规则 {value}', { value: item.value })" @click="overlay.rules.splice(index, 1)"><Trash2 :size="16" /></Button></li></ol>
      <p v-if="!overlay.rules.length" class="routing-empty">{{ t("还没有自定义分流。订阅规则会照常工作。") }}</p>
      <details class="mn-disclosure"><summary>{{ t("自定义策略组与出口") }} · {{ overlay.outbounds.length }}</summary>
        <ul class="routing-outbounds"><li v-for="(item, index) in overlay.outbounds" :key="item.tag"><div><strong>{{ item.tag }}</strong><span>{{ item.type }}</span></div><Button v-if="['selector','urltest','socks','http','trojan','shadowsocks','vless'].includes(item.type)" variant="ghost" :aria-label="t('修改出口')" @click="editOutbound(item)"><Pencil :size="16" /></Button><Button variant="ghost" :aria-label="t('删除出口 {value}', { value: item.tag })" @click="overlay.outbounds.splice(index, 1)"><Trash2 :size="16" /></Button></li></ul>
        <form class="routing-form" @submit.prevent="addOutbound">
          <label>{{ t("出口类型") }}<select :aria-label="t('出口类型')" v-model="endpoint.type" class="mn-field"><option value="selector">{{ t("手动策略组") }}</option><option value="urltest">{{ t("自动测速组") }}</option><option value="socks">SOCKS5</option><option value="http">HTTP</option><option value="trojan">Trojan</option><option value="shadowsocks">Shadowsocks</option><option value="vless">VLESS</option></select></label>
          <label>{{ t("名称") }}<Input v-model="endpoint.tag" autocomplete="off" /></label>
          <label v-if="['selector','urltest'].includes(endpoint.type)" class="routing-wide">{{ t("组成员（原始名称，逗号分隔）") }}<Input v-model="endpoint.members" /></label>
          <template v-else><label>{{ t("服务器") }}<Input v-model="endpoint.server" autocomplete="off" /></label><label>{{ t("端口") }}<Input v-model="endpoint.port" type="number" min="1" max="65535" /></label><label v-if="['socks','http'].includes(endpoint.type)">{{ t("用户名") }}<Input v-model="endpoint.username" autocomplete="off" /></label><label v-if="endpoint.type !== 'vless'">{{ t("密码") }}<Input v-model="endpoint.password" type="password" autocomplete="new-password" /></label><label v-if="endpoint.type === 'vless'">UUID<Input v-model="endpoint.uuid" type="password" autocomplete="off" /></label><label v-if="endpoint.type === 'shadowsocks'">{{ t("加密方式") }}<Input v-model="endpoint.method" /></label><template v-if="['http','trojan','vless'].includes(endpoint.type)"><label class="routing-check"><input v-model="endpoint.tls" type="checkbox" />TLS</label><label>SNI<Input v-model="endpoint.sni" /></label></template></template>
          <Button type="submit"><Plus :size="16" />{{ t("加入或更新出口") }}</Button>
        </form>
      </details>
    </fieldset>
    <div class="routing-actions"><Button variant="secondary" :disabled="Boolean(busy) || revision === null" @click="preview"><Check :size="16" />{{ t("预览变更") }}</Button><Button :disabled="Boolean(busy) || !validated || validated !== serialized" @click="save">{{ t(busy === 'save' ? '应用中…' : '保存并应用') }}</Button><Button variant="ghost" :disabled="Boolean(busy) || !previous" @click="undo"><Undo2 :size="16" />{{ t("撤销上次应用") }}</Button><Button variant="ghost" :disabled="Boolean(busy)" @click="reload"><RefreshCw :size="16" />{{ t("重新读取") }}</Button></div>
    <p v-if="busy" role="status">{{ t("正在处理分流配置，请稍候…") }}</p>
    <p v-if="message" :role="failed ? 'alert' : 'status'" :class="{ 'routing-error': failed }">{{ message }}</p>
    <div v-if="reloadRequested" class="routing-confirm" role="alert"><p>{{ t("重新读取会丢弃未保存的草稿。") }}</p><Button variant="secondary" @click="reloadRequested = false">{{ t("保留草稿") }}</Button><Button @click="load">{{ t("放弃草稿并重新读取") }}</Button></div>
  </section>
</template>

<style scoped>
.routing-editor { padding:24px 0; border-top:2px solid var(--mn-ink); border-bottom:1px solid var(--mn-border); min-width:0; }
.routing-header { display:flex; justify-content:space-between; align-items:start; gap:16px; margin-bottom:24px; }
.routing-eyebrow,.routing-kind,.routing-state { font-family:var(--font-mono); font-size:11px; letter-spacing:.04em; color:var(--mn-ink-muted); }
h2 { font-size:24px; font-weight:600; letter-spacing:-.035em; margin:8px 0; }
p,span { overflow-wrap:anywhere; }
.routing-header p:last-child,.routing-empty { color:var(--mn-ink-muted); font-size:13px; line-height:1.7; }
fieldset { border:0; padding:0; margin:0; min-width:0; }
.routing-form { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:14px; align-items:end; margin:16px 0; }
label { display:grid; gap:8px; font-size:12px; color:var(--mn-ink-soft); min-width:0; }
select { width:100%; min-height:48px; padding:10px 12px; border-radius:var(--mn-radius-sm); }
.routing-wide { grid-column:1 / -1; }
.routing-rules,.routing-outbounds { list-style:none; padding:0; margin:16px 0; }
li { display:flex; align-items:center; gap:12px; padding:14px 0; border-bottom:1px solid var(--mn-border); min-width:0; }
li>div { display:grid; gap:4px; min-width:0; flex:1; overflow-wrap:anywhere; }
li strong { font-size:14px; font-weight:500; } li span { font-size:12px; color:var(--mn-ink-muted); }
.routing-kind { width:64px; flex-shrink:0; }
.routing-actions { display:flex; flex-wrap:wrap; gap:8px; margin:20px 0 12px; }
.routing-error { color:var(--mn-danger); } .routing-check { display:flex; align-items:center; min-height:48px; }
.routing-confirm { border:1px solid var(--mn-border-strong); padding:16px; margin-top:12px; }
@media(min-width:720px) { .routing-form { grid-template-columns:repeat(3,minmax(0,1fr)); }.routing-wide { grid-column:span 2; } }
@media(max-width:359px) { .routing-form { grid-template-columns:minmax(0,1fr); }.routing-wide { grid-column:auto; }.routing-kind { width:48px; } }
</style>
