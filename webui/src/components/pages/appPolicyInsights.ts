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
  const captured = mode === "whitelist" ? `${proxy.length} 个 Proxy 名单应用` : "除 Bypass 外的应用";
  const bypassed = mode === "whitelist" ? "非 Proxy 名单应用" : `${bypass.length} 个 Bypass 名单应用`;
  return {
    summary: mode === "whitelist" ? "白名单模式只让 Proxy 名单进入 TUN。" : "黑名单模式默认接管应用，Bypass 名单绕过 TUN。",
    conflicts,
    installedProxy,
    installedBypass,
    items: [
      insight("接管范围", captured, proxy.length || mode === "blacklist" ? "success" : "warning"),
      insight("绕过范围", bypassed, bypass.length || mode === "whitelist" ? "success" : "neutral"),
      insight("名单冲突", conflicts.length ? `${conflicts.length} 个` : "无", conflicts.length ? "danger" : "success"),
      insight("当前列表命中", installedKnown ? `Proxy ${installedProxy.length} / Bypass ${installedBypass.length}` : "未读取应用", installedKnown ? "success" : "warning"),
      insight("可应用推荐", `${availableRecommendedCount} 个`, availableRecommendedCount ? "neutral" : "success")
    ]
  };
}

function insight(label: string, value: string, tone: AppPolicyInsight["tone"]): AppPolicyInsight {
  return { label, value, tone };
}
