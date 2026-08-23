import { fastestEntry, type NodeDelayEntry } from "@/composables/nodeDelayParsers";
import { fnv32Hex } from "@/lib/fnv32";
import { statusToneClasses } from "@/lib/statusTone";

export type NodeSwitchPlan = {
  status: "idle" | "keep" | "switch" | "warning";
  title: string;
  detail: string;
  currentNode: string;
  targetNode: string;
  improvementMillis: number | null;
  recommended: boolean;
};

const MEANINGFUL_GAIN_MS = 30;

export function buildNodeSwitchPlan(currentNode: string, entries: NodeDelayEntry[]): NodeSwitchPlan {
  if (!entries.length) {
    return plan("idle", "等待测速", "测速后会比较当前节点和最快节点。", currentNode, "", null, false);
  }
  const fastest = fastestEntry(entries);
  if (!fastest) {
    return plan("warning", "没有可用节点", "全部节点测速失败，暂不建议切换。", currentNode, "", null, false);
  }
  if (!currentNode.trim()) {
    return plan("warning", "需要先确认当前节点", "当前节点未读取，无法完成当前节点和最快节点的真实比较。", currentNode, fastest.node, null, false);
  }
  const current = entries.find((entry) => entry.node === currentNode) || null;
  if (!current) {
    return plan("warning", "当前节点未覆盖", "当前节点不在本次测速样本中，不能确认切换收益。", currentNode, fastest.node, null, false);
  }
  if (current.node === fastest.node) {
    return plan("keep", "保持当前节点", "当前节点已经是本次测速最快可用节点。", currentNode, fastest.node, 0, false);
  }
  if (current.delayMillis === null) {
    return plan("switch", "建议切换", "当前节点测速失败，最快可用节点可替代。", currentNode, fastest.node, null, true);
  }
  const improvementMillis = current.delayMillis - (fastest.delayMillis || 0);
  if (improvementMillis >= MEANINGFUL_GAIN_MS) {
    return plan("switch", "建议切换", `预计降低 ${improvementMillis}ms 延迟。`, currentNode, fastest.node, improvementMillis, true);
  }
  return plan("keep", "不必切换", `最快节点只低 ${Math.max(0, improvementMillis)}ms，收益不明显。`, currentNode, fastest.node, improvementMillis, false);
}

export function formatNodeSwitchPlanReport(plan: NodeSwitchPlan): string {
  return [
    "MagicNet node switch plan",
    "privacy_note=node names are omitted; only presence and fingerprints are exported",
    `status=${plan.status}`,
    `recommended=${plan.recommended ? 1 : 0}`,
    `title=${plan.title}`,
    `detail=${plan.detail}`,
    `current_present=${plan.currentNode ? 1 : 0}`,
    `target_present=${plan.targetNode ? 1 : 0}`,
    `current_fingerprint=${plan.currentNode ? fnv32Hex(plan.currentNode) : "none"}`,
    `target_fingerprint=${plan.targetNode ? fnv32Hex(plan.targetNode) : "none"}`,
    `improvement_ms=${plan.improvementMillis ?? "none"}`
  ].join("\n");
}

export function nodeSwitchPlanTone(status: NodeSwitchPlan["status"]): string {
  if (status === "switch") return statusToneClasses("switch");
  if (status === "warning") return statusToneClasses("danger");
  if (status === "keep") return statusToneClasses("keep");
  return statusToneClasses("neutral");

}

function plan(
  status: NodeSwitchPlan["status"],
  title: string,
  detail: string,
  currentNode: string,
  targetNode: string,
  improvementMillis: number | null,
  recommended: boolean
): NodeSwitchPlan {
  return { status, title, detail, currentNode, targetNode, improvementMillis, recommended };
}
