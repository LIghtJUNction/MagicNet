#!/usr/bin/env python3
"""Validate the final public installer, not an intermediate downloader template."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import zipfile


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify(archive: Path, core: Path, architecture: str = "arm64") -> None:
    raw = archive.read_bytes()
    require(raw == core.read_bytes(), "Public installer must be the exact release-pinned core ZIP")
    require(len(raw) <= 12 * 1024 * 1024, "Installer exceeds the core download budget")
    with zipfile.ZipFile(archive) as z:
        require(z.testzip() is None, "Installer ZIP CRC mismatch")
        names = z.namelist()
        require(len(names) == len(set(names)), "Duplicate installer ZIP members")
        for info in z.infolist():
            offset = info.header_offset
            require(raw[offset:offset + 4] == b"PK\x03\x04", "Invalid ZIP local header")
            name_len = struct.unpack_from("<H", raw, offset + 26)[0]
            encoding = "utf-8" if info.flag_bits & 0x800 else "cp437"
            require(raw[offset + 30:offset + 30 + name_len].decode(encoding) == info.filename,
                    "ZIP local and central filenames differ")
        for name in ("module.prop", "customize.sh", "components.json", "bin/magicnet-components",
                     "service.sh", "action.sh", "boot-completed.sh", ".config/sing-box/config.json"):
            require(name in names, f"Missing installed-module entry: {name}")
        for name in ("download.json", "bin/module-downloader"):
            require(name not in names, f"Obsolete recursive downloader remains: {name}")
        props = dict(line.split("=", 1) for line in z.read("module.prop").decode().splitlines()
                     if "=" in line and not line.startswith("#"))
        require(props.get("id") == "MagicNet", "Manager must install MagicNet, not magicnet_installer")
        require(re.fullmatch(r"v\d+\.\d+\.\d+", props.get("version", "")) is not None,
                "Invalid module version")
        require(props.get("versionCode", "").isdigit(), "Missing numeric versionCode")
        manifest = json.loads(z.read("components.json"))
        require(manifest.get("module") == "MagicNet" and manifest.get("schema") == 1,
                "Unexpected component manifest identity")
        require(manifest.get("version") == props["version"], "Core and components must pin the same release")
        require(manifest.get("architecture") == architecture, "Unexpected component architecture")
        components = manifest.get("components", [])
        require(bool(components), "Installer has no component manifest")
        for component in components:
            for payload in component["files"]:
                require(payload["path"] not in names, "Installer redundantly bundles a separate component")
        script = z.read("customize.sh")
        require(script.count(b"# Component bootstrap:") == 1, "Missing/duplicate component bootstrap")
        require(b"--previous-dir" in script, "Installer must reuse verified previous components")
        require(re.search(rb"\binstall_module\b", script) is None, "Recursive manager installation is forbidden")
        binary = z.read("bin/magicnet-components")
        machine = {"arm64": 183, "amd64": 62}[architecture]
        require(len(binary) >= 20 and binary[:6] == b"\x7fELF\x02\x01" and
                struct.unpack_from("<H", binary, 18)[0] == machine,
                "Component helper is not a matching 64-bit ELF")
        require(bool((z.getinfo("bin/magicnet-components").external_attr >> 16) & 0o111),
                "Component helper is not executable")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--core", type=Path)
    parser.add_argument("--arch", choices=("arm64", "amd64"), default="arm64")
    args = parser.parse_args()
    verify(args.archive, args.core or args.archive.with_name("MagicNet-core.zip"), args.arch)
    print("Final installer ZIP/ELF, MagicNet identity, release pinning and core-only payload passed")


if __name__ == "__main__":
    main()
