#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFDATA="${LLVM_PROFDATA:-llvm-profdata}"
COV="${LLVM_COV:-llvm-cov}"
TARGET_DIR="$ROOT/${CARGO_TARGET_DIR:-target}/coverage-local"
PROFRAW_DIR="$TARGET_DIR/profraw"
BIN_DIR="$TARGET_DIR/debug/deps"

rm -rf "$TARGET_DIR"
mkdir -p "$PROFRAW_DIR"

RUSTFLAGS="-C instrument-coverage" \
LLVM_PROFILE_FILE="$PROFRAW_DIR/magicnet-%p-%m.profraw" \
CARGO_TARGET_DIR="$TARGET_DIR" \
cargo test -p magicnet-cli -- --test-threads=1

"$PROFDATA" merge -sparse "$PROFRAW_DIR"/*.profraw -o "$TARGET_DIR/coverage.profdata"

mapfile -t OBJECTS < <(
  find "$BIN_DIR" -maxdepth 1 -type f -perm -111 -name 'magicnet_cli-*' | sort
)

if [ "${#OBJECTS[@]}" -eq 0 ]; then
  echo "coverage object not found" >&2
  exit 1
fi

IGNORE_RE='/.cargo/registry|/rustc/|target/coverage-local/debug/build'
SOURCES=(
  "crates/magicnet-cli/src/base64.rs"
  "crates/magicnet-cli/src/tailscale/singbox.rs"
  "crates/magicnet-cli/src/tailscale/mihomo.rs"
)
SOURCE_ARGS=()
for source in "${SOURCES[@]}"; do
  SOURCE_ARGS+=(--sources "$source")
done

REPORT_FILE="$TARGET_DIR/report.txt"
EXPORT_FILE="$TARGET_DIR/export.json"

"$COV" report \
  "${OBJECTS[0]}" \
  -instr-profile="$TARGET_DIR/coverage.profdata" \
  -ignore-filename-regex="$IGNORE_RE" \
  "${SOURCE_ARGS[@]}" \
  -show-region-summary=false | tee "$REPORT_FILE"

"$COV" export \
  "${OBJECTS[0]}" \
  -instr-profile="$TARGET_DIR/coverage.profdata" \
  -ignore-filename-regex="$IGNORE_RE" \
  "${SOURCE_ARGS[@]}" \
  -skip-expansions \
  -skip-branches > "$EXPORT_FILE"

python3 - "$EXPORT_FILE" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
totals = data["data"][0]["totals"]

checks = {
    "lines": totals["lines"],
    "functions": totals["functions"],
}

failed = []
for name, values in checks.items():
    count = values["count"]
    covered = values["covered"]
    percent = values["percent"]
    if count == 0 or covered != count or round(percent, 2) != 100.0:
        failed.append(f"{name}: {covered}/{count} ({percent:.2f}%)")

if failed:
    print("coverage gate failed: " + "; ".join(failed), file=sys.stderr)
    sys.exit(1)

print("coverage gate passed: lines=100.00%, functions=100.00%")
PY
