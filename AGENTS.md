# Agent Instructions

本仓库根目录下的 `.env` 是本机私密环境文件。后续 agent 需要订阅信息、设备侧配置默认值或构建时私有变量时，先读取 `.env`。

`.env` 禁止提交、禁止写入补丁、禁止复制到文档、日志、issue、PR 描述或最终回复。回复用户时只能说明“已写入本地 `.env`”或引用变量名，不要回显订阅 URL、token、secret、password 等敏感值。

当前约定的订阅变量名：

- `MAGICNET_SINGBOX_SUBSCRIPTION_URL`：sing-box 订阅。

如果需要把订阅应用到真机运行配置，读取 `.env` 后写入设备上的：

- `/data/adb/modules/MagicNet/.config/sing-box/subscription.url`

通过 adb 给真机写入临时文件或中转补丁时，不要使用 `/data/local/tmp`。本设备该路径可能不可写。统一使用 `/sdcard/Download/MagicNet/` 作为中转目录，写入前 `mkdir -p /sdcard/Download/MagicNet`，任务结束后清理本次创建的临时文件，方便用户手动检查和清理。

修改代码或文档时继续遵守项目既有约束：不要恢复已删除的 TProxy、eBPF 或其他非 TUN 透明路径；当前主线只支持 sing-box `magicnet0` TUN。不要新增 `auto` 或 netd `ALLOW_MULTI` promote 路径，也不要假定 `cli ebpf status` 存在；真机状态以 `cli transparent status`、`cli health` 和 `magicnet0` 为准。
