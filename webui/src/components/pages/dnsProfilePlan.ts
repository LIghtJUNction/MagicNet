export type DnsProfilePlan = {
  profile: string;
  transport: string;
  primary: string;
  secondary: string;
  restart: boolean;
  items: Array<{ label: string; value: string; tone: "success" | "warning" | "danger" | "neutral" }>;
  warnings: string[];
};

const PROFILE_LABELS: Record<string, string> = {
  default: "默认 DNS",
  "cloudflare-doh": "Cloudflare DoH",
  "cloudflare-dot": "Cloudflare DoT",
  "cloudflare-udp": "Cloudflare UDP"
};

export function buildDnsProfilePlan(currentProfile: string, targetProfile: string): DnsProfilePlan {
  const target = normalizeDnsProfile(targetProfile);
  const current = normalizeDnsProfile(currentProfile);
  const transport = dnsTransport(target);
  const servers = dnsServers(target);
  const same = current === target;
  return {
    profile: target,
    transport,
    primary: servers.primary,
    secondary: servers.secondary,
    restart: true,
    items: [
      item("Profile", `${label(current)} -> ${label(target)}`, same ? "neutral" : "warning"),
      item("Transport", transport, transport === "udp" ? "warning" : "success"),
      item("Primary", servers.primary, "neutral"),
      item("Backup", servers.secondary || "none", servers.secondary ? "success" : "neutral"),
      item("Apply", same ? "重新应用并重启" : "写入配置并重启", "warning")
    ],
    warnings: [
      ...(same ? ["当前已经是该 DNS profile，确认执行通常只会重新应用配置。"] : []),
      ...(target === "cloudflare-udp" ? ["UDP 方式更容易受网络环境影响；如解析不稳定，优先改用 DoH/DoT。"] : []),
      ...(target !== "default" ? ["Cloudflare profile 会保留直连 bootstrap-local-dns，并把默认 DNS fallback 切到代理 detour 的 Cloudflare server。"] : [])
    ]
  };
}

export function formatDnsProfilePlanReport(plan: DnsProfilePlan): string {
  return [
    "MagicNet DNS profile plan",
    "privacy_note=contains profile names and public DNS server labels only",
    `profile=${plan.profile}`,
    `transport=${plan.transport}`,
    `primary=${plan.primary}`,
    `secondary=${plan.secondary || "none"}`,
    `restart=${plan.restart ? 1 : 0}`,
    `warning_count=${plan.warnings.length}`
  ].join("\n");
}

function normalizeDnsProfile(profile: string): string {
  if (["cloudflare", "doh", "1.1.1.1-doh"].includes(profile)) return "cloudflare-doh";
  if (["dot", "1.1.1.1-dot"].includes(profile)) return "cloudflare-dot";
  if (["udp", "1.1.1.1"].includes(profile)) return "cloudflare-udp";
  return ["cloudflare-doh", "cloudflare-dot", "cloudflare-udp"].includes(profile) ? profile : "default";
}

function dnsTransport(profile: string): string {
  if (profile === "cloudflare-doh") return "doh";
  if (profile === "cloudflare-dot") return "dot";
  if (profile === "cloudflare-udp") return "udp";
  return "default";
}

function dnsServers(profile: string): { primary: string; secondary: string } {
  if (profile === "default") return { primary: "bootstrap-local-dns", secondary: "" };
  if (profile === "cloudflare-doh") return { primary: "https://cloudflare-dns.com/dns-query", secondary: "https://1.0.0.1/dns-query" };
  if (profile === "cloudflare-dot") return { primary: "tls://1.1.1.1", secondary: "tls://1.0.0.1" };
  return { primary: "1.1.1.1", secondary: "1.0.0.1" };
}

function label(profile: string): string {
  return PROFILE_LABELS[profile] || profile;
}

function item(labelText: string, value: string, tone: DnsProfilePlan["items"][number]["tone"]): DnsProfilePlan["items"][number] {
  return { label: labelText, value, tone };
}
