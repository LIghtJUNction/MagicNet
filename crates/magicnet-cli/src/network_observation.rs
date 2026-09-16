//! Bounded, read-only kernel observations. Recovery inventory is not liveness.
use std::path::Path;
use std::process::Command;
use std::time::Duration;

fn snapshot(program: &str, args: &[&str]) -> Result<String, &'static str> {
    let system = format!("/system/bin/{program}");
    let mut command = Command::new(if Path::new(&system).is_file() {
        &system
    } else {
        program
    });
    command.args(args).env("LC_ALL", "C").env("LANG", "C");
    let result = crate::run_bounded_command(command, Duration::from_secs(2), 128 * 1024)
        .map_err(|_| "observation-unavailable")?;
    if result.timed_out || result.truncated {
        return Err("observation-incomplete");
    }
    if !result.status.is_some_and(|status| status.success()) {
        let error = String::from_utf8_lossy(&result.stderr);
        return Err(
            if error.contains("Table does not exist")
                || error.contains("Address family not supported")
            {
                "table-unsupported"
            } else {
                "observation-failed"
            },
        );
    }
    String::from_utf8(result.stdout).map_err(|_| "observation-invalid")
}

pub(crate) fn dns_family(
    program: &str,
    port: u64,
) -> Result<(bool, bool, bool, bool), &'static str> {
    // -S avoids hostname resolution and reads the chain plus callers together.
    // No -L hostname lookups, per-rule races or failed -C treated as absence.
    if program == "ip6tables" {
        let version = snapshot(program, &["--version"])?;
        if version.contains("(legacy)") {
            // Even a legacy table read can request module loading.
            // Inspect the proc registry before asking for nat rules.
            let path = Path::new("/proc/net/ip6_tables_names");
            let registry = match path.try_exists() {
                Ok(false) => Ok(None),
                Err(_) => Err("observation-unavailable"),
                Ok(true) => crate::read_proc_text_bounded(path, 4096)
                    .map(Some)
                    .map_err(|_| "observation-incomplete"),
            };
            registered_ipv6_nat(registry.as_ref().map(|v| v.as_deref()).map_err(|e| *e))?;
        }
    }
    let text = snapshot(program, &["-t", "nat", "-S"])?;
    dns_rules(&text, port)
}

fn dns_rules(text: &str, port: u64) -> Result<(bool, bool, bool, bool), &'static str> {
    let mut uid0 = false;
    let mut output_rules = 0;
    let mut jumps = 0;
    let mut first = false;
    let mut udp = false;
    let mut tcp = false;
    for line in text.lines() {
        let normalized = line
            .replace(" -m tcp ", " ")
            .replace(" -m udp ", " ")
            .replace("'!'", "!");
        let words = normalized.split_whitespace().collect::<Vec<_>>();
        if words.starts_with(&["-A", "OUTPUT"]) {
            output_rules += 1;
            if words.contains(&"magicnet-dns-output") {
                jumps += 1;
                first = output_rules == 1 && words == ["-A", "OUTPUT", "-j", "magicnet-dns-output"];
            }
        }
        if !words.starts_with(&["-A", "magicnet-dns-output"]) {
            continue;
        }
        let rule = &words[2..];
        if rule == ["-p", "tcp", "!", "--dport", "53", "-j", "RETURN"]
            || rule == ["-p", "udp", "!", "--dport", "53", "-j", "RETURN"]
        {
            continue;
        }
        if rule.len() == 6
            && rule[..3] == ["-m", "owner", "--uid-owner"]
            && rule[4..] == ["-j", "RETURN"]
        {
            match rule[3].parse::<u32>() {
                Ok(0) => uid0 = true,
                Ok(_) => (),
                Err(_) => return Err("capture-rule-unrecognized"),
            }
            continue;
        }
        if rule.len() == 6
            && rule[..3] == ["-m", "mark", "--mark"]
            && rule[4..] == ["-j", "RETURN"]
            && matches!(rule[3], "0x80/0x80" | "128/128")
        {
            continue;
        }
        if rule.len() == 8
            && rule[0] == "-p"
            && rule[2..7] == ["--dport", "53", "-j", "REDIRECT", "--to-ports"]
            && rule[7].parse::<u64>() == Ok(port)
        {
            match rule[1] {
                "udp" => udp = true,
                "tcp" => tcp = true,
                _ => return Err("capture-rule-unrecognized"),
            }
        } else {
            return Err("capture-rule-unrecognized");
        }
    }
    Ok((uid0, first && jumps == 1, udp, tcp))
}

fn iface_valid(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 15
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.:-".contains(&c))
}

fn hotspot_matches(inventory: &str, rules: &str, routes: &str, forward: &str) -> bool {
    let prefixes = routes
        .lines()
        .filter_map(|line| {
            let words = line.split_whitespace().collect::<Vec<_>>();
            if words.windows(2).any(|pair| pair == ["dev", "magicnet0"]) {
                words.first().copied()
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    let ready = prefixes
        .iter()
        .any(|prefix| matches!(*prefix, "default" | "0.0.0.0/0"))
        || (prefixes.contains(&"0.0.0.0/1") && prefixes.contains(&"128.0.0.0/1"));
    if !ready {
        return false;
    }
    let rows = inventory
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>();
    if rows.is_empty() || rows.len() > 64 {
        return false;
    }
    rows.iter().all(|row| {
        let Some((priority, iface)) = row.split_once('|') else { return false; };
        if priority.parse::<u32>().is_err() || !iface_valid(iface) { return false; }
        let present = rules.lines().any(|line| {
            let words = line.split_whitespace().collect::<Vec<_>>();
            words.first().is_some_and(|word| *word == format!("{priority}:"))
                && words.windows(2).any(|pair| pair == ["iif", iface])
                && words.windows(2).any(|pair| pair == ["lookup", "2022"])
        });
        let outbound = format!("-A FORWARD -i {iface} -o magicnet0 -m comment --comment magicnet-hotspot -j ACCEPT");
        let inbound = format!("-A FORWARD -i magicnet0 -o {iface} -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment magicnet-hotspot -j ACCEPT");
        let lines = forward.lines().map(|line| line.replace('"', "").replace("ESTABLISHED,RELATED", "RELATED,ESTABLISHED")).collect::<Vec<_>>();
        present && lines.contains(&outbound) && lines.contains(&inbound)
    })
}

pub(crate) fn hotspot_state(path: &Path) -> &'static str {
    let inventory = match crate::read_proc_text_bounded(path, 8192) {
        Ok(text) => text,
        Err(_) => return "unknown",
    };
    let observed = snapshot("ip", &["-4", "rule", "show"]).and_then(|rules| {
        let routes = snapshot("ip", &["-4", "route", "show", "table", "2022"])?;
        let forward = snapshot("iptables", &["-S", "FORWARD"])?;
        Ok(hotspot_matches(&inventory, &rules, &routes, &forward))
    });
    match observed {
        Ok(true) => "active",
        Ok(false) => "pending",
        Err(_) => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn capture() -> String {
        "-A OUTPUT -j magicnet-dns-output\n-A magicnet-dns-output -p tcp -m tcp ! --dport 53 -j RETURN\n-A magicnet-dns-output -p udp -m udp ! --dport 53 -j RETURN\n-A magicnet-dns-output -p udp -m udp --dport 53 -j REDIRECT --to-ports 1053\n-A magicnet-dns-output -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 1053\n".into()
    }
    #[test]
    fn capture_checks_both_transports_actual_port_and_jump_priority() {
        assert_eq!(dns_rules(&capture(), 1053), Ok((false, true, true, true)));
        assert!(dns_rules(&capture(), 5353).is_err());
        assert!(
            !dns_rules(&format!("-A OUTPUT -j foreign\n{}", capture()), 1053)
                .unwrap()
                .1
        );
        assert!(
            !dns_rules(
                &format!("{}-A OUTPUT -j magicnet-dns-output\n", capture()),
                1053
            )
            .unwrap()
            .1
        );
        assert!(dns_rules(
            &format!("{}-A magicnet-dns-output -j RETURN\n", capture()),
            1053
        )
        .is_err());
    }
    #[test]
    fn root_bypass_is_observed_not_silently_exempted() {
        assert!(
            dns_rules(
                &format!(
                    "{}-A magicnet-dns-output -m owner --uid-owner 0 -j RETURN\n",
                    capture()
                ),
                1053
            )
            .unwrap()
            .0
        );
        assert_eq!(
            dns_rules("-P OUTPUT ACCEPT\n", 1053),
            Ok((false, false, false, false))
        );
    }
    #[test]
    fn inventory_does_not_prove_hotspot_liveness() {
        let ip = "8999: from all iif wlan1 lookup 2022\n";
        let route = "default dev magicnet0 scope link\n";
        let forward = "-A FORWARD -i wlan1 -o magicnet0 -m comment --comment magicnet-hotspot -j ACCEPT\n-A FORWARD -i magicnet0 -o wlan1 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment magicnet-hotspot -j ACCEPT\n";
        assert!(hotspot_matches("8999|wlan1\n", ip, route, forward));
        assert!(!hotspot_matches(
            "8999|wlan1\n",
            ip,
            "198.18.0.1 dev magicnet0\n",
            forward
        ));
        assert!(!hotspot_matches(
            "8999|wlan1\n",
            ip,
            "0.0.0.0/1 dev magicnet0\n",
            forward
        ));
        assert!(hotspot_matches(
            "8999|wlan1\n",
            ip,
            "0.0.0.0/1 dev magicnet0\n128.0.0.0/1 dev magicnet0\n",
            forward
        ));

        for (rules, routes, fw) in [("", route, forward), (ip, "", forward), (ip, route, "")] {
            assert!(!hotspot_matches("8999|wlan1\n", rules, routes, fw));
        }
        assert!(!hotspot_matches(
            "8999|wlan1\n",
            &ip.replace("2022", "20220"),
            route,
            forward
        ));
        assert!(!hotspot_matches(
            "8999|wlan1\n9000|usb0\n",
            ip,
            route,
            forward
        ));
    }
}

fn registered_ipv6_nat(registry: Result<Option<&str>, &'static str>) -> Result<(), &'static str> {
    match registry? {
        Some(names) if names.lines().any(|line| line.trim() == "nat") => Ok(()),
        _ => Err("table-unsupported"),
    }
}
#[cfg(test)]
mod registry_tests {
    use super::registered_ipv6_nat;
    #[test]
    fn table_observation_does_not_load_or_guess_legacy_ipv6_nat() {
        assert_eq!(registered_ipv6_nat(Ok(Some("filter\nnat\n"))), Ok(()));
        for names in [None, Some(""), Some("filter\n"), Some("notnat\n")] {
            assert_eq!(registered_ipv6_nat(Ok(names)), Err("table-unsupported"));
        }
        for failure in ["observation-unavailable", "observation-incomplete"] {
            assert_eq!(registered_ipv6_nat(Err(failure)), Err(failure));
        }
    }
}
