#!/bin/sh
# Linux install harness: keep archive extraction real, then substitute host
# executables for Android binaries explicitly requested by customize.sh.
# The archive itself is never edited. Android simulation uses the real payload.
set -eu
"${MAGICNET_TEST_HOST_UNZIP:?}" "$@"
_fixture_target=''
_fixture_next=0
_fixture_checkers=0
for _fixture_arg in "$@"; do
    if [ "$_fixture_next" = 1 ]; then
        _fixture_target=$_fixture_arg
        _fixture_next=0
    fi
    case "$_fixture_arg" in
        -d) _fixture_next=1 ;;
        bin/jq | bin/sing-box) _fixture_checkers=1 ;;
    esac
done
if [ "$_fixture_checkers" = 1 ] && [ -n "$_fixture_target" ]; then
    "${MAGICNET_TEST_HOST_CP:?}" "${MAGICNET_TEST_HOST_JQ:?}" "$_fixture_target/bin/jq"
    "$MAGICNET_TEST_HOST_CP" "${MAGICNET_TEST_HOST_SINGBOX:?}" "$_fixture_target/bin/sing-box"
fi
