#  customize.sh 脚本说明
#
# 脚本功能：
# 1. 打印自定义安装过程的开始信息。
# 2. 检查设备架构，并根据架构类型打印相应信息或终止安装。
# 3. 检查 Android API 版本，确保版本在支持范围内，否则终.安装。
# 4. 设置指定文件和目录的权限。
# 5. 打印自定义安装过程的完成信息。
#
# 脚本详细说明：
# - ui_print: 用于在安装过程中打印信息到控制台。
# - case "$ARCH" in ... esac: 检查设备架构，支持 "arm", "arm64", "x86", "x64" 四种架构。
# - abort: 用于终止安装过程并打印错.信息。
# - if [ "$API" -lt 23 ]; then ... fi: 检查 Android API 版本，要求版本不低于 23。
# - set_perm: 设置单个文件的权限。
# - set_perm_recursive: 递归设置目录及其内容的权限。

# 打印信息到控制台
ui_print "开始安装$MODID"
ui_print "模块路径: $MODPATH"

# 检查设备架构
case "$ARCH" in
    "arm")
        ui_print "设备架构为 ARM 32位"
        abort "不支持32位设备架构: $ARCH"
        ;;
    "arm64")
        ui_print "设备架构为 ARM 64位"
        ;;
    "x86")
        ui_print "设备架构为 x86 32位"
        abort "不支持32位设备架构: $ARCH"
        ;;
    "x64")
        ui_print "设备架构为 x86 64位"
        ;;
    *)
        abort "不支持的设备架构: $ARCH"
        ;;
esac

ui_print "Android API 版本: $API"

if [ "$KSU" = "true" ]; then
  ui_print "- kernelSU version: $KSU_VER ($KSU_VER_CODE)"
  touch $MODPATH/ksu
  echo $KSU_VER > $MODPATH/ksu

elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "- APatch version: $APATCH_VER"
  ui_print "- KERNEL_VERSION: $KERNEL_VERSION"
  ui_print "- KERNELPATCH_VERSION: $KERNELPATCH_VERSION"
  touch $MODPATH/apatch
  echo $APATCH_VER > $MODPATH/apatch

else
  ui_print "- Magisk version: $MAGISK_VER ($MAGISK_VER_CODE)"
  mv $MODPATH/boot-completed.sh $MODPATH/service.sh
  touch $MODPATH/magisk
  echo $MAGISK_VER > $MODPATH/magisk
fi
# 应该很少有人同时安装两个吧

ui_print "模块目录: $MODPATH "
ui_print "给你3秒,请记住模块安装目录"
sleep 3

# 以上写的非常通用
# 可选
start(){
  pkg="$1"
  if [ -n "$pkg" ];then
    r=$(am start -d "$url" -p "$pkg" -a android.intent.action.VIEW 2>&1)
    else
    r=$(am start -d "$url" -a android.intent.action.VIEW 2>&1)
    fi
    echo "$r" | grep -q -v "Error"
    return $?
}

loc=$(getprop persist.sys.locale)

if echo "$loc" | grep -q "zh" && echo "$loc" | grep -q "CN"; then
url="https://github.com/LIghtJUNction/RootManage-Module-Model/tree/MagicNet"
pkg1="com.github.android"
ui_print "未经允许,禁止付费代刷 -- 仅供学习 -- 用户应该为自己行为负责 -- 安装本模块即代表你接受本协议 "
else
url="https://github.com/LIghtJUNction/RootManage-Module-Model/tree/MagicNet"
pkg1="com.github.android"
un_print "This module is intended for Chinese users. Do you want to install it? "
fi

ui_print "- [ Vol UP(+): Yes ] -- 按音量上（+）键 跳转到github仓库给作者一个star :)"
ui_print "- [ Vol DOWN(-): No ] -- 按音量下（-）键 取消跳转"

START_TIME=$(date +%s)
while true ; do
  NOW_TIME=$(date +%s)
  timeout 1 getevent -lc 1 2>&1 | grep KEY_VOLUME > "$TMPDIR/events"
  if [ $(( NOW_TIME - START_TIME )) -gt 9 ]; then
    ui_print "- 默认跳转 "
    start $pkg1 || start com.android.browser || start || ui_print "跳转失败"
    break
  elif $(cat $TMPDIR/events | grep -q KEY_VOLUMEUP); then
    ui_print "- 跳转"
    start $pkg1 || start com.android.browser || start || ui_print "跳转失败"
    break
  elif $(cat $TMPDIR/events | grep -q KEY_VOLUMEDOWN); then
    ui_print "- 取消"
    break
  fi
done

ui_print "如要使用yacd，请在模块安装目录下新建yacd文件并重启"

ui_print "如要使用sub_store可以安装MagicSub模块"


# 设置文件权限
set_perm_recursive $MODPATH 0 0 0755 0755
ui_print "感谢使用！关注我的公众号/加入我的qq群/关注我的酷安号：LIghtJUNction/以获取支持!"

ui_print "安装完成"

# 鸣谢



