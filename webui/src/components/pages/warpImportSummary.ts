import { t } from "@/i18n";
import { statusToneClasses } from "@/lib/statusTone";
export type WarpImportSummary = {
  status: "idle" | "ok" | "warning" | "error";
  message: string;
  lines: number;
  hasInterface: boolean;
  hasPeer: boolean;
  hasPrivateKey: boolean;
  hasPublicKey: boolean;
  hasAddress: boolean;
  hasEndpoint: boolean;
  allowedIps: number;
  dnsServers: number;
  mtu: string;
  keepalive: string;
  endpointHost: string;
  endpointPort: string;
  looksImportable: boolean;
};

type SectionName = "interface" | "peer" | "";

export function summarizeWarpImport(text: string): WarpImportSummary {
  const trimmed = text.trim();
  if (!trimmed) return summary("idle", t("等待粘贴 WireGuard/WARP 配置。"), 0, {}, {});
  const parsed = parseWireGuard(trimmed);
  const endpoint = splitEndpoint(parsed.peer.endpoint || "");
  const missing = [
    parsed.hasInterface ? "" : "[Interface]",
    parsed.hasPeer ? "" : "[Peer]",
    parsed.interface.privatekey ? "" : "PrivateKey",
    parsed.interface.address ? "" : "Address",
    parsed.peer.publickey ? "" : "PublicKey",
    parsed.peer.endpoint ? "" : "Endpoint"
  ].filter(Boolean);
  if (missing.length) {
    return summary("error", t("缺少 {fields}，CLI 会拒绝导入。", { fields: missing.join(", ") }), parsed.lines, parsed.interface, parsed.peer, parsed.hasInterface, parsed.hasPeer);
  }
  if (!endpoint.host || !endpoint.port) {
    return summary("error", t("Endpoint 需要包含 host:port。"), parsed.lines, parsed.interface, parsed.peer, parsed.hasInterface, parsed.hasPeer);
  }
  if (!validPort(endpoint.port)) {
    return summary("error", t("Endpoint 端口必须是 0-65535 的数字。"), parsed.lines, parsed.interface, parsed.peer, parsed.hasInterface, parsed.hasPeer);
  }
  if (!parsed.peer.allowedips) {
    return summary("warning", t("AllowedIPs 未填写，CLI 会使用 0.0.0.0/0 和 ::/0 默认值。"), parsed.lines, parsed.interface, parsed.peer, parsed.hasInterface, parsed.hasPeer);
  }
  return summary("ok", t("配置字段齐全，可交给 CLI 导入。"), parsed.lines, parsed.interface, parsed.peer, parsed.hasInterface, parsed.hasPeer);
}

export function formatWarpImportSummaryReport(summary: WarpImportSummary): string {
  return [
    "MagicNet WARP import summary",
    "privacy_note=private/public keys and raw endpoint are omitted",
    `status=${summary.status}`,
    `message=${summary.message}`,
    `lines=${summary.lines}`,
    `has_interface=${summary.hasInterface ? 1 : 0}`,
    `has_peer=${summary.hasPeer ? 1 : 0}`,
    `has_private_key=${summary.hasPrivateKey ? 1 : 0}`,
    `has_public_key=${summary.hasPublicKey ? 1 : 0}`,
    `has_address=${summary.hasAddress ? 1 : 0}`,
    `has_endpoint=${summary.hasEndpoint ? 1 : 0}`,
    `endpoint_host_present=${summary.endpointHost ? 1 : 0}`,
    `endpoint_port=${summary.endpointPort || "none"}`,
    `allowed_ips=${summary.allowedIps}`,
    `dns_servers=${summary.dnsServers}`,
    `mtu=${summary.mtu || "default"}`,
    `keepalive=${summary.keepalive || "default"}`
  ].join("\n");
}

export function warpImportTone(status: WarpImportSummary["status"]): string {
  if (status === "error") return statusToneClasses("error");
  if (status === "warning") return statusToneClasses("warning");
  if (status === "ok") return statusToneClasses("ok");
  return statusToneClasses("neutral");

}

function parseWireGuard(text: string): {
  lines: number;
  hasInterface: boolean;
  hasPeer: boolean;
  interface: Record<string, string>;
  peer: Record<string, string>;
} {
  let section: SectionName = "";
  const iface: Record<string, string> = {};
  const peer: Record<string, string> = {};
  let hasInterface = false;
  let hasPeer = false;
  const lines = text.split(/\r?\n/);
  lines.forEach((raw) => {
    const line = raw.split("#", 1)[0].split(";", 1)[0].trim();
    if (!line) return;
    if (line.startsWith("[") && line.endsWith("]")) {
      const sectionName = line.slice(1, -1).trim();
      section = sectionName === "Interface" ? "interface" : sectionName === "Peer" ? "peer" : "";
      hasInterface ||= section === "interface";
      hasPeer ||= section === "peer";
      return;
    }
    const [key, ...rest] = line.split("=");
    const value = rest.join("=").trim();
    const normalizedKey = key?.trim().toLowerCase();
    if (!normalizedKey) return;
    if (section === "interface") iface[normalizedKey] = value;
    if (section === "peer") peer[normalizedKey] = value;
  });
  return { lines: lines.filter((line) => line.trim()).length, hasInterface, hasPeer, interface: iface, peer };
}

function summary(
  status: WarpImportSummary["status"],
  message: string,
  lines: number,
  iface: Record<string, string>,
  peer: Record<string, string>,
  hasInterface = false,
  hasPeer = false
): WarpImportSummary {
  const endpoint = splitEndpoint(peer.endpoint || "");
  return {
    status,
    message,
    lines,
    hasInterface,
    hasPeer,
    hasPrivateKey: Boolean(iface.privatekey),
    hasPublicKey: Boolean(peer.publickey),
    hasAddress: Boolean(iface.address),
    hasEndpoint: Boolean(peer.endpoint),
    allowedIps: splitCsv(peer.allowedips).length,
    dnsServers: splitCsv(iface.dns).length,
    mtu: iface.mtu || "",
    keepalive: peer.persistentkeepalive || "",
    endpointHost: endpoint.host,
    endpointPort: endpoint.port,
    looksImportable: status === "ok" || status === "warning"
  };
}

function splitEndpoint(endpoint: string): { host: string; port: string } {
  if (endpoint.startsWith("[")) {
    const end = endpoint.indexOf("]:");
    if (end < 0) return { host: "", port: "" };
    return { host: endpoint.slice(1, end), port: endpoint.slice(end + 2) };
  }
  const index = endpoint.lastIndexOf(":");
  if (index <= 0 || index >= endpoint.length - 1) return { host: "", port: "" };
  return { host: endpoint.slice(0, index), port: endpoint.slice(index + 1) };
}

function validPort(port: string): boolean {
  if (!/^\d+$/.test(port)) return false;
  const parsed = Number(port);
  return Number.isInteger(parsed) && parsed >= 0 && parsed <= 65535;
}

function splitCsv(value = ""): string[] {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}
