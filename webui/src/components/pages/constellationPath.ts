import type { RuntimeState } from "@/types";

/**
 * The overview's live traffic constellation. Each star is backed by one
 * machine-reported fact; edges only "flow" when both ends are proven.
 * Unknown evidence is never drawn as a working path, and a running core is
 * never presented as proof of Internet connectivity.
 */
export type StarState = "ok" | "off" | "unknown";
export type EdgeState = "flowing" | "idle" | "unknown";

export type ConstellationStar = {
  key: "device" | "dataplane" | "core" | "egress";
  label: string;
  detail: string;
  state: StarState;
};

export type ConstellationModel = {
  stars: ConstellationStar[];
  edges: EdgeState[];
  summary: "flowing" | "stopped" | "partial" | "unknown";
};

type RuntimeFacts = Pick<
  RuntimeState,
  | "singBoxState"
  | "singBox"
  | "singBoxRssKib"
  | "serviceReady"
  | "transparentDataplaneReady"
  | "transparentMode"
  | "transparentEffectiveMode"
  | "transparentLocalCgroup"
  | "transparentSharedTc"
>;

function dataplaneStar(runtime: RuntimeFacts): ConstellationStar {
  const mode = runtime.transparentMode;
  const label = mode === "ebpf" ? "eBPF" : mode === "tun" ? "TUN" : "数据面";
  let detail = "状态未知";
  if (mode === "tun") detail = "magicnet0";
  else if (mode === "ebpf") {
    detail = runtime.transparentEffectiveMode === "hybrid" ? "local + shared"
      : runtime.transparentLocalCgroup === "attached" ? "local cgroup" : "cgroup / TC";
  }
  let state: StarState = "unknown";
  if (runtime.singBoxState === "stopped") state = "off";
  else if (runtime.transparentDataplaneReady === true) state = "ok";
  else if (runtime.transparentDataplaneReady === false) state = "off";
  return { key: "dataplane", label, detail, state };
}

function coreStar(runtime: RuntimeFacts): ConstellationStar {
  if (runtime.singBoxState === "sing-box") {
    const memory = runtime.singBoxRssKib == null ? "" : ` · ${(runtime.singBoxRssKib / 1024).toFixed(0)} MiB`;
    return { key: "core", label: "sing-box", detail: `PID ${runtime.singBox.split(",")[0]}${memory}`, state: "ok" };
  }
  if (runtime.singBoxState === "stopped") return { key: "core", label: "sing-box", detail: "已停止", state: "off" };
  return { key: "core", label: "sing-box", detail: "未确认", state: "unknown" };
}

function edge(left: StarState, right: StarState): EdgeState {
  if (left === "ok" && right === "ok") return "flowing";
  if (left === "off" || right === "off") return "idle";
  return "unknown";
}

export function buildConstellation(runtime: RuntimeFacts, hasDevice: boolean): ConstellationModel {
  if (!hasDevice) {
    const stars: ConstellationStar[] = [
      { key: "device", label: "设备", detail: "未连接", state: "unknown" },
      { key: "dataplane", label: "数据面", detail: "未连接", state: "unknown" },
      { key: "core", label: "sing-box", detail: "未连接", state: "unknown" },
      { key: "egress", label: "出口", detail: "未连接", state: "unknown" },
    ];
    return { stars, edges: ["unknown", "unknown", "unknown"], summary: "unknown" };
  }
  const core = coreStar(runtime);
  const dataplane = dataplaneStar(runtime);
  // The device always originates traffic; it is "ok" only once captured.
  const device: ConstellationStar = {
    key: "device",
    label: "设备",
    detail: "本机应用",
    state: dataplane.state === "ok" ? "ok" : dataplane.state === "off" ? "off" : "unknown",
  };
  const egressState: StarState = runtime.serviceReady === true && core.state === "ok" ? "ok"
    : core.state === "off" || runtime.serviceReady === false ? "off" : "unknown";
  const egress: ConstellationStar = {
    key: "egress",
    label: "出口",
    detail: egressState === "ok" ? "按规则分流" : egressState === "off" ? "未就绪" : "未确认",
    state: egressState,
  };
  const stars = [device, dataplane, core, egress];
  const edges = [edge(device.state, dataplane.state), edge(dataplane.state, core.state), edge(core.state, egress.state)];
  const summary = edges.every((item) => item === "flowing") ? "flowing"
    : runtime.singBoxState === "stopped" ? "stopped"
      : edges.some((item) => item === "flowing") ? "partial" : "unknown";
  return { stars, edges, summary };
}
