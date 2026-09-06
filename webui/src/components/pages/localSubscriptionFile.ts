import { t } from "@/i18n";
import {
  buildPrivateSubscriptionSourceApplyCommand,
  redactedCliPreview,
} from "../../utils.ts";

export const MAX_LOCAL_SUBSCRIPTION_BYTES = 8 * 1024 * 1024;

export type LocalSubscriptionImport = {
  fileName: string;
  text: string;
  sizeBytes: number;
  format: "clash" | "share-links" | "encoded" | "json" | "text";
};

export function parseLocalSubscriptionFile(
  fileName: string,
  bytes: Uint8Array,
): LocalSubscriptionImport {
  if (!bytes.byteLength) {
    throw new Error(t("文件为空。"));
  }
  if (bytes.byteLength > MAX_LOCAL_SUBSCRIPTION_BYTES) {
    throw new Error(t("文件超过 8 MiB 限制。"));
  }

  let source: string;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(t("文件不是有效的 UTF-8 文本。"));
  }

  if (!source.trim()) throw new Error(t("文件为空。"));
  if (source.includes("\0")) throw new Error(t("文件包含 NUL 字节。"));
  const text = source.endsWith("\n") ? source : `${source}\n`;
  const format = /^\s*proxies\s*:/m.test(source)
    ? "clash"
    : /(?:^|\s)(?:ss|vmess|vless|trojan|hysteria2|hy2|tuic|anytls):\/\//m.test(source)
      ? "share-links"
      : /^\s*[A-Za-z0-9+/=_-]+\s*$/.test(source)
        ? "encoded"
        : /^\s*[\[{]/.test(source)
          ? "json"
          : "text";

  return {
    fileName: fileName || "subscriptions.txt",
    text,
    sizeBytes: bytes.byteLength,
    format,
  };
}

export function buildLocalSubscriptionApplyLaunch(basename: string) {
  const displayArgs = "webui payload apply-subscription-source [private-payload]";
  return {
    args: buildPrivateSubscriptionSourceApplyCommand(basename),
    displayArgs,
    preview: redactedCliPreview(displayArgs),
    lifecycleArgs: "sub apply-file sing-box [local-source]",
  };
}
