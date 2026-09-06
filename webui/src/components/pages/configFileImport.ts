import { t } from "@/i18n";
export const MAX_LOCAL_CONFIG_BYTES = 4 * 1024 * 1024;

export type LocalConfigImport = {
  fileName: string;
  text: string;
  sizeBytes: number;
};

export function parseLocalConfigFile(fileName: string, bytes: Uint8Array): LocalConfigImport {
  if (!bytes.byteLength) {
    throw new Error(t("文件为空。"));
  }
  if (bytes.byteLength > MAX_LOCAL_CONFIG_BYTES) {
    throw new Error(t("文件超过 4 MiB 限制。"));
  }

  let source: string;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(t("文件不是有效的 UTF-8 文本。"));
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(source);
  } catch (error) {
    throw new Error(t("JSON 语法错误：{value}", { value: error instanceof Error ? error.message : String(error) }));
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(t("配置顶层必须是 JSON 对象。"));
  }

  return {
    fileName: fileName || "config.json",
    text: `${JSON.stringify(parsed, null, 2)}\n`,
    sizeBytes: bytes.byteLength,
  };
}
