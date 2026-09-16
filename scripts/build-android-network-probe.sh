#!/usr/bin/env bash
# Dependency-free test APK built with the installed, version-pinned Android SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK is required}}"
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
