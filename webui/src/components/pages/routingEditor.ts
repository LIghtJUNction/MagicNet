export const ROUTING_KEY = "$magicnet_routing";
export type RoutingRule = { kind: "domain" | "app"; value: string; outbound: string };
export type RoutingOutbound = { tag: string; type: string; [key: string]: unknown };
export type RoutingOverlay = { schema: 1; rules: RoutingRule[]; outbounds: RoutingOutbound[] };
export type RoutingTarget = { tag: string; type: string };

export function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
export function parseOverlay(value: unknown): RoutingOverlay | null {
  if (value === undefined) return { schema: 1, rules: [], outbounds: [] };
  if (!object(value) || value.schema !== 1 || !Array.isArray(value.rules) || !Array.isArray(value.outbounds)) return null;
  const rules: RoutingRule[] = [];
  const outbounds: RoutingOutbound[] = [];
  for (const rule of value.rules) {
    if (!object(rule) || (rule.kind !== "domain" && rule.kind !== "app") || typeof rule.value !== "string" || typeof rule.outbound !== "string") return null;
    rules.push({ kind: rule.kind, value: rule.value, outbound: rule.outbound });
  }
  for (const item of value.outbounds) {
    if (!object(item) || typeof item.tag !== "string" || typeof item.type !== "string") return null;
    outbounds.push({ ...item, tag: item.tag, type: item.type });
  }
  return { schema: 1, rules, outbounds };
}
export function parseTargets(value: unknown): RoutingTarget[] | null {
  if (!Array.isArray(value)) return null;
  const result: RoutingTarget[] = [];
  for (const item of value) {
    if (!object(item) || typeof item.tag !== "string" || typeof item.type !== "string") return null;
    result.push({ tag: item.tag, type: item.type });
  }
  return result;
}
export function validRoutingValue(kind: "domain" | "app", value: string): boolean {
  if (kind === "app") return value.length <= 256 && value.includes(".") && value.split(".").every((part) => /^[A-Za-z0-9_]+$/.test(part));
  return value.length <= 253 && value.includes(".") && value.split(".").every((part) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part));
}
