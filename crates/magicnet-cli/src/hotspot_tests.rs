//! Hotspot transactions use only temporary intent files, shell doubles and a
//! fake curl. No fixture applies rules to the Android host or contacts an API.
use std::fs;
use std::os::unix::fs::PermissionsExt;

use serde_json::{json, Value};

use crate::test_support::{temp_app, TempApp};
use crate::{selector_store, service, webui_api, App};

const SELECTIONS: &str = ".config/magicnet/selector-selections.json";
const OWNER: &str = ".state/hotspot/tether-offload.previous";

fn executable(app: &App, name: &str, body: &str) {
    let shell = if cfg!(target_os = "android") {
        "/system/bin/sh"
    } else {
        "/bin/sh"
    };
    let path = app.moddir.join("bin").join(name);
    fs::write(&path, format!("#!{shell}\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

fn fixture(member: Option<&str>) -> TempApp {
    let app = temp_app();
    for directory in ["bin", "lib/kamfw", ".config/magicnet", ".state/hotspot"] {
        fs::create_dir_all(app.moddir.join(directory)).unwrap();
    }
    let mut choices = json!({"proxy":"fixture-node"});
    if let Some(member) = member {
        choices["hotspot"] = json!(member);
    }
    fs::write(app.moddir.join(SELECTIONS), choices.to_string()).unwrap();
    fs::write(
        app.moddir.join("runtime-member"),
        member.unwrap_or("direct"),
    )
    .unwrap();
    if member == Some("proxy") {
        fs::write(app.moddir.join(OWNER), "value=0\n").unwrap();
        fs::write(app.moddir.join("watcher"), "running").unwrap();
    }
    fs::write(app.moddir.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
    fs::write(
        app.moddir.join("lib/magicnet_singbox_subscribe.sh"),
        "magicnet_singbox_update_lock_active() { return 1; }\n",
    )
    .unwrap();
    fs::write(
        app.moddir.join("lib/magicnet.sh"),
        r#"
step() {
    printf '%s\n' "$1" >>"$MODDIR/calls"
    if [ -f "$MODDIR/fail-api-after-step" ] && [ "$(cat "$MODDIR/fail-api-after-step")" = "$1" ]; then
        : >"$MODDIR/fail-select-always"
    fi
    if [ -f "$MODDIR/break-store-after-step" ] && [ "$(cat "$MODDIR/break-store-after-step")" = "$1" ]; then
        rm -f "$MODDIR/.config/magicnet/selector-selections.json.lock"
        mkdir "$MODDIR/.config/magicnet/selector-selections.json.lock"
    fi
    if [ -f "$MODDIR/fail-once" ] && [ "$(cat "$MODDIR/fail-once")" = "$1" ]; then
        rm "$MODDIR/fail-once"
        return 42
    fi
    if [ -f "$MODDIR/fail-always" ] && [ "$(cat "$MODDIR/fail-always")" = "$1" ]; then
        return 43
    fi
}
magicnet_hotspot_offload_enable() {
    step offload-enable || return $?
    printf 'value=0\n' >"$MODDIR/.state/hotspot/tether-offload.previous"
}
magicnet_hotspot_offload_restore() {
    step offload-restore || return $?
    rm -f "$MODDIR/.state/hotspot/tether-offload.previous"
}
magicnet_hotspot_reconcile() { step reconcile; }
magicnet_hotspot_route_cleanup() { step cleanup; }
magicnet_hotspot_watchdog_start() {
    step watcher-start || return $?
    printf running >"$MODDIR/watcher"
}
magicnet_hotspot_watchdog_stop() {
    step watcher-stop || return $?
    rm -f "$MODDIR/watcher"
}
magicnet_apply_runtime_config() { step materialize; }
magicnet_singbox_runtime_fingerprint_matches() { return 0; }
magicnet_singbox_hotspot_policy_current() { return 0; }
"#,
    )
    .unwrap();
    executable(
        &app,
        "curl",
        r#"
root=${0%/bin/curl}
case "$*" in
    */proxies/hotspot*)
        printf 'select\n' >>"$root/api-calls"
        if [ -f "$root/fail-select-always" ]; then exit 7; fi
        if [ -f "$root/fail-select-once" ]; then rm "$root/fail-select-once"; exit 7; fi
        case "$*" in
            *'"name":"proxy"'*) printf proxy >"$root/runtime-member" ;;
            *'"name":"direct"'*) printf direct >"$root/runtime-member" ;;
            *) exit 90 ;;
        esac ;;
    */proxies*)
        printf 'probe\n' >>"$root/api-calls"
        printf '{"proxies":{"hotspot":{"now":"%s"}}}' "$(cat "$root/runtime-member")" ;;
    */connections*) printf '{"connections":[]}' ;;
    *) exit 91 ;;
esac
"#,
    );
    app
}

fn action(app: &App, name: &str) -> Result<(), String> {
    webui_api::hotspot_cmd(app, &[name.to_string()])
}

fn choices(app: &App) -> Value {
    serde_json::from_slice(&fs::read(app.moddir.join(SELECTIONS)).unwrap()).unwrap()
}

fn assert_policy(app: &App, member: &str) {
    assert_eq!(choices(app)["hotspot"], member);
    assert_eq!(choices(app)["proxy"], "fixture-node");
    assert_eq!(
        fs::read_to_string(app.moddir.join("runtime-member")).unwrap(),
        member
    );
    assert_eq!(app.moddir.join(OWNER).exists(), member == "proxy");
    assert_eq!(app.moddir.join("watcher").exists(), member == "proxy");
}

#[test]
fn hotspot_repeated_enable_failure_restores_proxy_instead_of_forcing_direct() {
    let app = fixture(Some("proxy"));
    fs::write(app.moddir.join("fail-once"), "watcher-start").unwrap();
    assert!(action(&app, "enable").is_err());
    assert_policy(&app, "proxy");
}

#[test]
fn hotspot_failed_disable_restores_previous_proxy_intent_and_resources() {
    let app = fixture(Some("proxy"));
    fs::write(app.moddir.join("fail-once"), "offload-restore").unwrap();
    assert!(action(&app, "disable").is_err());
    assert_policy(&app, "proxy");
}

#[test]
fn hotspot_each_enable_failure_restores_direct_and_preserves_other_selectors() {
    for step in [
        "offload-enable",
        "materialize",
        "reconcile",
        "watcher-start",
    ] {
        let app = fixture(Some("direct"));
        fs::write(app.moddir.join("fail-once"), step).unwrap();
        assert!(action(&app, "enable").is_err(), "{step}");
        assert_policy(&app, "direct");
    }
}

#[test]
fn hotspot_failed_enable_does_not_make_a_previously_unset_choice_explicit() {
    let app = fixture(None);
    fs::write(app.moddir.join("fail-once"), "watcher-start").unwrap();
    assert!(action(&app, "enable").is_err());
    assert!(choices(&app).get("hotspot").is_none());
    assert_eq!(choices(&app)["proxy"], "fixture-node");
    assert!(!app.moddir.join(OWNER).exists());
}

#[test]
fn hotspot_save_failure_is_fatal_before_runtime_or_android_settings_change() {
    let app = fixture(Some("direct"));
    fs::create_dir(
        app.moddir
            .join(".config/magicnet/selector-selections.json.lock"),
    )
    .unwrap();
    assert!(action(&app, "enable").is_err());
    assert_policy(&app, "direct");
    assert!(!app.moddir.join("calls").exists());
    let api = fs::read_to_string(app.moddir.join("api-calls")).unwrap_or_default();
    assert!(!api.lines().any(|line| line == "select"));
}

#[test]
fn hotspot_unknown_intent_is_not_quarantined_or_replaced_by_a_default() {
    let app = fixture(Some("direct"));
    fs::write(app.moddir.join(SELECTIONS), "not-json").unwrap();
    assert!(action(&app, "enable").is_err());
    assert_eq!(
        fs::read_to_string(app.moddir.join(SELECTIONS)).unwrap(),
        "not-json"
    );
    assert!(!app.moddir.join("calls").exists());
    assert!(!fs::read_dir(app.moddir.join(".config/magicnet"))
        .unwrap()
        .any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".corrupt.")));
}

#[test]
fn hotspot_busy_config_lock_rejects_toggle_before_changing_any_policy() {
    let app = fixture(Some("direct"));
    let _guard = service::config_apply_lock(&app).unwrap();
    let error = action(&app, "enable").unwrap_err();
    assert!(error.contains("busy"), "{error}");
    assert_policy(&app, "direct");
    assert!(!app.moddir.join("calls").exists());
    assert!(!app.moddir.join("api-calls").exists());
}

#[test]
fn hotspot_rollback_failure_is_reported_and_saved_intent_is_still_restored() {
    let app = fixture(Some("proxy"));
    fs::write(app.moddir.join("fail-always"), "materialize").unwrap();
    let error = action(&app, "disable").unwrap_err();
    assert!(error.contains("rollback"), "{error}");
    assert_eq!(choices(&app)["hotspot"], "proxy");
}

#[test]
fn hotspot_successful_toggle_commits_saved_runtime_and_owned_resources() {
    let app = fixture(Some("direct"));
    action(&app, "enable").unwrap();
    assert_policy(&app, "proxy");
    action(&app, "disable").unwrap();
    assert_policy(&app, "direct");
}

#[test]
fn hotspot_extra_arguments_are_rejected_before_any_mutation() {
    let app = fixture(Some("direct"));
    assert!(webui_api::hotspot_cmd(&app, &["enable".into(), "extra".into()]).is_err());
    assert_policy(&app, "direct");
    assert!(!app.moddir.join("calls").exists());
}

#[test]
fn hotspot_api_write_failure_restores_saved_runtime_and_resources() {
    for previous in ["direct", "proxy"] {
        let app = fixture(Some(previous));
        fs::write(app.moddir.join("fail-select-once"), "").unwrap();
        let action_name = if previous == "proxy" {
            "disable"
        } else {
            "enable"
        };
        assert!(action(&app, action_name).is_err());
        assert_policy(&app, previous);
    }
}

#[test]
fn hotspot_failed_rollback_put_does_not_skip_offload_or_route_compensation() {
    let app = fixture(Some("direct"));
    fs::write(app.moddir.join("fail-once"), "watcher-start").unwrap();
    fs::write(app.moddir.join("fail-api-after-step"), "watcher-start").unwrap();
    let error = action(&app, "enable").unwrap_err();
    assert!(error.contains("rollback"), "{error}");
    assert_eq!(choices(&app)["hotspot"], "direct");
    assert!(!app.moddir.join(OWNER).exists());
    assert!(!app.moddir.join("watcher").exists());
    let calls = fs::read_to_string(app.moddir.join("calls")).unwrap();
    let rollback = calls.split_once("watcher-start\n").unwrap().1;
    for step in ["watcher-stop", "offload-restore", "cleanup", "materialize"] {
        assert!(
            rollback.lines().any(|line| line == step),
            "missing {step}: {rollback}"
        );
    }
}

#[test]
fn hotspot_failed_rollback_save_still_attempts_independent_resource_cleanup() {
    let app = fixture(Some("direct"));
    fs::write(app.moddir.join("fail-once"), "watcher-start").unwrap();
    fs::write(app.moddir.join("break-store-after-step"), "watcher-start").unwrap();
    let error = action(&app, "enable").unwrap_err();
    assert!(error.contains("rollback failed: intent"), "{error}");
    assert!(!app.moddir.join(OWNER).exists());
    assert!(!app.moddir.join("watcher").exists());
    assert_eq!(
        fs::read_to_string(app.moddir.join("runtime-member")).unwrap(),
        "direct"
    );
    let calls = fs::read_to_string(app.moddir.join("calls")).unwrap();
    let rollback = calls.split_once("watcher-start\n").unwrap().1;
    assert!(!rollback.lines().any(|line| line == "materialize"));
}

#[test]
fn hotspot_rollback_keeps_configured_and_observed_choices_separate() {
    let app = fixture(Some("proxy"));
    fs::write(app.moddir.join("runtime-member"), "direct").unwrap();
    fs::write(app.moddir.join("fail-once"), "watcher-start").unwrap();
    assert!(action(&app, "enable").is_err());
    assert_eq!(choices(&app)["hotspot"], "proxy");
    assert_eq!(
        fs::read_to_string(app.moddir.join("runtime-member")).unwrap(),
        "direct"
    );
    assert!(app.moddir.join(OWNER).exists());
    assert!(app.moddir.join("watcher").exists());
}

#[test]
fn hotspot_invalid_saved_or_requested_member_is_rejected_without_mutation() {
    let app = fixture(Some("invalid"));
    assert!(action(&app, "enable").is_err());
    assert_eq!(choices(&app)["hotspot"], "invalid");
    assert!(!app.moddir.join("calls").exists());
    assert!(!app.moddir.join("api-calls").exists());

    let app = fixture(Some("direct"));
    assert!(webui_api::select_proxy(&app, "hotspot", "invalid").is_err());
    assert_policy(&app, "direct");
    assert!(!app.moddir.join("calls").exists());
    assert!(!app.moddir.join("api-calls").exists());
}

#[test]
fn hotspot_selector_store_symlink_is_rejected_without_following_it() {
    let app = fixture(Some("direct"));
    let target = app.moddir.join("unrelated.json");
    fs::write(&target, "{}").unwrap();
    fs::remove_file(app.moddir.join(SELECTIONS)).unwrap();
    std::os::unix::fs::symlink(&target, app.moddir.join(SELECTIONS)).unwrap();
    assert!(action(&app, "enable").is_err());
    assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
    assert!(!app.moddir.join("calls").exists());
    assert!(!app.moddir.join("api-calls").exists());
}

#[test]
fn hotspot_generic_selector_entry_uses_the_same_transaction() {
    let app = fixture(Some("direct"));
    webui_api::select_proxy(&app, "hotspot", "proxy").unwrap();
    assert_policy(&app, "proxy");
    assert_eq!(
        selector_store::selected(&app, "hotspot").as_deref(),
        Some("proxy")
    );
}
