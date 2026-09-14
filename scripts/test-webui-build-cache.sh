#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJECT="$WORK/project"
MODULE="$WORK/module"
FAKE_BIN="$WORK/bin"
CALL_LOG="$WORK/bun-calls"
mkdir -p "$PROJECT/hooks/pre-build" "$PROJECT/hooks/lib" "$PROJECT/webui/src" "$FAKE_BIN"
cp "$ROOT/hooks/pre-build/2000.BUILD_WEBUI.sh" "$PROJECT/hooks/pre-build/2000.BUILD_WEBUI.sh"

cat >"$PROJECT/hooks/lib/utils.sh" <<'EOF'
log_info() { :; }
log_error() { printf '%s\n' "$*" >&2; }
log_success() { :; }
EOF
cat >"$PROJECT/webui/package.json" <<'EOF'
{"name":"cache-fixture","scripts":{"check":"fixture"}}
EOF
printf 'lock\n' >"$PROJECT/webui/bun.lock"
printf 'first\n' >"$PROJECT/webui/src/app.js"

cat >"$FAKE_BIN/bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
--version)
    printf '1.2.3\n'
    ;;
install)
    printf 'install\n' >>"$CALL_LOG"
    ;;
run)
    [ "${2:-}" = check ] || exit 64
    printf 'check\n' >>"$CALL_LOG"
    mkdir -p dist/assets
    printf '<html>fixture</html>\n' >dist/index.html
    printf 'asset:%s\n' "$(cat src/app.js)" >dist/assets/app.js
    ;;
*)
    exit 64
    ;;
esac
EOF
chmod +x "$FAKE_BIN/bun" "$PROJECT/hooks/pre-build/2000.BUILD_WEBUI.sh"

(
    cd "$PROJECT"
    git init -q
    git add webui hooks/pre-build/2000.BUILD_WEBUI.sh
)

export PATH="$FAKE_BIN:$PATH"
export CALL_LOG
export KAM_PROJECT_ROOT="$PROJECT"
export KAM_HOOKS_ROOT="$PROJECT/hooks"
export KAM_MODULE_ROOT="$MODULE"

run_hook() {
    bash "$PROJECT/hooks/pre-build/2000.BUILD_WEBUI.sh"
    [ -f "$MODULE/webroot/index.html" ]
    [ ! -e "$MODULE/webroot/.magicnet-build-key" ]
}

call_count() {
    [ -f "$CALL_LOG" ] && wc -l <"$CALL_LOG" | tr -d ' ' || printf '0\n'
}

run_hook
[ "$(call_count)" = 2 ]
[ -f "$PROJECT/webui/dist/.magicnet-build-key" ]

# Identical inputs must reuse the restored dist without touching the package manager.
run_hook
[ "$(call_count)" = 2 ]

# Working-tree source changes must invalidate even before they are committed.
printf 'second\n' >"$PROJECT/webui/src/app.js"
run_hook
[ "$(call_count)" = 4 ]
run_hook
[ "$(call_count)" = 4 ]

# Vite build-time environment is part of the cache identity.
export VITE_CACHE_TEST=changed
run_hook
[ "$(call_count)" = 6 ]
run_hook
[ "$(call_count)" = 6 ]

# A damaged restored output must never be trusted solely because its input key matches.
printf 'corrupt\n' >"$PROJECT/webui/dist/assets/app.js"
run_hook
[ "$(call_count)" = 8 ]
grep -Fq 'asset:second' "$PROJECT/webui/dist/assets/app.js"

printf 'webui build cache regression passed\n'
