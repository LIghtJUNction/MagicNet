# shellcheck shell=ash
# binstall.sh
#
# Helper: binstall
#
# Purpose:
#   Download / extract / install a binary to a target location.
#   Designed to be flexible (direct URL or GitHub release asset).
#   POSIX/ash compatible; does NOT use 'local'.
#
# Usage (examples):
#   # simple direct URL (no extraction)
#   binstall --name mihomo --target "$MODPATH/bin" --url "https://example.com/mihomo" --chmod 0755
#
#   # github release (latest tag), asset name may contain ${TAG} and ${ARCH} placeholders
#   binstall --name mihomo --target "$MODPATH/bin" \
#       --repo MetaCubeX/mihomo --asset "mihomo-${ARCH}-${TAG}.gz" --arch android-arm64-v8 \
#       --chmod 0755 --version-file "$MODPATH/mihomo.version"
#
# Notes:
# - Uses `curl` for download; `gh` optional for resolving latest tag.
# - Supports simple archives: gzip (.gz), tar.gz/.tgz, zip.
# - All user-visible text uses i18n keys declared below.
#
# Quick verification:
# 1. In a shell: export MODPATH="$PWD/src/MagicNet" ; . "$MODPATH/lib/kamfw/.kamfwrc" ; import binstall
# 2. Try a dry-run: binstall --name test --target /tmp/bin --url http://example.com/binary --dry-run
# 3. Try a full run with a known small asset.
#

set_i18n "BINSTALL_MISSING_CURL" \
    "zh" "缺少下载工具：curl，无法继续" \
    "en" "Required tool 'curl' not found; cannot download"

set_i18n "BINSTALL_MISSING_GH" \
    "zh" "缺少 GitHub CLI：gh，无法检测最新 release" \
    "en" "Required tool 'gh' not found; cannot query GitHub releases"

set_i18n "BINSTALL_NO_URL_OR_REPO" \
    "zh" "未提供 URL 或 GitHub 仓库/asset 信息" \
    "en" "No URL or GitHub repo/asset information provided"

set_i18n "BINSTALL_DOWNLOAD_FAILED" \
    "zh" '下载失败：$_1' \
    "en" 'Download failed: $_1'

set_i18n "BINSTALL_EXTRACT_FAILED" \
    "zh" '解压失败：$_1' \
    "en" 'Extract failed: $_1'

set_i18n "BINSTALL_INSTALL_OK" \
    "zh" '安装完成: $_1' \
    "en" 'Installed: $_1'

set_i18n "BINSTALL_WRITING_VERSION" \
    "zh" '写入版本文件: $_1' \
    "en" 'Writing version file: $_1'

# -----------------------------------------------------------------------------
# binstall: main function
# -----------------------------------------------------------------------------
# Options (posix style):
#   --name NAME               final binary name in target dir (required)
#   --target DIR              target directory to place binary (required)
#   --url URL                 direct download URL (mutually exclusive with --repo)
#   --repo owner/repo         github repo (use with --asset and optional --tag)
#   --tag TAG                 release tag; if omitted and --repo used, will query 'latest'
#   --asset ASSET_PATTERN     asset filename (can include ${TAG}, ${ARCH})
#   --arch ARCH               optional arch placeholder for asset
#   --result-name FILENAME    explicitly set extracted filename inside archive
#   --chmod MODE              permission, default 0755
#   --version VERSION         version string to write (or use tag when --repo used)
#   --version-file FILE       path to version file to write
#   --tmpdir DIR             temp dir base (default $TMPDIR or /tmp)
#   --dry-run                do not perform actions, just print steps
#   --no-clean               keep tempdir for debugging
# -----------------------------------------------------------------------------
binstall() {
    # parse args
    _name=""
    _target=""
    _url=""
    _repo=""
    _tag=""
    _asset=""
    _arch=""
    _result_name=""
    _chmod="0755"
    _version=""
    _version_file=""
    _tmpbase="${TMPDIR:-/tmp}"
    _dryrun=false
    _noclean=false

    while [ $# -gt 0 ]; do
        case "$1" in
        --name)
            _name="$2"
            shift 2
            ;;
        --target)
            _target="$2"
            shift 2
            ;;
        --url)
            _url="$2"
            shift 2
            ;;
        --repo)
            _repo="$2"
            shift 2
            ;;
        --tag)
            _tag="$2"
            shift 2
            ;;
        --asset)
            _asset="$2"
            shift 2
            ;;
        --arch)
            _arch="$2"
            shift 2
            ;;
        --result-name)
            _result_name="$2"
            shift 2
            ;;
        --chmod)
            _chmod="$2"
            shift 2
            ;;
        --version)
            _version="$2"
            shift 2
            ;;
        --version-file)
            _version_file="$2"
            shift 2
            ;;
        --tmpdir)
            _tmpbase="$2"
            shift 2
            ;;
        --dry-run)
            _dryrun=true
            shift
            ;;
        --no-clean)
            _noclean=true
            shift
            ;;
        --help | -h)
            print "Usage: binstall --name NAME --target DIR [--url URL | --repo REPO --asset ASSET [--tag TAG]] [options]"
            return 0
            ;;
        *)
            # unknown, skip
            shift
            ;;
        esac
    done

    [ -n "$_name" ] || abort 'binstall: --name required'
    [ -n "$_target" ] || abort 'binstall: --target required'

    # ensure target dir
    mkdir -p "$_target" 2>/dev/null || abort "binstall: cannot create target dir $_target"

    # Determine download URL
    if [ -n "$_url" ]; then
        _download_url="$_url"
        _resolved_tag="${_version:-}"
    elif [ -n "$_repo" ]; then
        # need asset
        [ -n "$_asset" ] || abort "$(i18n 'BINSTALL_NO_URL_OR_REPO' 2>/dev/null || echo 'No URL or repo/asset provided')"

        # determine tag (if not set, query latest via gh)
        if [ -z "$_tag" ] || [ "$_tag" = "latest" ]; then
            if ! command -v gh >/dev/null 2>&1; then
                abort "$(i18n 'BINSTALL_MISSING_GH' 2>/dev/null || echo 'gh missing')"
            fi
            _tag="$(gh release view --repo "$_repo" --json tagName --template '{{.tagName}}' 2>/dev/null || true)"
            [ -n "$_tag" ] || abort "binstall: failed to query latest tag for $_repo"
        fi
        _resolved_tag="$_tag"

        # substitute placeholders in asset
        _assetname="$(printf '%s' "$_asset" | sed -e \"s | \\\${TAG} | $_tag | g\" -e \"s | \\\${ARCH} | $_arch | g\")"
        _download_url="https://github.com/${_repo}/releases/download/${_tag}/${_assetname}"
    else
        abort "$(i18n 'BINSTALL_NO_URL_OR_REPO' 2>/dev/null || echo 'No URL or repo info provided')"
    fi

    info "Downloading: $_download_url"

    # check curl
    if ! command -v curl >/dev/null 2>&1; then
        abort "$(i18n 'BINSTALL_MISSING_CURL' 2>/dev/null || echo 'curl missing')"
    fi

    # prepare tmp dir
    _tmpdir="$(mktemp -d "${_tmpbase}/binstall.XXXXXX" 2>/dev/null || mktemp -d 2>/dev/null || printf '%s' '')"
    if [ -z "$_tmpdir" ]; then
        abort 'binstall: failed to create tmpdir'
    fi

    _outname="$(basename "$_download_url")"
    _outfile="$_tmpdir/$_outname"

    if [ "$_dryrun" = true ]; then
        info "DRY-RUN: would download $_download_url -> $_outfile"
        info "DRY-RUN: would extract/copy and place as $_target/$_name (chmod $_chmod)"
        if [ -n "$_version_file" ] && [ -n "$_resolved_tag" ]; then
            info "$(i18n 'BINSTALL_WRITING_VERSION' 2>/dev/null | t \"$_version_file\" 2>/dev/null || printf 'Would write version to %s' \"$_version_file\")"
        fi
        [ "$_noclean" = false ] && rm -rf "$_tmpdir" 2>/dev/null || true
        return 0
    fi

    # download
    if ! curl -L -o "$_outfile" "$_download_url"; then
        rm -rf "$_tmpdir" 2>/dev/null || true
        abort "$(i18n 'BINSTALL_DOWNLOAD_FAILED' 2>/dev/null | t \"$_download_url\" 2>/dev/null || printf 'Download failed: %s' \"$_download_url\")"
    fi

    # decide extraction or direct install
    _type="none"
    case "$_outfile" in
    *.tar.gz | *.tgz) _type="tar.gz" ;;
    *.zip) _type="zip" ;;
    *.gz) _type="gz" ;;
    *) _type="none" ;;
    esac

    _final_file=""
    case "$_type" in
    gz)
        if ! command -v gunzip >/dev/null 2>&1; then
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t 'gunzip missing' 2>/dev/null || printf 'gunzip missing')"
        fi
        if ! gunzip -f "$_outfile"; then
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t \"$_outfile\" 2>/dev/null || printf 'Extract failed: %s' \"$_outfile\")"
        fi
        _final_file="$_tmpdir/$(basename "$_outfile" .gz)"
        ;;
    tar.gz)
        if ! command -v tar >/dev/null 2>&1; then
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t 'tar missing' 2>/dev/null || printf 'tar missing')"
        fi
        if ! tar -xzf "$_outfile" -C "$_tmpdir" 2>/dev/null; then
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t \"$_outfile\" 2>/dev/null || printf 'Extract failed: %s' \"$_outfile\")"
        fi
        # if result name given use it; otherwise pick single file if only one
        if [ -n "$_result_name" ]; then
            _final_file="$_tmpdir/$_result_name"
        else
            _count="$(find "$_tmpdir" -maxdepth 1 -type f | wc -l 2>/dev/null || true)"
            if [ "$_count" = "1" ]; then
                _final_file="$(find "$_tmpdir" -maxdepth 1 -type f | head -n1)"
            else
                # try to pick a file without extension .sha etc, otherwise fail
                _final_file="$(find "$_tmpdir" -maxdepth 1 -type f ! -name '*.sha*' ! -name '*.sig' | head -n1)"
                if [ -z "$_final_file" ]; then
                    rm -rf "$_tmpdir" 2>/dev/null || true
                    abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t \"multiple files\" 2>/dev/null || printf 'Multiple files in archive; specify --result-name')"
                fi
            fi
        fi
        ;;
    zip)
        if ! command -v unzip >/dev/null 2>&1 && ! command -v zipinfo >/dev/null 2>&1; then
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t 'unzip missing' 2>/dev/null || printf 'unzip missing')"
        fi
        if command -v unzip >/dev/null 2>&1; then
            unzip -o "$_outfile" -d "$_tmpdir" >/dev/null 2>&1 || {
                rm -rf "$_tmpdir" 2>/dev/null || true
                abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t \"$_outfile\" 2>/dev/null || printf 'Extract failed: %s' \"$_outfile\")"
            }
        else
            rm -rf "$_tmpdir" 2>/dev/null || true
            abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t 'unzip missing' 2>/dev/null || printf 'unzip missing')"
        fi
        if [ -n "$_result_name" ]; then
            _final_file="$_tmpdir/$_result_name"
        else
            _final_file="$(find "$_tmpdir" -maxdepth 1 -type f | head -n1)"
        fi
        ;;
    none)
        _final_file="$_outfile"
        ;;
    esac

    [ -n "$_final_file" ] || {
        rm -rf "$_tmpdir" 2>/dev/null || true
        abort "$(i18n 'BINSTALL_EXTRACT_FAILED' 2>/dev/null | t 'no final file' 2>/dev/null || printf 'No final file')"
    }

    # Apply final name and move to target
    _dest="$_target/$_name"
    if mv -f "$_final_file" "$_dest" 2>/dev/null; then
        chmod "$_chmod" "$_dest" 2>/dev/null || chmod a+x "$_dest" 2>/dev/null || true
        success "$(i18n 'BINSTALL_INSTALL_OK' 2>/dev/null | t "$_dest" 2>/dev/null || printf 'Installed: %s' "$_dest")"
        # write version if requested (prefer explicit --version, else use tag if present)
        if [ -n "$_version_file" ]; then
            _v="${_version:-${_resolved_tag:-}}"
            if [ -n "$_v" ]; then
                printf '%s\n' "$_v" >"$_version_file" 2>/dev/null || true
                info "$(i18n 'BINSTALL_WRITING_VERSION' 2>/dev/null | t \"$ _version_file\" 2>/dev/null || printf 'Writing version file: %s' \"$ _version_file\")"
            fi
        fi
    else
        rm -rf "$_tmpdir" 2>/dev/null || true
        abort "$(i18n 'BINSTALL_DOWNLOAD_FAILED' 2>/dev/null | t \"move failed\" 2>/dev/null || printf 'Move failed')"
    fi

    # cleanup
    if [ "$_noclean" = false ]; then
        rm -rf "$_tmpdir" 2>/dev/null || true
    else
        info "binstall: tmpdir kept: $_tmpdir"
    fi

    # unset temporary vars
    unset _name _target _url _repo _tag _asset _arch _result_name _chmod _version _version_file _tmpbase \
        _download_url _resolved_tag _tmpdir _outname _outfile _type _final_file _dest _v _cmd

    return 0
}
