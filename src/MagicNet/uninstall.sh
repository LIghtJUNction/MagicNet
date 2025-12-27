# shellcheck shell=ash

[ -f "${MODPATH}/lib/kamfw/.kamfwrc" ] && . "$MODPATH/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'
# 作者注：
# 啥也不干上面这行也不要删，用来自动清理残留文件
# 清理的是安装时自动提取到/data/adb/kam/bin的部分，其他的不管
#