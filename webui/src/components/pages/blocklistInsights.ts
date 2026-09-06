import { t } from "@/i18n";
import type { BlocklistState } from "@/types";

export type BlocklistInsight = {
  label: string;
  value: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export type BlocklistSummary = {
  status: "active" | "partial" | "empty" | "disabled";
  summary: string;
  insights: BlocklistInsight[];
  communityEntries: string[];
};

export function buildCommunityEntries(blocklist: BlocklistState): string[] {
  const rules = [...blocklist.communityRules];
  for (const domain of blocklist.communityDomains) {
    const rule = `DOMAIN-SUFFIX,${domain}`;
    if (!rules.includes(rule) && !blocklist.allowRules.includes(rule)) rules.push(rule);
  }
  return rules;
}

export function buildBlocklistSummary(blocklist: BlocklistState): BlocklistSummary {
  const communityEntries = buildCommunityEntries(blocklist);
  const activeSources = [
    blocklist.manual.length ? t('本地阻断') : "",
    blocklist.community && communityEntries.length ? t('社区库') : ""
  ].filter(Boolean);
  const status = !blocklist.enabled
    ? "disabled"
    : !activeSources.length
      ? "empty"
      : blocklist.community && communityEntries.length
        ? "active"
        : "partial";
  return {
    status,
    summary: blocklist.enabled
      ? t('{value} 生效', { value: activeSources.join(" + ") || t('无规则') })
      : t('黑名单已关闭，所有阻断规则暂不生效'),
    communityEntries,
    insights: [
      insight(t('总开关'), blocklist.enabled ? t('启用') : t('关闭'), blocklist.enabled ? "success" : "warning"),
      insight(t('社区库'), blocklist.community ? t('启用') : t('关闭'), blocklist.community ? "success" : "neutral"),
      insight(t('本地阻断'), t('{count} 条', { count: blocklist.manual.length }), blocklist.manual.length ? "success" : "neutral"),
      insight(t('社区有效'), t('{count} 条', { count: communityEntries.length }), communityEntries.length ? "success" : "warning"),
      insight(t('广告放行'), t('{count} 条', { count: blocklist.allowRules.length }), blocklist.allowRules.length ? "warning" : "neutral")
    ]
  };
}

export function filterBlocklistEntries(entries: string[], query: string): string[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return entries;
  return entries.filter((entry) => entry.toLowerCase().includes(needle));
}

function insight(label: string, value: string, tone: BlocklistInsight["tone"]): BlocklistInsight {
  return { label, value, tone };
}
