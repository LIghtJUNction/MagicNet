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
    blocklist.manual.length ? "本地阻断" : "",
    blocklist.community && communityEntries.length ? "社区库" : ""
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
      ? `${activeSources.join(" + ") || "无规则"} 生效`
      : "黑名单已关闭，所有阻断规则暂不生效",
    communityEntries,
    insights: [
      insight("总开关", blocklist.enabled ? "启用" : "关闭", blocklist.enabled ? "success" : "warning"),
      insight("社区库", blocklist.community ? "启用" : "关闭", blocklist.community ? "success" : "neutral"),
      insight("本地阻断", `${blocklist.manual.length} 条`, blocklist.manual.length ? "success" : "neutral"),
      insight("社区有效", `${communityEntries.length} 条`, communityEntries.length ? "success" : "warning"),
      insight("本地排除", `${blocklist.allowRules.length} 条`, blocklist.allowRules.length ? "warning" : "neutral")
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
