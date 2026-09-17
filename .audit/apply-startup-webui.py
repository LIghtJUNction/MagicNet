#!/usr/bin/env python3
"""Apply reviewed UTF-8 line edits only after validating both source generations."""
import base64
import hashlib
import json
from pathlib import Path
import sys
import zlib

root = Path(sys.argv[1]).resolve(strict=True)
here = Path(__file__).resolve().parent
parts = [(here / f"startup-webui-{i}.txt").read_text().strip() for i in range(1, 4)]
# Correct two transcription insertions in the transport, then require the exact
# locally verified payload digest. These are not edits to production sources.
parts[2] = parts[2].replace("HLNem2W", "HLem2W").replace("1KlUUolf", "1KlUolf")
expected_parts = [
    "d8727226060147bc574cf12e2c648aca8037cddd70a986b43a91fee6f35b2a07",
    "a7f5414149a5d7deed073187968ea145374a66b4460800e9dde298611ab02781",
    "4532097fcd75d06f8b9f3b29d4bcac7c1ae270c6f3e7c2b3e375e801ed5eae5a",
]
for i, (part, expected) in enumerate(zip(parts, expected_parts), 1):
    actual = hashlib.sha256(part.encode()).hexdigest()
    if actual != expected:
        raise SystemExit(f"transport part {i}: digest mismatch ({actual})")
payload = "".join(parts)
assert len(payload) == 19960
assert hashlib.sha256(payload.encode()).hexdigest() == "28577493bb64fb98e7b2ee25456ab08ded5116ddd9479478092bd050686098f4"
records = json.loads(zlib.decompress(base64.b64decode(payload, validate=True)))
assert isinstance(records, dict) and len(records) == 17
staged = []
for name, record in records.items():
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("unsafe patch path")
    if not name.startswith(("webui/", "scripts/", "src/MagicNet/lib/magicnet/")):
        raise SystemExit("path outside reviewed scope")
    target = root / relative
    if target.is_symlink() or not target.resolve().is_relative_to(root):
        raise SystemExit("unsafe patch destination")
    if record["before"] is None:
        assert not target.exists(), name
        old = b""
    else:
        old = target.read_bytes()
        assert hashlib.sha256(old).hexdigest() == record["before"], f"base mismatch: {name}"
    lines = old.decode().splitlines(keepends=True)
    for start, end, replacement in reversed(record["edits"]):
        assert 0 <= start <= end <= len(lines)
        lines[start:end] = replacement.splitlines(keepends=True)
    new = "".join(lines).encode()
    assert hashlib.sha256(new).hexdigest() == record["after"], f"result mismatch: {name}"
    staged.append((target, new, 0o755 if record["mode"] & 0o111 else 0o644))
for target, content, mode in staged:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    target.chmod(mode)
    print(f"verified {target.relative_to(root)} {hashlib.sha256(content).hexdigest()}")
print(f"Applied {len(staged)} files with all original and final content hashes verified.")
