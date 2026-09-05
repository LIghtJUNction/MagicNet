#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export KAM_PROJECT_ROOT="$test_root/project"
export KAM_HOOKS_ROOT="$test_root/hooks"
mkdir -p "$KAM_PROJECT_ROOT/dist" "$KAM_PROJECT_ROOT/scripts" "$KAM_HOOKS_ROOT/lib" \
    "$test_root/source/lib/kamfw" "$test_root/source/.config/sing-box"
printf '[prop]\nid = "MagicNet"\n' > "$KAM_PROJECT_ROOT/kam.toml"
printf 'fixture\n' > "$test_root/source/lib/kamfw/__singbox__.sh"
printf '{}\n' > "$test_root/source/.config/sing-box/.dns-test.json"
cat > "$KAM_HOOKS_ROOT/lib/utils.sh" <<'SH'
log_info() { :; }
require_command() { command -v "$1" >/dev/null; }
SH
printf '#!/bin/bash\nexit 0\n' > "$KAM_PROJECT_ROOT/scripts/package-smoke.sh"
chmod +x "$KAM_PROJECT_ROOT/scripts/package-smoke.sh"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$test_root/key.pem" 2>/dev/null
openssl pkey -in "$test_root/key.pem" -pubout -out "$test_root/public.pem"
artifact="$KAM_PROJECT_ROOT/dist/MagicNet.zip"
sanitize_hooks=("$repo_root"/hooks/post-build/*.sanitize_zip.sh)
test "${#sanitize_hooks[@]}" -eq 1
sanitize_hook="${sanitize_hooks[0]}"

make_archive() {
    rm -f "$artifact" "${artifact}.sig"
    (cd "$test_root/source" && zip -qr "$artifact" .)
}
sign_archive() {
    openssl dgst -sha256 -sign "$test_root/key.pem" -out "$test_root/signature.der" "$artifact"
    openssl base64 -A -in "$test_root/signature.der" -out "${artifact}.sig"
}
verify_archive() {
    "$repo_root/scripts/verify-artifact-signature.sh" "$artifact" "$test_root/public.pem" >/dev/null 2>&1
}

# Reproduce the original failure: a valid signature becomes invalid after cleanup.
make_archive
sign_archive
verify_archive
bash "$sanitize_hook"
if verify_archive; then
    echo 'Post-sign cleanup must invalidate the original signature' >&2
    exit 1
fi

# KAM merges base and overlay hooks in filename order; exercise that order.
make_archive
while IFS= read -r hook; do
    case "$hook" in
        8000.SIGN_IF_ENABLE.sh) sign_archive ;;
        *) bash "$sanitize_hook" ;;
    esac
done < <(printf '%s\n' "${sanitize_hook##*/}" 8000.SIGN_IF_ENABLE.sh | LC_ALL=C sort)
verify_archive
if unzip -Z1 "$artifact" | grep -Fq '.dns-test.json'; then
    echo 'Archive cleanup did not remove its fixture' >&2
    exit 1
fi

# The final artifact check must reject later mutation and a missing signature.
printf 'changed\n' >> "$artifact"
if verify_archive; then
    echo 'Modified archive passed signature verification' >&2
    exit 1
fi
rm "${artifact}.sig"
if verify_archive; then
    echo 'Unsigned archive passed signature verification' >&2
    exit 1
fi
printf 'Artifact signing order and integrity checks passed\n'
