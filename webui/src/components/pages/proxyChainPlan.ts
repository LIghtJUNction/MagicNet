export type ProxyChainMode = "manual" | "auto";

export type ProxyChainStatus = {
  enabled: boolean;
  mode: ProxyChainMode;
  upstream: string;
  exit: string;
  runtime: {
    available: boolean;
    proxy: string;
    chain: string;
    hop1: string;
    exit: string;
  };
};

export type ProxyChainDraft = Pick<ProxyChainStatus, "enabled" | "mode" | "upstream" | "exit">;

export type ProxyChainActionKind =
  | "set-upstream"
  | "set-exit"
  | "clear-upstream"
  | "clear-exit"
  | "mode"
  | "enable"
  | "disable";

export type ProxyChainAction = {
  kind: ProxyChainActionKind;
  value?: string;
  label: string;
};

export type ProxyChainPlan = {
  changed: boolean;
  actions: ProxyChainAction[];
  summary: string;
};

export function createProxyChainStatus(): ProxyChainStatus {
  return {
    enabled: false,
    mode: "manual",
    upstream: "",
    exit: "",
    runtime: {
      available: false,
      proxy: "",
      chain: "",
      hop1: "",
      exit: "",
    },
  };
}

export function parseProxyChainStatus(text: string): ProxyChainStatus {
  const values = new Map<string, string>();
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    values.set(line.slice(0, separator), line.slice(separator + 1).trim());
  }

  const role = (key: string): string => {
    const value = values.get(key) || "";
    return value === "none" ? "" : value;
  };
  const bool = (key: string): boolean => ["1", "true", "yes", "on"].includes((values.get(key) || "").toLowerCase());
  const mode = values.get("mode") === "auto" ? "auto" : "manual";

  return {
    enabled: bool("enabled"),
    mode,
    upstream: role("upstream"),
    exit: role("exit"),
    runtime: {
      available: values.get("runtime") === "available",
      proxy: values.get("runtime.proxy") || "",
      chain: values.get("runtime.chain") || "",
      hop1: values.get("runtime.chain-hop1") || "",
      exit: values.get("runtime.chain-exit") || "",
    },
  };
}

export function parseProxyNodeList(text: string): string[] {
  return Array.from(new Set(
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("[")),
  ));
}

export function mergeProxyChainNodes(nodes: string[], ...selected: string[]): string[] {
  return Array.from(new Set([...nodes, ...selected].map((item) => item.trim()).filter(Boolean)));
}

export function validateProxyChainDraft(draft: ProxyChainDraft, nodes: string[] = []): string[] {
  const errors: string[] = [];
  const upstream = draft.upstream.trim();
  const exit = draft.exit.trim();

  if (draft.enabled && !upstream) errors.push("启用链式代理前请选择中转节点。");
  if (draft.enabled && !exit) errors.push("启用链式代理前请选择落地节点。");
  if (draft.enabled && upstream && exit && upstream === exit) errors.push("中转节点和落地节点不能是同一个节点。");
  if (draft.enabled && nodes.length && upstream && !nodes.includes(upstream)) errors.push("当前中转节点已不在可用节点列表中，请重新选择。");
  if (draft.enabled && nodes.length && exit && !nodes.includes(exit)) errors.push("当前落地节点已不在可用节点列表中，请重新选择。");
  return errors;
}

export function buildProxyChainPlan(current: ProxyChainStatus, draft: ProxyChainDraft): ProxyChainPlan {
  const actions: ProxyChainAction[] = [];
  const currentUpstream = current.upstream.trim();
  const currentExit = current.exit.trim();
  const upstream = draft.upstream.trim();
  const exit = draft.exit.trim();

  // Disable first when the user is changing a live chain into a disabled or
  // cleared state. The CLI intentionally rejects clearing roles while enabled.
  if (current.enabled && !draft.enabled) actions.push({ kind: "disable", label: "停用链式代理" });

  if (currentUpstream !== upstream) {
    actions.push(upstream
      ? { kind: "set-upstream", value: upstream, label: "设置中转节点" }
      : { kind: "clear-upstream", label: "清除中转节点" });
  }
  if (currentExit !== exit) {
    actions.push(exit
      ? { kind: "set-exit", value: exit, label: "设置落地节点" }
      : { kind: "clear-exit", label: "清除落地节点" });
  }
  if (current.mode !== draft.mode) {
    actions.push({ kind: "mode", value: draft.mode, label: `切换为${draft.mode === "auto" ? "自动" : "手动"}模式` });
  }

  if (!current.enabled && draft.enabled) actions.push({ kind: "enable", label: "启用链式代理" });

  return {
    changed: actions.length > 0,
    actions,
    summary: actions.length ? `将按顺序执行 ${actions.length} 项配置操作。` : "当前配置没有变化。",
  };
}
