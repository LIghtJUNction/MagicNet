import { sanitizeProxyName, type ProxyGroupSummary } from "@/composables/proxyGroupParsers";

/** Search the complete snapshot before limiting the rendered list. */
export function matchingProxyGroups(groups: ProxyGroupSummary[], query: string): ProxyGroupSummary[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return groups;
  return groups.filter((group) => [group.name, group.type, group.now, ...group.proxies]
    .some((value) => sanitizeProxyName(value).toLowerCase().includes(needle)));
}

export function matchingProxyGroupNodes(group: ProxyGroupSummary, query: string): string[] {
  const needle = query.trim().toLowerCase();
  const groupMatched = [group.name, group.type, group.now]
    .some((value) => sanitizeProxyName(value).toLowerCase().includes(needle));
  const nodes = !needle || groupMatched ? group.proxies : group.proxies.filter((node) =>
    sanitizeProxyName(node).toLowerCase().includes(needle));
  // Keep a matching active choice visible even when it occurs late in a provider list.
  return nodes.includes(group.now)
    ? [group.now, ...nodes.filter((node) => node !== group.now)]
    : nodes;
}
