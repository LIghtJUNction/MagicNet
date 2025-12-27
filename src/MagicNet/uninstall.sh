# shellcheck shell=ash

[ -f "${MODPATH}/lib/kamfw/.kamfwrc" ] && . "$MODPATH/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'
# 作者注：
# 用来自动清理残留文件
import __uninstall__
