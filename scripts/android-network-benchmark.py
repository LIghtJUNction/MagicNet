#!/usr/bin/env python3
"""Benchmark MagicNet inside an Android AVD through adb.

Network probes deliberately run as Android's non-root shell UID. MagicNet's TUN
excludes UID 0, so running wget from a root adbd would bypass the dataplane and
produce a false-positive acceptance result. Root is used only for installation
and process accounting; probe traffic itself must traverse MagicNet.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import shlex
import statistics
import subprocess
import sys
import time
from typing import Any


def adb_shell(command: str, timeout: int = 60, check: bool = False) -> subprocess.CompletedProcess[str]:
    cp = subprocess.run(
        ["adb", "shell", command],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if check and cp.returncode != 0:
        raise RuntimeError(f"adb shell failed ({cp.returncode}): {command}\n{cp.stdout}")
    return cp


def adb_mode(root: bool) -> None:
    action = "root" if root else "unroot"
    cp = subprocess.run(
        ["adb", action],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    # `adb root`/`unroot` may report that adbd already has the requested mode.
    if cp.returncode != 0:
        raise RuntimeError(f"adb {action} failed: {cp.stdout}")
    subprocess.run(["adb", "wait-for-device"], check=True, timeout=60)
    time.sleep(1)
    uid = adb_shell("id -u", check=True).stdout.strip()
    if root and uid != "0":
        raise RuntimeError(f"adb root did not produce uid 0 (got {uid!r})")
    if not root and uid == "0":
        raise RuntimeError("network acceptance would run as excluded uid 0")


def q(value: str) -> str:
    return shlex.quote(value)


def elapsed_ms(start: str, end: str) -> int:
    try:
        return max(0, round((float(end) - float(start)) * 1000.0))
    except ValueError:
        return 0


def fetch_probe(bb: str, url: str, timeout_s: int) -> dict[str, Any]:
    command = (
        "set +e; "
        f"start=$({bb} cut -d' ' -f1 /proc/uptime); "
        f"{bb} timeout {timeout_s} {bb} wget -q -T {timeout_s} -O /dev/null {q(url)}; "
        "rc=$?; "
        f"end=$({bb} cut -d' ' -f1 /proc/uptime); "
        "printf '%s|%s|%s\\n' \"$rc\" \"$start\" \"$end\"; exit 0"
    )
    cp = adb_shell(command, timeout=timeout_s + 15)
    line = cp.stdout.strip().splitlines()[-1] if cp.stdout.strip() else "255|0|0"
    try:
        rc_s, start_s, end_s = line.split("|", 2)
        rc = int(rc_s)
        duration_ms = elapsed_ms(start_s, end_s)
    except (ValueError, IndexError):
        rc, duration_ms = 255, 0
    return {"ok": rc == 0, "rc": rc, "elapsed_ms": duration_ms, "output": cp.stdout[-600:]}


def speed_probe(bb: str, name: str, url: str, bytes_target: int, timeout_s: int) -> dict[str, Any]:
    block_size = 64 * 1024
    blocks = (bytes_target + block_size - 1) // block_size
    tmp = "/data/local/tmp/magicnet-speed-probe.bin"
    inner = (
        f"{bb} wget -q -T {timeout_s} -O - {q(url)} | "
        f"{bb} dd of={q(tmp)} bs={block_size} count={blocks} 2>/dev/null"
    )
    command = (
        "set +e; "
        f"rm -f {q(tmp)}; "
        f"start=$({bb} cut -d' ' -f1 /proc/uptime); "
        f"{bb} timeout {timeout_s} sh -c {q(inner)}; rc=$?; "
        f"end=$({bb} cut -d' ' -f1 /proc/uptime); "
        f"received=$({bb} wc -c < {q(tmp)} 2>/dev/null || echo 0); "
        f"rm -f {q(tmp)}; "
        "printf '%s|%s|%s|%s\\n' \"$rc\" \"$start\" \"$end\" \"$received\"; exit 0"
    )
    cp = adb_shell(command, timeout=timeout_s + 15)
    line = cp.stdout.strip().splitlines()[-1] if cp.stdout.strip() else "255|0|0|0"
    try:
        rc_s, start_s, end_s, received_s = line.split("|", 3)
        rc = int(rc_s)
        duration_ms = elapsed_ms(start_s, end_s)
        received = max(0, int(received_s.strip()))
    except (ValueError, IndexError):
        rc, duration_ms, received = 255, 0, 0

    ok = received >= bytes_target
    mbps = None
    if ok and duration_ms > 0:
        mbps = round((received * 8.0) / (duration_ms / 1000.0) / 1_000_000.0, 3)
    return {
        "name": name,
        "url": url,
        "ok": ok,
        "rc": rc,
        "elapsed_ms": duration_ms,
        "requested_bytes": bytes_target,
        "received_bytes": received,
        "mbps": mbps,
    }


def parse_targets(path: Path) -> list[dict[str, str]]:
    targets: list[dict[str, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) != 4:
            raise ValueError(f"bad target row: {raw}")
        target_id, category, url, expected = parts
        targets.append({"id": target_id, "category": category, "url": url, "expected": expected})
    return targets


def median(values: list[int]) -> float | None:
    return round(statistics.median(values), 2) if values else None


def collect_processes(bb: str) -> dict[str, Any]:
    names = ["sing-box", "magicnet-cli", "magicnet-mcp-server"]
    result: dict[str, Any] = {}
    for name in names:
        pids_cp = adb_shell(f"{bb} pidof {q(name)} 2>/dev/null || true")
        pids = [p for p in pids_cp.stdout.strip().split() if p.isdigit()]
        entries = []
        for pid in pids:
            status_cp = adb_shell(
                f"cat /proc/{pid}/status 2>/dev/null | "
                "grep -E '^(Name|Pid|VmRSS|VmHWM|VmSize|Threads|voluntary_ctxt_switches|nonvoluntary_ctxt_switches):' || true"
            )
            parsed: dict[str, Any] = {"pid": int(pid)}
            for line in status_cp.stdout.splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                parsed[key] = value.strip()
            fd_cp = adb_shell(f"ls /proc/{pid}/fd 2>/dev/null | {bb} wc -l || true")
            try:
                parsed["fd_count"] = int(fd_cp.stdout.strip())
            except ValueError:
                parsed["fd_count"] = None
            entries.append(parsed)
        result[name] = entries
    meminfo = adb_shell("cat /proc/meminfo | head -n 12").stdout
    top = adb_shell("top -b -n 1 -o PID,CPU%,MEM%,RES,ARGS 2>/dev/null | head -n 30 || true").stdout
    return {"processes": result, "meminfo": meminfo, "top": top}


def process_rss_kb(snapshot: dict[str, Any], name: str) -> int:
    total = 0
    for entry in snapshot.get("processes", {}).get(name, []):
        value = str(entry.get("VmRSS", "0 kB")).split()[0]
        try:
            total += int(value)
        except ValueError:
            pass
    return total


def prepare_probe_busybox(root_bb: str, probe_bb: str) -> None:
    adb_shell(
        f"cp {q(root_bb)} {q(probe_bb)} && chmod 0755 {q(probe_bb)} && "
        f"test -x {q(probe_bb)}",
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--targets", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--strict-external", action="store_true")
    parser.add_argument("--speed", action="store_true")
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument("--max-sing-box-rss-kb", type=int, default=120 * 1024)
    args = parser.parse_args()

    if args.rounds < 1 or args.rounds > 10:
        parser.error("--rounds must be 1..10")
    if args.max_sing_box_rss_kb < 1:
        parser.error("--max-sing-box-rss-kb must be positive")

    args.output.mkdir(parents=True, exist_ok=True)
    root_bb = "/data/adb/ksu/bin/busybox"
    probe_bb = "/data/local/tmp/magicnet-probe-busybox"
    if adb_shell(f"test -x {root_bb}").returncode != 0:
        print("KernelSU BusyBox is missing", file=sys.stderr)
        return 2

    targets = parse_targets(args.targets)
    prepare_probe_busybox(root_bb, probe_bb)
    before = collect_processes(root_bb)
    records: list[dict[str, Any]] = []
    speed_records: list[dict[str, Any]] = []

    # This transition is the key acceptance invariant: UID 0 is excluded from the
    # TUN, so every public-network request below must originate as shell (uid 2000
    # on AOSP) or another non-root uid.
    adb_mode(False)
    probe_uid = adb_shell("id -u", check=True).stdout.strip()
    try:
        for target in targets:
            for round_no in range(1, args.rounds + 1):
                probe = fetch_probe(probe_bb, target["url"], args.timeout)
                record = {**target, "round": round_no, "probe_uid": probe_uid, **probe}
                records.append(record)
                print(
                    f"[{target['category']}] {target['id']} round={round_no} "
                    f"uid={probe_uid} ok={probe['ok']} elapsed_ms={probe['elapsed_ms']}"
                )
                time.sleep(0.15)

        if args.speed:
            speed_records.append(
                speed_probe(
                    probe_bb,
                    "global-cloudflare-8MiB",
                    "https://speed.cloudflare.com/__down?bytes=8388608",
                    8 * 1024 * 1024,
                    45,
                )
            )
            speed_records.append(
                speed_probe(
                    probe_bb,
                    "domestic-tuna-8MiB",
                    "https://mirrors.tuna.tsinghua.edu.cn/iina/IINA.v1.4.4.dmg",
                    8 * 1024 * 1024,
                    45,
                )
            )
    finally:
        adb_mode(True)

    after = collect_processes(root_bb)
    adb_shell(f"rm -f {q(probe_bb)} /data/local/tmp/magicnet-speed-probe.bin || true")

    per_target: list[dict[str, Any]] = []
    for target in targets:
        rows = [r for r in records if r["id"] == target["id"]]
        successes = [r for r in rows if r["ok"]]
        per_target.append(
            {
                "id": target["id"],
                "category": target["category"],
                "url": target["url"],
                "rounds": len(rows),
                "successes": len(successes),
                "success_rate": round(len(successes) / len(rows), 4) if rows else 0.0,
                "median_latency_ms": median([int(r["elapsed_ms"]) for r in successes]),
            }
        )

    domestic = [r for r in per_target if r["category"] == "domestic"]
    globalish = [r for r in per_target if r["category"] != "domestic"]
    google = [r for r in per_target if r["category"] == "google"]
    domestic_any = any(r["successes"] > 0 for r in domestic)
    global_any = any(r["successes"] > 0 for r in globalish)
    google_failures = [r["id"] for r in google if r["successes"] == 0]
    google_all = bool(google) and not google_failures
    total_success = sum(r["successes"] for r in per_target)
    total_rounds = sum(r["rounds"] for r in per_target)
    success_ratio = total_success / total_rounds if total_rounds else 0.0

    sing_before = process_rss_kb(before, "sing-box")
    sing_after = process_rss_kb(after, "sing-box")
    sing_peak_observed = max(sing_before, sing_after)
    memory_ok = 0 < sing_peak_observed <= args.max_sing_box_rss_kb

    summary = {
        "rounds": args.rounds,
        "strict_external": args.strict_external,
        "probe_uid": probe_uid,
        "target_count": len(targets),
        "probe_count": total_rounds,
        "success_count": total_success,
        "success_ratio": round(success_ratio, 4),
        "domestic_any": domestic_any,
        "global_any": global_any,
        "google_all": google_all,
        "google_failures": google_failures,
        "sing_box_rss_kb_before": sing_before,
        "sing_box_rss_kb_after": sing_after,
        "sing_box_rss_kb_observed_max": sing_peak_observed,
        "sing_box_rss_limit_kb": args.max_sing_box_rss_kb,
        "memory_ok": memory_ok,
        "speed": speed_records,
        "targets": per_target,
    }

    (args.output / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "process-before.json").write_text(json.dumps(before, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "process-after.json").write_text(json.dumps(after, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (args.output / "probes.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["id", "category", "url", "expected", "round", "probe_uid", "ok", "rc", "elapsed_ms"],
        )
        writer.writeheader()
        for record in records:
            writer.writerow({k: record.get(k) for k in writer.fieldnames})

    md = [
        "# Android KernelSU network acceptance",
        "",
        f"- Probe UID: **{probe_uid}** (must be non-root; UID 0 is excluded from MagicNet TUN)",
        f"- Targets: **{len(targets)}**; probes: **{total_rounds}**; successful: **{total_success}** ({success_ratio:.1%})",
        f"- Domestic reachability: **{'PASS' if domestic_any else 'FAIL'}**",
        f"- Global/proxied reachability: **{'PASS' if global_any else 'FAIL'}**",
        f"- Required Google matrix: **{'PASS' if google_all else 'FAIL'}**",
        f"- sing-box RSS: **{sing_before} KiB → {sing_after} KiB**, gate **≤ {args.max_sing_box_rss_kb} KiB**: **{'PASS' if memory_ok else 'FAIL'}**",
        "",
        "| Target | Class | Success | Median latency |",
        "|---|---:|---:|---:|",
    ]
    for row in per_target:
        latency = f"{row['median_latency_ms']} ms" if row["median_latency_ms"] is not None else "-"
        md.append(f"| {row['id']} | {row['category']} | {row['successes']}/{row['rounds']} | {latency} |")
    if google_failures:
        md += ["", f"Required Google failures: **{', '.join(google_failures)}**"]
    if speed_records:
        md += ["", "## Throughput", "", "| Probe | Result | Received | Throughput |", "|---|---:|---:|---:|"]
        for row in speed_records:
            rate = f"{row['mbps']} Mbps" if row["mbps"] is not None else "-"
            received_mib = round(row["received_bytes"] / 1024 / 1024, 2)
            md.append(f"| {row['name']} | {'PASS' if row['ok'] else 'FAIL'} | {received_mib} MiB | {rate} |")
    md += [
        "",
        "> These are anonymous public endpoint tests from a non-root Android UID through the transparent dataplane. They do not log into third-party apps or send account credentials through free proxy nodes.",
        "",
    ]
    (args.output / "summary.md").write_text("\n".join(md), encoding="utf-8")

    if not memory_ok:
        return 5
    if not google_all:
        return 6
    if not domestic_any or not global_any:
        return 3
    if args.strict_external and success_ratio < 0.80:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
