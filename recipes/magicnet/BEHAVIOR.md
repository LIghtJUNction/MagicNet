# 用户行为与端到端合同

## 首次成功

用户通过 root 管理器安装模块并重启；系统 Private DNS 应关闭。首次进入 WebUI 有订阅引导，可取消并稍后继续。用户输入一到五个公网 HTTPS 来源或导入本地内容；服务下载/解析候选、结构化合并、校验后才激活。
成功必须同时有受控 sing-box 进程、可用管理 API 与当前数据面证据；未配置、空节点、拒绝的格式、失败下载有可理解的结果，不能显示已代理。

## 日常工作

1. 概览区分进程、API、TUN/eBPF、配置意图与实际值，并提供显式启动、停止、重启、模式切换和热点选择。
2. 订阅支持 URL/本地来源原子切换、刷新、用量与到期信息、更新周期 off/12/24/48/72 小时、User-Agent、过滤规则。失败保留当前有效来源、配置和选择。
3. 节点列表、当前选择、延迟测试、自动 urltest、业务独立 selector、链式代理的前置节点/出口与 manual/auto；选择持久化，更新后消失的节点重建成合法候选。没有合格出口时 fail-closed。
4. 应用支持 proxy/direct/bypass、名单模式、搜索/批量设置；覆盖 Android 多用户、重装、共享 UID。proxy 强制代理；direct 经数据面走 direct；bypass 同时离开数据面与 MagicNet DNS 捕获。
   用户可按应用名称或域名配置出口，并通过结构化界面维护自定义具名策略组/出口；保存前预览范围，增量合并时保留订阅和系统托管规则。
5. Wi-Fi 名单支持 SSID/BSSID、blacklist/whitelist、启停和 3–300 秒间隔。blacklist 命中用 direct，其余 rule；whitelist 命中用 rule，其余 direct；disable 恢复 rule。
6. 热点 direct/proxy 不创建热点，不替代 OEM DHCP/NAT；下游消失是 pending。代理时持有的 offload 设置、路由和 TC 必须在停用/卸载时准确释放或恢复。
7. JSON 编辑器支持读取、格式化、校验并保存、模板仓库选择和同步；未保存草稿跨页面保留，刷新可丢失，离开前提示，不存浏览器持久存储。
8. 持久覆写使用 JSON Merge Patch；保存草稿与激活分开，支持 preview、expected_revision、reset、冲突和回滚。受控入站/API/热点字段不可篡改。
9. 网络设置 IPv6 策略、MTU、UDP 超时、DNS profile、捕获端口和 TUN CIDR；读接口分 configured/effective。默认双栈 prefer_ipv4、1400、5m、1053、172.19.0.1/30。端口/网段冲突必须诊断。
10. 应用网络限制恢复只操作用户审阅并确认的候选，展示所有共享身份的包；先检查，后显式 repair/reapply/rollback，不做开机或安装自动解禁。
11. 广告/域名规则、allow 例外、社区规则开关、路由域名 direct/proxy/block/warp、WARP WireGuard 导入和 rule/global 模式继续可用。
12. userspace Tailscale 不创建第二个 TUN；保留登录、暂停、恢复、显式本地登出和失败待清理状态。停用不等于登出，不删除自定义状态目录或云端账号。
13. 内嵌节点面板、代理组/连接/统计、关闭单连接/匹配连接/全部连接可用；流量和原始 API 数据按私密边界处理。
14. 健康、拓扑、DNS 测试、网络预检、日志、脱敏支持包、加密备份/恢复、终端命令保留；HTTP delay 不写成 ICMP ping。
15. eCapture tls/gotls/nspr/pcap 为用户主动发起的有界诊断；不安装 CA，不保证任意浏览器 TLS 明文；文件非空、捕获成功与进程启动分开。
16. MCP 默认关闭，独立 secret 认证；机器状态与 UI 一致，显式私密工具与自动脱敏资源分开。
17. 官方模块更新可检查、安装和恢复后台状态；成功 staging 只显示需重启，不能冒充已生效，也不自动重启。

## 操作菜单

终端编号+回车，空输入退出；管理器音量减选择、音量加确认。默认只读诊断；启动和停止独立。断网可能性的停止/订阅更新再次确认且默认取消。MAGICNET_NONINTERACTIVE=1 只显示状态，不阻塞等输入；失败退出码不能被刷新覆盖。

## 不包含的服务

MagicNet 不提供订阅、节点、出口账号、Android root、本地热点控制器、系统级 Tailscale 账号管理或通用远程 shell 服务。规则数据更新由新构建携带；普通订阅刷新不会偷偷改变上游分类数据。
