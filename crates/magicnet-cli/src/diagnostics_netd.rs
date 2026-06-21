use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) fn find_netd_cgroup_path() -> Option<PathBuf> {
    for entry in fs::read_dir("/proc").ok()?.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.bytes().any(|byte| !byte.is_ascii_digit()) {
            continue;
        }
        let dir = entry.path();
        if !is_netd_process(&dir) {
            continue;
        }
        if let Some(path) = read_cgroup_path(&dir.join("cgroup")) {
            return Some(path);
        }
    }
    None
}

pub(super) fn collect_netd_status(
    loader_path: &PathBuf,
    loader_executable: bool,
) -> (BTreeMap<String, String>, String) {
    let mut map = BTreeMap::new();
    for (name, path) in [
        (
            "connect4",
            "/sys/fs/bpf/netd_shared/prog_netd_connect4_inet4_connect",
        ),
        (
            "connect6",
            "/sys/fs/bpf/netd_shared/prog_netd_connect6_inet6_connect",
        ),
        (
            "udp4_dns",
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg4_udp4_sendmsg",
        ),
        (
            "udp6_dns",
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg6_udp6_sendmsg",
        ),
    ] {
        map.insert(
            format!("{name}.netd_pin"),
            if PathBuf::from(path).exists() {
                "present"
            } else {
                "missing"
            }
            .to_string(),
        );
    }

    if !loader_executable {
        return (map, "loader missing".to_string());
    }

    let output = Command::new(loader_path)
        .args(["query", "--cgroup", "/sys/fs/cgroup"])
        .output();
    let output = match output {
        Ok(output) => output,
        Err(err) => return (map, format!("run query: {err}")),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stdout.lines() {
        parse_netd_query_line(&mut map, line);
    }
    if output.status.success() {
        (map, String::new())
    } else {
        let detail = stderr.trim();
        (
            map,
            if detail.is_empty() {
                format!(
                    "query exited with status {}",
                    output.status.code().unwrap_or(1)
                )
            } else {
                detail.to_string()
            },
        )
    }
}

fn is_netd_process(dir: &Path) -> bool {
    fs::read_to_string(dir.join("comm"))
        .map(|comm| comm.trim() == "netd")
        .unwrap_or(false)
        || fs::read(dir.join("cmdline"))
            .ok()
            .and_then(|cmdline| {
                cmdline
                    .split(|byte| *byte == 0)
                    .find(|arg| !arg.is_empty())
                    .map(|arg| String::from_utf8_lossy(arg).into_owned())
            })
            .and_then(|arg0| {
                Path::new(&arg0)
                    .file_name()
                    .map(|name| name.to_string_lossy() == "netd")
            })
            .unwrap_or(false)
}

fn read_cgroup_path(path: &Path) -> Option<PathBuf> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let Some(cgroup) = line.strip_prefix("0::") else {
            continue;
        };
        let mut out = PathBuf::from("/sys/fs/cgroup");
        if cgroup != "/" {
            out.push(cgroup.trim_start_matches('/'));
        }
        return Some(out);
    }
    None
}

fn parse_netd_query_line(map: &mut BTreeMap<String, String>, line: &str) {
    let line = line.trim();
    let Some((left, right)) = line.split_once(':') else {
        return;
    };
    let Some((name, scope)) = left.split_once('.') else {
        return;
    };
    if right.contains("count=") {
        for part in right.split(',') {
            let part = part.trim();
            if let Some(value) = part.strip_prefix("count=") {
                map.insert(format!("{name}.{scope}.count"), value.trim().to_string());
            } else if let Some(value) = part.strip_prefix("attach_flags=") {
                map.insert(
                    format!("{name}.{scope}.attach_flags"),
                    value.trim().to_string(),
                );
            }
        }
        return;
    }
    if let Some((index, value)) = left.split_once('[') {
        let Some((name, scope)) = index.split_once('.') else {
            return;
        };
        let Some(prog_id) = right.trim().strip_prefix("prog_id=") else {
            return;
        };
        let key = format!("{name}.{scope}.prog_ids");
        let existing = map.get(&key).cloned().unwrap_or_default();
        let suffix = value.trim_end_matches(']');
        let item = format!("{suffix}:{}", prog_id.trim());
        map.insert(
            key,
            if existing.is_empty() {
                item
            } else {
                format!("{existing},{item}")
            },
        );
    }
}
