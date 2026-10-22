#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MODDIR="$WORKDIR/module"
mkdir -p \
  "$MODDIR/.config/sing-box" \
  "$MODDIR/.state/sing-box/subscription-work"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# Fail only the prepared-phase marker write while keeping fixture setup and
# diagnostics on the real printf implementation.
printf() {
    if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = prepared ] &&
        [ "${MAGICNET_TEST_FAIL_JOURNAL_WRITE:-0}" = "1" ]; then
        return 1
    fi
    if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = active-config ] &&
        [ "${MAGICNET_TEST_FAIL_PHASE_WRITE:-0}" = "1" ]; then
        return 1
    fi
    command printf "$@"
}

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# This journal-mechanics fixture models core acceptance for named generations.
# Real JSON validation and failed core checks are covered by baseline-safety.
magicnet_singbox_recovery_config_valid() {
  case "$(cat "$1" 2>/dev/null)" in
  active-config | candidate-config | old-config | stable-config | term-old-config | old-config-without-url-or-work) return 0 ;;
  *) return 1 ;;
  esac
}

printf '%s\n' active-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' active-url >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' active-work >"$MODDIR/.state/sing-box/subscription-work/marker"
INPUT_SOURCE="$WORKDIR/candidate.url"
printf '%s\n' candidate >"$INPUT_SOURCE"

_sub_input_source="$INPUT_SOURCE"
_sub_source_mode=url
_sub_was_running=0
_sub_generation_id=journal-fixture

MAGICNET_TEST_FAIL_JOURNAL_WRITE=1
export MAGICNET_TEST_FAIL_JOURNAL_WRITE
set +e
magicnet_singbox_transaction_begin
begin_rc=$?
set -e
unset MAGICNET_TEST_FAIL_JOURNAL_WRITE

[ "$begin_rc" -ne 0 ] || {
    printf '%s\n' 'transaction journal creation succeeded after a metadata write failure' >&2
    exit 1
}
[ ! -e "$MODDIR/.state/sing-box/subscription-transaction" ] || {
    printf '%s\n' 'transaction journal was published despite an incomplete phase marker' >&2
    exit 1
}
[ -z "$(find "$MODDIR/.state/sing-box" -maxdepth 1 -name 'subscription-transaction.new.*' -print -quit)" ] || {
    printf '%s\n' 'failed transaction journal staging directory leaked' >&2
    exit 1
}

printf '%s\n' 'subscription transaction journal safety test passed'

# Transaction phase metadata is also journal state.  A failed write must not
# truncate the last durable phase or report success to the caller.
TRANSACTION_DIR="$MODDIR/.state/sing-box/subscription-transaction"
mkdir -p "$TRANSACTION_DIR"
printf '%s\n' old-phase >"$TRANSACTION_DIR/phase"
MAGICNET_TEST_FAIL_PHASE_WRITE=1
export MAGICNET_TEST_FAIL_PHASE_WRITE
set +e
magicnet_singbox_transaction_phase active-config
phase_rc=$?
set -e
unset MAGICNET_TEST_FAIL_PHASE_WRITE

[ "$phase_rc" -ne 0 ] || {
    printf '%s\n' 'transaction phase write reported success after a metadata failure' >&2
    exit 1
}
[ "$(<"$TRANSACTION_DIR/phase")" = old-phase ] || {
    printf '%s\n' 'failed transaction phase write truncated the durable phase' >&2
    exit 1
}
[ -z "$(find "$TRANSACTION_DIR" -maxdepth 1 -name 'phase.tmp.*' -print -quit)" ] || {
    printf '%s\n' 'failed transaction phase write leaked its temporary file' >&2
    exit 1
}

printf '%s\n' 'subscription transaction phase safety test passed'

# A corrupt generation identifier is metadata, never a path for recursive
# cleanup. Reject it before changing the active config, work, or source files.
GENERATION_ROOT="$MODDIR/.state/sing-box/subscription-generations"
UNRELATED_DIR="$MODDIR/.state/sing-box/unrelated-data"
mkdir -p "$GENERATION_ROOT" "$UNRELATED_DIR"
printf '%s\n' preserve-me >"$UNRELATED_DIR/marker"
printf '%s\n' active-local >"$MODDIR/.config/sing-box/subscription.local"
for invalid_generation in '../unrelated-data' . .. 'invalid token' "$(printf '%0129d' 0)"; do
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR/old-work"
    : >"$TRANSACTION_DIR/had-config"
    : >"$TRANSACTION_DIR/had-work"
    : >"$TRANSACTION_DIR/had-url"
    : >"$TRANSACTION_DIR/had-local"
    printf '%s\n' old-config >"$TRANSACTION_DIR/old-config"
    printf '%s\n' old-work >"$TRANSACTION_DIR/old-work/marker"
    printf '%s\n' old-url >"$TRANSACTION_DIR/old-url"
    printf '%s\n' old-local >"$TRANSACTION_DIR/old-local"
    printf '%s\n' "$invalid_generation" >"$TRANSACTION_DIR/generation-id"
    if magicnet_singbox_transaction_reconcile; then
        printf '%s\n' 'transaction recovery accepted an invalid generation identifier' >&2
        exit 1
    fi
    test "$(cat "$MODDIR/.config/sing-box/config.json")" = active-config
    test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = active-work
    test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = active-url
    test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = active-local
    test "$(cat "$UNRELATED_DIR/marker")" = preserve-me
    test -d "$TRANSACTION_DIR"
done

# A valid interrupted generation still restores its backup and removes only
# its own staged files. The malformed journal can be retried after correction.
printf '%s\n' journal-fixture >"$TRANSACTION_DIR/generation-id"
mkdir -p "$GENERATION_ROOT/journal-fixture" "$GENERATION_ROOT/unrelated-generation"
: >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
: >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
magicnet_singbox_transaction_reconcile
test "$(cat "$MODDIR/.config/sing-box/config.json")" = old-config
test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = old-work
test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = old-url
test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = old-local
test "$(cat "$UNRELATED_DIR/marker")" = preserve-me
test -d "$GENERATION_ROOT/unrelated-generation"
test ! -e "$GENERATION_ROOT/journal-fixture"
test ! -e "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
test ! -e "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
test ! -e "$TRANSACTION_DIR"
printf '%s\n' 'subscription transaction generation safety test passed'

# Run malformed journal recovery in a bounded child. A FIFO must fail closed,
# not hang the lifecycle lock; a read error must not look like a legacy field.
cat >"$WORKDIR/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
magicnet_source_primitives() { :; }
# shellcheck disable=SC1090
. "$1"
magicnet_singbox_recovery_config_valid() {
    [ "$(cat "$1" 2>/dev/null)" = old-config ]
}
head() {
    if [ "${*: -1}" = "$MODDIR/.state/sing-box/subscription-transaction/${MAGICNET_TEST_METADATA_FIELD:-}" ]; then
        case "${MAGICNET_TEST_METADATA_FAILURE:-}" in
        read) return 1 ;;
        short-read) command head -c 1 "${*: -1}"; return ;;
        esac
    fi
    command head "$@"
}
stat() {
    if [ "${MAGICNET_TEST_METADATA_FAILURE:-}" = stat ] &&
        [ "${*: -1}" = "$MODDIR/.state/sing-box/subscription-transaction/${MAGICNET_TEST_METADATA_FIELD:-}" ]; then
        return 1
    fi
    command stat "$@"
}
magicnet_singbox_transaction_reconcile
EOF

journal_recovery_fixture() {
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR/old-work" "$MODDIR/.state/sing-box/subscription-work" \
        "$GENERATION_ROOT/journal-fixture"
    printf '%s\n' active-config >"$MODDIR/.config/sing-box/config.json"
    printf '%s\n' active-work >"$MODDIR/.state/sing-box/subscription-work/marker"
    printf '%s\n' active-url >"$MODDIR/.config/sing-box/subscription.url"
    printf '%s\n' active-local >"$MODDIR/.config/sing-box/subscription.local"
    printf '%s\n' old-config >"$TRANSACTION_DIR/old-config"
    printf '%s\n' old-work >"$TRANSACTION_DIR/old-work/marker"
    printf '%s\n' old-url >"$TRANSACTION_DIR/old-url"
    printf '%s\n' old-local >"$TRANSACTION_DIR/old-local"
    printf '%s\n' journal-fixture >"$TRANSACTION_DIR/generation-id"
    printf '%s\n' prepared >"$TRANSACTION_DIR/phase"
    printf '%s\n' url >"$TRANSACTION_DIR/input-mode"
    touch "$TRANSACTION_DIR/had-config" "$TRANSACTION_DIR/had-work" \
        "$TRANSACTION_DIR/had-url" "$TRANSACTION_DIR/had-local"
    : >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
    : >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
}

assert_journal_recovery_rejected() {
    recovery_rc=0
    MAGICNET_TEST_METADATA_FAILURE="${2:-}" MAGICNET_TEST_METADATA_FIELD="${3:-}" \
        timeout 3 bash "$WORKDIR/reconcile.sh" \
        "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh" \
        >"$WORKDIR/recovery.out" 2>"$WORKDIR/recovery.err" || recovery_rc=$?
    if [ "$recovery_rc" -ne 1 ]; then
        printf '%s\n' "$1: expected rejected recovery, got exit $recovery_rc" >&2
        cat "$WORKDIR/recovery.err" >&2
        exit 1
    fi
    test "$(cat "$MODDIR/.config/sing-box/config.json")" = active-config
    test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = active-work
    test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = active-url
    test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = active-local
    test -d "$GENERATION_ROOT/journal-fixture"
    test -f "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
    test -f "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
    test -e "$TRANSACTION_DIR" || test -L "$TRANSACTION_DIR"
}

# Presence markers have the same safety boundary as generation-id: a damaged
# had-config marker must never be mistaken for permission to delete config.
for metadata_field in generation-id phase input-mode \
    had-config had-work had-url had-local was-running \
    owns-generation owns-config-candidate; do
    for metadata_kind in fifo directory symlink dangling-symlink content read stat; do
        journal_recovery_fixture
        metadata_file="$TRANSACTION_DIR/$metadata_field"
        rm -f "$metadata_file"
        case "$metadata_kind" in
        fifo) mkfifo "$metadata_file" ;;
        directory) mkdir "$metadata_file" ;;
        symlink)
            : >"$WORKDIR/metadata-target"
            ln -s "$WORKDIR/metadata-target" "$metadata_file"
            ;;
        dangling-symlink) ln -s "$WORKDIR/missing-metadata" "$metadata_file" ;;
        content) printf '%s\n' 'invalid token' >"$metadata_file" ;;
        read | stat)
            case "$metadata_field" in
            generation-id | phase | input-mode) printf '%s\n' journal-fixture >"$metadata_file" ;;
            *) : >"$metadata_file" ;;
            esac
            ;;
        esac
        assert_journal_recovery_rejected "$metadata_field/$metadata_kind" "$metadata_kind" "$metadata_field"
        # Preserve the damaged evidence itself as well as the active files.
        case "$metadata_kind" in
        fifo) test -p "$metadata_file" ;;
        directory) test -d "$metadata_file" ;;
        symlink | dangling-symlink) test -L "$metadata_file" ;;
        *) test -f "$metadata_file" ;;
        esac
    done
done

for corrupt_text in second-line extra-newline nul oversized short-read; do
    journal_recovery_fixture
    case "$corrupt_text" in
    second-line) printf 'journal-fixture\nother-generation\n' >"$TRANSACTION_DIR/generation-id" ;;
    extra-newline) printf 'journal-fixture\n\n' >"$TRANSACTION_DIR/generation-id" ;;
    nul) printf 'journal-\000fixture\n' >"$TRANSACTION_DIR/generation-id" ;;
    oversized) printf '%0130d' 0 >"$TRANSACTION_DIR/generation-id" ;;
    esac
    cp "$TRANSACTION_DIR/generation-id" "$WORKDIR/generation-evidence"
    assert_journal_recovery_rejected "$corrupt_text" "$corrupt_text" generation-id
    cmp -s "$WORKDIR/generation-evidence" "$TRANSACTION_DIR/generation-id"
done

journal_recovery_fixture
mv "$TRANSACTION_DIR" "$WORKDIR/linked-journal"
ln -s "$WORKDIR/linked-journal" "$TRANSACTION_DIR"
assert_journal_recovery_rejected 'symlink journal directory'
test -L "$TRANSACTION_DIR"
test "$(cat "$WORKDIR/linked-journal/old-config")" = old-config
rm -f "$TRANSACTION_DIR"
: >"$TRANSACTION_DIR"
assert_journal_recovery_rejected 'non-directory journal'
test -f "$TRANSACTION_DIR"
rm -f "$TRANSACTION_DIR"
mkfifo "$TRANSACTION_DIR"
assert_journal_recovery_rejected 'FIFO journal'
test -p "$TRANSACTION_DIR"
rm -f "$TRANSACTION_DIR"
ln -s "$WORKDIR/missing-journal" "$TRANSACTION_DIR"
assert_journal_recovery_rejected 'dangling journal symlink'
test -L "$TRANSACTION_DIR"

# A published journal must prove the previous config. Missing ownership is
# indeterminate, even when a generation/phase or an orphan backup survived.
for incomplete_journal in empty metadata-only orphan-config; do
    journal_recovery_fixture
    if [ "$incomplete_journal" = orphan-config ]; then
        rm -f "$TRANSACTION_DIR/had-config"
    else
        rm -rf "$TRANSACTION_DIR"
        mkdir "$TRANSACTION_DIR"
        if [ "$incomplete_journal" = metadata-only ]; then
            printf '%s\n' journal-fixture >"$TRANSACTION_DIR/generation-id"
            printf '%s\n' prepared >"$TRANSACTION_DIR/phase"
        fi
    fi
    assert_journal_recovery_rejected "$incomplete_journal journal"
    test -d "$TRANSACTION_DIR"
    test ! -e "$TRANSACTION_DIR/had-config"
    if [ "$incomplete_journal" = orphan-config ]; then
        test "$(cat "$TRANSACTION_DIR/old-config")" = old-config
    fi
done

for missing_marker in work url local; do
    journal_recovery_fixture
    rm -f "$TRANSACTION_DIR/had-$missing_marker"
    assert_journal_recovery_rejected "orphan $missing_marker backup"
    test ! -e "$TRANSACTION_DIR/had-$missing_marker"
    if [ "$missing_marker" = work ]; then
        test "$(cat "$TRANSACTION_DIR/old-work/marker")" = old-work
    else
        test "$(cat "$TRANSACTION_DIR/old-$missing_marker")" = "old-$missing_marker"
    fi
done

# Legacy absence remains distinct from corrupt metadata. Empty generation IDs
# and valid IDs with/without one terminal LF must still recover. Textual phase
# and mode values are bounded tokens, not a new closed vocabulary.
for legacy_generation in missing empty newline max-token max-token-no-newline; do
    journal_recovery_fixture
    rm -f "$TRANSACTION_DIR/phase" "$TRANSACTION_DIR/input-mode"
    case "$legacy_generation" in
    missing) rm -f "$TRANSACTION_DIR/generation-id" ;;
    empty) : >"$TRANSACTION_DIR/generation-id" ;;
    newline) printf '\n' >"$TRANSACTION_DIR/generation-id" ;;
    max-token) printf '%0128d\n' 0 >"$TRANSACTION_DIR/generation-id" ;;
    max-token-no-newline)
        printf '%0128d' 0 >"$TRANSACTION_DIR/generation-id"
        printf '%s\n' old-phase >"$TRANSACTION_DIR/phase"
        printf '%s\n' local >"$TRANSACTION_DIR/input-mode"
        ;;
    esac
    magicnet_singbox_transaction_reconcile
    test "$(cat "$MODDIR/.config/sing-box/config.json")" = old-config
    test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = old-work
    test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = old-url
    test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = old-local
    test ! -e "$TRANSACTION_DIR"
done

# An optional component can genuinely have been absent before the update;
# both its marker and backup must be absent to establish that baseline.
journal_recovery_fixture
rm -rf "$TRANSACTION_DIR/had-work" "$TRANSACTION_DIR/old-work"
rm -f "$TRANSACTION_DIR/had-url" "$TRANSACTION_DIR/old-url" \
    "$TRANSACTION_DIR/had-local" "$TRANSACTION_DIR/old-local"
magicnet_singbox_transaction_reconcile
test "$(cat "$MODDIR/.config/sing-box/config.json")" = old-config
test ! -e "$MODDIR/.state/sing-box/subscription-work"
test ! -e "$MODDIR/.config/sing-box/subscription.url"
test ! -e "$MODDIR/.config/sing-box/subscription.local"
test ! -e "$TRANSACTION_DIR"
printf '%s\n' 'subscription transaction bounded metadata safety test passed'
