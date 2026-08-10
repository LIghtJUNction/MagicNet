export type RefreshToolsStep = {
  label: string;
  ok: boolean;
};

export type RefreshToolsSummary = {
  completed: boolean;
  notice: string;
  output: string;
};

/**
 * Keep a partial tool refresh from being reported as a successful refresh.
 * The caller supplies the last command's diagnostic so we do not discard the
 * useful error that the quiet refresh already recorded.
 */
export function summarizeRefreshTools(
  steps: readonly RefreshToolsStep[],
  currentOutput: string,
): RefreshToolsSummary {
  const failed = steps.filter((step) => !step.ok).map((step) => step.label);
  if (!failed.length) {
    return {
      completed: true,
      notice: "工具状态已刷新。",
      output: "工具状态已刷新。",
    };
  }
  const detail = `以下步骤失败：${failed.join("、")}。请查看输出并重试。`;
  return {
    completed: false,
    notice: "工具刷新不完整",
    output: [detail, currentOutput.trim()].filter(Boolean).join("\n\n"),
  };
}
