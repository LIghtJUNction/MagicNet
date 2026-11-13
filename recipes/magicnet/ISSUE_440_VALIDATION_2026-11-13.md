# MagicNet #440：受信任 NAS 订阅修复与验证

## 交付结果

[#440](https://github.com/LIghtJUNction/MagicNet/issues/440) 所需的本地/NAS 订阅入口已实现。设备操作员可授权准确的协议、主机、端口和 CIDR，并选择直连或明确的 loopback SOCKS5 入口。默认公网 HTTPS 策略保持；此前已修复的订阅历史迁移继续保留。

实现提交为 [`magicnet-android@86828c8ae6c56e12f23330f551e6f2d9b41f8a38`](https://github.com/LIghtJUNction/magicnet-android/commit/86828c8ae6c56e12f23330f551e6f2d9b41f8a38)，tree 为 `706defefc0e51481f10c82c8149c1fc02ee836f5`，源码 [PR #8](https://github.com/LIghtJUNction/magicnet-android/pull/8) 已建立。该源码保留既有 `eca9ac8` 的 #436 相关修改。本文记录本地验证结果；CI、PR 合并和 Android 发布使用各自的实际状态。

## 使用方式

在设备 root shell 中执行以下命令。将示例 NAS 地址、端口和本地代理端口替换为自己的配置；完整订阅路径和 token 随后通过 WebUI 的私密输入传入。

```sh
magicnet_cli=/data/adb/modules/MagicNet/cli
trust_rules=$(printf '%s\n' 'http://100.100.1.2:25500 100.100.1.2/32 socks5://127.0.0.1:7892' | base64 | tr -d '\n')
"$magicnet_cli" sub trust set "$trust_rules"
unset trust_rules
```

上例对应 Issue 描述的“经手机本机代理访问 Tailnet NAS”。直连局域网服务器时省略第三列；每行是 `origin CIDR [proxy]`，最多 64 条、16 KiB。同一 origin 可以列出多个 CIDR，但路线须一致。使用 `/32` 或 `/128` 可将权限限定为单个地址。

撤销全部授权使用 `cli sub trust clear`，已保存订阅和有效配置保留。完整说明见源码的 [受信任订阅指南](https://github.com/LIghtJUNction/magicnet-android/blob/86828c8ae6c56e12f23330f551e6f2d9b41f8a38/docs/trusted-subscriptions.md)。

## 安全与兼容边界

授权同时约束来源与连接地址。清单只接受准确的 HTTP/HTTPS origin，以及完整位于 RFC1918、CGNAT、ULA 或 loopback 的规范 CIDR；不接受通配符、userinfo、路径、query、公网或 link-local/metadata 网段。每次请求、重试与跳转重新检查全部解析地址，再把已通过的地址固定给下载器。受信任链只允许同源跳转；公网链不会因跳转到已列入清单的目标而取得私网权限。

可选代理限定为明确端口的 literal loopback SOCKS5。目的地址仍由本机解析和校验，SOCKS5 接收已核对的数值 IP；HTTP Host 和 HTTPS 证书主机校验保持。SOCKS5h、HTTP/远端代理、环境代理和 `MAGICNET_SUB_PROXY` 继续拒绝。现有五跳、解压后 8 MiB、最高 120 秒及 TLS 证书检查保持。

CLI、WebUI、安装向导和刷新共用设备后端策略。HTTP 语法可进入校验，页面不自动写入授权；失败保留草稿和旧有效配置。信任清单保存在私有 `.config/sing-box/subscription-trust.list`，升级按既有统一迁移清单保留；公共状态、支持包和日志不披露清单或私密 URL。已有 `subscription-status` 历史按原字节迁移，缺失历史仍保持未记录。

信任授权只从已安装设备迁移，发行 ZIP 必须保持默认关闭。构建清理、组件拆包与最终包检查共同排除开发目录中的 `subscription-trust.list`，覆盖核心、完整包、安装别名及全部组件，防止新安装继承构建者的访问授权。

## 本地验证

下表分别记录实现、真实受控网络、前端与安装层；这些计数不合并成设备端到端测试数量。

| 检查 | 实际结果 | 证据与范围 |
| --- | --- | --- |
| Rust workspace 测试 | 932 通过（864 单元 + 68 集成），1 项既有 Android 专项忽略 | 覆盖来源授权、CIDR、代理路线、旧公网入口、机器接口和订阅事务 |
| Clippy | workspace / all-targets，`-D warnings` 通过 | 当前源码的所有 Rust 目标 |
| 新可信来源集成 | 15/15 通过，46.761 秒 | [test-subscription-trusted-source.py](https://github.com/LIghtJUNction/magicnet-android/blob/86828c8ae6c56e12f23330f551e6f2d9b41f8a38/scripts/test-subscription-trusted-source.py)：生产 CLI、Shell 下载器、真实本地 HTTP/TLS/SOCKS5；含 CGNAT 目标经 loopback 代理的数值地址握手、同源跳转、跨源拒绝、混合地址、撤销授权、安装向导 handler 与敏感信息清理 |
| 既有下载保护 | fetch-policy 通过；TLS/network 10/10 通过，17.790 秒 | [fetch-policy](https://github.com/LIghtJUNction/magicnet-android/blob/86828c8ae6c56e12f23330f551e6f2d9b41f8a38/scripts/test-subscription-fetch-policy.sh) 与 [network](https://github.com/LIghtJUNction/magicnet-android/blob/86828c8ae6c56e12f23330f551e6f2d9b41f8a38/scripts/test-subscription-network.py) 保留默认公网、TLS、重定向和资源边界 |
| WebUI | `npm run check`：390 通过，0 失败，0 跳过；vue-tsc 与 Vite build 通过 | Node 行为测试、类型检查与生产构建；本条不包含 Android 浏览器视觉验收 |
| 发布授权隔离 | 3/3 受影响打包用例通过，4.962 秒 | 所有发行 ZIP 剔除构建机 trust；重注入时 split 与最终包检查拒绝；设备升级保留自己的 trust/history |
| 打包升级 | core/full/installer 三个真实 ZIP 的迁移用例通过，11.765 秒 | [installer lifecycle](https://github.com/LIghtJUNction/magicnet-android/blob/86828c8ae6c56e12f23330f551e6f2d9b41f8a38/scripts/test-kernelsu-installer-lifecycle.py) 在宿主 `sh` 执行；trust/history 原字节与 0600 权限保留，当前更新锁不恢复 |

真实网络夹具运行在隔离宿主，使用本地测试服务和证书；CGNAT 目标由测试 SOCKS5 服务映射到受控 HTTP 服务。地址校验、下载执行器和 SOCKS5 握手使用生产路径，地址覆盖与重绑定负例含受控解析数据。安装向导执行真实 handler 和 CLI，文件工具适配宿主环境。

本轮没有接入用户 NAS、真实私密订阅或物理 Android 手机，也没有部署或发布新版。现有稳定发行仍由主仓库 `update.json` 与 Releases 指定。#436 的设备根因和完整 Android 验收保持原有范围，本修复不扩大相关结论。

## 配方集成

根配方更新为 `0.3.22`，M69 统一映射 runtime `SUB-016 / SUB-A23–A26`、control `C-SUB-009`、WebUI `UI-SUB-013` 及安装迁移合同。源码 gitlink、三语 README、BUILD_PROMPT、DEPENDENCIES 和发布复用工作流须固定为同一源码 SHA。

配方检查器的 15 项回归和 release-plan 的 41 项回归均通过。材料验证已完成 `check → pack → 归档 check → 完整 build prompt`；最终集成提交后再次执行 `scripts/check-recipes.py`，核对 HEAD gitlink 与全部活动文本 pin。
