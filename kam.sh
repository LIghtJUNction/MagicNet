#!/bin/bash
# kam install https://github.com/LIghtJUNction/MagicNet.git
set -euo pipefail

command -v kam >/dev/null || { pkg install -y rust && pkg install -y openssl && cargo install kam; }

command -v gh  >/dev/null || pkg install -y github-cli

command -v cz  >/dev/null || pkg install -y python-commitizen

command -v git >/dev/null || pkg install -y git

git submodule init --recursive

kam build && kam install
