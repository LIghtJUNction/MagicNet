import { t } from "@/i18n";
export function refreshAllNotice(completed: boolean, currentNotice: string): string {
  return completed ? t("面板数据已刷新。") : currentNotice;
}
