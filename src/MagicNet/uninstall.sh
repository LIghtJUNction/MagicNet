# shellcheck shell=ash

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac
if [ -f "${MODDIR}/lib/kamfw/.kamfwrc" ]; then
    . "$MODDIR/lib/kamfw/.kamfwrc"
else
    abort '! File ".kamfwrc" does not exist!'
fi
# 作者注：
# 用来自动清理残留文件
import __uninstall__
