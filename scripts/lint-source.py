#!/usr/bin/env python3
"""Catch cheap source/config mistakes before expensive test suites run.

This intentionally uses only the Python standard library. It is a fast safety
net, not a replacement for language-specific linters such as clippy,
shellcheck, vue-tsc, or go vet.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {
    ".conf",
    ".css",
    ".go",
    ".html",
    ".ini",
    ".js",
    ".json",
    ".list",
    ".md",
    ".mjs",
    ".properties",
    ".py",
    ".rs",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".vue",
    ".xml",
    ".yaml",
    ".yml",
}
CONFLICT_PREFIXES = ("<" * 7, ">" * 7)


class DuplicateJsonKey(ValueError):
    pass


def tracked_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [root / Path(item.decode("utf-8")) for item in result.stdout.split(b"\0") if item]


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJsonKey(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def duplicate_python_dict_keys(tree: ast.AST) -> list[tuple[int, object]]:
    duplicates: list[tuple[int, object]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Dict):
            continue
        seen: dict[object, int] = {}
        for key_node in node.keys:
            if not isinstance(key_node, ast.Constant):
                continue
            value = key_node.value
            try:
                hash(value)
            except TypeError:
                continue
            if value in seen:
                duplicates.append((getattr(key_node, "lineno", 0), value))
            else:
                seen[value] = getattr(key_node, "lineno", 0)
    return duplicates


def check_file(path: Path, root: Path) -> list[str]:
    relative = path.relative_to(root)
    if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
        return []

    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        return [f"{relative}: expected UTF-8 text: {exc}"]

    errors: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith(CONFLICT_PREFIXES):
            errors.append(f"{relative}:{line_number}: unresolved merge-conflict marker")

    suffix = path.suffix.lower()
    if suffix == ".py":
        try:
            tree = ast.parse(text, filename=str(relative))
        except SyntaxError as exc:
            line = exc.lineno or 0
            column = exc.offset or 0
            errors.append(f"{relative}:{line}:{column}: Python syntax error: {exc.msg}")
        else:
            for line, key in duplicate_python_dict_keys(tree):
                errors.append(f"{relative}:{line}: duplicate literal dict key {key!r}")
    elif suffix == ".json":
        try:
            json.loads(text, object_pairs_hook=reject_duplicate_json_keys)
        except (json.JSONDecodeError, DuplicateJsonKey) as exc:
            errors.append(f"{relative}: invalid JSON: {exc}")

    return errors


def main() -> int:
    errors: list[str] = []
    checked = 0
    for path in tracked_files(ROOT):
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
            checked += 1
            errors.extend(check_file(path, ROOT))

    if errors:
        print("source sanity checks failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    print(f"source sanity checks passed ({checked} tracked text files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
