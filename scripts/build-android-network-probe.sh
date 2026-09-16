#!/usr/bin/env bash
# Dependency-free test APK built with the installed, version-pinned Android SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prepare=0
if [[ "${1:-}" == --prepare-sdk ]]; then
    prepare=1
    shift
fi
[[ "$#" == 1 ]] || { echo 'Usage: build-android-network-probe.sh [--prepare-sdk] output.apk' >&2; exit 64; }
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
if [[ "$prepare" == 1 ]]; then
    manager="$SDK/cmdline-tools/latest/bin/sdkmanager"
    [[ -x "$manager" ]] || { echo 'Android command-line tools are missing from the configured SDK' >&2; exit 1; }
    timeout --kill-after=5s 180s "$manager" --sdk_root="$SDK" 'platforms;android-35' 'build-tools;35.0.0'
    # Hosted runners do not necessarily put Android command-line tools on PATH.
    # Export only the configured SDK for subsequent AVD steps, not an arbitrary
    # sdkmanager found elsewhere on the runner.
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$SDK/cmdline-tools/latest/bin" "$SDK/platform-tools" "$SDK/emulator" >> "$GITHUB_PATH"
    fi
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$SDK" "$SDK" >> "$GITHUB_ENV"
    fi
fi
TOOLS="$SDK/build-tools/35.0.0"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
OUT="${1:?Usage: build-android-network-probe.sh output.apk}"
for tool in aapt2 d8 zipalign apksigner; do
    test -x "$TOOLS/$tool" || { echo "missing Android build tool: $tool" >&2; exit 1; }
done
test -f "$ANDROID_JAR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/classes" "$WORK/dex" "$(dirname "$OUT")"
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
    -d "$WORK/classes" "$ROOT"/tests/android-probe/src/best/lmm/magicnet/probe/*.java
"$TOOLS/d8" --min-api 26 --lib "$ANDROID_JAR" --output "$WORK/dex" \
    "$WORK"/classes/best/lmm/magicnet/probe/*.class
"$TOOLS/aapt2" link -I "$ANDROID_JAR" --manifest "$ROOT/tests/android-probe/AndroidManifest.xml" \
    -o "$WORK/unsigned.apk"
(cd "$WORK/dex" && zip -q "$WORK/unsigned.apk" classes.dex)
"$TOOLS/zipalign" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
# Disposable test-only identity; never the module's production signing key.
keytool -genkeypair -keystore "$WORK/test.p12" -storetype PKCS12 -alias probe \
    -storepass test-only -keypass test-only -keyalg RSA -keysize 2048 -validity 2 \
    -dname 'CN=MagicNet Test Only' >/dev/null 2>&1
"$TOOLS/apksigner" sign --ks "$WORK/test.p12" --ks-key-alias probe \
    --ks-pass pass:test-only --out "$OUT" "$WORK/aligned.apk"
"$TOOLS/apksigner" verify "$OUT"
echo 'Built test-only Android application-UID probe'
