import { statusToneClasses } from "@/lib/statusTone";
export type WebuiVerifyCheck = {
  name: string;
  status: "ok" | "missing" | "unknown";
  path: string;
};

export type WebuiPanelInsight = {
  status: "ok" | "warning" | "missing" | "idle";
  title: string;
  detail: string;
  missing: string[];
};

const REQUIRED_CHECKS = ["module webui", "singbox zashboard"];

export function buildWebuiPanelInsight(checks: WebuiVerifyCheck[], verifyOutput: string): WebuiPanelInsight {
  if (!verifyOutput.trim()) {
    return {
      status: "idle",
      title: "尚未校验",
      detail: "运行 webui verify 后会显示模块 WebUI 与 sing-box 面板是否可用。",
      missing: []
    };
  }
  const missing = checks.filter((check) => check.status !== "ok").map((check) => check.name);
  const present = new Set(checks.map((check) => check.name));
  const notReported = REQUIRED_CHECKS.filter((name) => !present.has(name));
  if (missing.length || notReported.length) {
    return {
      status: "missing",
      title: "面板文件不完整",
      detail: `缺失 ${[...missing, ...notReported].join(", ")}，本地面板可能无法打开。`,
      missing: [...missing, ...notReported]
    };
  }
  if (!checks.length) {
    return {
      status: "warning",
      title: "未识别校验结果",
      detail: "webui verify 有输出，但未解析到标准检查项。",
      missing: []
    };
  }
  return {
    status: "ok",
    title: "面板校验通过",
    detail: "模块 WebUI 与 sing-box zashboard 都包含 index.html。",
    missing: []
  };
}

export function webuiInsightTone(status: WebuiPanelInsight["status"]): string {
  if (status === "ok") return statusToneClasses("ok");
  if (status === "missing") return statusToneClasses("missing");
  if (status === "warning") return statusToneClasses("warning");
  return statusToneClasses("neutral");

}
