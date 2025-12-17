#!/bin/sh
# kam_load 使用示例

# 加载 kam-utils.sh
[ -f "$(dirname "$0")/lib/kam-utils.sh" ] && . "$(dirname "$0")/lib/kam-utils.sh" || exit 1

echo "=== kam_load 使用示例 ==="

# 示例 1: 按需加载基础模块
echo
echo "1. 加载基础模块："
kam_load base

# 使用基础模块的函数
msg "这是基础模块的 msg 函数"
newline

# 示例 2: 加载多个模块
echo
echo "2. 加载检测和等待模块："
kam_load detect wait

# 使用检测模块
msg "架构: $ARCH"
msg "Root 类型: $ROOT_TYPE"

# 使用等待模块
msg "等待网络连接..."
if wait_net 5; then
    msg "网络已连接"
else
    msg "网络连接超时"
fi

# 示例 3: 列出所有可用模块
echo
echo "3. 列出所有可用模块："
list_modules

# 示例 4: 显示已加载模块
echo
echo "4. 显示已加载模块："
list_loaded_modules

# 示例 5: 加载 UI 模块进行交互
echo
echo "5. 加载 UI 模块并进行交互："
kam_load ui

# 使用 UI 模块的函数
if confirm "要继续吗？"; then
    msg "用户选择了继续"
else
    msg "用户选择了取消"
fi