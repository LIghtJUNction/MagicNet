# MCP 自动化说明

MagicNet 在 Android 模块内提供 Streamable HTTP MCP server，用于从工作站读取健康状态、管理配置和执行受控诊断。服务默认关闭，仅监听显式配置的地址，并要求 secret 认证。

项目 `.mcp.json` 只保存转发后的 endpoint：

```json
{
  "mcpServers": {
    "magicnet-device": {
      "url": "http://127.0.0.1:8766/mcp"
    }
  }
}
```

这个文件不是凭据存储。MCP 客户端必须通过自身支持的安全机制为请求附加 `Authorization: Bearer <secret>` 或 `X-MagicNet-MCP-Secret: <secret>`；不要把 secret 写入仓库，也不要向 `.mcp.json` 添加未经客户端文档确认的字段。

## 启用与端口转发

```bash
adb devices
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp enable 127.0.0.1 8766"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp status"'
adb forward tcp:8766 tcp:8766
adb forward --list
```

`status` 应显示 `enabled=1`、`secret_set=1` 和数字 PID。端口被其他进程占用时，状态会给出 `port_owner`；可以用 `cli mcp set <bind> <port>` 改为另一个本机端口后重新转发。

## 不回显 secret 的 curl 验证

以下命令把 secret 捕获到当前 shell 变量，不打印其值：

```bash
MCP_TEST_SECRET="$(adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp secret"' | tr -d '\r\n')"
curl -fsS http://127.0.0.1:8766/mcp \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${MCP_TEST_SECRET}" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
unset MCP_TEST_SECRET
```

不要使用 `set -x` 运行这段命令，也不要把含认证头的命令历史、终端录屏或日志贴到 Issue。

## Secret 轮换与日志

```bash
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp rotate-secret"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp status"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp logs 200"'
```

轮换会使旧客户端凭据立即失效；运行中的 server 会重启并读取新 secret。需要暂停自动化时执行 `cli mcp disable`。

## `magicnet-device` 启动失败检查

Codex 显示 `failed to start`、`handshaking ... initialize request` 或 `http://127.0.0.1:8766/mcp` 发送失败，表示工作站客户端没有完成到设备 MCP 的初始化。错误本身不能单独证明是 server 崩溃，按以下证据区分：

1. `adb devices`：确认目标设备在线且没有歧义；多设备时设置正确的 serial。
2. `cli mcp status`：`enabled=1` 且 `pid=<数字>`。`pid=stopped` 时查看 `cli mcp logs 200`，再执行 `cli mcp restart`。
3. `adb forward --list`：确认当前设备的 `tcp:8766` 转发存在。设备重启、USB 重连或 ADB server 重启后需要重新执行 `adb forward`。
4. 认证 curl：连接拒绝通常是服务/端口/转发问题；HTTP 401/403 是 secret 缺失或过期；成功返回工具列表说明设备端与转发正常。
5. 客户端认证：endpoint-only `.mcp.json` 不会自动携带 secret。确认所用 MCP 客户端确实通过其受支持的凭据机制发送认证头；轮换后同步更新客户端侧 secret。
6. 端口冲突：`cli mcp status` 的 `port_owner`、工作站 `ss -lntp` 和 `adb forward --list` 应指向预期进程与设备。

设备端与认证 curl 均正常但客户端仍无法初始化时，保留 `cli mcp logs 200`、客户端错误和不含 secret 的请求时间点，再提交 Issue。
