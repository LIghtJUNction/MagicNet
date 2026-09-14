#!/usr/bin/env python3
"""Benchmark MagicNet inside an Android AVD through adb.

The script intentionally uses KernelSU's bundled BusyBox on the device so the
measurement traverses the Android network stack and MagicNet's transparent TUN.
It does not use host networking for acceptance results.
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


def q(value: str) -> str:
    return shlex.quote(value)


def now_ms_expr(bb: str) -> str:
    return f"{bb} date +%s%3N"


def fetch_probe(bb: str, url: str, timeout_s: int) -> dict[str, Any]:
    command = (
        "set +e; "
        f"start=$({now_ms_expr(bb)}); "
        f"{bb} timeout {timeout_s} {bb} wget -q -T {timeout_s} -O /dev/null {q(url)}; "
        "rc=$?; "
        f"end=$({now_ms_expr(bb)}); "
        "elapsed=$((end-start)); "
        "printf '%s|%s\\n' \"$rc\" \"$elapsed\"; exit 0"
    )
    cp = adb_shell(command, timeout=timeout_s + 15)
    line = cp.stdout.strip().splitlines()[-1] if cp.stdout.strip() else "255|0"
    try:
        rc_s, elapsed_s = line.split("|", 1)
        rc = int(rc_s)
        elapsed_ms = max(0, int(elapsed_s))
    except (ValueError, IndexError):
        rc, elapsed_ms = 255, 0
    return {"ok": rc == 0, "rc": rc, "elapsed_ms": elapsed_ms, "output": cp.stdout[-600:]}


def speed_probe(bb: str, name: str, url: str, bytes_target: int, timeout_s: int) -> dict[str, Any]:
    # Stop after bytes_target even when the source object is larger. Pipeline
    # status follows head, intentionally treating wget's SIGPIPE as expected.
    inner = f"{bb} wget -q -T {timeout_s} -O - {q(url)} | {bb} head -c {bytes_target} > /dev/null"
    command = (
        "set +e; "
        f"start=$({now_ms_expr(bb)}); "
        f"{bb} timeout {timeout_s} sh -c {q(inner)}; rc=$?; "
        f"end=$({now_ms_expr(bb)}); elapsed=$((end-start)); "
        "printf '%s|%s\\n' \"$rc\" \"$elapsed\"; exit 0"
    )
    cp = adb_shell(command, timeout=timeout_s + 15)
    line = cp.stdout.strip().splitlines()[-1] if cp.stdout.strip() else "255|0"
    try:
        rc_s, elapsed_s = line.split("|", 1)
        rc = int(rc_s)
        elapsed_ms = max(0, int(elapsed_s))
    except (ValueError, IndexError):
        rc, elapsed_ms = 255, 0
    mbps = None
    if rc == 0 and elapsed_ms > 0:
        mbps = round((bytes_target * 8.0) / (elapsed_ms / 1000.0) / 1_000_000.0, 3)
    return {
        "name": name,
        "url": url,
        "ok": rc == 0,
        "rc": rc,
        "elapsed_ms": elapsed_ms,
        "bytes": bytes_target,
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--targets", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--strict-external", action="store_true")
    parser.add_argument("--speed", action="store_true")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    if args.rounds < 1 or args.rounds > 10:
        parser.error("--rounds must be 1..10")

    args.output.mkdir(parents=True, exist_ok=True)
    bb = "/data/adb/ksu/bin/busybox"
    if adb_shell(f"test -x {bb}").returncode != 0:
        print("KernelSU BusyBox is missing", file=sys.stderr)
        return 2

    targets = parse_targets(args.targets)
    before = collect_processes(bb)
    records: list[dict[str, Any]] = []

    for target in targets:
        for round_no in range(1, args.rounds + 1):
            probe = fetch_probe(bb, target["url"], args.timeout)
            record = {**target, "round": round_no, **probe}
            records.append(record)
            print(
                f"[{target['category']}] {target['id']} round={round_no} "
                f"ok={probe['ok']} elapsed_ms={probe['elapsed_ms']}"
            )
            time.sleep(0.15)

    speed_records: list[dict[str, Any]] = []
    if args.speed:
        speed_records.append(
            speed_probe(
                bb,
                "global-cloudflare-8MiB",
                "https://speed.cloudflare.com/__down?bytes=8388608",
                8 * 1024 * 1024,
                45,
            )
        )
        speed_records.append(
            speed_probe(
                bb,
                "domestic-tuna-8MiB",
                "https://mirrors.tuna.tsinghua.edu.cn/iina/IINA.v1.4.4.dmg",
                8 * 1024 * 1024,
                45,
            )
        )

    after = collect_processes(bb)

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
    domestic_any = any(r["successes"] > 0 for r in domestic)
    global_any = any(r["successes"] > 0 for r in globalish)
    total_success = sum(r["successes"] for r in per_target)
    total_rounds = sum(r["rounds"] for r in per_target)
    success_ratio = total_success / total_rounds if total_rounds else 0.0

    summary = {
        "rounds": args.rounds,
        "strict_external": args.strict_external,
        "target_count": len(targets),
        "probe_count": total_rounds,
        "success_count": total_success,
        "success_ratio": round(success_ratio, 4),
        "domestic_any": domestic_any,
        "global_any": global_any,
        "sing_box_rss_kb_before": process_rss_kb(before, "sing-box"),
        "sing_box_rss_kb_after": process_rss_kb(after, "sing-box"),
        "speed": speed_records,
        "targets": per_target,
    }

    (args.output / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "process-before.json").write_text(json.dumps(before, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "process-after.json").write_text(json.dumps(after, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (args.output / "probes.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["id", "category", "url", "expected", "round", "ok", "rc", "elapsed_ms"],
        )
        writer.writeheader()
        for record in records:
            writer.writerow({k: record.get(k) for k in writer.fieldnames})

    md = [
        "# Android KernelSU network acceptance",
        "",
        f"- Targets: **{len(targets)}**; probes: **{total_rounds}**; successful: **{total_success}** ({success_ratio:.1%})",
        f"- Domestic reachability: **{'PASS' if domestic_any else 'FAIL'}**",
        f"- Global/proxied reachability: **{'PASS' if global_any else 'FAIL'}**",
        f"- sing-box RSS: **{summary['sing_box_rss_kb_before']} KiB → {summary['sing_box_rss_kb_after']} KiB**",
        "",
        "| Target | Class | Success | Median latency |",
        "|---|---:|---:|---:|",
    ]
    for row in per_target:
        latency = f"{row['median_latency_ms']} ms" if row["median_latency_ms"] is not None else "-"
        md.append(f"| {row['id']} | {row['category']} | {row['successes']}/{row['rounds']} | {latency} |")
    if speed_records:
        md += ["", "## Throughput", "", "| Probe | Result | Throughput |", "|---|---:|---:|"]
        for row in speed_records:
            rate = f"{row['mbps']} Mbps" if row["mbps"] is not None else "-"
            md.append(f"| {row['name']} | {'PASS' if row['ok'] else 'FAIL'} | {rate} |")
    md += [
        "",
        "> These are anonymous public endpoint tests. They do not log into third-party apps or send account credentials through free proxy nodes.",
        "",
    ]
    (args.output / "summary.md").write_text("\n".join(md), encoding="utf-8")

    # Public endpoints and free nodes fluctuate. Individual misses are observations,
    # but losing an entire routing side means the acceptance environment is unusable.
    if not domestic_any or not global_any:
        return 3
    if args.strict_external and success_ratio < 0.80:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
