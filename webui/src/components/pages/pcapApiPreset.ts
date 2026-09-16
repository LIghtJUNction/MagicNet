// Use only the observed local controller. Never guess a capture port when
// the runtime endpoint is missing, malformed, or points off-device.
export function apiCaptureFilter(value: string): string | null {
  try {
    const endpoint = new URL(value);
    if (endpoint.protocol !== "http:" || endpoint.username || endpoint.password) return null;
    if (endpoint.hostname !== "[::1]" && !/^127\.(?:\d{1,3}\.){2}\d{1,3}$/.test(endpoint.hostname)) return null;
    const port = Number(endpoint.port || "80");
    if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
    return `tcp port ${port}`;
  } catch {
    return null;
  }
}
