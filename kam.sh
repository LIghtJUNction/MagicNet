#!/bin/bash
# kam install LIghtJUNction/MagicNet
set -euo pipefail

command -v kam >/dev/null || { pkg install -y rust && pkg install -y openssl perl make cmake && cargo install kam; }

command -v gh  >/dev/null || pkg install -y gh

command -v cz  >/dev/null || pkg install -y uv && uv tool update-shell && uv tool install commitizen

command -v git >/dev/null || pkg install -y git
command -v go >/dev/null || pkg install -y golang

git submodule update --init

kam build
