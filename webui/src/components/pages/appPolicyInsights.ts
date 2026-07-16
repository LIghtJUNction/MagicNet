export type AppPolicyMode = "blacklist" | "whitelist";

export type AppPolicyInsight = {
  label: string;
  value: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export type AppPolicySummary = {
  summary: string;
  items: AppPolicyInsight[];
  conflicts: string[];
  installedProxy: string[];
  installedBypass: string[];
};

export type AppPolicySafeReportInput = {
  mode: AppPolicyMode;
  proxy: string[];
  bypass: string[];
  summary: AppPolicySummary;
};

export const recommendedBypass = [
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
  "com.taobao.idlefish",
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

export function isValidPackageName(pkg: string): boolean {
  return /^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg);
}

export function buildAppPolicySummary(
  mode: AppPolicyMode,
  proxy: string[],
  bypass: string[],
  installedPackages: Set<string>,
  availableRecommendedCount: number
): AppPolicySummary {
  const proxySet = new Set(proxy);
  const bypassSet = new Set(bypass);
  const conflicts = proxy.filter((pkg) => bypassSet.has(pkg));
  const installedProxy = installedPackages.size ? proxy.filter((pkg) => installedPackages.has(pkg)) : [];
  const installedBypass = installedPackages.size ? bypass.filter((pkg) => installedPackages.has(pkg)) : [];
  const installedKnown = installedPackages.size > 0;
  const unlisted = mode === "whitelist" ? "绕过 TUN" : "进入 TUN";
  return {
    summary: mode === "whitelist"
      ? "Proxy 名单强制走 MagicNet proxy；未列出应用绕过 TUN。"
      : "Proxy 名单强制走 MagicNet proxy；Bypass 名单绕过 TUN，未列出应用正常进入 TUN。",
    conflicts,
    installedProxy,
    installedBypass,
    items: [
      insight("Proxy 强制", `${proxy.length} 个`, proxy.length ? "success" : "neutral"),
      insight("Bypass 绕过", `${bypass.length} 个`, bypass.length ? "success" : "neutral"),
      insight("未列出应用", unlisted, mode === "blacklist" ? "success" : "neutral"),
      insight("名单冲突", conflicts.length ? `${conflicts.length} 个` : "无", conflicts.length ? "danger" : "success"),
      insight("当前列表命中", installedKnown ? `Proxy ${installedProxy.length} / Bypass ${installedBypass.length}` : "未读取应用", installedKnown ? "success" : "warning"),
      insight("可应用推荐", `${availableRecommendedCount} 个`, availableRecommendedCount ? "neutral" : "success")
    ]
  };
}

export function formatAppPolicySafeReport(input: AppPolicySafeReportInput): string {
  return [
    "MagicNet app policy",
    "privacy_note=package names omitted; fingerprints are weak change markers, not privacy proof",
    `mode=${input.mode}`,
    `proxy_count=${input.proxy.length}`,
    `bypass_count=${input.bypass.length}`,
    `summary=${input.summary.summary}`,
    `conflict_count=${input.summary.conflicts.length}`,
    `current_list_proxy=${input.summary.installedProxy.length}`,
    `current_list_bypass=${input.summary.installedBypass.length}`,
    `proxy_fingerprint=${fingerprintList(input.proxy)}`,
    `bypass_fingerprint=${fingerprintList(input.bypass)}`,
    `conflict_fingerprint=${fingerprintList(input.summary.conflicts)}`,
    "",
    "[insights]",
    ...input.summary.items.map((item) => `${item.label}=${item.value} (${item.tone})`)
  ].join("\n").trim();
}

export function formatAppPolicyFullReport(input: AppPolicySafeReportInput): string {
  return [
    "MagicNet app policy",
    "privacy_note=contains package names from app policy lists",
    `mode=${input.mode}`,
    `proxy_count=${input.proxy.length}`,
    `bypass_count=${input.bypass.length}`,
    `summary=${input.summary.summary}`,
    `conflict_count=${input.summary.conflicts.length}`,
    `current_list_proxy=${input.summary.installedProxy.length}`,
    `current_list_bypass=${input.summary.installedBypass.length}`,
    "",
    "[insights]",
    ...input.summary.items.map((item) => `${item.label}=${item.value} (${item.tone})`),
    "",
    "[proxy]",
    ...input.proxy,
    "",
    "[bypass]",
    ...input.bypass
  ].join("\n").trim();
}

function insight(label: string, value: string, tone: AppPolicyInsight["tone"]): AppPolicyInsight {
  return { label, value, tone };
}

function fingerprintList(values: string[]): string {
  if (!values.length) return "none";
  return fnv32(values.slice().sort().join("\n")).toString(16).padStart(8, "0");
}

function fnv32(value: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}
