import { sanitizeProxyName, type ProxyGroupSummary } from "@/composables/proxyGroupParsers";
import { t } from "@/i18n";

const builtInNames: Record<string, string> = {
  proxy: "代理", direct: "直连", block: "拦截", select: "主策略", final: "默认出口",
  "proxy-auto": "自动测速", lan: "局域网", hotspot: "热点共享",
  "ad-block": "广告拦截", "ad-allow": "广告放行", "cn-direct": "国内流量",
  "apple-cn": "Apple 国内服务", "microsoft-cn": "Microsoft 国内服务",
  icloud: "iCloud", bing: "Bing", "dns-guard": "DNS 保护", "network-test": "网络检测",
  "proxy-rule": "代理规则", "dev-proxy": "开发服务", "social-proxy": "社交服务",
  "media-proxy": "影音服务", "game-proxy": "游戏服务", "download-direct": "下载服务",
  "ai-proxy": "AI 服务", "ai-chatgpt": "ChatGPT", "ai-gemini": "Gemini",
  "ai-grok": "Grok", "ai-claude": "Claude", "google-proxy": "Google 服务",
  "youtube-proxy": "YouTube", "github-proxy": "GitHub", "discord-proxy": "Discord",
  "netflix-proxy": "Netflix", "spotify-proxy": "Spotify", "twitter-proxy": "X / Twitter",
  "whatsapp-proxy": "WhatsApp", "telegram-proxy": "Telegram",
  chain: "链式代理", "chain-hop1": "前置代理", "chain-exit": "链式出口", "chain-auto": "自动链式出口",
};

/** Labels never replace the raw names used for selection or configuration. */
export function proxyNameLabel(name: string): string {
  return Object.hasOwn(builtInNames, name) ? t(builtInNames[name]) : sanitizeProxyName(name);
}

export function proxyDisplayName(name: string): string {
  const raw = sanitizeProxyName(name);
  const label = proxyNameLabel(name);
  return label === raw ? raw : `${label} (${raw})`;
}

function matchesName(name: string, needle: string): boolean {
  return proxyDisplayName(name).toLowerCase().includes(needle);
}

/** Search the complete snapshot before limiting the rendered list. */
export function matchingProxyGroups(groups: ProxyGroupSummary[], query: string): ProxyGroupSummary[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return groups;
  return groups.filter((group) => [group.name, group.type, group.now, ...group.proxies]
    .some((value) => matchesName(value, needle)));
}

export function matchingProxyGroupNodes(group: ProxyGroupSummary, query: string): string[] {
  const needle = query.trim().toLowerCase();
  const groupMatched = [group.name, group.type, group.now]
    .some((value) => matchesName(value, needle));
  const nodes = !needle || groupMatched ? group.proxies : group.proxies.filter((node) =>
    matchesName(node, needle));
  // Keep a matching active choice visible even when it occurs late in a provider list.
  return nodes.includes(group.now)
    ? [group.now, ...nodes.filter((node) => node !== group.now)]
    : nodes;
}
