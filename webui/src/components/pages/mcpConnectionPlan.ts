import { t } from "@/i18n";
import {
  formatMcpHostPort,
  isMcpIpLiteral,
  isValidMcpPort,
  type McpState,
} from "@/composables/parsers";

export type McpConnectionPlanInput = Pick<McpState, "enabled" | "pid" | "secretSet" | "portOwner"> & {
  bind: string;
  port: string;
  savedBind: string;
  savedPort: string;
};

export type McpConnectionPlan = {
  tone: "success" | "warning";
  title: string;
  summary: string;
  localUrl: string;
  adbForward: string;
  authHeader: string;
  verifyCommand: string;
  checks: string[];
  copyText: string;
};

function isLocalBind(bind: string): boolean {
  return bind === "127.0.0.1" || bind === "::1";
}

function isWildcardBind(bind: string): boolean {
  return bind === "0.0.0.0" || bind === "::";
}

function normalizePort(port: string): string {
  const trimmed = port.trim();
  return trimmed || "8766";
}

export function buildMcpConnectionPlan(input: McpConnectionPlanInput): McpConnectionPlan {
  const bind = input.bind.trim() || "127.0.0.1";
  const port = normalizePort(input.port);
  const deviceEndpoint = formatMcpHostPort(bind, port);
  const localUrl = `http://127.0.0.1:${port}/mcp`;
  const adbForward = `adb forward tcp:${port} tcp:${port}`;
  const secretCommand = `adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp secret"'`;
  const authHeader = "Authorization: Bearer <secret>";
  const verifyCommand = `curl -sS -H "Authorization: Bearer <secret>" ${localUrl}`;
  const checks: string[] = [];
  const savedEndpoint = bind === input.savedBind && port === input.savedPort;
  const activePortOwner = savedEndpoint ? input.portOwner : "";

  const invalidBind = !isMcpIpLiteral(bind);
  const invalidPort = !isValidMcpPort(port);
  if (invalidBind) checks.push(t("监听地址无效：MCP CLI 只接受 IPv4 或 IPv6 字面量。"));
  if (invalidPort) checks.push(t("端口无效：MCP CLI 只接受 1-65535。"));
  if (!input.enabled) checks.push(t("服务未启用：启动前会写入 MCP 配置并生成 secret。"));
  if (input.pid === "stopped") checks.push(t("服务未运行：需要先启动，或保存配置后重启。"));
  if (!input.secretSet) checks.push(t("secret 未设置：连接前先用 cli mcp secret 生成/读取。"));
  else checks.push(t("请求必须携带 Bearer secret 或 X-MagicNet-MCP-Secret。"));
  if (activePortOwner) checks.push(t("端口已被占用：{activePortOwner}", { activePortOwner }));
  else if (!savedEndpoint) checks.push(t("端口占用状态来自已保存配置；保存新地址后再刷新确认。"));
  if (invalidBind) checks.push(t("请先保存有效 IP 字面量后再复制或启动连接计划。"));
  else if (isWildcardBind(bind)) checks.push(t("监听所有地址：同一网络内设备侧端口可能被其他主机访问。"));
  else if (isLocalBind(bind)) checks.push(t("仅本机监听：适合 adb forward 连接。"));
  else checks.push(t("自定义监听地址：确认设备侧 {deviceEndpoint} 可绑定。", { deviceEndpoint }));

  const running = input.enabled && input.pid !== "stopped";
  const blocked = Boolean(activePortOwner && input.pid === "stopped");
  const title = invalidBind
    ? t("MCP 监听地址格式错误")
    : invalidPort
      ? t("MCP 端口格式错误")
      : blocked
        ? t("MCP 端口需要处理")
        : running
          ? t("MCP 鉴权连接计划")
          : t("MCP 连接前需要启动");
  const summary = invalidBind
    ? t("先改为有效的 IPv4 或 IPv6 字面量后再保存或复制连接命令。")
    : invalidPort
    ? t("先修正端口后再保存或复制连接命令。")
    : blocked
    ? t("当前端口被其他进程监听，直接启动可能失败。")
    : running
      ? t("电脑侧执行 adb forward 后，用 secret 鉴权访问 {localUrl}。", { localUrl })
      : t("启动 MCP 后读取 secret，再执行 adb forward 和鉴权请求。");

  const copyText = [
    `MCP local URL: ${localUrl}`,
    `Device bind: ${deviceEndpoint}`,
    `Service: enabled=${input.enabled ? "1" : "0"} pid=${input.pid}`,
    `Auth: ${authHeader}`,
    `Secret: ${input.secretSet ? "set, read with command below" : "missing, run secret command first"}`,
    activePortOwner ? `Port owner: ${activePortOwner}` : "Port owner: none reported for the saved endpoint",
    "",
    secretCommand,
    adbForward,
    verifyCommand
  ].join("\n");

  return {
    tone: invalidBind || invalidPort || blocked || !running || !input.secretSet ? "warning" : "success",
    title,
    summary,
    localUrl,
    adbForward,
    authHeader,
    verifyCommand,
    checks,
    copyText
  };
}
