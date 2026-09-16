/** Explicit feedback evidence: fixed selector identities, never provider node names. */
export const ROUTE_TAGS = new Set([
  "proxy", "select", "final", "proxy-rule", "dns-guard", "network-test", "hotspot",
  "download-direct", "dev-proxy", "social-proxy", "media-proxy", "game-proxy",
  "telegram-proxy", "google-proxy", "youtube-proxy", "github-proxy", "discord-proxy",
  "netflix-proxy", "spotify-proxy", "twitter-proxy", "whatsapp-proxy", "ai-proxy",
  "ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude", "direct", "block", "warp",
  "cn-direct", "lan", "icloud", "apple-cn", "microsoft-cn", "ad-block", "ad-allow",
  "chain", "chain-hop1", "chain-exit", "chain-auto",
]);
export function safeRouteHop(value: unknown): string {
  return typeof value === "string" && ROUTE_TAGS.has(value.trim()) ? value.trim() : "[selected-node]";
}
export function safeRouteText(text: string): string {
  return text.replace(/\b(outbound|selector)\/([a-z0-9_-]+)\[([^\]\r\n]*)\]/gi,
    (_all, prefix, type, tag) => `${prefix}/${type}[${safeRouteHop(tag)}]`)
    .replace(/\broute\(([^)\r\n]*)\)/gi, (_all, tag) => `route(${safeRouteHop(tag)})`);
}
export function isGoogleEvidence(domain: string, process: string, chain: string): boolean {
  return /(?:^|\.)(?:google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com|ggpht\.com|gvt1\.com|gvt2\.com)$/.test(domain)
    || /\b(?:com\.android\.vending|com\.google\.android\.(?:gms|gsf))\b/.test(process)
    || chain.split(" -> ").includes("google-proxy");
}
/** Whole lines only: never present a cut rule as an intact routing decision. */
export function boundedLines(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const lines = text.split(/\r?\n/), kept: string[] = [];
  let length = 0, omitted = 0;
  for (const line of lines) {
    if (length + line.length + 1 <= limit - 56) { kept.push(line); length += line.length + 1; }
    else omitted++;
  }
  return [...kept, `[omitted_lines=${omitted}; full evidence in output]`].join("\n");
}
/** Divide the compact support budget across sections instead of losing its middle. */
export function compactSupport(text: string, limit = 600): string {
  const sections = text.split(/(?=^\[[^\]\n]+\]$)/m);
  const wanted = ["service status", "health", "proxy selector and connection chains", "dns api and mcp", "subscription lifecycle"];
  return wanted.map(name => {
    const section = sections.find(s => s.startsWith(`[${name}]`));
    return section ? boundedLines(section.trim(), Math.floor(limit / wanted.length)) : `[${name}] unavailable`;
  }).join("\n");
}
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
/** Whitelist values rather than dumping machine envelopes or arbitrary error messages. */
export function compactService(text: string): string {
  try {
    const root = JSON.parse(text);
    if (!object(root) || root.schema !== 1 || root.ok !== true || root.command !== "service.status" || !object(root.data)) return "service_snapshot=unavailable";
    const data = root.data, lines: string[] = [];
    const walk = (value: unknown, path: string, depth: number): void => {
      if (depth > 5 || !object(value)) return;
      for (const [key, item] of Object.entries(value)) {
        if (!/^[a-z_]{1,40}$/.test(key)) continue;
        const name = path ? `${path}.${key}` : key;
        if (["ready", "running", "dataplane", "overall", "enabled", "process_state", "rss_kib", "effective_mode"].includes(key)) {
          if (typeof item === "boolean" || item === null || (key === "rss_kib" && Number.isSafeInteger(item) && Number(item) >= 0)
              || (typeof item === "string" && ["running", "stopped", "unknown", "ready", "unready", "healthy", "unhealthy", "tun", "ebpf"].includes(item))) lines.push(`${name}=${item}`);
        } else walk(item, name, depth + 1);
      }
    };
    walk(data, "", 0);
    return lines.length ? lines.join("\n") : "service_snapshot=unavailable";
  } catch { return "service_snapshot=unavailable"; }
}
export function selectorEvidence(text: string): string {
  try {
    const root = JSON.parse(text);
    if (!object(root) || !object(root.proxies)) return "selectors=unavailable";
    const proxies = root.proxies;
    return ["google-proxy", "proxy", "cn-direct", "ad-block"].map(tag => {
      let current = tag;
      const seen = new Set<string>(), chain: string[] = [];
      for (let i = 0; i < 12; i++) {
        if (seen.has(current)) return `${tag}=${chain.join(" -> ")} [cycle]`;
        seen.add(current); chain.push(safeRouteHop(current));
        const node = proxies[current];
        if (!object(node)) return `${tag}=${chain.join(" -> ")} [unavailable]`;
        if (typeof node.now === "string" && node.now) { current = node.now; continue; }
        const type = typeof node.type === "string" && /^[a-zA-Z0-9_-]{1,24}$/.test(node.type) ? node.type.toLowerCase() : "unknown";
        const allowed = ["direct", "reject", "block", "shadowsocks", "vmess", "vless", "trojan", "hysteria2", "tuic", "wireguard", "socks", "http", "urltest", "selector"];
        return `${tag}=${chain.join(" -> ")} type=${allowed.includes(type) ? type : "other"}`;
      }
      return `${tag}=${chain.join(" -> ")} [depth_limit]`;
    }).join("\n");
  } catch { return "selectors=unavailable"; }
}
export function deviceEvidence(text: string): { summary: string; packages: Map<number, string[]> } {
  const packages = new Map<number, string[]>();
  try {
    const root = JSON.parse(text);
    if (!object(root) || root.schema !== 1 || root.scope !== "read_only_feedback") throw new Error();
    const lines = ["memory_units=KiB; RSS_is_not_Go_heap; no_heap_profile_collected"];
    if (object(root.memory) && Array.isArray(root.memory.processes)) {
      lines.push(`measured_core_processes=${root.memory.processes.length}`);
      for (const [i, process] of root.memory.processes.slice(0, 8).entries()) {
        if (!object(process)) continue;
        for (const key of ["rss_kib", "anonymous_kib", "file_kib", "shmem_kib", "pss_kib", "private_clean_kib", "private_dirty_kib", "swap_kib", "threads"]) {
          const n = process[key];
          lines.push(`core.${i+1}.${key}=${Number.isSafeInteger(n) && Number(n)>=0 ? n : "unknown"}`);
        }
        if (Array.isArray(process.go_knobs)) for (const knob of process.go_knobs) {
          if (typeof knob === "string" && /^(GOMEMLIMIT=([0-9]+([KMGT]i?B)?|off)|GOGC=([0-9]+|off))$/.test(knob)) lines.push(knob);
        }
      }
    } else lines.push("memory=unavailable");
    if (object(root.config)) {
      for (const key of ["rule_sets", "dns_cache_capacity", "tailscale_endpoints"]) {
        const value = root.config[key];
        lines.push(`${key}=${Number.isSafeInteger(value) && Number(value)>=0 ? value : "unknown"}`);
      }
      if (Array.isArray(root.config.google_package_routes)) lines.push(`google_package_route_count=${root.config.google_package_routes.length}`);
    }
    if (root.package_lookup === "available" && Array.isArray(root.packages)) {
      for (const entry of root.packages) {
        if (object(entry) && ["com.android.vending", "com.google.android.gms", "com.google.android.gsf"].includes(String(entry.package)) && Number.isSafeInteger(entry.uid) && Number(entry.uid)>=0) {
          const names = packages.get(Number(entry.uid)) ?? [];
          names.push(String(entry.package)); packages.set(Number(entry.uid), names);
        }
      }
      lines.push(`play_gms_packages_resolved=${[...packages.values()].flat().length}`);
    } else lines.push("play_gms_packages=unknown");
    return { summary: lines.join("\n"), packages };
  } catch { return { summary: "device_evidence=unavailable", packages }; }
}
export function enrichPlayPackages(text: string, packages: Map<number, string[]>): string {
  try {
    const root = JSON.parse(text);
    if (!object(root) || !Array.isArray(root.connections)) return text;
    for (const item of root.connections.slice(0,2048)) {
      if (!object(item) || !object(item.metadata)) continue;
      const meta = item.metadata;
      const match = typeof meta.processPath === "string" ? meta.processPath.match(/\(([0-9]+)\)$/) : null;
      const uid = Number.isSafeInteger(meta.uid) ? Number(meta.uid) : match ? Number(match[1]) : -1;
      if (packages.has(uid)) meta.processPackageName = packages.get(uid)!.join(",");
    }
    return JSON.stringify(root);
  } catch { return text; }
}
