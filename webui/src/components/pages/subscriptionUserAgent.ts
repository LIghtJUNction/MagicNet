export type SubscriptionUserAgentPreset = {
  label: string;
  value: string;
};

export const subscriptionUserAgentPresets = [
  { label: "默认", value: "" },
  { label: "sing-box", value: "sing-box" },
  { label: "Mihomo", value: "clash.meta" },
  { label: "Clash for Windows", value: "ClashforWindows" },
  { label: "Shadowrocket", value: "Shadowrocket" },
  { label: "v2rayNG", value: "v2rayNG" },
] as const satisfies readonly SubscriptionUserAgentPreset[];
