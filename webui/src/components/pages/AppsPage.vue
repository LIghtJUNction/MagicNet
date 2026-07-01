<script setup lang="ts">
import { CheckCircle2, Copy, ListFilter, Plus, RefreshCw, RotateCcw, Search, ShieldCheck, Trash2, X } from "lucide-vue-next";
import { computed, onMounted, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { state, runCli, refreshApps, refreshPackages, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const removedBypass = ref<string[]>([]);
const pendingAppAction = ref<PendingAppAction | null>(null);
const appReportCopied = ref(false);

type PendingAppAction = {
  key: string;
  command: string;
  message: string;
  run: () => Promise<void>;
};

const recommendedBypass = [
  "com.eg.android.AlipayGphone",
  "com.tencent.mm",
  "com.unionpay",
  "com.unionpay.tsmservice",
  "com.icbc",
  "com.chinamworld.main",
  "com.ccb.longjiLife",
  "com.ccb.fintech.app.productions",
  "com.bankcomm.Bankcomm",
  "com.cmbchina.ccd.pluto.cmbActivity",
  "com.cmbchina.cmbim",
  "com.pingan.paces.ccms",
  "cn.com.spdb.mobilebank.per",
  "com.cib.cibmb",
  "com.csii.citicbank",
  "com.ecitic.bank.mobile",
  "com.bankofbeijing.mobilebanking",
  "com.chinamobile.mcloud",
  "com.greenpoint.android.mc10086.activity",
  "com.ct.client",
  "com.sinovatech.unicom.ui",
  "com.taobao.taobao",
  "com.tmall.wireless",
  "com.jingdong.app.mall",
  "com.xunmeng.pinduoduo",
  "com.suning.mobile.ebuy",
  "com.xingin.xhs",
  "com.sankuai.meituan",
  "com.sankuai.meituan.takeoutnew",
  "com.dianping.v1",
  "com.autonavi.minimap",
  "com.baidu.BaiduMap",
  "com.sdu.didi.psnger",
  "ctrip.android.view",
  "com.MobileTicket",
  "com.tencent.mobileqq",
  "com.tencent.tim",
  "tv.danmaku.bili",
  "com.tencent.qqlive",
  "com.qiyi.video",
  "com.youku.phone",
  "com.ss.android.ugc.aweme",
  "com.ss.android.article.video",
  "com.smile.gifmaker",
  "com.kuaishou.nebula",
  "com.netease.cloudmusic",
  "com.tencent.qqmusic",
  "fm.xiami.main",
  "com.ximalaya.ting.android",
  "com.sina.weibo",
  "com.zhihu.android",
  "com.baidu.searchbox",
  "com.UCMobile",
  "com.quark.browser",
  "com.huawei.appmarket",
  "com.xiaomi.market",
  "com.heytap.market",
  "com.bbk.appstore",
  "com.sec.android.app.samsungapps",
  "com.supwisdom.zzu",
  "com.supwisdom.supwisdom",
  "com.wisedu.cpdaily",
  "com.lysoft.android.lyyd.report.mobile",
  "com.xuexitong",
  "com.chaoxing.mobile",
  "com.alibaba.android.rimet",
  "com.tencent.wework",
  "com.android.vending",
  "com.google.android.gms",
  "com.google.android.gsf"
];

const recycledBypass = computed(() => {
  const active = new Set(state.appPolicy.bypass);
  return removedBypass.value.filter((pkg) => !active.has(pkg));
});

const installedNames = computed(() => new Set(state.packages.map((item) => item.packageName)));

const filteredPackages = computed(() => {
  const query = state.packageQuery.trim().toLowerCase();
  const listed = state.packages.filter((item) => {
    if (!query) return true;
    return item.packageName.toLowerCase().includes(query);
  });
  return listed.slice(0, 120);
});

const availableRecommendedBypass = computed(() => {
  const active = new Set([...state.appPolicy.proxy, ...state.appPolicy.bypass]);
  const installed = installedNames.value;
  return recommendedBypass.filter((pkg) => {
    if (active.has(pkg)) return false;
    return installed.size === 0 || installed.has(pkg);
  });
});

function commandFailed(text: string): boolean {
  return /\b(error|failed|fail|Usage:|not found)\b/i.test(text);
}

function rememberRemovedBypass(pkg: string): void {
  removedBypass.value = [pkg, ...removedBypass.value.filter((item) => item !== pkg)].slice(0, 24);
}

function forgetRemovedBypass(pkg: string): void {
  removedBypass.value = removedBypass.value.filter((item) => item !== pkg);
}

function validateAppPackage(pkg: string, target: "proxy" | "bypass"): boolean {
  if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
    state.output = "包名格式不对。示例：com.android.chrome";
    return false;
  }
  const list = target === "proxy" ? state.appPolicy.proxy : state.appPolicy.bypass;
  if (list.includes(pkg)) {
    state.output = `${pkg} 已存在，已自动去重。`;
    state.packageInput = "";
    return false;
  }
  return true;
}

function addApp(target: "proxy" | "bypass"): void {
  requestAddPackage(state.packageInput.trim(), target, `add-${target}`);
}

async function addPackage(pkg: string, target: "proxy" | "bypass", key = `add-${target}`): Promise<void> {
  await withAction(key, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    const list = target === "proxy" ? state.appPolicy.proxy : state.appPolicy.bypass;
    if (target === "proxy") state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
    else state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    list.push(pkg);
    state.packageInput = "";
    if (target === "bypass") forgetRemovedBypass(pkg);
    state.output = `已加入界面，正在保存 ${pkg}...`;
    const text = await runCli(`app add ${shellQuote(pkg)} ${target}`, `添加应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
  });
}

function requestAddPackage(pkg: string, target: "proxy" | "bypass", key = `add-${target}`): void {
  if (!validateAppPackage(pkg, target)) return;
  pendingAppAction.value = {
    key,
    command: `app add ${pkg} ${target}`,
    message: target === "proxy"
      ? `确认把 ${pkg} 加入 Proxy？该应用流量会进入 MagicNet TUN。`
      : `确认把 ${pkg} 加入 Bypass？该应用会绕过 MagicNet TUN。`,
    run: () => addPackage(pkg, target, key)
  };
}

async function removeApp(pkg: string, target: "proxy" | "bypass"): Promise<void> {
  await withAction(`remove-${target}-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    if (target === "proxy") {
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    } else {
      state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
      rememberRemovedBypass(pkg);
    }
    state.output = `已从界面移除 ${pkg}，正在后台保存...`;
    const text = await runCli(`app remove ${shellQuote(pkg)} ${target}`, `移除应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
  });
}

async function restoreBypass(pkg: string): Promise<void> {
  await withAction(`restore-bypass-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
    state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    state.output = `正在把 ${pkg} 加回 Bypass...`;
    const text = await runCli(`app add ${shellQuote(pkg)} bypass`, `恢复 Bypass 应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
    forgetRemovedBypass(pkg);
  });
}

async function setMode(mode: "blacklist" | "whitelist"): Promise<void> {
  await withAction(`mode-${mode}`, async () => {
    await runCli(`app mode ${mode}`, mode === "blacklist" ? "切换黑名单模式" : "切换白名单模式");
    await refreshApps(true);
  });
}

function requestSetMode(mode: "blacklist" | "whitelist"): void {
  pendingAppAction.value = {
    key: `mode-${mode}`,
    command: `app mode ${mode}`,
    message: mode === "blacklist" ? "确认切换到黑名单模式？应用分流语义会立即改变。" : "确认切换到白名单模式？只有 Proxy 名单应用会进入 TUN。",
    run: () => setMode(mode)
  };
}

async function searchPackages(): Promise<void> {
  await withAction("search-packages", () => refreshPackages());
}

async function copyAppPolicyReport(): Promise<void> {
  const report = [
    "MagicNet app policy",
    `mode=${state.appPolicy.mode}`,
    `proxy_count=${state.appPolicy.proxy.length}`,
    `bypass_count=${state.appPolicy.bypass.length}`,
    "",
    "[proxy]",
    ...state.appPolicy.proxy,
    "",
    "[bypass]",
    ...state.appPolicy.bypass
  ].join("\n").trim();
  appReportCopied.value = await copyText(report);
  state.output = appReportCopied.value ? "应用策略快照已复制。" : "剪贴板不可用，应用策略快照未复制。";
}

async function applyRecommendedBypass(): Promise<void> {
  await withAction("apply-recommended-bypass", async () => {
    const packages = availableRecommendedBypass.value;
    if (!packages.length) {
      state.output = "没有可加入的推荐 Bypass 应用。";
      return;
    }
    packages.forEach((pkg) => {
      if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
      forgetRemovedBypass(pkg);
    });
    const quoted = packages.map((pkg) => shellQuote(pkg)).join(" ");
    const text = await runCli(`app add-many bypass ${quoted}`, `应用推荐 Bypass 名单`);
    if (commandFailed(text)) {
      state.output = text;
      await refreshApps(true);
      return;
    }
    await refreshApps(true);
  });
}

function requestRecommendedBypass(): void {
  const count = availableRecommendedBypass.value.length;
  pendingAppAction.value = {
    key: "apply-recommended-bypass",
    command: `app add-many bypass (${count} packages)`,
    message: `确认把 ${count} 个推荐应用加入 Bypass？这会批量改写应用策略。`,
    run: applyRecommendedBypass
  };
}

function requestRemoveApp(pkg: string, target: "proxy" | "bypass"): void {
  pendingAppAction.value = {
    key: `remove-${target}-${pkg}`,
    command: `app remove ${pkg} ${target}`,
    message: `确认从 ${target} 名单移除 ${pkg}？`,
    run: () => removeApp(pkg, target)
  };
}

function requestRestoreBypass(pkg: string): void {
  pendingAppAction.value = {
    key: `restore-bypass-${pkg}`,
    command: `app add ${pkg} bypass`,
    message: `确认把 ${pkg} 加回 Bypass 名单？`,
    run: () => restoreBypass(pkg)
  };
}

function cancelAppAction(): void {
  pendingAppAction.value = null;
}

async function confirmAppAction(): Promise<void> {
  const action = pendingAppAction.value;
  if (!action) return;
  pendingAppAction.value = null;
  try {
    await action.run();
  } finally {
    if (pendingAppAction.value?.key === action.key) pendingAppAction.value = null;
  }
}

onMounted(() => {
  if (!state.packages.length) void refreshPackages(true);
});
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Per App Policy" title="应用名单" description="只管理应用进入或绕过 MagicNet TUN 的名单，不做节点和代理模式控制。">
      <div class="flex flex-wrap gap-2">
        <Button variant="outline" :loading="isRunning('refresh-apps')" @click="withAction('refresh-apps', () => refreshApps())"><RefreshCw :size="17" />读取名单</Button>
        <Button variant="outline" :loading="isRunning('search-packages')" @click="searchPackages"><ListFilter :size="17" />重新读取应用</Button>
        <Button variant="outline" :loading="isRunning('copy-app-policy-report')" @click="withAction('copy-app-policy-report', copyAppPolicyReport)"><Copy :size="17" />{{ appReportCopied ? '已复制快照' : '复制快照' }}</Button>
        <Button :loading="isRunning('apply-recommended-bypass')" :disabled="availableRecommendedBypass.length === 0" @click="requestRecommendedBypass"><ShieldCheck :size="17" />应用推荐名单</Button>
      </div>
    </PageHeader>

    <Card v-if="pendingAppAction" class="grid gap-3 border border-amber-500/40 bg-amber-500/10">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <span class="text-[11px] font-bold uppercase tracking-wide text-amber-300">Confirm app policy</span>
          <p class="mt-1 text-sm leading-6 text-amber-100">{{ pendingAppAction.message }}</p>
          <code class="mt-2 block break-all rounded-md bg-zinc-950/60 px-3 py-2 text-xs text-zinc-100">{{ pendingAppAction.command }}</code>
        </div>
        <div class="flex shrink-0 gap-2">
          <Button variant="secondary" :loading="isRunning(pendingAppAction.key)" @click="confirmAppAction">确认</Button>
          <Button variant="outline" @click="cancelAppAction">取消</Button>
        </div>
      </div>
    </Card>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <div class="inline-flex w-fit rounded-md border border-zinc-800 bg-zinc-950 p-1">
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-blacklist') || state.appPolicy.mode === 'blacklist'" :class="{ 'bg-zinc-800 text-zinc-50': state.appPolicy.mode === 'blacklist' }" @click="requestSetMode('blacklist')">黑名单</button>
          <button class="h-9 rounded px-3 text-sm text-zinc-400 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-whitelist') || state.appPolicy.mode === 'whitelist'" :class="{ 'bg-zinc-800 text-zinc-50': state.appPolicy.mode === 'whitelist' }" @click="requestSetMode('whitelist')">白名单</button>
        </div>
        <span class="text-sm text-zinc-500">黑名单模式下 Bypass 应用绕过 TUN；白名单模式下 Proxy 应用进入 TUN。</span>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
        <Input v-model="state.packageInput" placeholder="com.android.chrome" spellcheck="false" />
        <Button variant="secondary" :loading="isRunning('add-proxy')" @click="addApp('proxy')"><Plus :size="16" />{{ isRunning('add-proxy') ? '保存中' : 'Proxy' }}</Button>
        <Button variant="secondary" :loading="isRunning('add-bypass')" @click="addApp('bypass')"><Plus :size="16" />{{ isRunning('add-bypass') ? '保存中' : 'Bypass' }}</Button>
      </div>
    </Card>

    <div class="grid gap-3 lg:grid-cols-[minmax(0,1.25fr)_minmax(280px,0.75fr)]">
      <Card class="grid gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <div class="relative min-w-0 flex-1">
            <Search class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-600" :size="16" />
            <Input v-model="state.packageQuery" class="pl-9" placeholder="搜索已安装应用包名" spellcheck="false" @keyup.enter="searchPackages" />
          </div>
          <Button variant="secondary" :loading="isRunning('search-packages')" @click="searchPackages">重新读取</Button>
        </div>
        <div class="grid max-h-72 gap-2 overflow-auto">
          <div v-for="app in filteredPackages" :key="app.packageName" class="grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-center">
            <span class="min-w-0 break-all text-sm text-zinc-200">{{ app.packageName }}</span>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-proxy-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'proxy', `pick-proxy-${app.packageName}`)">Proxy</Button>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-bypass-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'bypass', `pick-bypass-${app.packageName}`)">Bypass</Button>
          </div>
          <em v-if="!filteredPackages.length" class="text-sm not-italic text-zinc-500">暂无结果，点“列出应用”或输入关键字过滤。</em>
        </div>
      </Card>

      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="text-base font-semibold">推荐 Bypass</h3>
            <p class="mt-1 text-sm leading-6 text-zinc-500">支付、银行、运营商、常用国内服务优先绕过，减少验证码、风控和国内服务误伤。</p>
          </div>
          <CheckCircle2 class="shrink-0 text-zinc-500" :size="18" />
        </div>
        <div class="flex max-h-64 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in availableRecommendedBypass" :key="pkg" class="inline-flex max-w-full items-center rounded-md border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs text-zinc-300 break-all">{{ pkg }}</span>
          <em v-if="!availableRecommendedBypass.length" class="text-sm not-italic text-zinc-500">推荐项已在名单中，或当前设备未读取到匹配应用。</em>
        </div>
      </Card>
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 text-base font-semibold">Proxy</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.proxy" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-proxy-${pkg}`)" type="button" title="移除" @click="requestRemoveApp(pkg, 'proxy')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.proxy.length" class="text-sm not-italic text-zinc-500">暂无应用</em>
        </div>
      </Card>
      <Card>
        <h3 class="mb-2 text-base font-semibold">Bypass</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.bypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-zinc-800 text-zinc-50 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-bypass-${pkg}`)" type="button" title="移入回收站" @click="requestRemoveApp(pkg, 'bypass')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.bypass.length" class="text-sm not-italic text-zinc-500">暂无应用</em>
        </div>
      </Card>
    </div>

    <Card class="grid gap-3 border-zinc-800/80 bg-zinc-950/65">
      <div class="flex items-center justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold">Bypass 回收站</h3>
          <p class="mt-1 text-sm text-zinc-500">从 Bypass 点 X 移除的应用会暂存在这里，可以直接加回名单。</p>
        </div>
        <Trash2 class="shrink-0 text-zinc-500" :size="18" />
      </div>
      <div class="flex max-h-56 flex-wrap gap-2 overflow-auto">
        <span v-for="pkg in recycledBypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-dashed border-zinc-700 bg-zinc-950 px-2 py-1 text-xs text-zinc-300 break-all">
          {{ pkg }}
          <button class="grid size-6 place-items-center rounded-full bg-emerald-500/15 text-emerald-300 disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`restore-bypass-${pkg}`)" type="button" title="加回 Bypass" @click="requestRestoreBypass(pkg)">
            <RotateCcw :size="14" />
          </button>
        </span>
        <em v-if="!recycledBypass.length" class="text-sm not-italic text-zinc-500">回收站为空</em>
      </div>
    </Card>
  </div>
</template>
