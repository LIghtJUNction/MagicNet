export type ProxyGroupSummary = {
  name: string;
  type: string;
  now: string;
  proxies: string[];
};

export type ProxyGroupsSnapshot = {
  groups: ProxyGroupSummary[];
};

export function parseProxyGroupsSnapshot(text: string): ProxyGroupsSnapshot | null {
  try {
    const root = JSON.parse(text) as Record<string, unknown>;
    const groups = [
      ...parseProxyGroupObject(objectValue(root.proxies)),
      ...parseProxyGroupObject(objectValue(root.providers))
    ];
    if (!groups.length) groups.push(...parseProxyGroupObject(root));
    return {
      groups: Array.from(new Map(groups.map((group) => [group.name, group])).values())
        .sort((left, right) => right.proxies.length - left.proxies.length)
    };
  } catch {
    return null;
  }
}

export function sanitizeProxyName(value: string): string {
  return value
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic|anytls):\/\/[^\s"'<>]+/gi, "[filtered-url]")
    .replace(/\b(private_?key|password|passwd|token|secret|uuid|api[_-]?key)(\s*[:=]\s*)[^\s,;}\]]+/gi, "$1$2[filtered]");
}

function parseProxyGroupObject(source: Record<string, unknown> | null): ProxyGroupSummary[] {
  if (!source) return [];
  return Object.entries(source)
    .map(([key, value]) => parseProxyGroup(key, objectValue(value)))
    .filter((group): group is ProxyGroupSummary => Boolean(group));
}

function parseProxyGroup(key: string, item: Record<string, unknown> | null): ProxyGroupSummary | null {
  if (!item) return null;
  const proxies = Array.isArray(item.proxies)
    ? item.proxies.map(proxyName).filter((name): name is string => Boolean(name))
    : [];
  if (!proxies.length && !stringValue(item.now)) return null;
  return {
    name: stringValue(item.name) || key,
    type: stringValue(item.type) || "provider",
    now: stringValue(item.now),
    proxies
  };
}

function proxyName(value: unknown): string | null {
  if (typeof value === "string") return value;
  const object = objectValue(value);
  return object ? stringValue(object.name) || null : null;
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}
