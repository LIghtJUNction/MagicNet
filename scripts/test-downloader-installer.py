#!/usr/bin/env python3
"""Verify the final incremental installer, not an intermediate downloader template."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import stat
import struct
import zipfile

MAX_INSTALLER_BYTES = 12 * 1024 * 1024


def verify(archive: Path, *, arch: str = "arm64", core: Path | None = None) -> None:
    raw = archive.read_bytes()
    assert len(raw) <= MAX_INSTALLER_BYTES, "Installer unexpectedly contains large payloads"
    if core is not None:
        assert raw == core.read_bytes(), "Installer must be the exact MagicNet core, not a wrapper"
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None, "ZIP CRC failure"
        names = z.namelist()
        assert len(names) == len(set(names)), "Duplicate ZIP entries"
        for info in z.infolist():
            offset = info.header_offset
            assert raw[offset:offset + 4] == b"PK\x03\x04", "Invalid ZIP local header"
            name_len = struct.unpack_from("<H", raw, offset + 26)[0]
            encoding = "utf-8" if info.flag_bits & 0x800 else "cp437"
            assert raw[offset + 30:offset + 30 + name_len].decode(encoding) == info.filename
        lines = z.read("module.prop").decode().splitlines()
        ids = [line for line in lines if line.startswith("id=")]
        assert ids == ["id=MagicNet"], "Manager would install the wrong module identity"
        prop = dict(line.split("=", 1) for line in lines if "=" in line and not line.startswith("#"))
        manifest = json.loads(z.read("components.json"))
        assert manifest["schema"] == 1 and manifest["module"] == "MagicNet"
        assert manifest["version"] == prop["version"]
        assert manifest["architecture"] == arch
        assert manifest["components"], "Missing runtime components"
        required = {"bin-sing-box", "bin-magicnet-cli", "bin-magicnet-mcp-server"}
        assert required <= {c["id"] for c in manifest["components"]}
        for component in manifest["components"]:
            assert component["files"], "Empty component"
            assert component["asset"] not in names, "Nested component archive wastes download bytes"
            for entry in component["files"]:
                assert entry["path"] not in names, f"Duplicated component payload: {entry['path']}"
        assert "download.json" not in names and "bin/module-downloader" not in names
        for name in ("service.sh", "cli", ".config/sing-box/config.json"):
            assert name in names, f"Missing MagicNet runtime scaffold: {name}"
        cli = z.getinfo("cli")
        assert stat.S_ISLNK(cli.external_attr >> 16), "cli alias must remain a symbolic link"
        assert cli.compress_type == zipfile.ZIP_STORED, (
            "BusyBox unzip cannot extract compressed symbolic links"
        )
        binary = z.read("bin/magicnet-components")
        assert binary[:6] == b"\x7fELF\x02\x01", "Expected a 64-bit little-endian ELF helper"
        assert struct.unpack_from("<H", binary, 18)[0] == {"arm64": 183, "amd64": 62}[arch]
        assert (z.getinfo("bin/magicnet-components").external_attr >> 16) & stat.S_IXUSR
        script = z.read("customize.sh")
        assert script.count(b"# Component bootstrap:") == 1
        assert b'"module.prop" "components.json" "bin/magicnet-components"' in script, (
            "SKIPUNZIP installer must extract module.prop into MODPATH for manager bookkeeping"
        )
        assert b'[ -f "$MODPATH/module.prop" ]' in script, (
            "Installer must fail before reporting success if module.prop is missing from MODPATH"
        )
        assert not re.search(rb"(?m)^\s*install_module(?:[\s;]|$)", script), "Nested manager installation"
    print("Final installer: MagicNet identity, core alias, stored symlink, ELF, CRC, manager metadata and component-only payloads verified")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--core", type=Path)
    parser.add_argument("--arch", choices=("arm64", "amd64"), default="arm64")
    args = parser.parse_args()
    verify(args.archive, arch=args.arch, core=args.core)


if __name__ == "__main__":
    main()
