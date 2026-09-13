#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    printf 'repository hygiene failed: %s\n' "$*" >&2
    exit 1
}

tracked_garbage="$(
    git ls-files | grep -E \
        '(^|/)(target|dist|node_modules|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|htmlcov)(/|$)|(^|/)(\.DS_Store|Thumbs\.db|\.coverage(\.[^/]*)?)$|(\.log|\.tmp|\.sw[op]|\.py[cod]|~)$' \
        || true
)"
[[ -z "$tracked_garbage" ]] || fail "tracked build/cache/editor artifacts found:
$tracked_garbage"

# Keep generated test/editor files out of future commits, not just this tree.
ignored_artifacts=(
    'scripts/__pycache__/test.cpython-313.pyc'
    'scripts/test.pyc'
    'scripts/test.pyo'
    '.pytest_cache/state'
    '.mypy_cache/state'
    '.ruff_cache/state'
    '.coverage'
    '.coverage.worker'
    'htmlcov/index.html'
    '.DS_Store'
    'webui/Thumbs.db'
    'scripts/test.sh.swp'
    'scripts/test.sh.swo'
    'scripts/test.sh~'
)
for artifact in "${ignored_artifacts[@]}"; do
    git check-ignore --no-index -q "$artifact" \
        || fail "generated artifact is not ignored: $artifact"
done

for sensitive in .env .tokensave; do
    if git ls-files --error-unmatch "$sensitive" >/dev/null 2>&1; then
        fail "private local file is tracked: $sensitive"
    fi
done

allowed_empty_files=(
    "src/MagicNet/.config/magicnet/route-block-domain-suffix.list"
    "src/MagicNet/.config/magicnet/route-direct-domain-suffix.list"
    "src/MagicNet/.config/magicnet/route-proxy-domain-suffix.list"
)

empty_tracked=()
while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -s "$file" ]] || continue
    allowed=0
    for expected in "${allowed_empty_files[@]}"; do
        if [[ "$file" == "$expected" ]]; then
            allowed=1
            break
        fi
    done
    [[ "$allowed" -eq 1 ]] || empty_tracked+=("$file")
done < <(git ls-files -z)

if [[ "${#empty_tracked[@]}" -gt 0 ]]; then
    printf 'repository hygiene failed: unexpected empty tracked files:\n' >&2
    printf '  %s\n' "${empty_tracked[@]}" >&2
    exit 1
fi

grep -Fq 'cli hotspot status' README.md \
    || fail "README must document the supported hotspot selector"
if grep -Fq '不会维护 TProxy、多核心切换、热点代理或 VPN 共存模式' README.md; then
    fail "README still claims that the supported hotspot selector is not maintained"
fi
grep -Fq '先选择问题类型' README.md \
    || fail "README must document category-aware Issue context collection"

printf 'repository hygiene tests passed\n'
