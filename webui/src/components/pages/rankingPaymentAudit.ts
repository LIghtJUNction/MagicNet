import type { RankingData } from "./rankingInsights";

export type PaymentAuditItem = {
  key: string;
  label: string;
  value: string;
  detail: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export type PaymentQrKind = "wechat" | "alipay";

export type PaymentQrValidation = {
  ok: boolean;
  reason: string;
  host: string;
  strict: boolean;
};

type PaymentAppKind = "wechatUrl" | "alipayUrl";

const QR_EXTENSIONS = /\.(?:png|jpg|jpeg|webp)(?:$|\?)/i;

export function buildPaymentAudit(data: RankingData): PaymentAuditItem[] {
  const wechatQr = validatePaymentQr("wechat", data.payment.wechatQr || "");
  const alipayQr = validatePaymentQr("alipay", data.payment.alipayQr || "");
  const wechatApp = validatePaymentAppScheme("wechatUrl", data.payment.wechatUrl);
  const alipayApp = validatePaymentAppScheme("alipayUrl", data.payment.alipayUrl);
  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.contactEmail);
  return [
    auditItem("wechatQr", "微信码", wechatQr.ok ? wechatQr.host : "不可用", wechatQr.reason, qrTone(wechatQr)),
    auditItem("alipayQr", "支付宝码", alipayQr.ok ? alipayQr.host : "不可用", alipayQr.reason, qrTone(alipayQr)),
    auditItem("wechatUrl", "微信入口", wechatApp.value, wechatApp.reason, wechatApp.ok ? "neutral" : "warning"),
    auditItem("alipayUrl", "支付宝入口", alipayApp.value, alipayApp.reason, alipayApp.ok ? "neutral" : "warning"),
    auditItem("contactEmail", "联系邮箱", emailOk ? "格式有效" : "需检查", emailOk ? "邮箱格式可用于复制联系。" : "邮箱为空或格式异常。", emailOk ? "success" : "warning")
  ];
}

export function validatePaymentQr(kind: PaymentQrKind, value: string): PaymentQrValidation {
  const label = kind === "wechat" ? "微信收款码" : "支付宝收款码";
  if (!value.trim()) return { ok: false, reason: `${label}图片链接为空。`, host: "", strict: false };
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return { ok: false, reason: `${label}图片链接不是有效 URL。`, host: "", strict: false };
  }
  if (parsed.protocol !== "https:") {
    return { ok: false, reason: `${label}必须使用 HTTPS 图片链接。`, host: parsed.hostname || "", strict: false };
  }
  if (!QR_EXTENSIONS.test(`${parsed.pathname}${parsed.search}`)) {
    return { ok: true, reason: `${label}是 HTTPS 链接，但文件类型需下载后确认。`, host: parsed.hostname, strict: false };
  }
  return { ok: true, reason: `${label}链接格式可保存。`, host: parsed.hostname, strict: true };
}

export function validatePaymentOpen(kind: PaymentAppKind, value: string): PaymentQrValidation {
  const result = validatePaymentAppScheme(kind, value);
  return { ok: result.ok, reason: result.reason, host: result.value, strict: false };
}

export function formatPaymentAuditReport(data: RankingData): string {
  return [
    "privacy_note=omits full payment QR URLs; includes QR hostnames and local syntax checks only",
    "[payment_resources]",
    ...buildPaymentAudit(data).map((item) => `${item.key}=${item.value} (${item.tone}) ${item.detail}`)
  ].join("\n");
}

function validatePaymentAppScheme(kind: PaymentAppKind, value: string): { ok: boolean; value: string; reason: string } {
  const label = kind === "wechatUrl" ? "微信支付入口" : "支付宝支付入口";
  const allowedProtocol = kind === "wechatUrl" ? "weixin:" : "alipays:";
  if (!value.trim()) return { ok: false, value: "空", reason: `${label}为空。` };
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return { ok: false, value: "无效", reason: `${label}不是有效 URL。` };
  }
  if (parsed.protocol !== allowedProtocol) {
    return { ok: false, value: parsed.protocol || "未知协议", reason: `${label}协议应为 ${allowedProtocol}` };
  }
  return { ok: true, value: parsed.protocol, reason: `${label}仅完成本地协议检查，是否可支付取决于设备 App。` };
}

function qrTone(result: PaymentQrValidation): PaymentAuditItem["tone"] {
  if (!result.ok) return "danger";
  return result.strict ? "success" : "warning";
}

function auditItem(key: string, label: string, value: string, detail: string, tone: PaymentAuditItem["tone"]): PaymentAuditItem {
  return { key, label, value, detail, tone };
}
