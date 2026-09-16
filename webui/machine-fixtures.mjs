// Test-only schema-1 fixtures. Production parsers, not alternate parsers, consume them.
export const envelope = (command, data) => JSON.stringify({schema: 1, ok: true, command, data});
export function subscriptionData(changes = {}) {
  return {
    source: {mode: "remote_url", configured_count: 1},
    update: {owner: "none", running: false, lock_present: false, transaction_pending: false},
    last: {phase: "commit", result: "success", attempt_epoch: 1, success_epoch: 1,
      configured_count: 1, source_count: 1, imported_count: 24, skipped_count: 0,
      generation_id: "old", has_reason: false},
    cache: {entries: 2, source_entries: 1, provenance_entries: 1, identity: "url_sha256_identity"},
    schedule: {interval_hours: "off", enabled: false, owner: "none", running: false, owner_valid: true},
    refresh: {event_count: 0, error_count: 0},
    configuration: {sing_box_urls: ["https://provider.example/sub?token=secret"], user_agent: "", filters: []},
    source_usage: [], ...changes,
  };
}
export const subscriptionSnapshot = (changes = {}) => envelope("sub.inspect", subscriptionData(changes));
export function wifiData(changes = {}) {
  return {
    policy: {enabled: true, mode: "blacklist", interval_seconds: 5, supervisor: "123"},
    network: {connected: true, matched: true, desired_mode: "direct", ssid: "Home WiFi", bssid: "aa:bb:cc:dd:ee:ff"},
    current_mode: "direct",
    configuration: {ssids: ["Home WiFi", "Office"], bssids: ["aa:bb:cc:dd:ee:ff"]},
    ...changes,
  };
}
export const wifiSnapshot = (changes = {}) => envelope("wifi.inspect", wifiData(changes));
