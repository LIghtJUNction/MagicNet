#!/usr/bin/env python3
"""Normalize sing-box routing rules without changing selector ownership.

The packaged template intentionally contains readable, policy-oriented rules.
This pass makes the hot path cheaper by prioritizing exact high-frequency
matches, protecting narrow WeChat route/DNS classifiers from broad ad lists,
prioritizing known foreign domains over country-IP fallbacks, and coalescing
stateless rule-set dispatches. DNS response evaluation and route metadata
mutations are ordering barriers, not redundant rules.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import stat
from pathlib import Path
from typing import Any, Callable

MATCH_LIST_FIELDS = {
    "inbound",
    "network",
    "domain",
    "domain_suffix",
    "domain_keyword",
    "domain_regex",
    "ip_cidr",
    "source_ip_cidr",
    "package_name",
    "rule_set",
    "port",
    "source_port",
}


def _stable_marker(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _stable_unique(values: list[Any]) -> list[Any]:
    seen: set[str] = set()
    result: list[Any] = []
    for value in values:
        marker = _stable_marker(value)
        if marker in seen:
            continue
        seen.add(marker)
        result.append(value)
    return result


def _normalize_rule(rule: Any) -> Any:
    if not isinstance(rule, dict):
        return rule
    normalized = copy.deepcopy(rule)
    for key in MATCH_LIST_FIELDS:
        value = normalized.get(key)
        if isinstance(value, list):
            normalized[key] = _stable_unique(value)
    return normalized


def _state_barrier(rule: Any) -> bool:
    """Do not move or deduplicate across mutable evaluation state or modes."""
    if not isinstance(rule, dict):
        return True
    if rule.get("action", "route") not in {"route", "reject", "hijack-dns"}:
        return True
    if "match_response" in rule or "clash_mode" in rule:
        return True
    return any(_state_barrier(child) for child in rule.get("rules", []))


def _pure_dispatch(rule: Any, key: str, matcher: str = "rule_set") -> bool:
    """Accept both implicit and explicit route actions, never scoped rules."""
    return (
        isinstance(rule, dict)
        and set(rule) - {"action"} == {matcher, key}
        and rule.get("action", "route") == "route"
    )


def _dedupe_rules(rules: list[Any]) -> list[Any]:
    seen: set[str] = set()
    result: list[Any] = []
    for rule in rules:
        # evaluate/resolve/sniff/route-options can change subsequent matches.
        # Repeated actions, and the same terminal rule on either side, matter.
        if _state_barrier(rule):
            seen.clear()
            result.append(rule)
            continue
        marker = _stable_marker(rule)
        if marker in seen:
            continue
        seen.add(marker)
        result.append(rule)
    return result


def _contains(rule: dict[str, Any], key: str, expected: Any) -> bool:
    value = rule.get(key)
    if isinstance(value, list):
        return expected in value
    return value == expected


def _only_rule_sets(rule: dict[str, Any], allowed: set[str]) -> bool:
    value = rule.get("rule_set", [])
    tags = value if isinstance(value, list) else [value]
    return bool(tags) and all(tag in allowed for tag in tags)


def _move_before(
    rules: list[Any],
    moving: Callable[[dict[str, Any]], bool],
    anchor: Callable[[dict[str, Any]], bool],
) -> list[Any]:
    moving_index = next(
        (i for i, rule in enumerate(rules) if isinstance(rule, dict) and moving(rule)),
        None,
    )
    anchor_index = next(
        (i for i, rule in enumerate(rules) if isinstance(rule, dict) and anchor(rule)),
        None,
    )
    if moving_index is None or anchor_index is None or moving_index <= anchor_index:
        return rules

    if any(_state_barrier(rule) for rule in rules[anchor_index:moving_index + 1]):
        return rules

    rule = rules.pop(moving_index)
    anchor_index = next(
        i for i, candidate in enumerate(rules) if isinstance(candidate, dict) and anchor(candidate)
    )
    rules.insert(anchor_index, rule)
    return rules


def _move_rule_set_tag_before(
    rules: list[Any],
    tag: str,
    dispatch_key: str,
    dispatch_value: str,
    anchor: Callable[[dict[str, Any]], bool],
) -> list[Any]:
    """Move one pure rule-set tag without dragging merged sibling tags with it."""

    source_index = next(
        (
            i
            for i, rule in enumerate(rules)
            if _pure_dispatch(rule, dispatch_key)
            and rule.get(dispatch_key) == dispatch_value
            and _contains(rule, "rule_set", tag)
        ),
        None,
    )
    anchor_index = next(
        (i for i, rule in enumerate(rules) if isinstance(rule, dict) and anchor(rule)),
        None,
    )
    if source_index is None or anchor_index is None or source_index <= anchor_index:
        return rules

    if any(_state_barrier(rule) for rule in rules[anchor_index:source_index + 1]):
        return rules

    source = rules[source_index]
    moved = copy.deepcopy(source)
    moved["rule_set"] = [tag]
    # sing-box accepts a single tag as well as a list; never split it into characters.
    value = source["rule_set"]
    tags = value if isinstance(value, list) else [value]
    remainder = [value for value in tags if value != tag]
    if remainder:
        source = copy.deepcopy(source)
        source["rule_set"] = remainder
        rules[source_index] = source
    else:
        rules.pop(source_index)

    anchor_index = next(
        i for i, candidate in enumerate(rules) if isinstance(candidate, dict) and anchor(candidate)
    )
    rules.insert(anchor_index, moved)
    return rules


def _compact_adjacent_rule_sets(rules: list[Any], dispatch_key: str) -> list[Any]:
    """Merge only adjacent `rule_set -> same target` rules.

    Different rule sets in one sing-box default rule have OR semantics. Restricting
    this optimization to adjacent rules with no other match fields makes it
    behavior-preserving while reducing the number of rule objects on the hot path.
    """

    result: list[Any] = []
    for rule in rules:
        if (
            result
            and _pure_dispatch(rule, dispatch_key)
            and _pure_dispatch(result[-1], dispatch_key)
            and rule.get(dispatch_key) == result[-1].get(dispatch_key)
            and isinstance(rule.get("rule_set"), list)
            and isinstance(result[-1].get("rule_set"), list)
        ):
            result[-1]["rule_set"] = _stable_unique(
                result[-1]["rule_set"] + rule["rule_set"]
            )
            continue
        result.append(copy.deepcopy(rule))
    return result


def _dns_fast_path(rules: list[Any]) -> list[Any]:
    """Fast-path port 53 only for the template's scoped sniff -> DNS pair.

    Keep protocol sniffing as a fallback for DNS on non-standard ports. Do not
    invent a DNS policy for custom inbounds or cross earlier policy rules.
    """
    result: list[Any] = []
    for index, rule in enumerate(rules):
        if (
            isinstance(rule, dict)
            and set(rule) == {"inbound", "action"}
            and rule.get("action") == "sniff"
            and index + 1 < len(rules)
            and rules[index + 1] == {"protocol": "dns", "action": "hijack-dns"}
        ):
            inbounds = rule["inbound"]
            tags = inbounds if isinstance(inbounds, list) else [inbounds]
            if tags and all(tag in ("mixed-in", "tun-in") for tag in tags):
                fast = {"inbound": copy.deepcopy(inbounds), "port": 53, "action": "hijack-dns"}
                if not result or result[-1] != fast:
                    result.append(fast)
        result.append(rule)
    return result


def _optimize_section(section: str, rules: list[Any]) -> list[Any]:
    dispatch_key = "outbound" if section == "route" else "server"
    rules = [_normalize_rule(rule) for rule in rules]
    rules = _dedupe_rules(rules)
    if section == "route":
        rules = _dns_fast_path(rules)
        # A maintained domain classification is more specific than the country
        # of a resolved IP. Preserve domestic/service exceptions above this tail.
        cn_ip_tags = {"lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"}
        rules = _move_rule_set_tag_before(
            rules,
            "metacubex-geosite-geolocation-not-cn",
            "outbound",
            "proxy-rule",
            lambda rule: _pure_dispatch(rule, "outbound")
            and rule.get("outbound") == "cn-direct"
            and _only_rule_sets(rule, cn_ip_tags),
        )

    google_target = "google-proxy" if section == "route" else "doh-google"
    wechat_target = "cn-direct" if section == "route" else "bootstrap-local-dns"

    # Exact Google authentication / Android service names are hit frequently.
    # Evaluate the cheap exact-domain rule before binary service rule sets.
    rules = _move_before(
        rules,
        lambda rule: _pure_dispatch(rule, dispatch_key, "domain")
        and rule.get(dispatch_key) == google_target
        and _contains(rule, "domain", "android.clients.google.com"),
        lambda rule: _contains(rule, "rule_set", "meta-google-gemini"),
    )

    # WeChat is latency-sensitive and its dedicated classifier is narrower than
    # either the generic Tencent set or the broad advertising lists. The pinned
    # DNS template uses explicit domain suffixes; also accept the domain-only
    # service-wechat-dns SRS and legacy mixed Karing tag for compatibility.
    if section == "dns":
        rules = _move_before(
            rules,
            lambda rule: _pure_dispatch(rule, dispatch_key, "domain_suffix")
            and rule.get(dispatch_key) == wechat_target
            and _contains(rule, "domain_suffix", "wechat.com")
            and _contains(rule, "domain_suffix", "weixin.com"),
            lambda rule: _contains(rule, "rule_set", "lyc-geosite-ads"),
        )
        rules = _move_rule_set_tag_before(
            rules,
            "service-wechat-dns",
            dispatch_key,
            wechat_target,
            lambda rule: _contains(rule, "rule_set", "lyc-geosite-ads"),
        )

    rules = _move_rule_set_tag_before(
        rules,
        "karing-acl4ssr-wechat",
        dispatch_key,
        wechat_target,
        lambda rule: _contains(rule, "rule_set", "lyc-geosite-ads"),
    )

    # Removing a duplicate created by compaction can expose another adjacent
    # pair. Repeat until stable; every changing pass removes at least one rule.
    while True:
        compacted = _dedupe_rules(_compact_adjacent_rule_sets(rules, dispatch_key))
        if compacted == rules:
            return compacted
        rules = compacted


def optimize_config(config: dict[str, Any]) -> dict[str, Any]:
    optimized = copy.deepcopy(config)
    for section in ("route", "dns"):
        section_config = optimized.get(section)
        if not isinstance(section_config, dict):
            raise ValueError(f"{section} must be an object")
        rules = section_config.get("rules")
        if not isinstance(rules, list):
            raise ValueError(f"{section}.rules must be a list")
        section_config["rules"] = _optimize_section(section, rules)
    return optimized


def optimize_file(path: Path, check: bool = False) -> bool:
    original_text = path.read_text(encoding="utf-8")
    original = json.loads(original_text)
    if not isinstance(original, dict):
        raise ValueError("config root must be an object")

    optimized = optimize_config(original)
    changed = optimized != original
    before_route = len(original["route"]["rules"])
    after_route = len(optimized["route"]["rules"])
    before_dns = len(original["dns"]["rules"])
    after_dns = len(optimized["dns"]["rules"])

    if check:
        if changed:
            raise SystemExit(
                f"routing config needs normalization: route {before_route}->{after_route}, "
                f"dns {before_dns}->{after_dns}"
            )
        print(f"routing config already normalized: route={after_route} dns={after_dns}")
        return False

    if not changed:
        print(f"routing config unchanged: route={after_route} dns={after_dns}")
        return False

    rendered = json.dumps(optimized, ensure_ascii=False, indent=2) + "\n"
    mode = stat.S_IMODE(path.stat().st_mode)
    temporary = path.with_name(f".{path.name}.routing.{os.getpid()}.tmp")
    try:
        temporary.write_text(rendered, encoding="utf-8")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

    print(
        f"optimized routing config: route {before_route}->{after_route}, "
        f"dns {before_dns}->{after_dns}"
    )
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        optimize_file(args.config, check=args.check)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.exit(1, f"routing optimization failed: {error}\n")


if __name__ == "__main__":
    main()
