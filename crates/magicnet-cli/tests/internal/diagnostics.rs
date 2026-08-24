// Unit tests included from the matching src module.

use super::{
    configured_tun_is_canonical, network_policy_check, proxy_chain_evidence_from_values,
    read_only_command_with_timeout, redact, supervisor_cmdline_matches, support_bundle,
    traffic_loop_guard_check,
};
use crate::App;
use std::fs;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[test]
fn tun_health_accepts_only_the_canonical_magicnet_interface() {
    assert!(!configured_tun_is_canonical(&[]));
    assert!(configured_tun_is_canonical(&[String::from("magicnet0")]));
    assert!(!configured_tun_is_canonical(&[String::from("utun")]));
    assert!(!configured_tun_is_canonical(&[
        String::from("magicnet0"),
        String::from("Meta"),
    ]));
}

fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn supervisor_status_requires_exact_managed_argv() {
    let module = std::path::PathBuf::from("/data/adb/modules/MagicNet");
    assert!(supervisor_cmdline_matches(
        &module,
        "magicnet-config",
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/.state/fswatch/magicnet-config.loop.sh",
        ])
    ));
    assert!(supervisor_cmdline_matches(
        &module,
        "magicnet-wifi-policy",
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/cli",
            "wifi",
            "watch",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        "magicnet-config",
        &argv(&[
            "sleep",
            "600",
            "/data/adb/modules/MagicNet/.state/fswatch/magicnet-config.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        "magicnet-wifi-policy",
        &argv(&["/data/adb/modules/MagicNet/cli wifi watch"])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        "magicnet-wifi-policy",
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/Other/cli",
            "wifi",
            "watch",
        ])
    ));
}

#[test]
fn traffic_loop_guard_requires_root_and_loopback_exclusions(
) -> Result<(), Box<dyn std::error::Error>> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let root = std::env::temp_dir().join(format!("magicnet-loop-guard-{stamp}"));
    fs::create_dir_all(root.join(".config/sing-box"))?;
    fs::write(
        root.join(".config/sing-box/config.json"),
        r#"{
              "inbounds": [{
                "type": "tun",
                "exclude_uid": [0],
                "route_exclude_address": ["127.0.0.0/8", "::1/128"]
              }],
              "outbounds": [{"type": "vless", "tag": "node", "server": "example.com"}]
            }"#,
    )?;
    let app = App::for_test(root.clone());
    assert!(traffic_loop_guard_check(&app).0);

    fs::write(
        root.join(".config/sing-box/config.json"),
        r#"{"inbounds":[{"type":"tun"}],"outbounds":[]}"#,
    )?;
    assert!(!traffic_loop_guard_check(&app).0);
    let _ = fs::remove_dir_all(root);
    Ok(())
}

#[test]
fn network_policy_accepts_dual_stack_and_rejects_stale_ipv6_guard(
) -> Result<(), Box<dyn std::error::Error>> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let root = std::env::temp_dir().join(format!("magicnet-network-policy-{stamp}"));
    fs::create_dir_all(root.join(".config/sing-box"))?;
    let config_path = root.join(".config/sing-box/config.json");
    fs::write(
        &config_path,
        r#"{
              "dns": {"strategy": "prefer_ipv4"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1400,
                "udp_timeout": "5m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": []}
            }"#,
    )?;
    let app = App::for_test(root.clone());
    assert!(network_policy_check(&app).0);

    fs::write(
        &config_path,
        r#"{
              "dns": {"strategy": "prefer_ipv4"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1400,
                "udp_timeout": "5m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": [
                {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true}
              ]}
            }"#,
    )?;
    assert!(!network_policy_check(&app).0);

    fs::write(
        &config_path,
        r#"{
              "dns": {"strategy": "prefer_ipv6"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1280,
                "udp_timeout": "10m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": [{"ip_version": 6, "outbound": "block"}]}
            }"#,
    )?;
    assert!(!network_policy_check(&app).0);
    let _ = fs::remove_dir_all(root);
    Ok(())
}

#[test]
fn redact_removes_subscription_and_node_identifiers() {
    let input = "url=https://sub.example.com/path?token=abc query=customer-id candidate=private-profile selected=Tokyo-Premium path=config/subscription.url outbound=private-out host=edge.example.com profile=paid secret=secret-value token=customer-token-1234567890 email=user@example.com ip=203.0.113.9 device_id=DEVICE-CANARY serial=SERIAL-CANARY https://bare.example.net/a?x=y BareToken0123456789Secret ReviewerBarePassword!2026 bare@example.net 198.51.100.7 节点-东京";
    let output = redact(input);

    for sensitive in [
        "sub.example.com",
        "/path",
        "abc",
        "secret-value",
        "user@example.com",
        "203.0.113.9",
        "Tokyo-Premium",
        "customer-id",
        "private-profile",
        "config/subscription.url",
        "private-out",
        "edge.example.com",
        "paid",
        "节点-东京",
        "bare.example.net",
        "BareToken0123456789Secret",
        "bare@example.net",
        "198.51.100.7",
        "DEVICE-CANARY",
        "SERIAL-CANARY",
        "ReviewerBarePassword!2026",
    ] {
        assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
    }
}

#[test]
fn redact_removes_stable_interface_ids_but_keeps_interface_state() {
    let input = "2: enx001122aabbcc: <BROADCAST,UP> state UP type ether 3: br-deadbeefcafe1234: state DOWN type bridge 4: veth0123456789abcdef@if5: state UP type ether";
    let output = redact(input);

    for sensitive in [
        "enx001122aabbcc",
        "br-deadbeefcafe1234",
        "veth0123456789abcdef",
    ] {
        assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
    }
    assert!(output.contains("state UP type ether"));
    assert!(output.contains("state DOWN type bridge"));
}

#[test]
fn redact_keeps_safe_status_assignments_and_filters_unknown_entropy() {
    let safe = "last_skipped_count=3 cache_provenance_count=2 cache_source=url_sha256_identity";
    assert_eq!(redact(safe), safe);

    let unknown = "mystery=UnknownHighEntropyToken1234567890";
    assert!(!redact(unknown).contains("UnknownHighEntropyToken1234567890"));
}

#[test]
fn redact_keeps_prose_url_label_but_filters_following_secret_assignment() {
    let input = "reason=No subscription URL is configured; token=BUNDLE-STARTUP-CANARY";
    let output = redact(input);

    assert!(output.contains("reason=No subscription URL is configured"));
    assert!(!output.contains("BUNDLE-STARTUP-CANARY"));
}

#[test]
fn redact_filters_values_after_url_copulas() {
    for input in [
        "reason=Configured URL is short-secret",
        "reason=Configured URL was short-secret",
    ] {
        let output = redact(input);
        assert!(!output.contains("short-secret"), "leaked value: {output}");
    }
}

#[test]
fn read_only_command_reports_explicit_timeout() {
    let started = Instant::now();
    let output =
        read_only_command_with_timeout("sh", &["-c", "sleep 5 & wait"], Duration::from_millis(50));

    assert_eq!(output, "sh=timeout after 50ms");
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn read_only_command_closes_inherited_pipes_after_direct_child_exit() {
    let started = Instant::now();
    let output = read_only_command_with_timeout(
        "sh",
        &["-c", "sleep 5 & printf ready"],
        Duration::from_millis(50),
    );

    assert_eq!(output, "ready");
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn proxy_chain_evidence_keeps_routing_context_without_node_names_or_targets() {
    let proxies = serde_json::json!({
        "proxies": {
            "proxy-rule": {"type": "Selector", "now": "proxy"},
            "proxy": {"type": "Selector", "now": "PRIVATE-NODE-CANARY"},
            "PRIVATE-NODE-CANARY": {"type": "VLESS"},
            "direct": {"type": "Direct"},
            "block": {"type": "Block"}
        }
    });
    let connections = serde_json::json!({
        "connections": [
            {
                "metadata": {
                    "host": "PRIVATE-TARGET-CANARY.example",
                    "destinationIP": "203.0.113.9"
                },
                "chains": ["PRIVATE-NODE-CANARY", "proxy", "proxy-rule"]
            },
            {
                "metadata": {"host": "SECOND-PRIVATE-TARGET.example"},
                "chains": ["PRIVATE-NODE-CANARY", "proxy", "proxy-rule"]
            },
            {"chains": ["direct"]}
        ]
    });

    let output = proxy_chain_evidence_from_values(Some(&proxies), Some(&connections));

    assert!(output.contains("selector.proxy-rule=proxy-rule -> proxy -> <node:vless>"));
    assert!(output.contains("active_chain.1=count:2 chain:<node:vless> -> proxy -> proxy-rule"));
    assert!(output.contains("active_connection_count=3"));
    let redacted = redact(&output);
    assert!(redacted.contains("selector.proxy-rule=proxy-rule -> proxy -> <node:vless>"));
    assert!(redacted.contains("active_chain.1=count:2 chain:<node:vless> -> proxy -> proxy-rule"));
    for sensitive in [
        "PRIVATE-NODE-CANARY",
        "PRIVATE-TARGET-CANARY",
        "SECOND-PRIVATE-TARGET",
        "203.0.113.9",
    ] {
        assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
    }
}

#[test]
fn support_bundle_has_unique_redacted_read_only_evidence_sections(
) -> Result<(), Box<dyn std::error::Error>> {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let root = std::env::temp_dir().join(format!("magicnet-support-{nonce}"));
    let app = App::for_test(root.clone());
    fs::create_dir_all(root.join(".config/sing-box"))?;
    fs::create_dir_all(root.join(".state/sing-box"))?;
    fs::create_dir_all(root.join(".log"))?;
    fs::write(
        root.join(".config/sing-box/subscription.url"),
        "https://private.example.invalid/sub?token=BUNDLE-URL-CANARY\n",
    )?;
    fs::write(
            root.join(".state/sing-box/subscription-status"),
            "phase=activate\nresult=failed\nattempt_epoch=123\nsuccess_epoch=100\nconfigured_count=1\nsource_count=1\nimported_count=2\nskipped_count=0\ngeneration_id=123-456\nreason=token=BUNDLE-TOKEN-CANARY\nsource_mode=url\nnative_parser=share-links\nnative_node_count=0\nconverter_enabled=1\nconverter_available=1\nconverter_attempted=1\nconverter_format=singbox\nconverter_result=failed\n",
        )?;
    fs::write(
        root.join(".state/startup-error"),
        "No subscription URL is configured; token=BUNDLE-STARTUP-CANARY\n",
    )?;

    let bundle = support_bundle(&app);
    for heading in [
        "[subscription lifecycle]",
        "[service status]",
        "[startup state]",
        "[health]",
        "[core process and listeners]",
        "[tun routes and ip rules]",
        "[proxy selector and connection chains]",
        "[dns api and mcp]",
        "[subscription refresh log counts]",
    ] {
        assert_eq!(
            bundle.matches(heading).count(),
            1,
            "duplicate or missing {heading}"
        );
    }
    assert!(bundle.contains("last_phase=activate"));
    assert!(bundle.contains("last_result=failed"));
    assert!(bundle.contains("source_mode=url"));
    assert!(bundle.contains("update_running=0"));
    assert!(bundle.contains("last_native_node_count=0"));
    assert!(bundle.contains("last_converter_format=singbox"));
    assert!(bundle.contains("last_converter_result=failed"));
    assert!(bundle.contains("blocked=true"));
    assert!(bundle.contains("reason=No subscription URL is configured"));
    for sensitive in [
        "private.example.invalid",
        "BUNDLE-URL-CANARY",
        "BUNDLE-TOKEN-CANARY",
        "BUNDLE-STARTUP-CANARY",
        root.to_string_lossy().as_ref(),
    ] {
        assert!(
            !bundle.contains(sensitive),
            "support bundle leaked {sensitive}"
        );
    }
    fs::remove_dir_all(root)?;
    Ok(())
}
