export function refreshAllNotice(completed: boolean, currentNotice: string): string {
  return completed ? "面板数据已刷新。" : currentNotice;
}
