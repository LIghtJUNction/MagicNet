# 文件即状态

.config 持久化用户意图；.state/machines/<domain>.state 是每域唯一 public canonical；其他 journal/PID/owner/cache/probe 只作为恢复与观测输入；.log 是诊断历史。
固定域：service、transparent、subscription、subscription-refresh、selectors、app-policy、supervisors、wifi、hotspot、dns、mcp、tailscale、transactions、overrides、module-update。每个文件 schema=1，有界 key=value token，字段分别表达 configured、observed、phase、ownership；不把所有事实挤进 running。

任何状态写入必须先 reconcile 外部事实：准确进程身份、接口、cgroup、TC、路由/防火墙。枚举失败 unknown，等待外部条件 pending，旧观测 stale。驻留 producer 内部状态变动后主动 publish，不能等退出才发布；普通生命周期写操作结束 reconcile。
每文件 staged/synced 原子替换。跨域先完整计算、stage/sync，再逐个提交；后续替换失败回滚已替换文件。多个 rename 对无锁读者并不同时可见，需要跨域快照使用机器接口，其底层 OS 探测也不是全系统瞬时原子观察。

canonical 不含订阅 URL、SSID/BSSID、selector/node 名、原始 UID、token/secret/password/auth key、原始 reason、完整配置或命令输出。用布尔、计数、规范化 token。
selector 用户选择在 .config/magicnet/selector-selections.json；旧 .state 路径仅迁移输入。替换旧状态入口必须先迁 producer/consumer、补行为回归、确认恢复不依赖，再删除旧路径。
WebUI 展示按钮、对话框、未保存草稿留内存；任何跨 WebUI 生命周期的后台操作必须有设备文件证据并投影到 canonical。
journal 留下旧配置、原资源值和准确 ownership，不代表可以当成第二个公共状态。支持包不导出私密恢复内容。

## 必须区分的事实

保存的意图≠物化配置≠运行指纹≠API ready≠数据面 ready≠真实 App 网络可用。
Tailscale enabled/resumable/logout_pending 与是否在线分开。
module-update accepted/installer exited/staged/reboot_required 与 effective installed version 分开。
网络策略 configured_verified 只表示 setter 后 API readback 一致，不表示 Play Store/DNS/下载可用。

订阅当前已提交来源数、失败候选来源数、source缓存文件数、节点数和套餐记录行数分别是不同事实。subscription_batch_v1 使用机器接口表达同 generation 的多字段视图，不新增第二份 public marker 来让客户端自行拼凑。来源列表读取错误不能发布成零来源成功；恢复中和未知 owner 的规则见 SUBSCRIPTION_INTERFACE.md。
