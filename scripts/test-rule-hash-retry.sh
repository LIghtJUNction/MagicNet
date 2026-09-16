#!/bin/bash
# Compatibility entry point: upstream Git hash retries now belong to MagicNetRules.
# The module consumes Releases and must retry failed builds without accepting stale data.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/test-bundled-rules.py" \
    BundledRuleTests.test_release_download_failure_preserves_previous_file_and_marker \
    BundledRuleTests.test_release_download_is_retried_on_next_build \
    BundledRuleTests.test_missing_required_rule_does_not_fetch_upstream \
    -v
