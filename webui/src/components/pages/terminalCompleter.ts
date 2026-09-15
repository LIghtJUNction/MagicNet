export type CommandDoc = {
  name: string;
  syntax?: string;
  description?: string;
  children?: CommandDoc[];
};

export const CLI_COMMAND_TREE: readonly CommandDoc[] = [
  {
    name: "service",
    syntax: "{status|start|stop|restart|logs...}",
    description: "服务状态与生命周期管理",
    children: [
      { name: "status", description: "查看 sing-box 等服务运行状态" },
      { name: "start", description: "启动代理服务" },
      { name: "stop", description: "停止代理服务" },
      { name: "restart", description: "重启当前选中的核心服务" },
      { name: "ensure", description: "确保服务在后台正常运行" },
      {
        name: "toggle",
        syntax: "sing-box",
        description: "切换服务启停状态",
        children: [{ name: "sing-box", description: "切换 sing-box 启停" }],
      },
      {
        name: "logs",
        syntax: "[target] [lines]",
        description: "查看服务运行日志",
        children: [
          { name: "sing-box", description: "sing-box 核心日志" },
          { name: "webui", description: "WebUI 服务日志" },
          { name: "mcp", description: "MCP 协议服务日志" },
          { name: "fswatch", description: "配置热重载监控日志" },
          { name: "supervisors", description: "守护进程综合日志" },
        ],
      },
    ],
  },
  {
    name: "supervisor",
    syntax: "{status|start|stop|restart} [target]",
    description: "守护进程控制",
    children: [
      { name: "status", description: "查看守护进程状态" },
      { name: "start", description: "启动守护进程" },
      { name: "stop", description: "停止守护进程" },
      { name: "restart", description: "重启守护进程" },
    ],
  },
  { name: "health", description: "全面检查系统健康状态、接口、内核与路由" },
  { name: "pingtest", description: "测试网络基础连通性与往返延迟" },
  { name: "speedtest", description: "执行代理下载测速" },
  { name: "topology", description: "分析当前网络拓扑结构与路由分流路径" },
  {
    name: "ecapture",
    syntax: "{status|version|tls|pcap...}",
    description: "eBPF 免证书 HTTPS/TLS 抓包与审计",
    children: [
      { name: "status", description: "检查 eCapture 运行环境" },
      { name: "version", description: "查看 eCapture 版本" },
      { name: "tls", syntax: "[seconds] [pid|all] [uid|all]", description: "抓取 TLS 明文流量" },
      { name: "gotls", syntax: "[seconds] [pid|all] [uid|all]", description: "抓取 Go TLS 流量" },
      { name: "nspr", syntax: "[seconds] [pid|all] [uid|all]", description: "抓取 NSPR / NSS 流量" },
      { name: "pcap", syntax: "[seconds] <ifname>", description: "抓取指定网卡 PCAP 数据包" },
      { name: "help", description: "查看 eCapture 抓包说明" },
    ],
  },
  {
    name: "sysroute",
    syntax: "{list|snapshot...}",
    description: "系统 IP 规则与路由表诊断",
    children: [
      { name: "list", description: "列出当前 IP 规则与策略路由" },
      { name: "snapshot", description: "导出当前系统路由表快照" },
    ],
  },
  { name: "repair", description: "自动修复防火墙、路由残留与运行环境" },
  {
    name: "support",
    syntax: "bundle",
    description: "故障诊断支持",
    children: [{ name: "bundle", description: "收集诊断日志打包为支持包" }],
  },
  { name: "setup", syntax: "<subscription-url>", description: "使用订阅链接初始化 MagicNet 配置" },
  {
    name: "config",
    syntax: "apply",
    description: "核心配置应用",
    children: [{ name: "apply", description: "验证并热应用最新配置" }],
  },
  {
    name: "config-editor",
    syntax: "{get|validate|sync-template} <sing-box>",
    description: "核心配置文件读取、校验与同步",
    children: [
      {
        name: "get",
        syntax: "sing-box",
        description: "读取当前生效配置",
        children: [{ name: "sing-box", description: "读取 sing-box 配置" }],
      },
      { name: "path", description: "查看配置文件实际存储路径" },
      {
        name: "validate",
        syntax: "sing-box",
        description: "校验配置格式正确性",
        children: [{ name: "sing-box", description: "校验 sing-box 配置" }],
      },
      {
        name: "sync-template",
        syntax: "sing-box",
        description: "从模板同步更新配置",
        children: [{ name: "sing-box", description: "同步 sing-box 模板" }],
      },
    ],
  },
  {
    name: "transparent",
    syntax: "{status|set tun|set ebpf|apply}",
    description: "透明代理模式管理 (tun / ebpf)",
    children: [
      { name: "status", description: "查看当前透明代理模式及运行情况" },
      {
        name: "set",
        syntax: "<tun|ebpf>",
        description: "切换透明代理工作模式",
        children: [
          { name: "tun", description: "使用 tun 虚拟网卡模式 (magicnet0)" },
          { name: "ebpf", description: "使用 eBPF TC 分流模式" },
        ],
      },
      { name: "apply", description: "重新应用透明代理策略与规则" },
    ],
  },
  {
    name: "network",
    syntax: "{status|set...|apply}",
    description: "网络栈、MTU 及超时策略管理",
    children: [
      { name: "status", description: "查看当前网络栈配置与策略" },
      {
        name: "set",
        syntax: "<ipv4_only|prefer_ipv4|prefer_ipv6> <mtu> <timeout>",
        description: "设置网络协议优先级与参数",
        children: [
          { name: "prefer_ipv4", description: "优先 IPv4，备选 IPv6" },
          { name: "ipv4_only", description: "仅使用 IPv4" },
          { name: "prefer_ipv6", description: "优先 IPv6" },
        ],
      },
      { name: "apply", description: "应用网络策略变更" },
    ],
  },
  {
    name: "core",
    syntax: "{status|selected|select sing-box}",
    description: "内核切换与状态查看",
    children: [
      { name: "status", description: "查看核心运行状态" },
      { name: "selected", description: "查看当前选中的核心类型" },
      {
        name: "select",
        syntax: "sing-box",
        description: "选择核心类型",
        children: [{ name: "sing-box", description: "选用 sing-box 核心" }],
      },
    ],
  },
  {
    name: "node",
    syntax: "{list|current|use|test|test-all}",
    description: "代理节点查看、切换与延迟测速",
    children: [
      { name: "list", description: "列出当前订阅的所有节点" },
      { name: "current", description: "查看当前正在使用的出站节点" },
      { name: "use", syntax: "<node-name>", description: "切换到指定节点" },
      { name: "test", syntax: "<node-name>", description: "测试指定节点 TCP/HTTP 延迟" },
      { name: "test-all", description: "并发批测所有节点延迟" },
    ],
  },
  {
    name: "chain",
    syntax: "{status|enable|disable|mode manual|mode auto}",
    description: "双跳前置/出口链式代理管理",
    children: [
      { name: "status", description: "查看链式代理状态与当前上下游" },
      { name: "enable", description: "启用链式代理" },
      { name: "disable", description: "停用链式代理" },
      {
        name: "mode",
        syntax: "<manual|auto>",
        description: "切换链式代理模式",
        children: [
          { name: "manual", description: "手动指定前置与出口节点" },
          { name: "auto", description: "自动选择延迟最低组合" },
        ],
      },
      { name: "clear-upstream", description: "清空当前前置节点配置" },
      { name: "clear-exit", description: "清空当前落地出口节点配置" },
    ],
  },
  {
    name: "mode",
    syntax: "<rule|global|direct>",
    description: "分流模式切换",
    children: [
      { name: "rule", description: "规则分流模式：按规则判定代理、直连或拦截" },
      { name: "global", description: "全局代理模式：所有流量均通过代理出站" },
      { name: "direct", description: "全局直连模式：不经过代理直接出站" },
    ],
  },
  {
    name: "wifi",
    syntax: "{status|enable|disable|mode|check}",
    description: "Wi-Fi 局域网白名单 / 黑名单免代理策略",
    children: [
      { name: "status", description: "查看 Wi-Fi 规则状态与当前连接" },
      { name: "enable", description: "开启 Wi-Fi 自动判定策略" },
      { name: "disable", description: "关闭 Wi-Fi 策略" },
      {
        name: "mode",
        syntax: "<blacklist|whitelist>",
        description: "设置 Wi-Fi 过滤模式",
        children: [
          { name: "blacklist", description: "黑名单模式：在列表中的 Wi-Fi 绕过代理" },
          { name: "whitelist", description: "白名单模式：仅在列表中的 Wi-Fi 启用代理" },
        ],
      },
      { name: "check", description: "立即执行一次 Wi-Fi 策略判定" },
    ],
  },
  {
    name: "hotspot",
    syntax: "{status|enable|disable|reconcile}",
    description: "移动热点客户端流量代理与分流",
    children: [
      { name: "status", description: "查看热点代理分流状态" },
      { name: "enable", description: "启用热点客户端流量走代理" },
      { name: "disable", description: "停用热点代理，热点流量直连" },
      { name: "reconcile", description: "重新同步热点网络接口规则" },
    ],
  },
  {
    name: "route",
    syntax: "{list|add-domain|remove-domain|apply}",
    description: "自定义域名分流规则管理",
    children: [
      { name: "list", description: "查看所有自定义路由域名规则" },
      { name: "apply", description: "将规则变动应用到核心" },
      {
        name: "add-domain",
        syntax: "<proxy|direct|block|warp> <suffix>",
        description: "添加域名后缀规则",
        children: [
          { name: "proxy", description: "指定域名后缀走代理" },
          { name: "direct", description: "指定域名后缀走直连" },
          { name: "block", description: "指定域名后缀拦截阻止" },
          { name: "warp", description: "指定域名后缀走 WARP 出口" },
        ],
      },
      {
        name: "remove-domain",
        syntax: "<proxy|direct|block|warp> <suffix>",
        description: "删除域名后缀规则",
      },
    ],
  },
  {
    name: "dns",
    syntax: "{status|set|test|apply}",
    description: "安全 DNS 上游服务器与防泄漏策略",
    children: [
      { name: "status", description: "查看当前 DNS 配置与防泄漏状态" },
      {
        name: "set",
        syntax: "<default|cloudflare-doh|cloudflare-dot|cloudflare-udp>",
        description: "设置 DNS 解析方案",
        children: [
          { name: "default", description: "使用默认 DNS 方案" },
          { name: "cloudflare-doh", description: "使用 Cloudflare DNS over HTTPS" },
          { name: "cloudflare-dot", description: "使用 Cloudflare DNS over TLS" },
          { name: "cloudflare-udp", description: "使用 Cloudflare 标准 UDP DNS" },
        ],
      },
      { name: "test", syntax: "[domain]", description: "测试指定域名的 DNS 解析延迟" },
      { name: "apply", description: "立即重载生效 DNS 方案" },
    ],
  },
  {
    name: "warp",
    syntax: "{status|enable|disable|global|rule|apply|test}",
    description: "Cloudflare WARP 免费出口与解锁",
    children: [
      { name: "status", description: "查看 WARP 出口状态与端点连通性" },
      { name: "enable", description: "启用 WARP 出站" },
      { name: "disable", description: "停用 WARP 出站" },
      { name: "global", description: "全局所有流量走 WARP" },
      { name: "rule", description: "仅按分流规则流量走 WARP" },
      { name: "test", description: "测试 WARP 出口 IP 与延迟" },
      { name: "apply", description: "应用 WARP 配置变更" },
    ],
  },
  {
    name: "sub",
    syntax: "{status|update|update-all|list|get|schedule}",
    description: "订阅地址管理与定期更新",
    children: [
      { name: "status", description: "查看订阅状态、节点数与最后更新时间" },
      {
        name: "update",
        syntax: "<sing-box|all>",
        description: "更新指定订阅源",
        children: [
          { name: "sing-box", description: "更新 sing-box 订阅" },
          { name: "all", description: "更新所有订阅" },
        ],
      },
      { name: "update-all", description: "立即并发拉取所有订阅" },
      { name: "list", description: "列出已配置的订阅源" },
      {
        name: "get",
        syntax: "sing-box",
        description: "查看当前 sing-box 订阅配置",
        children: [{ name: "sing-box", description: "查看 sing-box 订阅" }],
      },
      {
        name: "file",
        syntax: "sing-box",
        description: "查看本地静态订阅文件内容",
        children: [{ name: "sing-box", description: "查看 sing-box 本地订阅" }],
      },
      {
        name: "schedule",
        syntax: "{status|set <off|12|24|48|72>}",
        description: "定时自动更新订阅配置",
        children: [
          { name: "status", description: "查看定时自动更新周期" },
        ],
      },
    ],
  },
  {
    name: "block",
    syntax: "{list|enable|disable|update|diff|apply}",
    description: "广告拦截、隐私保护规则库",
    children: [
      { name: "list", description: "查看拦截规则状态与规则集" },
      { name: "enable", description: "启用广告拦截" },
      { name: "disable", description: "停用广告拦截" },
      { name: "update", description: "更新在线广告规则列表" },
      { name: "diff", description: "查看规则列表与上次版本的差异" },
      { name: "apply", description: "应用拦截规则变动" },
    ],
  },
  {
    name: "mcp",
    syntax: "{status|enable|disable|start|stop|restart|logs}",
    description: "Model Context Protocol (MCP) 服务端控制",
    children: [
      { name: "status", description: "查看 MCP 服务器运行状态与端口" },
      { name: "enable", description: "开机自启 MCP 服务" },
      { name: "disable", description: "禁用 MCP 服务开机自启" },
      { name: "secret", description: "查看 MCP 当前鉴权令牌" },
      { name: "rotate-secret", description: "轮换 MCP 鉴权令牌" },
      { name: "start", description: "立即启动 MCP 守护服务" },
      { name: "stop", description: "停止 MCP 服务" },
      { name: "restart", description: "重启 MCP 服务" },
      { name: "logs", syntax: "[lines]", description: "查看 MCP 服务运行日志" },
    ],
  },
  {
    name: "webui",
    syntax: "{status|verify}",
    description: "WebUI 控制面板安装与校验",
    children: [
      { name: "status", description: "查看 WebUI 版本与静态资源状态" },
      { name: "verify", description: "校验 WebUI 文件的 SHA256 完整性" },
    ],
  },
  {
    name: "backup",
    syntax: "{export|restore}",
    description: "模块配置全量加密备份与恢复",
    children: [
      { name: "export", syntax: "[password]", description: "导出当前配置备份" },
      { name: "restore", syntax: "[password] <base64>", description: "从备份数据还原配置" },
    ],
  },
  {
    name: "api",
    syntax: "{groups|proxies|conns|stats|close-all|tailscale-status}",
    description: "sing-box 运行时 Clash API 快速查询",
    children: [
      { name: "groups", description: "查看所有策略组" },
      { name: "proxies", description: "查看所有节点及延迟" },
      { name: "conns", description: "查看当前活动的网络连接" },
      { name: "stats", description: "查看当前上行/下行速率与累计流量" },
      { name: "close-all", description: "强制中断所有活动连接" },
      { name: "tailscale-status", syntax: "<endpoint-tag>", description: "查询 Tailscale 节点的在线与授权状态" },
    ],
  },
  {
    name: "app",
    syntax: "{list|recommendations|mode|apply}",
    description: "Android 应用分流白名单 / 黑名单策略",
    children: [
      { name: "list", description: "查看当前应用分流规则配置" },
      { name: "recommendations", description: "列出常见国内/国际应用推荐分流配置" },
      {
        name: "mode",
        syntax: "<blacklist|whitelist>",
        description: "设置分流模式",
        children: [
          { name: "blacklist", description: "黑名单模式：仅指定应用走代理" },
          { name: "whitelist", description: "白名单模式：仅指定应用绕过代理" },
        ],
      },
      { name: "apply", description: "应用应用分流规则" },
    ],
  },
  { name: "diagnose", description: "执行全面一键诊断排错" },
  { name: "help", description: "显示完整 CLI 帮助手册与用法说明" },
];

export type CompletionItem = {
  command: string;
  display: string;
  syntax?: string;
  description?: string;
};

export type CompletionResult = {
  suggestions: CompletionItem[];
  ghostText: string;
  normalizedPrefix: string;
};

export function getCompletions(
  rawInput: string,
  history: readonly string[] = [],
): CompletionResult {
  const trimmedLeft = rawInput.replace(/^\s+/, "");
  const hasCliPrefix = /^(?:cli|magicnet-cli)\s+/i.test(trimmedLeft);
  const withoutPrefix = hasCliPrefix
    ? trimmedLeft.replace(/^(?:cli|magicnet-cli)\s+/i, "")
    : trimmedLeft;

  const endsWithSpace = /\s$/.test(rawInput);
  const rawTokens = withoutPrefix.split(/\s+/).filter(Boolean);

  let searchTokens: string[];
  let currentPartial: string;

  if (endsWithSpace) {
    searchTokens = [...rawTokens];
    currentPartial = "";
  } else {
    searchTokens = rawTokens.slice(0, -1);
    currentPartial = rawTokens[rawTokens.length - 1] ?? "";
  }

  // Walk command tree to find the current level nodes
  let currentLevel: readonly CommandDoc[] = CLI_COMMAND_TREE;
  for (const token of searchTokens) {
    const matched = currentLevel.find(
      (node) => node.name.toLowerCase() === token.toLowerCase(),
    );
    if (matched && matched.children && matched.children.length > 0) {
      currentLevel = matched.children;
    } else {
      currentLevel = [];
      break;
    }
  }

  const prefixLeader = hasCliPrefix ? "cli " : "";
  const baseTokensJoined = searchTokens.length > 0 ? searchTokens.join(" ") + " " : "";

  // Match commands from current level
  const commandMatches: CompletionItem[] = [];
  for (const node of currentLevel) {
    if (!currentPartial || node.name.toLowerCase().startsWith(currentPartial.toLowerCase())) {
      const fullCmd = `${prefixLeader}${baseTokensJoined}${node.name}`;
      commandMatches.push({
        command: fullCmd,
        display: node.name,
        syntax: node.syntax,
        description: node.description,
      });
    }
  }

  // Also match from recent history if input is non-empty
  const historyMatches: CompletionItem[] = [];
  if (trimmedLeft.length > 1) {
    const seen = new Set(commandMatches.map((m) => m.command.toLowerCase()));
    for (let i = history.length - 1; i >= 0; i--) {
      const hist = history[i].trim();
      if (!hist) continue;
      const histNorm = hasCliPrefix && !/^cli\s+/i.test(hist) ? `cli ${hist}` : hist;
      if (
        histNorm.toLowerCase().startsWith(trimmedLeft.toLowerCase()) &&
        !seen.has(histNorm.toLowerCase()) &&
        histNorm.length > trimmedLeft.length
      ) {
        seen.add(histNorm.toLowerCase());
        historyMatches.push({
          command: histNorm,
          display: histNorm,
          description: "历史命令",
        });
        if (historyMatches.length >= 3) break;
      }
    }
  }

  const allSuggestions = [...commandMatches, ...historyMatches];

  // Calculate Ghost Text
  let ghostText = "";
  if (allSuggestions.length > 0) {
    const top = allSuggestions[0];
    const targetCommand = top.command;
    if (targetCommand.toLowerCase().startsWith(trimmedLeft.toLowerCase())) {
      ghostText = targetCommand.slice(trimmedLeft.length);
    } else if (
      !hasCliPrefix &&
      `cli ${targetCommand}`.toLowerCase().startsWith(trimmedLeft.toLowerCase())
    ) {
      ghostText = `cli ${targetCommand}`.slice(trimmedLeft.length);
    }
  }

  return {
    suggestions: allSuggestions,
    ghostText,
    normalizedPrefix: prefixLeader + baseTokensJoined,
  };
}

/**
 * Given current input, calculates the autocompleted string when pressing Tab.
 */
export function applyTabCompletion(
  currentInput: string,
  history: readonly string[] = [],
): { completed: string; changed: boolean } {
  const { suggestions, ghostText } = getCompletions(currentInput, history);
  if (ghostText) {
    return { completed: currentInput + ghostText, changed: true };
  }
  if (suggestions.length > 0) {
    const target = suggestions[0].command;
    if (target.length > currentInput.trim().length) {
      return { completed: target, changed: true };
    }
  }
  return { completed: currentInput, changed: false };
}
