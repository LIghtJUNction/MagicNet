#!/usr/bin/env bash
# Test-only Android curl; never replace a production payload or execute it here.
set -Eeuo pipefail
export LC_ALL=C
OUT="${1:?usage: prepare-android-public-curl.sh OUTPUT_DIRECTORY}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT/curl" "$OUT/cacert.pem" "$OUT/build-provenance.json"
WORK="$(mktemp -d)"
finish() {
    local result=$?
    trap - EXIT
    set +e
    ((result == 0)) || rm -f "$OUT/curl" "$OUT/cacert.pem" "$OUT/build-provenance.json"
    rm -rf "$WORK"
    exit "$result"
}
trap finish EXIT
fail() { printf '[public-curl] ERROR: %s\n' "$*" >&2; exit 1; }
for tool in curl python3 sha256sum make perl pkg-config readelf install timeout; do
    command -v "$tool" >/dev/null || fail "required host tool unavailable: $tool"
done
PKG_CONFIG_ABS="$(command -v pkg-config)"
JOBS="${MAGICNET_PUBLIC_CURL_JOBS:-2}"
[[ "$JOBS" =~ ^[1-8]$ ]] || fail 'build jobs must be 1..8'
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" && -d "${ANDROID_HOME:-/nonexistent}/ndk" ]]; then
    NDK="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
fi
NDK="${NDK:-/opt/android-ndk}"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -f "$NDK/source.properties" ]] || fail 'Android NDK identity unavailable'
for tool in x86_64-linux-android35-clang llvm-ar llvm-ranlib llvm-nm llvm-strip; do
    [[ -x "$TOOLS/$tool" ]] || fail "Android NDK target tool unavailable: $tool"
done
NDK_SHA="$(sha256sum "$NDK/source.properties" | cut -d ' ' -f 1)"
[[ -z "${MAGICNET_PUBLIC_CURL_NDK_SHA256:-}" || "$NDK_SHA" == "$MAGICNET_PUBLIC_CURL_NDK_SHA256" ]] ||
    fail 'Android NDK differs from the workflow fingerprint'

# Reviewed literal inputs. A cache is only a byte source; it cannot change pins.
CURL_SHA=f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7
OPENSSL_SHA=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
ZLIB_SHA=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
CA_SHA=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
CURL_URL=https://github.com/curl/curl/releases/download/curl-8_22_0/curl-8.22.0.tar.xz
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz
ZLIB_URL=https://zlib.net/fossils/zlib-1.3.2.tar.gz
CA_URL=https://curl.se/ca/cacert-2026-09-25.pem
fetch() {
    local name="$1" url="$2" digest="$3"
    if [[ -n "${MAGICNET_PUBLIC_CURL_SOURCE_CACHE:-}" && -f "$MAGICNET_PUBLIC_CURL_SOURCE_CACHE/$name" ]]; then
        cp "$MAGICNET_PUBLIC_CURL_SOURCE_CACHE/$name" "$WORK/$name"
    else
        timeout --kill-after=5s 240s curl -q --fail --location --silent --show-error \
            --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 180 \
            --retry 2 "$url" -o "$WORK/$name"
    fi
    printf '%s  %s\n' "$digest" "$WORK/$name" | sha256sum --check --strict
}
fetch curl-8.22.0.tar.xz "$CURL_URL" "$CURL_SHA"
fetch openssl-3.5.8.tar.gz "$OPENSSL_URL" "$OPENSSL_SHA"
fetch zlib-1.3.2.tar.gz "$ZLIB_URL" "$ZLIB_SHA"
fetch cacert-2026-09-25.pem "$CA_URL" "$CA_SHA"
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys
import tarfile
root = Path(sys.argv[1])
ca = (root / 'cacert-2026-09-25.pem').read_bytes()
if len(ca) != 188900 or ca.count(b'-----BEGIN CERTIFICATE-----') != 121:
    raise SystemExit('fixed CA bundle shape differs')
for name in ('curl-8.22.0.tar.xz', 'openssl-3.5.8.tar.gz', 'zlib-1.3.2.tar.gz'):
    with tarfile.open(root / name) as archive:
        members = archive.getmembers()
        if len(members) > 30000 or sum(max(0, m.size) for m in members) > 512 * 1024 * 1024:
            raise SystemExit('source archive exceeds budget')
        archive.extractall(root, members=members, filter='data')
PY
PREFIX="$WORK/prefix"
# Use only target libraries from our private prefix, never ambient host .pc files.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CC CXX AR RANLIB NM STRIP \
    PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR LIBRARY_PATH LD_LIBRARY_PATH LD_PRELOAD \
    CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH CONFIG_SITE CROSS_COMPILE CROSS_SYSROOT \
    MAKEFLAGS MAKEOVERRIDES MFLAGS GNUMAKEFLAGS
export ANDROID_NDK_ROOT="$NDK" PATH="$TOOLS:$PATH"
export CC="$TOOLS/x86_64-linux-android35-clang" AR="$TOOLS/llvm-ar"
export RANLIB="$TOOLS/llvm-ranlib" NM="$TOOLS/llvm-nm" STRIP="$TOOLS/llvm-strip"
export CFLAGS='-O2 -fPIC -ffunction-sections -fdata-sections'
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=''
export PKG_CONFIG="$PKG_CONFIG_ABS"
(
    cd "$WORK/zlib-1.3.2"
    timeout 60 ./configure --static --prefix="$PREFIX"
    timeout --kill-after=5s 180s make -j"$JOBS"
    timeout 60 make install
)
(
    cd "$WORK/openssl-3.5.8"
    # OpenSSL discovers its own Android clang wrapper from NDK+API; no host CC.
    CC=clang timeout 60 perl Configure android-x86_64 -D__ANDROID_API__=35 \
        no-shared no-module no-tests no-dso --prefix="$PREFIX" --libdir=lib \
        --openssldir=/nonexistent/magicnet-public-curl
    timeout --kill-after=5s 600s make -j"$JOBS" build_libs
    timeout 60 make install_dev
)
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -Wl,--gc-sections"
export LIBS='-lssl -lcrypto -lz -ldl'
(
    cd "$WORK/curl-8.22.0"
    timeout 180 ./configure --enable-option-checking=fatal --host=x86_64-linux-android \
        --with-pic --disable-shared --enable-static --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
        --with-ca-embed="$WORK/cacert-2026-09-25.pem" --without-ca-bundle --without-ca-path \
        --without-ca-fallback --disable-openssl-auto-load-config --without-libpsl --without-libidn2 \
        --without-brotli --without-zstd --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
        --without-quiche --disable-ares --enable-threaded-resolver --disable-ldap --disable-ldaps
    timeout --kill-after=5s 300s make -j"$JOBS"
    "$STRIP" src/curl
)
python3 - "$WORK/curl-8.22.0/src/curl" "$WORK/cacert-2026-09-25.pem" "$NDK/source.properties" \
    "$CC" "${BASH_SOURCE[0]}" "$WORK/build-provenance.json" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
binary, ca, ndk, compiler, builder, destination = map(Path, sys.argv[1:])
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def readelf(*args):
    return subprocess.run(['readelf', *args, str(binary)], text=True, capture_output=True,
                          check=True, timeout=10).stdout
header, segments, dynamic = readelf('-h'), readelf('-l'), readelf('-d')
if not (re.search(r'Class:\s+ELF64', header) and re.search(r'Data:.*little endian', header)
        and re.search(r'Type:\s+DYN\b', header) and re.search(r'Machine:.*X86-64', header)):
    raise SystemExit('curl is not an Android x86_64 PIE')
interpreters = re.findall(r'Requesting program interpreter: ([^\]]+)', segments)
needed = sorted(re.findall(r'Shared library: \[([^\]]+)\]', dynamic))
if (interpreters != ['/system/bin/linker64'] or 'libc.so' not in needed or len(needed) != len(set(needed))
        or not set(needed) <= {'libc.so', 'libm.so', 'libdl.so'}
        or re.search(r'\((?:RPATH|RUNPATH)\)', dynamic)):
    raise SystemExit('curl has an unsupported loader or dynamic dependency')
revision = re.search(r'^Pkg.Revision\s*=\s*([^\r\n]+)', ndk.read_text(), re.M)
if not revision:
    raise SystemExit('NDK revision unknown')
version = subprocess.run([str(compiler), '--version'], text=True, capture_output=True,
                         check=True, timeout=10).stdout.splitlines()[0]
report = {'schema': 1, 'scope': 'disposable-x86_64-public-curl', 'status': 'built',
    'target': {'os': 'android', 'abi': 'x86_64', 'api': 35},
    'versions': {'curl': '8.22.0', 'openssl': '3.5.8', 'zlib': '1.3.2'},
    'sources': {
        'curl': {'url': 'https://github.com/curl/curl/releases/download/curl-8_22_0/curl-8.22.0.tar.xz',
                 'sha256': 'f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7'},
        'openssl': {'url': 'https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz',
                    'sha256': 'a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2'},
        'zlib': {'url': 'https://zlib.net/fossils/zlib-1.3.2.tar.gz',
                 'sha256': 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'},
        'ca': {'url': 'https://curl.se/ca/cacert-2026-09-25.pem', 'sha256': digest(ca)}},
    'ca': {'mode': 'embedded', 'sha256': digest(ca), 'bytes': ca.stat().st_size, 'cert_count': 121,
           'runtime_bundle': False, 'system_store': False},
    'toolchain': {'ndk_revision': revision.group(1).strip(), 'ndk_source_properties_sha256': digest(ndk),
                  'compiler': version},
    'elf': {'interpreter': interpreters[0], 'needed': needed, 'rpath': False},
    'builder_sha256': digest(builder), 'curl_sha256': digest(binary), 'curl_bytes': binary.stat().st_size,
    'runtime_capability': 'not_tested'}
destination.write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
PY
install -m 0755 "$WORK/curl-8.22.0/src/curl" "$OUT/curl"
install -m 0644 "$WORK/cacert-2026-09-25.pem" "$OUT/cacert.pem"
install -m 0644 "$WORK/build-provenance.json" "$OUT/build-provenance.json"
printf '[public-curl] Android x86_64 ELF built; runtime HTTPS capability NOT TESTED\n'
