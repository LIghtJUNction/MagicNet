use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::diagnostics_netd::{collect_netd_status, find_netd_cgroup_path};
use crate::App;

#[derive(Debug)]
pub(super) struct EbpfStatus {
    pub(super) mode: &'static str,
    pub(super) bpffs: bool,
    pub(super) btf: bool,
    pub(super) cgroup: bool,
    pub(super) dns_cgroup: bool,
    pub(super) config_cgroup_bpf: bool,
    pub(super) config_bpf_syscall: bool,
    pub(super) loader: bool,
    pub(super) loader_executable: bool,
    pub(super) redirect: bool,
    pub(super) profile: &'static str,
    pub(super) allow_multi_permission: bool,
    pub(super) probe: bool,
    pub(super) cgroup_path: String,
    pub(super) dns_cgroup_path: String,
    pub(super) loader_path: PathBuf,
    pub(super) mixed_port: String,
    pub(super) dns_port: String,
    pub(super) state_dir: PathBuf,
    pub(super) state_present: bool,
    pub(super) daemon_pid: String,
    pub(super) daemon_live: bool,
    pub(super) state: BTreeMap<String, String>,
    pub(super) netd: BTreeMap<String, String>,
    pub(super) query_error: String,
}

impl EbpfStatus {
    pub(super) fn ok(&self) -> bool {
        if self.mode == "tun" {
            return true;
        }
        let runtime_ok = self.mode != "ebpf" || (self.daemon_live && self.state_is_attached());
        self.bpffs
            && self.cgroup
            && self.dns_cgroup
            && self.config_cgroup_bpf
            && self.config_bpf_syscall
            && self.loader_executable
            && self.redirect
            && self.probe
            && runtime_ok
    }

    pub(super) fn netd_ok(&self) -> bool {
        if !self.query_error.is_empty() {
            return false;
        }
        ["connect4", "connect6"].iter().all(|name| {
            self.netd
                .get(&format!("{name}.netd_pin"))
                .map(|value| value == "present")
                .unwrap_or(false)
                && self
                    .netd
                    .get(&format!("{name}.direct.count"))
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(0)
                    >= 1
        })
    }

    fn state_is_attached(&self) -> bool {
        self.state
            .get("mode")
            .map(|value| value == "tcp-bridge")
            .unwrap_or(false)
            && self
                .state
                .get("mixed_port")
                .map(|value| value == &self.mixed_port)
                .unwrap_or(false)
            && self
                .state
                .get("dns_port")
                .map(|value| value == &self.dns_port)
                .unwrap_or(false)
            && non_empty_state(&self.state, "bridge4_port")
            && non_empty_state(&self.state, "bridge6_port")
            && attached_state(&self.state, "dns_udp4")
            && attached_state(&self.state, "dns_udp6")
            && attached_state(&self.state, "netd_dns_connect4")
            && attached_state(&self.state, "netd_dns_connect6")
            && attached_state(&self.state, "netd_dns_udp4")
            && attached_state(&self.state, "netd_dns_udp6")
            && self.state_profile_matches()
    }

    fn state_profile_matches(&self) -> bool {
        self.state
            .get("profile")
            .map(|value| value == self.profile)
            .unwrap_or(false)
    }

    pub(super) fn probe_label(&self) -> &'static str {
        probe_state(self.loader_executable, self.probe)
    }

    pub(super) fn daemon_label(&self) -> &'static str {
        if self.daemon_live && self.state_is_attached() {
            "running"
        } else if self.daemon_live {
            "pid-live-state-incomplete"
        } else if self.daemon_pid != "stopped" {
            "stale"
        } else {
            "stopped"
        }
    }

    pub(super) fn health_detail(&self) -> String {
        format!(
            "mode={}, profile={}, daemon={}, bpffs={}, btf={}, cgroup={}, dns_cgroup={}, config={}, syscall={}, loader={}, redirect={}, allow_multi={}, probe={}, mixed_port={}, dns_port={}, state={}",
            self.mode,
            self.profile,
            self.daemon_label(),
            yes_no(self.bpffs),
            yes_no(self.btf),
            yes_no(self.cgroup),
            yes_no(self.dns_cgroup),
            yes_no(self.config_cgroup_bpf),
            yes_no(self.config_bpf_syscall),
            yes_no(self.loader_executable),
            yes_no(self.redirect),
            yes_no(self.allow_multi_permission),
            self.probe_label(),
            self.mixed_port,
            self.dns_port,
            present_word(self.state_present),
        )
    }

    pub(super) fn netd_detail(&self) -> String {
        if !self.query_error.is_empty() {
            return format!("query=failed, {}", self.query_error);
        }
        self.netd_summary()
    }

    pub(super) fn netd_summary(&self) -> String {
        let mut parts = Vec::new();
        for name in ["connect4", "connect6", "udp4_dns", "udp6_dns"] {
            let pin = self
                .netd
                .get(&format!("{name}.netd_pin"))
                .map(String::as_str)
                .unwrap_or("missing");
            let flags = self
                .netd
                .get(&format!("{name}.direct.attach_flags"))
                .map(String::as_str)
                .unwrap_or("unknown");
            let count = self
                .netd
                .get(&format!("{name}.direct.count"))
                .map(String::as_str)
                .unwrap_or("unknown");
            parts.push(format!("{name}:pin={pin},flags={flags},count={count}"));
        }
        parts.join("; ")
    }
}

pub(super) fn collect_ebpf_status(app: &App) -> EbpfStatus {
    let mode = transparent_mode(app);
    let cgroup_path = if PathBuf::from("/sys/fs/cgroup/apps").is_dir() {
        "/sys/fs/cgroup/apps".to_string()
    } else {
        "/sys/fs/cgroup".to_string()
    };
    let dns_cgroup_path = find_netd_cgroup_path()
        .unwrap_or_else(|| PathBuf::from("/sys/fs/cgroup"))
        .display()
        .to_string();
    let bpffs =
        shell_ok("[ -d /sys/fs/bpf ] && mount 2>/dev/null | grep -q ' on /sys/fs/bpf type bpf '");
    let btf = PathBuf::from("/sys/kernel/btf/vmlinux").is_file()
        || shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_DEBUG_INFO_BTF=y'")
        || shell_ok("[ ! -r /proc/config.gz ]");
    let config_cgroup_bpf =
        shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_CGROUP_BPF=y'")
            || shell_ok("[ ! -r /proc/config.gz ]");
    let config_bpf_syscall =
        shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_BPF_SYSCALL=y'")
            || shell_ok("[ ! -r /proc/config.gz ]");
    let loader_path = app.moddir.join("bin/magicnet-ebpf");
    let loader = loader_path.exists();
    let loader_executable = is_executable(&loader_path);
    let redirect = loader_executable && command_success(&loader_path, &["supports-redirect"]);
    let profile = ebpf_profile(app);
    let allow_multi_permission = ebpf_allow_multi_enabled(app);
    let probe = if bpffs
        && PathBuf::from(&cgroup_path).is_dir()
        && PathBuf::from(&dns_cgroup_path).is_dir()
        && config_cgroup_bpf
        && config_bpf_syscall
        && loader_executable
    {
        command_success(
            &loader_path,
            &[
                "probe",
                "--cgroup",
                &cgroup_path,
                "--dns-cgroup",
                &dns_cgroup_path,
            ],
        )
    } else {
        false
    };
    let state_dir = app.moddir.join(".state/ebpf");
    let state_file = state_dir.join("magicnet-ebpf.state");
    let state = read_state_file(&state_file);
    let state_present = state_file.is_file();
    let daemon_pid = read_pid(state_dir.join("guard.pid"));
    let daemon_live = daemon_pid
        .parse::<u32>()
        .map(proc_pid_exists)
        .unwrap_or(false);
    let (netd, query_error) = collect_netd_status(&loader_path, loader_executable);
    let (mixed_port, dns_port) = singbox_ports(app);

    EbpfStatus {
        mode,
        bpffs,
        btf,
        cgroup: PathBuf::from(&cgroup_path).is_dir(),
        dns_cgroup: PathBuf::from(&dns_cgroup_path).is_dir(),
        config_cgroup_bpf,
        config_bpf_syscall,
        loader,
        loader_executable,
        redirect,
        profile,
        allow_multi_permission,
        probe,
        cgroup_path,
        dns_cgroup_path,
        loader_path,
        mixed_port,
        dns_port,
        state_dir,
        state_present,
        daemon_pid,
        daemon_live,
        state,
        netd,
        query_error,
    }
}

pub(super) fn transparent_mode(app: &App) -> &'static str {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .and_then(|text| {
            if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=ebpf")
            {
                Some("ebpf")
            } else if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=auto")
            {
                Some("auto")
            } else if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=tun")
            {
                Some("tun")
            } else {
                None
            }
        })
        .unwrap_or("auto")
}

pub(super) fn ebpf_profile(app: &App) -> &'static str {
    fs::read_to_string(app.moddir.join(".config/magicnet/ebpf-profile.conf"))
        .ok()
        .and_then(|text| {
            if text.lines().any(|line| {
                matches!(
                    line.trim(),
                    "MAGICNET_EBPF_PROFILE=tcp" | "MAGICNET_EBPF_PROFILE=tcp-bridge"
                )
            }) {
                Some("tcp")
            } else {
                None
            }
        })
        .unwrap_or("tcp")
}

fn ebpf_allow_multi_enabled(app: &App) -> bool {
    fs::read_to_string(app.moddir.join(".config/magicnet/ebpf-allow-multi.conf"))
        .map(|text| {
            text.lines()
                .any(|line| line.trim() == "MAGICNET_EBPF_ALLOW_MULTI=1")
        })
        .unwrap_or(false)
}

fn shell_ok(script: &str) -> bool {
    Command::new("sh")
        .args(["-c", script])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn command_success(program: &PathBuf, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn is_executable(path: &PathBuf) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn read_state_file(path: &PathBuf) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        map.insert(key.trim().to_string(), value.trim().to_string());
    }
    map
}

fn read_pid(path: PathBuf) -> String {
    fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
        .filter(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
        .unwrap_or_else(|| "stopped".to_string())
}

fn proc_pid_exists(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

fn singbox_ports(app: &App) -> (String, String) {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let json: serde_json::Value = match serde_json::from_str(&text) {
        Ok(json) => json,
        Err(_) => return ("unknown".to_string(), "1053".to_string()),
    };
    let mixed = json
        .get("inbounds")
        .and_then(|value| value.as_array())
        .and_then(|inbounds| {
            inbounds.iter().find_map(|inbound| {
                let kind = inbound.get("type").and_then(|value| value.as_str())?;
                if kind != "mixed" {
                    return None;
                }
                inbound.get("listen_port").and_then(|value| value.as_u64())
            })
        })
        .map(|port| port.to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let dns = json
        .get("inbounds")
        .and_then(|value| value.as_array())
        .and_then(|inbounds| {
            inbounds.iter().find_map(|inbound| {
                let tag = inbound.get("tag").and_then(|value| value.as_str())?;
                if tag != "magicnet-ebpf-dns4-in" && tag != "magicnet-ebpf-dns6-in" {
                    return None;
                }
                inbound.get("listen_port").and_then(|value| value.as_u64())
            })
        })
        .map(|port| port.to_string())
        .unwrap_or_else(|| "1053".to_string());
    (mixed, dns)
}

fn attached_state(state: &BTreeMap<String, String>, key: &str) -> bool {
    state
        .get(key)
        .map(|value| value == "attached")
        .unwrap_or(false)
}

fn non_empty_state(state: &BTreeMap<String, String>, key: &str) -> bool {
    state
        .get(key)
        .map(|value| !value.is_empty())
        .unwrap_or(false)
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}

fn present_word(value: bool) -> &'static str {
    if value {
        "present"
    } else {
        "missing"
    }
}

fn probe_state(loader: bool, probe: bool) -> &'static str {
    if probe {
        "ok"
    } else if loader {
        "blocked"
    } else {
        "missing"
    }
}
