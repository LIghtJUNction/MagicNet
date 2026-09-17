#!/bin/sh
# Fault injection into real startup orchestration; no Android/network writes.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CORE_SOURCE="${MAGICNET_CORE_TEST_SOURCE:-$ROOT/src/MagicNet/lib/magicnet/core.sh}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for stage in subscription chain transparent hotspot dns tailscale apps warp auth config-check route-baseline core-launch; do
    for code in 1 2; do
        (
            # shellcheck disable=SC1090
            . "$CORE_SOURCE"
            MODDIR="$WORK/module"
            export MODDIR
            mkdir -p "$MODDIR/.state"
            : >"$WORK/calls"
            : >"$WORK/scrub"
            test_step() {
                printf '%s\n' "$1" >>"$WORK/calls"
                [ "$1" != "$stage" ] || return "$code"
            }
            magicnet_module_disabled() { return 1; }
            magicnet_cmd_exists() { return 0; }
            magicnet_warn() { printf '%s\n' "$*"; }
            import() { :; }
            is_singbox_running() { return 1; }
            magicnet_prepare_singbox_nodes_unlocked() { test_step subscription; }
            magicnet_singbox_chain_apply() { test_step chain; }
            magicnet_singbox_apply_transparent_mode() { test_step transparent; }
            magicnet_singbox_apply_hotspot_policy() { test_step hotspot; }
            magicnet_dns_apply_unlocked() { test_step dns; }
            magicnet_tailscale_apply_unlocked() { test_step tailscale; }
            magicnet_app_policy_apply_unlocked() { test_step apps; }
            magicnet_warp_apply_unlocked() { test_step warp; }
            magicnet_singbox_apply_zashboard() { :; }
            magicnet_tailscale_inject_auth_key() { test_step auth; }
            magicnet_tailscale_scrub_auth_key() { echo scrub >>"$WORK/scrub"; }
            magicnet_validate_singbox_transparent_config() { test_step config-check; }
            magicnet_kernel_route_state_begin() { test_step route-baseline; }
            magicnet_kernel_route_report_result() { :; }
            singbox_start() { test_step core-launch; }
            magicnet_singbox_running_has_nodes() { :; }
            if magicnet_start_singbox_unlocked >"$WORK/stdout" 2>"$WORK/stderr"; then
                fail "$stage/$code reported success"
            else
                rc=$?
            fi
            expected="$code"
            # An unverified baseline is always indeterminate ownership.
            [ "$stage" != route-baseline ] || expected=2
            [ "$rc" -eq "$expected" ] || fail "$stage/$code collapsed to $rc"
            grep -qx "Startup step failed: stage=$stage exit=$code" "$WORK/stderr" || fail "$stage/$code has no precise stderr diagnostic"
            [ ! -s "$WORK/stdout" ] || fail 'stage diagnostic polluted stdout'
            [ "$(tail -1 "$WORK/calls")" = "$stage" ] || fail 'startup continued after a failed step'
            case "$stage" in
                config-check|route-baseline|core-launch)
                    [ -s "$WORK/scrub" ] || fail "$stage leaked transient auth material" ;;
            esac
        )
    done
done

# Caller-visible state changes must survive; a subshell wrapper would break this.
(
    # shellcheck disable=SC1090
    . "$CORE_SOURCE"
    magicnet_warn() { :; }
    materialize() { MAGICNET_TEST_STAGE_VALUE=ready; }
    magicnet_startup_step config-check materialize
    [ "$MAGICNET_TEST_STAGE_VALUE" = ready ] || fail 'step lost same-shell changes'
)

# Unknown identity must remain rc=2 through the public entrypoint, even if a
# cleanup helper overwrites conventional global scratch variables.
(
    # shellcheck disable=SC1090
    . "$CORE_SOURCE"
    magicnet_warn() { :; }
    magicnet_detach_pid_from_app_cgroup() { :; }
    magicnet_kernel_start_preamble() { :; }
    magicnet_kernel_running() { return 1; }
    magicnet_require_subscription_or_stop() { :; }
    magicnet_disable_dns_capture() { :; }
    magicnet_disable_dns_leak_guard() { :; }
    magicnet_start_singbox_ready() { return 2; }
    magicnet_cmd_exists() { return 0; }
    magicnet_hotspot_startup_snapshot_clear() { _rc=0; _ready_start_rc=0; }
    if magicnet_start_kernel; then fail 'unknown startup returned success'; else rc=$?; fi
    [ "$rc" -eq 2 ] || fail 'public startup collapsed indeterminate identity'
)

# An early rc=2 must not authorize stopping an unverified process generation.
(
    # shellcheck disable=SC1090
    . "$CORE_SOURCE"
    magicnet_start_singbox_unlocked() { return 2; }
    magicnet_rollback_failed_start_unlocked() { fail 'unknown identity triggered teardown'; }
    if magicnet_start_singbox_ready_unlocked; then fail 'unknown identity became ready'; else rc=$?; fi
    [ "$rc" -eq 2 ] || fail 'ready entrypoint collapsed unknown identity'
)
printf '%s\n' 'startup diagnostics: 24 failure-stage cases and 3 safety cases passed'
