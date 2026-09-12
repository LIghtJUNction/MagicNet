#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    binary = work / "bin"
    binary.mkdir()
    module = work / "module"
    config = module / ".config/sing-box/config.json"
    config.parent.mkdir(parents=True)
    config.write_text('{"sentinel":true}\n')
    mock = binary / "curl"
    mock.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
mode = os.environ.get("VOICE_TEST", "valid")
if mode == "failure": sys.exit(22)
if "-o" not in sys.argv:
    print(json.dumps({"object":{"sha":"a"*40}}))
else:
    assert any("/" + "a"*40 + "/" in arg for arg in sys.argv)
    prefixes = ["203.0.113.8/32", "2001:db8::8/128"]
    if mode == "empty": prefixes = []
    if mode == "invalid": prefixes = ["999.0.0.0/32"]
    if mode == "catchall": prefixes = ["0.0.0.0/0"]
    Path(sys.argv[sys.argv.index("-o")+1]).write_text(json.dumps(
        {"version":2,"rules":[{"ip_cidr":prefixes}]}))
""")
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(binary)+":"+os.environ["PATH"],
               KAM_HOOKS_ROOT=str(root/"hooks"), KAM_MODULE_ROOT=str(module))
    def run(mode):
        return subprocess.run(["bash", str(root/"hooks/pre-build/5460.update_chatgpt_voice_rules.sh")],
                              env=dict(env, VOICE_TEST=mode), capture_output=True)
    assert run("valid").returncode == 0
    output = module / ".config/sing-box/rules/sukka-chatgpt-voice.json"
    expected = output.read_bytes()
    assert run("valid").returncode == 0 and output.read_bytes() == expected
    for mode in ("empty", "invalid", "catchall", "failure"):
        assert run(mode).returncode != 0, mode
        assert output.read_bytes() == expected, mode
    assert config.read_text() == '{"sentinel":true}\n'
    assert not list(output.parent.glob(".chatgpt-voice.*"))
config = json.loads((root/"src/MagicNet/.config/sing-box/config.json").read_text())
voice = [rule for rule in config["route"]["rules"] if "sukka-chatgpt-voice" in rule.get("rule_set", [])]
assert {(rule["network"], rule["port"], rule["outbound"]) for rule in voice} == {
    ("udp", 3478, "ai-chatgpt"), ("tcp", 443, "ai-chatgpt")}
assert all("ip_cidr" not in rule for rule in voice)
print("Maintained ChatGPT Voice rule-set tests passed")
PY
