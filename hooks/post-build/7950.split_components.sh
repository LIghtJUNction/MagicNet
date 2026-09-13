#!/usr/bin/env bash
# All ZIP mutations must precede KAM's 8000 signing hook.
set -euo pipefail
: "${KAM_PROJECT_ROOT:?}"
python3 "$KAM_PROJECT_ROOT/scripts/package-components.py" "$KAM_PROJECT_ROOT/dist/MagicNet.zip"
