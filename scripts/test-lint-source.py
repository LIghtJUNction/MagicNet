#!/usr/bin/env python3
"""Regression tests for the dependency-free source sanity checker."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

MODULE_PATH = Path(__file__).with_name("lint-source.py")
SPEC = importlib.util.spec_from_file_location("magicnet_lint_source", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class SourceSanityTests(unittest.TestCase):
    def check(self, name: str, content: bytes) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / name
            path.write_bytes(content)
            return LINT.check_file(path, root)

    def test_accepts_valid_python_and_json(self) -> None:
        self.assertEqual(self.check("valid.py", b"value = {'one': 1}\n"), [])
        self.assertEqual(self.check("valid.json", b'{"one": 1, "two": 2}\n'), [])

    def test_rejects_python_syntax_errors(self) -> None:
        errors = self.check("broken.py", b"def broken(:\n    pass\n")
        self.assertTrue(any("Python syntax error" in error for error in errors), errors)

    def test_rejects_duplicate_literal_python_dict_keys(self) -> None:
        errors = self.check("duplicate.py", b"value = {'same': 1, 'same': 2}\n")
        self.assertTrue(any("duplicate literal dict key" in error for error in errors), errors)

    def test_rejects_invalid_and_duplicate_json(self) -> None:
        invalid = self.check("broken.json", b'{"value": }\n')
        duplicate = self.check("duplicate.json", b'{"same": 1, "same": 2}\n')
        self.assertTrue(any("invalid JSON" in error for error in invalid), invalid)
        self.assertTrue(any("duplicate JSON key" in error for error in duplicate), duplicate)

    def test_rejects_unresolved_conflict_markers(self) -> None:
        left = "<" * 7
        right = ">" * 7
        errors = self.check("conflict.ts", f"{left} HEAD\nvalue\n{right} branch\n".encode())
        self.assertEqual(sum("merge-conflict marker" in error for error in errors), 2)

    def test_rejects_non_utf8_source_text(self) -> None:
        errors = self.check("broken.py", b"\xff\xfe")
        self.assertTrue(any("expected UTF-8" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
