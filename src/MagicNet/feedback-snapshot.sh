#!/system/bin/sh
# Read-only, on-demand feedback. Never print raw configuration or environment.
MODDIR=${0%/*}
JQ="$MODDIR/bin/jq"
BB=/data/adb/ksu/bin/busybox
bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    elif [ -x "$BB" ]; then
        "$BB" timeout 5 "$@"
    else
        return 127
    fi
}
[ -x "$JQ" ] || exit 1
machine=$(bounded "$MODDIR/cli" --json service status 2>/dev/null) || machine='{}'
pids=$(printf '%s' "$machine" | "$JQ" -r '
  if .schema==1 and .ok==true and .command=="service.status"
  then .data.core.sing_box.pid_summary // "unknown" else "unknown" end' 2>/dev/null)
processes='[]'
expected=$(readlink -f "$MODDIR/bin/sing-box" 2>/dev/null)
case "$pids" in ''|*[!0-9,]*) pids='' ;; esac
# Only a module-owned process, with a stable start time, can supply memory data.
for pid in $(printf '%s' "$pids" | tr ',' ' '); do
    [ "$(printf '%s' "$processes" | "$JQ" length)" -lt 8 ] || break
    [ -n "$expected" ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$expected" ] || continue
    before=$(bounded cat "/proc/$pid/stat" 2>/dev/null | sed 's/.*) //' | awk '{print $20}')
    [ -n "$before" ] || continue
    status=$(bounded cat "/proc/$pid/status" 2>/dev/null | awk '
        /^(VmRSS|RssAnon|RssFile|RssShmem|VmSwap|Threads):/ {print $1 " " $2}')
    rollup=$(bounded cat "/proc/$pid/smaps_rollup" 2>/dev/null | awk '
        /^(Pss|Private_Clean|Private_Dirty|Anonymous|Swap):/ {print $1 " " $2}')
    # Whitelist two Go knobs only; subscription/API secrets stay in the process.
    knobs=$(bounded cat "/proc/$pid/environ" 2>/dev/null | tr '\000' '\n' | sed -n '/^GOMEMLIMIT=/p; /^GOGC=/p')
    after=$(bounded cat "/proc/$pid/stat" 2>/dev/null | sed 's/.*) //' | awk '{print $20}')
    [ "$before" = "$after" ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$expected" ] || continue
    sample=$("$JQ" -cn --arg status "$status" --arg rollup "$rollup" --arg knobs "$knobs" '
        def fields($text): [$text | split("\n")[] | select(test("^[A-Za-z_]+: [0-9]+$"))
          | split(": ") | {key:.[0],value:(.[1]|tonumber)}] | from_entries;
        (fields($status) + fields($rollup)) as $m |
        {rss_kib:($m.VmRSS//null), anonymous_kib:($m.RssAnon//null), file_kib:($m.RssFile//null),
         shmem_kib:($m.RssShmem//null), pss_kib:($m.Pss//null), private_clean_kib:($m.Private_Clean//null),
         private_dirty_kib:($m.Private_Dirty//null), swap_kib:($m.VmSwap//null), threads:($m.Threads//null),
         go_knobs:[$knobs|split("\n")[]|select(test("^(GOMEMLIMIT=([0-9]+([KMGT]i?B)?|off)|GOGC=([0-9]+|off))$"))]}') || continue
    processes=$("$JQ" -cn --argjson previous "$processes" --argjson sample "$sample" '$previous+[$sample]')
done
config=$("$JQ" -c '
  def list: if type=="array" then . else [] end;
  {rule_sets:(.route.rule_set|list|length), dns_cache_capacity:(.dns.cache_capacity//null),
   tailscale_endpoints:([.endpoints|list|.[]|select(.type=="tailscale")]|length),
   tun_stacks:[.inbounds|list|.[]|select(.type=="tun")|.stack//"default"],
   google_package_routes:[.route.rules|list|.[]|select(any(.package_name|list|.[];
      .=="com.android.vending" or .=="com.google.android.gms" or .=="com.google.android.gsf"))
      | {outbound:(if (.outbound=="google-proxy" or .outbound=="proxy" or .outbound=="direct" or .outbound=="block") then .outbound else "custom" end)}]}
  | .dns_cache_capacity |= (if type=="number" and .>=0 and .<=10000000 then . else null end)
  | .tun_stacks |= map(if .=="mixed" or .=="system" or .=="gvisor" or .=="default" then . else "custom" end)
' "$MODDIR/.config/sing-box/config.json" 2>/dev/null) || config=null
# Resolve only the three relevant packages for the foreground Android user.
# Failure is unknown, not proof that an application is missing or excluded.
user=$(bounded am get-current-user 2>/dev/null | tr -d '\r\n')
packages='[]'; package_status=unknown
case "$user" in
    ''|*[!0-9]*) ;;
    *)
        listing=$(bounded cmd package list packages --user "$user" -U 2>/dev/null) && package_status=available
        packages=$(printf '%s\n' "$listing" | "$JQ" -Rsc '
          [split("\n")[] | try capture("^package:(?<package>com\\.android\\.vending|com\\.google\\.android\\.(gms|gsf)) uid:(?<uid>[0-9]+)\\r?$") catch empty
           | {package:.package,uid:(.uid|tonumber)}]') || packages='[]'
        ;;
esac
"$JQ" -cn --argjson processes "$processes" --argjson config "$config" --argjson packages "$packages" \
    --arg package_status "$package_status" '{schema:1,scope:"read_only_feedback",memory:{processes:$processes,
      measurement:(if ($processes|length)>0 then "proc_status" else "unavailable" end)},
      config:$config,package_lookup:$package_status,packages:$packages}'
