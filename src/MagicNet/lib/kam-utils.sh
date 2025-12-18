# shellcheck shell=ash
##########################################################################################
#
# KAM - Cross-Root Manager Utility Library
# 跨 Root 管理器统一工具库
#
##########################################################################################
export MODDIR=${MODPATH:-${0%/*}}
# 环境变量
export PATH=${MODDIR}/.local/bin/:$PATH
export LD_LIBRARY_PATH=${MODDIR}/.local/lib/:$LD_LIBRARY_PATH
export HOME=${MODDIR}

# =============================================================================
# kam_load 按需加载工具库
# =============================================================================

# 按需加载模块
# 用法: kam_load "模块名" [更多模块名...]
kam_load() {
    [ $# -eq 0 ] && {
        echo "请指定要加载的模块" >&2
        return 1
    }

    # 获取 kam_utils 目录（以 MODDIR 作为模块根目录锚点）
    _kam_load_kam_utils_dir=""
    if [ -d "${MODDIR}/lib/kam_utils" ]; then
        _kam_load_kam_utils_dir="${MODDIR}/lib/kam_utils"
    elif [ -d "${MODDIR}/kam_utils" ]; then
        _kam_load_kam_utils_dir="${MODDIR}/kam_utils"
    else
        echo "错误: 无法找到 kam_utils 目录 (基于 MODDIR=${MODDIR})" >&2
        return 1
    fi

    # 使用 MODDIR（${0%/*}）作为模块根目录锚点；模块加载器使用本地变量在本函数内定位模块文件

    # 加载指定模块
    for module in "$@"; do
        # 检查是否已加载（防止重复加载）
        _kam_load_var_name="_KAM_MODULE_LOADED_$(echo "$module" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
        eval "_kam_load_is_loaded=\${${_kam_load_var_name}:-0}"
        if [ "$_kam_load_is_loaded" = "1" ]; then
            continue
        fi

        module_file="${_kam_load_kam_utils_dir}/${module}.sh"
        if [ -f "$module_file" ]; then
            . "$module_file" || {
                echo "加载模块失败: $module" >&2
                return 1
            }
            # 标记为已加载
            eval "${_kam_load_var_name}=1"
        else
            echo "模块不存在: $module (${module_file})" >&2
            return 1
        fi
    done
}

# Source internal implementation helper
# 用法: kam_source_impl <module>
# 示例: kam_source_impl navigation
kam_source_impl() {
    module="$1"

    # 使用 MODDIR 作为模块根目录锚点
    _kam_utils_dir="${MODDIR}/lib/kam_utils"
    # 兼容早期布局：kam_utils 可能直接位于模块根目录
    [ ! -d "${_kam_utils_dir}" ] && [ -d "${MODDIR}/kam_utils" ] && _kam_utils_dir="${MODDIR}/kam_utils"
    [ ! -d "${_kam_utils_dir}" ] && { echo "错误: 无法找到 kam_utils 目录 (基于 MODDIR=${MODDIR})" >&2; return 1; }

    impl_file="${_kam_utils_dir}/_${module}.sh"

    if [ -f "$impl_file" ]; then
        . "$impl_file" || { echo "错误: 无法加载内部实现: $impl_file" >&2; return 1; }
        return 0
    else
        echo "错误: 无法找到内部实现: $impl_file" >&2
        return 1
    fi
}

# =============================================================================
# 初始化函数
# =============================================================================

# 通用初始化
# 从 .kam 文件夹提取合适架构的二进制文件到对应目录
kam_init() {
    moddir="${MODDIR}"
    kam_dir="${moddir}/.kam"

    # 加载必需的基础模块
    # base 必须最先加载，因为其他模块依赖它
    kam_load base ui depends install detect || {
        echo "! Failed to load required modules" >&2
        return 1
    }

    # 检查 .kam 目录是否存在
    [ ! -d "$kam_dir" ] && return 0

    # 检测架构（使用检测模块）
    detect_arch >/dev/null 2>&1
    arch="${ARCH:-unknown}"

    # Per-prefix per-arch installation:
    # Support layout: .kam/<prefix>/<arch>/*  ->  <moddir>/<prefix>/*
    # e.g. .kam/system/bin/arm64/foo -> system/bin/foo
    if [ "$arch" != "unknown" ]; then
        # Preferred arch order: ARCH, ABI32 (if present), then generic fallbacks
        fallback_archs="$arch"
        [ -n "${ABI32:-}" ] && fallback_archs="$fallback_archs ${ABI32}"
        fallback_archs="$fallback_archs all universal any common"

        # record processed prefixes to avoid duplicate work (format :prefix1:prefix2:)
        processed_prefixes=":"

        # iterate directories up to a reasonable depth to discover prefixes
        for prefix_dir in "$kam_dir"/* "$kam_dir"/*/* "$kam_dir"/*/*/*; do
            [ -d "$prefix_dir" ] || continue

            base=$(basename "$prefix_dir")
            # skip if this directory itself is an arch directory (we want its parent as the prefix)
            case " $fallback_archs " in
                *" $base "*) continue ;;
            esac

            rel="${prefix_dir#$kam_dir/}"
            # avoid duplicate processing of same prefix (due to multiple globs)
            case ":$processed_prefixes:" in
                *":$rel:"*) continue ;;
                *) processed_prefixes="${processed_prefixes}${rel}:" ;;
            esac

            arch_found=0
            # try preferred arch dirs in order for this prefix
            for a in $fallback_archs; do
                if [ -d "${prefix_dir}/${a}" ]; then
                    arch_dir="${prefix_dir}/${a}"
                    dest="${moddir}/${rel}"
                    mkdir -p "$dest" 2>/dev/null || true

                    for src in "$arch_dir"/*; do
                        [ -f "$src" ] || continue
                        cp -f "$src" "$dest/" 2>/dev/null || true
                        case "$rel" in
                            */bin|bin|*/sbin|sbin)
                                chmod 755 "$dest/$(basename "$src")" 2>/dev/null || true
                                ;;
                            *)
                                chmod 644 "$dest/$(basename "$src")" 2>/dev/null || true
                                ;;
                        esac
                    done

                    arch_found=1
                    break
                fi
            done

            # if no arch-specific dir found, but this prefix contains files directly, treat as generic prefix
            if [ "$arch_found" -eq 0 ]; then
                has_files=0
                for f in "$prefix_dir"/*; do
                    [ -f "$f" ] && { has_files=1; break; }
                done

                if [ "$has_files" -eq 1 ]; then
                    dest="${moddir}/${rel}"
                    mkdir -p "$dest" 2>/dev/null || true

                    for src in "$prefix_dir"/*; do
                        [ -f "$src" ] || continue
                        cp -f "$src" "$dest/" 2>/dev/null || true
                        case "$rel" in
                            */bin|bin|*/sbin|sbin)
                                chmod 755 "$dest/$(basename "$src")" 2>/dev/null || true
                                ;;
                            *)
                                chmod 644 "$dest/$(basename "$src")" 2>/dev/null || true
                                ;;
                        esac
                    done
                fi
            fi
        done

        # Backwards-compatibility: legacy single-arch file at .kam/<arch>
        # Install into .local/bin so older modules still work.
        if [ -f "${kam_dir}/${arch}" ]; then
            mkdir -p "${moddir}/.local/bin" 2>/dev/null || true
            cp -f "${kam_dir}/${arch}" "${moddir}/.local/bin/" 2>/dev/null || true
            chmod 755 "${moddir}/.local/bin/$(basename "${kam_dir}/${arch}")" 2>/dev/null || true
        fi
    fi

}

# 通用结束函数
# 删除 .kam 文件夹
kam_end() {
    moddir="${MODDIR}"
    kam_dir="${moddir}/.kam"

    # 删除 .kam 目录
    [ -d "$kam_dir" ] && rm -rf "$kam_dir" 2>/dev/null
}

kam_load base
