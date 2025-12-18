#!/system/bin/sh
# Termux Dialog 包装脚本 - 使用 Intent 绕过 socket 限制
# 用法: termux_dialog_wrapper.sh "标题" "提示" [默认值]

title="$1"
prompt="$2"
default="${3:-}"

# 创建临时文件
temp_file="/data/local/tmp/termux_dialog_$$"
result_file="/data/local/tmp/termux_dialog_result_$$"

# 清理函数
cleanup() {
    rm -f "$temp_file" "$result_file" 2>/dev/null || true
}

# 确保清理
trap cleanup EXIT

# 准备输入内容
cat > "$temp_file" << EOF
{
    "method": "text",
    "title": "$title",
    "text": "$prompt",
    "default": "$default"
}
EOF

# 使用 am 启动 Termux:API 对话框 Activity
am start -a com.termux.api.dialog.TextDialog \
    --es title "$title" \
    --es text "$prompt" \
    --es default "$default" \
    --ei request_id $$ \
    -e result_file "$result_file" \
    com.termux.api/.DialogActivity 2>/dev/null

# 等待结果
wait_count=0
max_wait=30

while [ $wait_count -lt $max_wait ]; do
    if [ -f "$result_file" ] && [ -s "$result_file" ]; then
        # 读取结果
        result=$(cat "$result_file")
        echo "$result"
        exit 0
    fi
    sleep 1
    wait_count=$((wait_count + 1))
done

# 超时，返回默认值
echo "$default"
exit 1