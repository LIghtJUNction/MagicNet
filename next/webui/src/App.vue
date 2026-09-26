<script setup lang="ts">
import { computed, onMounted, onBeforeUnmount, ref, watch, nextTick } from 'vue';
import { send, nativeAvailable } from './bridge';
import { request, status as parseStatus, settings as parseSettings, capabilities as parseCapabilities, RpcError, type Settings, type Status, type Capabilities } from './protocol';

type Page = 'overview' | 'sources' | 'network' | 'maintenance';
const pages: { id: Page; title: string; icon: string }[] = [{id:'overview',title:'概览',icon:'◉'},{id:'sources',title:'订阅',icon:'＋'},{id:'network',title:'网络',icon:'⇄'},{id:'maintenance',title:'维护',icon:'≡'}];
const page = ref<Page>('overview');
const current = ref<Status | null>(null), saved = ref<Settings | null>(null), caps = ref<Capabilities | null>(null);
const urls = ref(''), local = ref(''), agent = ref(''), template = ref('');
const busy = ref(false), error = ref(''), note = ref(''), stale = ref(false), diagnostics = ref('');
const showAdvanced = ref(false), confirmReload = ref(false), modal = ref<HTMLElement | null>(null);
let previousFocus: HTMLElement | null = null;
watch(confirmReload, async open => { if (open) { previousFocus = document.activeElement as HTMLElement; await nextTick(); modal.value?.querySelector<HTMLButtonElement>('button')?.focus(); } else previousFocus?.focus(); });
function modalKey(event: KeyboardEvent) { if (event.key === 'Escape') { confirmReload.value = false; event.preventDefault(); } if (event.key === 'Tab') { const buttons = modal.value?.querySelectorAll<HTMLButtonElement>('button'); if (!buttons?.length) return; const first = buttons[0]!, last = buttons[buttons.length-1]!; if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); } else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); } } }
const dirty = computed(() => !!saved.value && (urls.value !== saved.value.sources.map(s => s.url).join('\n') || agent.value !== saved.value.user_agent || template.value !== JSON.stringify(saved.value.template,null,2)));
const activeOperation = computed(() => current.value?.operation?.phase === 'running');
const editable = computed(() => nativeAvailable() && saved.value !== null && caps.value !== null && !busy.value && !activeOperation.value && !stale.value);
const phase = computed(() => stale.value ? '状态已过期' : ({running:'进程正在运行',stopped:'已停止',ownership_changed:'进程身份已变化',unknown:'状态待确认'}[current.value?.phase ?? 'unknown']));
const revision = computed(() => current.value ? `${current.value.configured_revision} / ${current.value.effective_revision}` : '— / —');
const messages: Record<string,string> = {
  bridge_unavailable:'请从 KernelSU 打开模块界面。浏览器不会模拟运行状态。', invalid_response:'模块返回的数据无效，没有将它当作操作成功。',
  revision_conflict:'配置已经被其他操作修改。你的输入仍然保留，请先重新加载再比较。', busy:'另一项操作正在进行；没有强行删除它的锁。',
  acceptance_required:'重写版尚未完成 Android 验收，启用入口仍被保护。', migration_required:'当前目录尚未完成迁移，不会覆盖旧模块。',
  missing_dependency:'模块缺少所需工具；没有清空已保存的订阅。', subscription_fetch_failed:'订阅更新失败，原有节点和配置仍被保留。',
  no_supported_nodes:'没有找到支持的节点，原配置未被替换。', invalid_subscription:'无法解析这份订阅，请检查格式。',
  stop_timeout:'停止仍未完成，进程没有被强制杀死。请检查状态和恢复记录。', ownership_unknown:'无法确认进程归属，没有操作其他进程。',
  rollback_incomplete:'回滚尚未完成，恢复记录已保留。请先处理恢复。', cancelled:'操作已取消，尚未发布的修改不会生效。',
  response_timeout:'尚未收到结果；这不代表后台操作失败，也不应直接重复提交。', invalid_config:'配置未通过内核校验，原运行配置未被替换。',
  too_large:'输入内容超过上限。', invalid_url:'订阅链接格式不正确。', invalid_user_agent:'User-Agent 必须是一行有效文字。',
  invalid_request:'请求格式无效。', request_conflict:'请求标识冲突，没有重复执行。', source_not_ready:'请先成功更新订阅，再应用配置。',
};
function failure(value: unknown) {
  const code = value instanceof RpcError ? value.code : 'unexpected_error';
  error.value = messages[code] ?? `操作没有完成（${code}）。`; note.value = '';
}
function syncDraft(value: Settings) { saved.value = value; urls.value = value.sources.map(s=>s.url).join('\n'); agent.value = value.user_agent; template.value = JSON.stringify(value.template,null,2); }
let polling = false, timer: ReturnType<typeof setTimeout> | undefined, disposed = false;
async function observe() {
  if (polling || !nativeAvailable()) return;
  polling = true;
  try { current.value = parseStatus(await send(request('status'))); stale.value = false; }
  catch (e) { stale.value = true; failure(e); }
  finally { polling = false; }
}
async function load(force = false) {
  if (dirty.value && !force) { confirmReload.value = true; return; }
  confirmReload.value = false; busy.value = true; error.value = '';
  try {
    caps.value = parseCapabilities(await send(request('capabilities')));
    syncDraft(parseSettings(await send(request('settings'))));
    await observe();
  } catch (e) { failure(e); } finally { busy.value = false; }
}
async function mutate(method: string, params: unknown = null) {
  if ((!editable.value && method !== 'service.stop') || !saved.value) return;
  if ((method === 'settings.replace' && urls.value !== saved.value.sources.map(s=>s.url).join('\n')) || (method === 'sources.replace' && (agent.value !== saved.value.user_agent || template.value !== JSON.stringify(saved.value.template,null,2)))) { error.value = '请先保存另一页面的修改，避免丢失尚未提交的草稿。'; return; }
  if (!caps.value?.write.includes(method)) { failure(new RpcError('unsupported_command')); return; }
  busy.value = true; error.value = ''; note.value = '';
  try {
    await send(request(method, params, saved.value.revision));
    // Lifecycle recovery can run while a user has an unrelated draft. Keep
    // its original base revision so a later save conflicts rather than
    // silently rebasing and overwriting concurrent configuration changes.
    if (!dirty.value || method === 'settings.replace' || method === 'sources.replace') syncDraft(parseSettings(await send(request('settings'))));
    if (method === 'sources.import') local.value = '';
    note.value = method.startsWith('sources.') || method === 'settings.replace' ? '已保存，尚未应用到运行配置。' : '操作已返回，请以当前状态为准。';
  } catch (e) { failure(e); }
  finally { await observe(); busy.value = false; }
}
function saveNetwork() {
  if (!saved.value) return;
  try { const value: unknown = JSON.parse(template.value); if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(); void mutate('settings.replace', {...saved.value, user_agent:agent.value, template:value}); }
  catch { error.value = '原生配置不是有效的 JSON 对象；你的输入仍然保留。'; }
}
async function diagnose() {
  try { diagnostics.value = JSON.stringify(await send(request('diagnostics')), null, 2); error.value = ''; }
  catch (e) { failure(e); }
}
function beforeUnload(event: BeforeUnloadEvent) { if (dirty.value || local.value) event.preventDefault(); }
onMounted(() => {
  if (nativeAvailable()) void load();
  const poll = async () => { if (disposed) return; if (!document.hidden) await observe(); if (!disposed) timer = setTimeout(poll, 2000); };
  timer = setTimeout(poll, 2000); window.addEventListener('beforeunload', beforeUnload);
});
onBeforeUnmount(() => { disposed = true; if (timer) clearTimeout(timer); window.removeEventListener('beforeunload', beforeUnload); });
</script>

<template>
  <div class="app-shell">
    <header class="topbar"><a class="brand" href="#" @click.prevent="page='overview'"><span class="brand-mark" aria-hidden="true">M</span>MagicNet<span class="badge">NEXT</span></a><span class="connection"><span class="dot" :class="{'dot-connected':nativeAvailable()}"></span>{{nativeAvailable()?'KernelSU 接口':'未连接设备'}}</span></header>
    <nav aria-label="主导航"><button v-for="item in pages" :key="item.id" :aria-current="page===item.id?'page':undefined" @click="page=item.id"><span aria-hidden="true">{{item.icon}}</span>{{item.title}}</button></nav>
    <main id="main-content">
      <div class="page-heading"><div><p class="eyebrow">MAGICNET / {{page.toUpperCase()}}</p><h1>{{pages.find(p=>p.id===page)?.title}}</h1></div><button class="quiet" :disabled="busy || !nativeAvailable()" @click="load()">重新读取</button></div>
      <aside class="candidate-note"><strong>独立重写候选版</strong><span>尚未替换旧模块。Android 验收、迁移和部分功能仍待完成。</span></aside>
      <div v-if="!nativeAvailable()" class="notice">当前仅展示界面结构。没有伪造节点、登录结果或联网状态。</div>
      <div v-if="error" role="alert" class="notice error">{{error}}</div><div v-if="note" role="status" class="notice success">{{note}}</div>
      <div v-if="activeOperation || busy" role="status" class="activity"><span class="spinner" aria-hidden="true"></span>{{activeOperation?'模块正在执行操作':'正在读取或保存'}}<code v-if="activeOperation">{{current?.operation?.method}}</code></div>

      <section v-if="page==='overview'" aria-label="运行概览" class="grid">
        <article class="card hero"><div class="card-top"><span class="eyebrow">运行状态</span><span class="pill">{{current?.mode?.toUpperCase() ?? '—'}}</span></div><h2 class="state-title">{{phase}}</h2><p>进程存活不等于网络正常。DNS、路由和应用联网需要分别验收。</p><div class="actions"><button class="primary" :disabled="!editable || caps?.lifecycle==='experimental'" @click="mutate('service.start')">应用并启用</button><button :disabled="!nativeAvailable() || !saved" @click="mutate('service.stop')">停止服务</button></div><p class="hint">候选运行时尚未通过验收，启用按钮暂不开放。</p></article>
        <article class="card"><h2>配置与实际状态</h2><dl><div><dt>配置意图</dt><dd>{{current ? current.configured?'启用':'停用' : '未读取'}}</dd></div><div><dt>保存 / 运行版本</dt><dd>{{revision}}</dd></div><div><dt>尚未应用</dt><dd>{{current ? current.pending_changes?'有修改':'无' : '未知'}}</dd></div><div><dt>恢复记录</dt><dd>{{current ? current.recovery_pending?'待处理':'无' : '未知'}}</dd></div></dl></article>
        <article class="card wide compact"><div><h2>订阅来源</h2><p>每行一个链接，保存后整份替换。删除链接会移除它对应的缓存节点。</p></div><button @click="page='sources'">管理订阅 <span aria-hidden="true">↗</span></button></article>
      </section>

      <section v-if="page==='sources'" aria-label="订阅管理" class="stack">
        <article class="card"><div class="card-top"><h2>订阅链接</h2><span class="pill">{{saved?.sources.length ?? 0}} 个来源</span></div><label for="urls">每行一个 HTTP / HTTPS 链接</label><textarea id="urls" v-model="urls" :disabled="!editable" rows="6" spellcheck="false" autocomplete="off" placeholder="https://example.test/subscription"></textarea><p class="hint">链接只交给本机模块，不会写入公开诊断。空列表表示移除全部 URL 来源，本地导入不会被删除。</p><div class="actions"><button class="primary" :disabled="!editable" @click="mutate('sources.replace',{text:urls})">保存链接列表</button><button :disabled="!editable || !saved?.sources.length || dirty" @click="mutate('sources.refresh')">更新订阅</button></div></article>
        <article class="card"><h2>本地导入</h2><p>支持原生 JSON、Clash JSON；YAML 由模块内的 yq 解码。仅导入节点，不接受订阅修改本机路由。</p><label for="local">订阅内容</label><textarea id="local" v-model="local" :disabled="!editable" rows="5" spellcheck="false" placeholder='{"outbounds": [...]}'></textarea><div class="actions"><button :disabled="!editable || !local.trim() || dirty" @click="mutate('sources.import',{body:local})">校验并保存本地节点</button></div></article>
      </section>

      <section v-if="page==='network'" aria-label="网络配置" class="stack">
        <article class="card"><h2>连接方式</h2><div class="mode-options"><div class="mode-option selected"><strong>TUN</strong><span>默认模式，接口 magicnet0</span></div><div class="mode-option"><strong>eBPF <span class="pill">待迁移</span></strong><span>未通过新运行时验收，不自动切换或降级。</span></div></div><label for="agent">订阅 User-Agent</label><input id="agent" v-model="agent" :disabled="!editable" maxlength="256" autocomplete="off"><p class="hint">订阅请求不使用用户配置的 HTTP 代理。内核透明路由能否直连需要设备验证。</p><div class="actions"><button :disabled="!editable" @click="saveNetwork">保存网络配置</button><button class="quiet" :aria-expanded="showAdvanced" @click="showAdvanced=!showAdvanced">{{showAdvanced?'收起':'查看'}}原生配置</button></div><div v-if="showAdvanced" class="advanced"><label for="template">原生 sing-box 模板</label><textarea id="template" v-model="template" :disabled="!editable" rows="14" spellcheck="false"></textarea><p class="hint">保存仅修改意图；应用之前必须通过安装内核的校验。</p></div></article>
        <article class="card compact"><div><h2>Tailscale</h2><p>禁用、退出登录和路由回收尚未迁移。此候选版不会读取或清除旧模块的登录状态。</p></div><span class="pill">未接入</span></article>
      </section>

      <section v-if="page==='maintenance'" aria-label="维护与诊断" class="stack">
        <article class="card"><h2>事务恢复</h2><p>先核对进程归属，再处理未完成事务。不会删掉其他模块的规则，也不会通过强制杀死内核来伪装停止成功。</p><dl><div><dt>最近操作</dt><dd>{{current?.operation?.method ?? '未读取'}}</dd></div><div><dt>操作状态</dt><dd>{{current?.operation?.phase ?? '未知'}}</dd></div></dl><button :disabled="!editable" @click="mutate('runtime.recover')">核对并恢复事务</button></article>
        <article class="card"><h2>只读诊断</h2><p>不包含订阅链接、节点凭据和完整配置。不会为了生成报告而自动修复或改变网络。</p><button :disabled="!nativeAvailable()" @click="diagnose">读取诊断</button><pre v-if="diagnostics" tabindex="0" aria-label="诊断结果">{{diagnostics}}</pre></article>
        <article class="card"><h2>迁移边界</h2><p>旧版仍保留在归档分支。MCP、加密备份、热点、Wi-Fi 策略和完整 Android 生命周期尚未迁移，不能把这份候选代码当作安装包。</p></article>
      </section>
      <footer><span>MagicNet · 独立候选目录</span><span>只展示已验证的状态</span></footer>
    </main>
    <div v-if="confirmReload" class="modal-backdrop" @click.self="confirmReload=false"><section ref="modal" role="dialog" aria-modal="true" @keydown="modalKey" aria-labelledby="reload-title" class="modal"><h2 id="reload-title">丢弃尚未保存的修改？</h2><p>重新读取会替换订阅链接和网络配置草稿。</p><div class="actions"><button @click="confirmReload=false">保留输入</button><button class="danger" @click="load(true)">丢弃并重新读取</button></div></section></div>
  </div>
</template>
