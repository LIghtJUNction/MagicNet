# Agent Instructions

本仓库根目录下的 `.env` 是本机私密环境文件。后续 agent 需要订阅信息、设备侧配置默认值或构建时私有变量时，先读取 `.env`。

`.env` 禁止提交、禁止写入补丁、禁止复制到文档、日志、issue、PR 描述或最终回复。回复用户时只能说明“已写入本地 `.env`”或引用变量名，不要回显订阅 URL、token、secret、password 等敏感值。

当前约定的订阅变量名：

- `MAGICNET_SINGBOX_SUBSCRIPTION_URL`：sing-box 订阅。

如果需要把订阅应用到真机运行配置，读取 `.env` 后写入设备上的：

- `/data/adb/modules/MagicNet/.config/sing-box/subscription.url`

通过 adb 给真机写入临时文件或中转补丁时，不要使用 `/data/local/tmp`。本设备该路径可能不可写。统一使用 `/sdcard/Download/MagicNet/` 作为中转目录，写入前 `mkdir -p /sdcard/Download/MagicNet`，任务结束后清理本次创建的临时文件，方便用户手动检查和清理。

修改代码或文档时遵守以下透明代理约束：主线显式支持 sing-box `tun`（`magicnet0`）和 `ebpf`（`type: "ebpf"` inbound）两种模式，默认仍为 `tun`，只允许 `tun|ebpf`，不新增 `auto`，不恢复 TProxy、Redirect 或 netd `ALLOW_MULTI` 路径。模式切换必须显式、原子且可回滚。`tun` 模式以 `magicnet0` 为准；`ebpf` 模式以 capability、cgroup 和 TC attachment 状态为准，不得错误要求 `magicnet0` 存在。统一通过 `cli transparent status` 和 `cli health` 报告状态，不假定存在 `cli ebpf status`。
