# shellcheck shell=ash

MODDIR=${0%/*}
if [ -f "${MODDIR}/lib/kamfw/.kamfwrc" ]; then
    . "$MODDIR/lib/kamfw/.kamfwrc"
else
    abort '! File ".kamfwrc" does not exist!'
fi
# 作者注：
# 用来自动清理残留文件
import __uninstall__
