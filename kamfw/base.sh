# shellcheck shell=ash

# =============================================================================
# base.sh
# =============================================================================
# 注意：输出/错误处理的唯一事实来源是 lib/kamfw/.kamfwrc 提供的
# print/ui_print/abort。这里禁止再定义 kam_print/kam_error/kam_abort。
# =============================================================================


# 判断是否在交互式终端（TTY）中运行
is_tty() {
    # [ -t 0 ] 检查标准输入是否连接到终端
    # [ -t 1 ] 检查标准输出是否连接到终端
    if [ -t 0 ] || [ -t 1 ]; then
        return 0
    else
        return 1
    fi
}
if is_tty; then
    export COL_RED='\033[0;31m'
    export COL_GRN='\033[0;32m'
    export COL_YLW='\033[0;33m'
    export COL_BLU='\033[0;34m'
    export COL_PUR='\033[0;35m'
    export COL_CYN='\033[0;36m'
    export COL_RST='\033[0m'
    export ANSI_CURSOR_UP='\033[%dA'
    export ANSI_CLEAR_LINE='\033[2K\r'
else
    export COL_RED='╳'
    export COL_GRN='▚'
    export COL_YLW='◬'
    export COL_BLU='◈'
    export COL_PUR='║'
    export COL_CYN='┆'
    export COL_RST='❖'
    export ANSI_CURSOR_UP=''
    export ANSI_CLEAR_LINE=''
fi

x() {
    _n=${1:-1}
    if [ ! -t 0 ]; then
        _input=$(cat)
        printf "%${_n}s" | sed "s/ /${input}/g"
    fi
    unset _n _input
}

# NOTE: Logging helpers have been moved to `src/MagicNet/lib/kamfw/logging.sh`

wait_key() {
    _wkr_match_list="$*"
    _wkr_event=""
    _wkr_res=""

    while :; do
        _wkr_event=$(getevent -qlc 1 2>/dev/null | awk '$2~/0001|EV_KEY/ && $4~/00000001|DOWN/ {print $3; exit}')
        [ -z "$_wkr_event" ] && continue
        case "$_wkr_event" in
        KEY_VOLUMEUP | 0073) _wkr_res="up" ;;
        KEY_VOLUMEDOWN | 0072) _wkr_res="down" ;;
        KEY_POWER | 0074) _wkr_res="power" ;;
        KEY_MUTE | 0071) _wkr_res="mute" ;;
        KEY_F*) _wkr_res="f${_wkr_event#KEY_F}" ;;
        *) _wkr_res="" ;;
        esac

        if [ -n "$_wkr_res" ]; then
            if [ "$_wkr_match_list" = "any" ]; then
                print "$_wkr_res"
                break
            else
                case " ${_wkr_match_list} " in
                *" ${_wkr_res} "*)
                    print "$_wkr_res"
                    break
                    ;;
                esac
            fi
        fi
    done
    unset _wkr_match_list _wkr_event _wkr_res
}

wait_key_up() {
    wait_key "up"
}

wait_key_down() {
    wait_key "down"
}

wait_key_up_down() {
    wait_key "up" "down"
}

wait_key_power() {
    wait_key "power"
}

wait_key_mute() {
    wait_key "mute"
}

wait_key_f() {
    wait_key "f1" "f2" "f3" "f4" "f5" "f6" "f7" "f8" "f9" "f10" "f11" "f12"
}

# 用于“按任意键继续”
wait_key_any() {
    wait_key "any"
}

# 其他分支暂不计入
# 如有必要欢迎提交PR补全！
get_manager() {
    if [ -n "$_GM_CACHE" ]; then
        print "$_GM_CACHE"
        return 0
    fi

    _gm_type="unknown"
    if command -v magisk >/dev/null 2>&1; then
        _gm_type="magisk"
    elif [ -f "/data/adb/ksud" ] || command -v ksud >/dev/null 2>&1; then
        _gm_type="ksud"
    elif [ -f "/data/adb/apd" ] || command -v apd >/dev/null 2>&1; then
        _gm_type="ap"
    fi

    _GM_CACHE="$_gm_type"
    print "$_gm_type"
    unset _gm_type
}

is_magisk() {
    _im_mgr=$(get_manager)
    [ "$_im_mgr" = "magisk" ]
}

is_ksu() {
    _ik_mgr=$(get_manager)
    [ "$_ik_mgr" = "ksud" ]
}

is_ap() {
    _ia_mgr=$(get_manager)
    [ "$_ia_mgr" = "ap" ]
}
