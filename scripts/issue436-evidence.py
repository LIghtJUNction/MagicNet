#!/usr/bin/env python3
"""Read one fixed Actions artifact and rerun its unchanged, pinned full gate."""
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

OUT = Path("evidence")
OUT.mkdir(exist_ok=True)
SUMMARY = {"schema": 1, "scope": "original-android-artifact-read-only",
           "gate": {"invoked": False, "exit_code": None},
           "host_scope": "diagnostics-only; no causal inference or acceptance substitution"}
HOST = ("launch", "exit", "before-stop", "stop-request", "cleanup")
LIMITS = {"simulation.json": 1048576, "route-recovery.json": 1048576}
LIMITS.update({f"emulator-host-{name}.json": 32768 for name in HOST})


def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixed(key, pattern):
    value = os.environ.get(key, "")
    require(re.fullmatch(pattern, value) is not None, "invalid_fixed_" + key.lower())
    return value


def unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "duplicate_json_key")
        value[key] = item
    return value


def number(value):
    result = float(value)
    require(math.isfinite(result), "nonfinite_json_number")
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique, parse_float=number, parse_constant=number)


def project(value, spec):
    if isinstance(spec, dict):
        return {key: project(value[key], item) for key, item in spec.items() if key in value} if isinstance(value, dict) else None
    if isinstance(spec, list):
        return [project(item, spec[0]) for item in value[:16]] if isinstance(value, list) else None
    if value is None or type(value) in (bool, int):
        return value
    if type(value) is float:
        return value if math.isfinite(value) else None
    return value if isinstance(value, str) and len(value) <= 256 else None


def fields(names):
    return {name: None for name in names.split()}


def curl(path, output, limit):
    # Default curl behavior drops Authorization across host redirects.
    # Never add --location-trusted, verbose output, or a signed download URL.
    result = subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location",
         "--proto", "=https", "--proto-redir", "=https", "--max-time", "90",
         "--max-filesize", str(limit), "-H", "Accept: application/vnd.github+json",
         "-H", "X-GitHub-Api-Version: 2022-11-28",
         "-H", "Authorization: Bearer " + os.environ["GITHUB_TOKEN"],
         "https://api.github.com/" + path, "--output", str(output)],
        capture_output=True, timeout=100)
    require(result.returncode == 0, "github_download_failed")
    require(output.stat().st_size <= limit, "download_exceeds_budget")


def api(path, directory):
    target = directory / "api.json"
    curl(path, target, 1048576)
    return decode(target.read_bytes())


def originals(archive):
    selected = {}
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        require(len(entries) <= 512, "too_many_zip_members")
        for info in entries:
            name = info.filename
            parts = name.rstrip("/").split("/")
            require(not PurePosixPath(name).is_absolute() and "\\" not in name
                    and "\0" not in name and all(part not in ("", ".", "..") for part in parts),
                    "unsafe_zip_member_name")
            basename = parts[-1]
            if basename not in LIMITS:
                continue
            require(basename not in selected, "duplicate_whitelisted_zip_member")
            require(not info.is_dir() and not (info.flag_bits & 1)
                    and stat.S_IFMT(info.external_attr >> 16) in (0, stat.S_IFREG),
                    "invalid_whitelisted_zip_member")
            limit = LIMITS[basename]
            require(0 < info.file_size <= limit, "zip_member_exceeds_budget")
            with bundle.open(info) as stream:
                data = stream.read(limit + 1)
            require(len(data) == info.file_size and len(data) <= limit, "zip_member_size_mismatch")
            selected[basename] = data
    return selected


STATE = fields("status warning recovery_status recovery_limit recovery_attempts consecutive_failures checked_at last_recovery_at next_check_at retry_in_seconds")
APP = fields("complete ok uid accepted transport reason elapsed_ms receiver_bound receiver_closed request_attempted")
OWNER = fields("phone_id sub_id user_data_enabled data_enabled data_state") | {
    "connections": [fields("state transport net_id interface")]}
NETWORK = fields("net_id type") | {"interfaces": [None], "details": [None]}
PROCESS = fields("status pid start_ticks state ppid cpu_ticks threads rss_pages")
STAMP = fields("monotonic_ns unix_ns")
MEMORY_EVENTS = fields("low high max oom oom_kill oom_group_kill")
MEMORY = fields("status identity_sha256") | {"values": {
    "memory.events": MEMORY_EVENTS, "memory.events.local": MEMORY_EVENTS,
    "memory.current": None, "memory.peak": None, "memory.max": None}}
HOST_SPEC = fields("schema scope launch_status launch argv_sha256 emulator_pid returncode exit_code signal observer_lost budget_seconds status refusal") | {
    "started": STAMP, "captured": STAMP, "finished": STAMP, "observed": STAMP, "requested": STAMP,
    "emulator": PROCESS, "observer": PROCESS, "cgroup": MEMORY,
    "exit": fields("status returncode exit_code signal observed_monotonic_ns"),
    "adb": fields("status device_count target_state"),
    "kernel_oom": fields("scope read_status oom_line_count") | {
        "matching_pid_events": [fields("pid kind kernel_seconds")]}}



def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True,
                      allow_nan=False, separators=(",", ":")).encode()


def row_summary(value):
    if not isinstance(value, list):
        return {"availability": "missing_or_invalid"}
    result = {"row_count": len(value)}
    if len(value) <= 1024 and all(isinstance(row, str) and len(row) <= 2048 for row in value):
        result.update(availability="observed", sorted_rows_sha256=digest(canonical(sorted(value))))
    else:
        result["availability"] = "invalid"
    return result


def snapshot_summary(value):
    if not isinstance(value, dict):
        return {"availability": "missing_or_invalid"}
    result = project(value, fields("core_pid core_start_ticks tun_name tun_ifindex"))
    result.update(rules=row_summary(value.get("rules")), fib=row_summary(value.get("fib")))
    netd = value.get("netd")
    if not isinstance(netd, dict):
        result["netd"] = {"availability": "missing_or_invalid"}
        return result
    networks = netd.get("networks")
    owned = [item for item in networks if isinstance(item, dict)
             and isinstance(item.get("interfaces"), list) and "eth0" in item["interfaces"]] if isinstance(networks, list) else []
    result["netd"] = project(netd, fields("eth0_ifindex")) | {
        "total_network_count": len(networks) if isinstance(networks, list) else None,
        "eth0_network_count": len(owned) if isinstance(networks, list) else None,
        "eth0_networks": project(owned, [NETWORK]) if isinstance(networks, list) else None,
        "eth0_networks_truncated": len(owned) > 16 if isinstance(networks, list) else None,
        "eth0_fib": row_summary(netd.get("eth0_fib"))}
    return result


def describe_reports(data):
    for name in HOST:
        filename = f"emulator-host-{name}.json"
        if filename not in data:
            SUMMARY.setdefault("host", {})[name] = {"availability": "missing"}
            continue
        try:
            value = decode(data[filename])
            record = {"availability": "parsed", "observation": project(value, HOST_SPEC)}
        except (ValueError, RuntimeError, TypeError, RecursionError):
            record = {"availability": "invalid_json"}
        SUMMARY.setdefault("host", {})[name] = record
    report = decode(data["simulation.json"])
    require(isinstance(report, dict), "simulation_not_object")
    provenance = report.get("provenance", {})
    provenance = provenance if isinstance(provenance, dict) else {}
    cases = report.get("cases", [])
    cases = cases if isinstance(cases, list) else []
    SUMMARY["simulation"] = project(report, fields("schema status scope"))
    SUMMARY["simulation"]["cases"] = [project(case, fields("name status seconds")) for case in cases[:16]]
    SUMMARY["simulation"]["case_record_count"] = len(cases)
    SUMMARY["simulation"]["case_counts"] = {
        status: sum(isinstance(case, dict) and case.get("status") == status for case in cases)
        for status in ("passed", "failed", "not_run")}
    for result, case in zip(SUMMARY["simulation"]["cases"], cases):
        if isinstance(case, dict) and "reason" in case and isinstance(result, dict):
            reason = str(case["reason"])
            result["reason_sha256"] = digest(reason.encode())
            result["reason"] = reason if re.fullmatch(r"[a-z][a-z0-9_]{0,95}", reason) or reason == "Android boot deadline exceeded" else "unclassified"
    SUMMARY["provenance"] = project(provenance, fields("schema scope source_sha production_zip_sha256 fixture_zip_sha256"))
    reboots = provenance.get("reboot_checks", [])
    reboots = reboots if isinstance(reboots, list) else []
    SUMMARY["reboots"] = {"record_count": len(reboots),
        "passed_count": sum(isinstance(item, dict) and item.get("status") == "passed" for item in reboots),
        "new_boot_observed_count": sum(isinstance(item, dict) and item.get("new_boot_observed") is True for item in reboots),
        "observations": [project(item, fields("status command_exit_code command_result new_boot_observed root_verified selinux_enforcing kernelsu_reactivation")) for item in reboots[:16]]}
    route = provenance.get("route_recovery")
    standalone = None
    comparison = {"embedded_present": isinstance(route, dict),
                  "standalone_present": "route-recovery.json" in data, "equal": None,
                  "method": "sorted-key canonical JSON preserving scalar types"}
    if comparison["standalone_present"]:
        try:
            standalone = decode(data["route-recovery.json"])
            comparison["standalone_parsed"] = isinstance(standalone, dict)
        except (ValueError, RuntimeError, TypeError, RecursionError):
            comparison["standalone_parsed"] = False
    if isinstance(route, dict) and isinstance(standalone, dict):
        comparison.update(equal=canonical(route) == canonical(standalone),
                          embedded_canonical_sha256=digest(canonical(route)),
                          standalone_canonical_sha256=digest(canonical(standalone)))
    SUMMARY["route_equivalence"] = comparison
    SUMMARY["route_location"] = "simulation.provenance.route_recovery"
    if not isinstance(route, dict) and isinstance(standalone, dict):
        route = standalone
        SUMMARY["route_location"] = "standalone-route-recovery.json; not substituted into full report"
    if not isinstance(route, dict):
        SUMMARY["route"] = {"availability": "missing"}
        return
    SUMMARY["route"] = project(route, fields("schema status scope reason app_uid positive reject positive_after restored") | {
        "network_fixture": fields("scope qemu abi control_transport_verified wifi_initial_enabled wifi_disabled prepared wifi_final_enabled restored"),
        "rpdb_loss": fields("status reason recovery_entry recovery_tick_count removed_rule_count ready_after_fault ready_after_recovery core_identity_unchanged tun_unchanged fib_unchanged unowned_rules_unchanged") | {
            "baseline_app": APP, "fault_app": APP, "recovered_app": APP,
            "recovery_before": STATE, "recovery_after": STATE},
        "uplink_reconnect": fields("status reason stage interface default_interfaces restore_method down_observed up_observed down_flags up_flags control_transport_verified control_channel_survived restore_guard_finished recovery_tick_count ready_after_recovery app_after_recovery") | {
            "cellular_lifecycle": {"acknowledged": None, **{
                name: {"owner": OWNER, "networks": [NETWORK], **({"flags": None} if name == "down" else {})}
                for name in ("before", "down", "after")}},
            "default_interfaces": [None],
            "last_observation": fields("ready selected_default") | {
                "routes": [None], "state": STATE, "tcp": {"called": None, "result": APP}},
            "recovery_after": STATE}})
    loss = route.get("rpdb_loss")
    if isinstance(loss, dict):
        for stage in ("before", "fault", "after"):
            SUMMARY["route"]["rpdb_loss"][stage] = snapshot_summary(loss.get(stage))


def verify(directory):
    repo = fixed("TARGET_REPOSITORY", r"LIghtJUNction/(MagicNet|magicnet-android)")
    require(repo == os.environ["GITHUB_REPOSITORY"], "artifact_must_be_in_workflow_repository")
    run_id = int(fixed("TARGET_RUN_ID", r"[1-9][0-9]{0,19}"))
    artifact_id = int(fixed("TARGET_ARTIFACT_ID", r"[1-9][0-9]{0,19}"))
    size = int(fixed("EXPECTED_ARTIFACT_SIZE", r"[1-9][0-9]{0,8}"))
    require(size <= 33554432, "archive_exceeds_budget")
    expected_digest = fixed("EXPECTED_ARTIFACT_SHA256", r"[0-9a-f]{64}")
    head = fixed("EXPECTED_RUN_HEAD_SHA", r"[0-9a-f]{40}")
    source = fixed("VALIDATOR_SOURCE_SHA", r"[0-9a-f]{40}")
    tree = fixed("VALIDATOR_TREE_SHA", r"[0-9a-f]{40}")
    report_sha = fixed("EXPECTED_REPORT_SOURCE_SHA", r"[0-9a-f]{40}")
    gate_digest = fixed("EXPECTED_GATE_SHA256", r"[0-9a-f]{64}")
    name = fixed("EXPECTED_ARTIFACT_NAME", r"android-kernelsu-acceptance-[0-9]+-[0-9]+")
    run = api(f"repos/{repo}/actions/runs/{run_id}", directory)
    require(run.get("id") == run_id and run.get("status") == "completed"
            and run.get("head_sha") == head and run.get("repository", {}).get("full_name") == repo,
            "run_identity_or_completion_mismatch")
    artifact = api(f"repos/{repo}/actions/artifacts/{artifact_id}", directory)
    require(artifact.get("id") == artifact_id and artifact.get("name") == name
            and artifact.get("expired") is False and artifact.get("size_in_bytes") == size
            and artifact.get("digest") == "sha256:" + expected_digest
            and artifact.get("workflow_run", {}).get("id") == run_id
            and artifact["workflow_run"].get("head_sha") == head, "artifact_metadata_mismatch")
    SUMMARY["run"] = project(run, fields("id run_attempt status conclusion head_sha event"))
    SUMMARY["repository"] = repo
    SUMMARY["artifact"] = {"id": artifact_id, "name": name, "bytes": size, "sha256": expected_digest}
    archive = directory / "original.zip"
    curl(f"repos/{repo}/actions/artifacts/{artifact_id}/zip", archive, 33554432)
    require(archive.stat().st_size == size and digest(archive.read_bytes()) == expected_digest,
            "original_archive_digest_or_size_mismatch")
    SUMMARY["artifact"]["download_verified"] = True
    gate = Path("validator/scripts/require-android-acceptance.py")
    actual_source = subprocess.check_output(["git", "-C", "validator", "rev-parse", "HEAD"], timeout=15).decode().strip()
    actual_tree = subprocess.check_output(["git", "-C", "validator", "rev-parse", "HEAD^{tree}"], timeout=15).decode().strip()
    require((actual_source, actual_tree) == (source, tree) and digest(gate.read_bytes()) == gate_digest,
            "validator_identity_mismatch")
    tested_commit = api(f"repos/LIghtJUNction/magicnet-android/git/commits/{report_sha}", directory)
    require(tested_commit.get("sha") == report_sha and tested_commit.get("tree", {}).get("sha") == tree,
            "report_source_tree_mismatch")
    SUMMARY["validator"] = {"source_sha": source, "tree_sha": tree, "gate_sha256": gate_digest,
                            "expected_report_source_sha": report_sha, "report_source_tree_verified": True}
    data = originals(archive)
    SUMMARY["files"] = {name: {"bytes": len(value), "sha256": digest(value)} for name, value in sorted(data.items())}
    require("simulation.json" in data, "simulation_missing")
    original = directory / "simulation.json"
    original.write_bytes(data["simulation.json"])
    SUMMARY["gate"] = {"invoked": True, "exit_code": None}
    completed = subprocess.run([sys.executable, str(gate), "--report", str(original),
                                "--source-sha", report_sha], capture_output=True, timeout=60)
    unchanged = original.read_bytes() == data["simulation.json"]
    SUMMARY["gate"] = {"invoked": True, "exit_code": completed.returncode, "original_report_unchanged": unchanged}
    require(unchanged, "original_report_changed")
    output = (completed.stdout + completed.stderr)[:8192]
    SUMMARY["gate"]["output"] = output.decode("utf-8", errors="replace")
    SUMMARY["gate"]["output_truncated"] = len(completed.stdout) + len(completed.stderr) > 8192
    describe_reports(data)
    return 0 if completed.returncode == 0 else 1


def main():
    result = 1
    try:
        with tempfile.TemporaryDirectory(prefix="issue436-evidence-") as directory:
            result = verify(Path(directory))
    except RuntimeError as error:
        SUMMARY["verification_error"] = str(error)
    except (OSError, ValueError, TypeError, KeyError, RecursionError, zipfile.BadZipFile,
            subprocess.SubprocessError) as error:
        SUMMARY["verification_error"] = type(error).__name__
    SUMMARY["job_exit_code"] = result
    payload = json.dumps(SUMMARY, ensure_ascii=True, allow_nan=False, indent=2) + "\n"
    require(len(payload.encode()) <= 65536, "normalized_summary_exceeds_budget")
    (OUT / "summary.json").write_text(payload, encoding="utf-8")
    print("ISSUE436_EVIDENCE_BEGIN")
    print(payload, end="")
    print("ISSUE436_EVIDENCE_END")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
