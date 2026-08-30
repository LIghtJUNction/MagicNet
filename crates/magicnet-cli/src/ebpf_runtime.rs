use crate::{owned_singbox_pids, read_proc_text_bounded, run_bounded_command, App};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

const BPF_PROG_QUERY: libc::c_uint = 16;
const BPF_CGROUP_INET4_CONNECT: u32 = 10;
const BPF_CGROUP_INET6_CONNECT: u32 = 11;
const BPF_CGROUP_UDP4_SENDMSG: u32 = 14;
const BPF_CGROUP_UDP6_SENDMSG: u32 = 15;
const BPF_CGROUP_UDP4_RECVMSG: u32 = 19;
const BPF_CGROUP_UDP6_RECVMSG: u32 = 20;
const BPF_TCX_INGRESS: u32 = 46;
const BPF_TCX_EGRESS: u32 = 47;
const MAX_QUERY_PROGRAMS: usize = 128;
const MAX_FDINFO_FILES: usize = 2048;
const MAX_FDINFO_BYTES: usize = 8192;
const MAX_TC_OUTPUT_BYTES: usize = 16 * 1024;

#[repr(C)]
#[derive(Default)]
struct BpfProgQueryAttr {
    target_fd: u32,
    attach_type: u32,
    query_flags: u32,
    attach_flags: u32,
    prog_ids: u64,
    prog_cnt: u32,
    reserved: u32,
    prog_attach_flags: u64,
    link_ids: u64,
    link_attach_flags: u64,
    revision: u64,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct EbpfAttachmentEvidence {
    pub(crate) local_attached: bool,
    pub(crate) shared_attached: bool,
    pub(crate) shared_interfaces: Vec<(String, bool)>,
    pub(crate) detail: String,
}

pub(crate) fn inspect_ebpf_attachments(
    app: &App,
    report: &Value,
    local_expected: bool,
    cgroup_path: &str,
    network: &[String],
    shared_interfaces: &[String],
) -> EbpfAttachmentEvidence {
    let active = match active_programs(report) {
        Ok(active) => active,
        Err(reason) => return failed_evidence(shared_interfaces, reason),
    };
    let held = match core_program_ids(app) {
        Ok(held) => held,
        Err(reason) => return failed_evidence(shared_interfaces, reason),
    };

    let local = if local_expected {
        inspect_local_attachments(cgroup_path, network, &active, &held)
    } else {
        Ok(())
    };
    let mut shared_states = Vec::with_capacity(shared_interfaces.len());
    let mut shared_errors = Vec::new();
    for interface in shared_interfaces {
        match inspect_shared_attachment(interface, &active, &held) {
            Ok(()) => shared_states.push((interface.clone(), true)),
            Err(reason) => {
                shared_states.push((interface.clone(), false));
                shared_errors.push(format!("{interface}:{reason}"));
            }
        }
    }

    let local_attached = local.is_ok();
    let shared_attached = shared_states.iter().all(|(_, attached)| *attached);
    let mut details = Vec::new();
    if let Err(reason) = local {
        details.push(format!("local:{reason}"));
    } else if local_expected {
        details.push("local:attached".to_string());
    } else {
        details.push("local:inactive".to_string());
    }
    if shared_interfaces.is_empty() {
        details.push("shared:pending".to_string());
    } else if shared_attached {
        details.push("shared:attached".to_string());
    } else {
        details.push(format!("shared:{}", shared_errors.join("+")));
    }
    EbpfAttachmentEvidence {
        local_attached,
        shared_attached,
        shared_interfaces: shared_states,
        detail: details.join(","),
    }
}

fn failed_evidence(shared_interfaces: &[String], reason: String) -> EbpfAttachmentEvidence {
    EbpfAttachmentEvidence {
        local_attached: false,
        shared_attached: false,
        shared_interfaces: shared_interfaces
            .iter()
            .cloned()
            .map(|interface| (interface, false))
            .collect(),
        detail: reason,
    }
}

fn active_programs(report: &Value) -> Result<BTreeMap<u32, String>, String> {
    if report
        .get("active_state_error")
        .and_then(Value::as_str)
        .is_some_and(|error| !error.is_empty())
    {
        return Err("active-state-error".to_string());
    }
    let programs = report
        .get("active_programs")
        .and_then(Value::as_array)
        .ok_or_else(|| "active-program-report-missing".to_string())?;
    let mut active = BTreeMap::new();
    for program in programs {
        let Some(id) = program
            .get("id")
            .and_then(Value::as_u64)
            .and_then(|id| u32::try_from(id).ok())
        else {
            continue;
        };
        let Some(name) = program.get("name").and_then(Value::as_str) else {
            continue;
        };
        if name.starts_with("sb_ebpf_") || name.starts_with("sb_share_") {
            active.insert(id, name.to_string());
        }
    }
    if active.is_empty() {
        return Err("managed-active-programs-missing".to_string());
    }
    Ok(active)
}

fn core_program_ids(app: &App) -> Result<BTreeSet<u32>, String> {
    let pids = owned_singbox_pids(app)?;
    let [pid] = pids.as_slice() else {
        return Err(match pids.len() {
            0 => "owned-core-stopped".to_string(),
            count => format!("owned-core-count:{count}"),
        });
    };
    let proc_root = Path::new("/proc").join(pid);
    let fd_dir = proc_root.join("fd");
    let fdinfo_dir = proc_root.join("fdinfo");
    let entries = fs::read_dir(&fd_dir)
        .map_err(|_| "core-fds-unreadable".to_string())?
        .take(MAX_FDINFO_FILES);
    let mut ids = BTreeSet::new();
    for entry in entries {
        let Ok(entry) = entry else { continue };
        let Ok(target) = fs::read_link(entry.path()) else {
            continue;
        };
        if !target.to_string_lossy().contains("bpf") {
            continue;
        }
        let path = fdinfo_dir.join(entry.file_name());
        let Ok(text) = read_proc_text_bounded(&path, MAX_FDINFO_BYTES) else {
            continue;
        };
        ids.extend(parse_fdinfo_program_ids(&text));
    }
    if ids.is_empty() {
        return Err("core-bpf-fds-missing".to_string());
    }
    Ok(ids)
}

fn parse_fdinfo_program_ids(text: &str) -> BTreeSet<u32> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            (key.trim() == "prog_id")
                .then(|| value.trim().parse::<u32>().ok())
                .flatten()
        })
        .collect()
}

fn inspect_local_attachments(
    cgroup_path: &str,
    network: &[String],
    active: &BTreeMap<u32, String>,
    held: &BTreeSet<u32>,
) -> Result<(), String> {
    let cgroup = File::open(cgroup_path).map_err(|_| "cgroup-open-failed".to_string())?;
    let mut attach_types = vec![BPF_CGROUP_INET4_CONNECT, BPF_CGROUP_INET6_CONNECT];
    if network.iter().any(|value| value == "udp") {
        attach_types.extend([
            BPF_CGROUP_UDP4_SENDMSG,
            BPF_CGROUP_UDP6_SENDMSG,
            BPF_CGROUP_UDP4_RECVMSG,
            BPF_CGROUP_UDP6_RECVMSG,
        ]);
    }
    for attach_type in attach_types {
        let target = u32::try_from(cgroup.as_raw_fd()).map_err(|_| "cgroup-fd-invalid")?;
        let ids = query_program_ids(target, attach_type)
            .map_err(|_| format!("cgroup-query-{attach_type}-failed"))?;
        if !ids
            .iter()
            .any(|id| managed_program_matches(*id, "sb_ebpf_", active, held))
        {
            return Err(format!("cgroup-attach-{attach_type}-missing"));
        }
    }
    Ok(())
}

fn inspect_shared_attachment(
    interface: &str,
    active: &BTreeMap<u32, String>,
    held: &BTreeSet<u32>,
) -> Result<(), String> {
    let interface_c = CString::new(interface).map_err(|_| "interface-invalid".to_string())?;
    let index = unsafe { libc::if_nametoindex(interface_c.as_ptr()) };
    if index == 0 {
        return Err("interface-missing".to_string());
    }
    let tcx_ingress = query_program_ids(index, BPF_TCX_INGRESS).unwrap_or_default();
    let tcx_egress = query_program_ids(index, BPF_TCX_EGRESS).unwrap_or_default();
    let tcx_ok = tcx_ingress
        .iter()
        .any(|id| managed_program_matches(*id, "sb_share_in", active, held))
        && tcx_egress
            .iter()
            .any(|id| managed_program_matches(*id, "sb_share_out", active, held));
    if tcx_ok {
        return Ok(());
    }

    let ingress = tc_filter_program_ids(interface, "ingress", "sb_share_in")?;
    let egress = tc_filter_program_ids(interface, "egress", "sb_share_out")?;
    if ingress
        .iter()
        .any(|id| managed_program_matches(*id, "sb_share_in", active, held))
        && egress
            .iter()
            .any(|id| managed_program_matches(*id, "sb_share_out", active, held))
    {
        Ok(())
    } else {
        Err("tc-ingress-or-egress-missing".to_string())
    }
}

fn managed_program_matches(
    id: u32,
    prefix: &str,
    active: &BTreeMap<u32, String>,
    held: &BTreeSet<u32>,
) -> bool {
    held.contains(&id) && active.get(&id).is_some_and(|name| name.starts_with(prefix))
}

fn query_program_ids(target_fd: u32, attach_type: u32) -> Result<Vec<u32>, String> {
    let mut ids = vec![0_u32; MAX_QUERY_PROGRAMS];
    let mut attr = BpfProgQueryAttr {
        target_fd,
        attach_type,
        prog_ids: ids.as_mut_ptr() as usize as u64,
        prog_cnt: ids.len() as u32,
        ..BpfProgQueryAttr::default()
    };
    let result = unsafe {
        libc::syscall(
            libc::SYS_bpf,
            BPF_PROG_QUERY,
            &mut attr as *mut BpfProgQueryAttr,
            std::mem::size_of::<BpfProgQueryAttr>(),
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let count = usize::try_from(attr.prog_cnt)
        .unwrap_or(MAX_QUERY_PROGRAMS)
        .min(MAX_QUERY_PROGRAMS);
    ids.truncate(count);
    Ok(ids)
}

fn tc_filter_program_ids(
    interface: &str,
    direction: &str,
    expected_name: &str,
) -> Result<Vec<u32>, String> {
    let program = if Path::new("/system/bin/tc").is_file() {
        "/system/bin/tc"
    } else {
        "tc"
    };
    let mut command = Command::new(program);
    command.args(["filter", "show", "dev", interface, direction]);
    let output = run_bounded_command(command, Duration::from_secs(2), MAX_TC_OUTPUT_BYTES)?;
    if output.timed_out || output.truncated || !output.status.is_some_and(|status| status.success())
    {
        return Err("tc-query-failed".to_string());
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "tc-output-invalid".to_string())?;
    Ok(parse_tc_program_ids(&text, expected_name))
}

fn parse_tc_program_ids(text: &str, expected_name: &str) -> Vec<u32> {
    text.lines()
        .filter(|line| line.contains(expected_name))
        .flat_map(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            fields
                .windows(2)
                .filter_map(|pair| {
                    (pair[0] == "id")
                        .then(|| pair[1].parse::<u32>().ok())
                        .flatten()
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{managed_program_matches, parse_fdinfo_program_ids, parse_tc_program_ids};
    use std::collections::{BTreeMap, BTreeSet};

    #[test]
    fn fdinfo_parser_collects_program_and_link_program_ids() {
        let ids = parse_fdinfo_program_ids("pos:\t0\nprog_id:\t42\nlink_id:\t9\nprog_id:\t77\n");
        assert_eq!(ids, BTreeSet::from([42, 77]));
    }

    #[test]
    fn tc_parser_requires_the_expected_program_name() {
        let text = "filter bpf name sb_share_in direct-action id 42 tag abc\n\
                    filter bpf name internet_egress direct-action id 84 tag def\n";
        assert_eq!(parse_tc_program_ids(text, "sb_share_in"), vec![42]);
        assert!(parse_tc_program_ids(text, "sb_share_out").is_empty());
    }

    #[test]
    fn attachment_match_binds_name_id_and_current_core_fd() {
        let active = BTreeMap::from([
            (42, "sb_ebpf_conn4".to_string()),
            (77, "sb_share_in".to_string()),
        ]);
        let held = BTreeSet::from([42]);
        assert!(managed_program_matches(42, "sb_ebpf_", &active, &held));
        assert!(!managed_program_matches(77, "sb_share_", &active, &held));
    }
}
