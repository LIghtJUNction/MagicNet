# shellcheck shell=ash
# __runtime__.sh
# 统一生命周期运行时：负责 KAM_HOME 初始化、PATH/LD_LIBRARY_PATH、以及 phase 调度

# -----------------------------
# KAM_HOME / HOME 初始化
# Lead 定案：KAM_HOME = $MODDIR
# -----------------------------
kamfw_init_home() {
    # MODDIR 在入口脚本里通常已设置；这里做兜底
    if [ -z "$MODDIR" ]; then
        MODDIR=${0%/*}
        export MODDIR
    fi

    export KAM_HOME="$MODDIR"
    export HOME="$MODDIR"

    # 约定目录（类 XDG，但根是 $MODDIR）
    for _d in \
        "$KAM_HOME/.config" \
        "$KAM_HOME/.cache" \
        "$KAM_HOME/.state" \
        "$KAM_HOME/.log"; do
        [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
    done

    # .tmp is lazy: payload/cache/transaction owners create it when needed.
    # Only remove the unused legacy spelling when it is genuinely empty.
    rmdir "$KAM_HOME/tmp" 2>/dev/null || true
    unset _d
}

# -----------------------------
# PATH / LD_LIBRARY_PATH
# -----------------------------
kamfw_init_paths() {
    # Fixed root-safe paths only: never inherit an app-owned Termux PATH.
    export PATH="$MODDIR/bin:/data/adb/magisk:/data/adb/ksu/bin:/system/bin:/system/xbin:/sbin"

    export LD_LIBRARY_PATH="$MODDIR/lib"
}

# -----------------------------
# 生命周期调度（最小实现）
# 入口脚本应调用：kamfw run <phase> -- "$@"
# -----------------------------
kamfw() {
    _cmd="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$_cmd" in
    run)
        kamfw_run "$@"
        ;;
    help | -h | --help)
        printf '%s\n' "Usage: kamfw run <phase> -- [args...]"
        ;;
    *)
        # 兼容未来扩展
        # 关键路径：输出必须走统一通道；error 失败视为框架未初始化，直接 abort。
        error "Invalid kamfw command: $_cmd" || abort "Invalid kamfw command: $_cmd"
        return 1
        ;;
    esac

    unset _cmd
}

kamfw_run() {
    _phase="${1:-}"
    [ -n "$_phase" ] || {
        error "Missing phase" || abort "Missing phase"
        return 2
    }
    shift

    # 允许：kamfw run <phase> -- <args>
    if [ "${1:-}" = "--" ]; then
        shift
    fi

    kamfw_init_home
    kamfw_init_paths

    # Phase route: shell handlers are the runtime source of truth.
    case "$_phase" in
    install)
        import __install_core__
        kamfw_phase_install "$@"
        ;;
    post-fs-data)
        kamfw_phase_post_fs_data "$@"
        ;;
    service)
        kamfw_phase_service "$@"
        ;;
    boot-completed)
        kamfw_phase_boot_completed "$@"
        ;;
    uninstall)
        import __uninstall__
        kamfw_phase_uninstall "$@"
        ;;
    action)
        kamfw_phase_action "$@"
        ;;
    post-mount)
        kamfw_phase_post_mount "$@"
        ;;
    *)
        # 关键路径：输出必须走统一通道；error 失败视为框架未初始化，直接 abort。
        error "Unknown phase: $_phase" || abort "Unknown phase: $_phase"
        return 2
        ;;
    esac

    unset _phase
}

# -----------------------------
# 默认 phase 实现（模板最小可运行；业务可覆盖这些函数）
# -----------------------------
kamfw_phase_install() { :; }
kamfw_phase_post_fs_data() { :; }
kamfw_phase_service() { :; }
kamfw_phase_boot_completed() { :; }
kamfw_phase_uninstall() { :; }
kamfw_phase_action() { :; }
kamfw_phase_post_mount() { :; }
