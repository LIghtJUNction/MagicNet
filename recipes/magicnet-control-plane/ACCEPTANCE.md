# 控制面验收

本表描述验收目标。各轮实际执行的子集与环境限制见根 VERIFICATION.md；原实现测量见 PERFORMANCE，不能据局部通过推断整表或设备业务通过。

1. --json 放头/尾各调用 capabilities，解析 stdout 恰好一个 schema-1；重复 flag/未知命令/service stop --json 返回非零结构化错误，不执行写命令。
2. 构造 PID 可见但 API 拒绝、API 正常但 TUN 缺失、PID 枚举失败、eBPF local attached 且 shared pending 的独立夹具；检查每层和 overall，不允许用一个 bool 覆盖未知。
3. 并发读取/发布 15 域，逐个 rename 注入失败；读不到半条文件，失败恢复已替换域；跨域读取走机器命令且不宣称全 OS 原子性。
4. 输入超大 JSON、FIFO、symlink、命令洪泛 stdout/stderr、保留 pipe 的孙进程、64 个卡住 helper、锁长期被持有；有界返回并清理可证明拥有的资源，不泄露秘密、不创建无限线程。
5. override 对象/数组/null、相同重放、旧 revision、外部改写和失败激活；检查 pending、conflict/busy/rollback_conflict 与原配置/用户停止意图。
6. MCP 未认证、错误协议、通知、重复/未知字段、私密文件 symlink、redact=false、generic 默认私密动作及 diagnose 尾参；拒绝前无运行副作用。
7. 在合成源、Wi-Fi、节点与错误里注入唯一 canary，扫描所有公共 JSON/canonical/resources/log tool 输出，不得出现 canary；explicit private inspector 只在对应明确调用返回必要数据。
8. 同一修改分别经人类 CLI、认证工具与 UI 调用，比较意图和 canonical；日志/状态刷新不得掩盖原失败退出码。
9. 执行 SUBSCRIPTION_INTERFACE.md 的 C-SUB-007 全部七组场景，覆盖 1/2/5 源跨入口一致性、候选与已提交数量分离、cache 文件数不当来源数、同名节点、owner/快照错误及公共 canary；capabilities 必须如实声明 subscription_batch_v1，旧版本回退和无历史批次的 null 独立验证。
10. batch 提交后仅 selector replay 失败时，退出码 0、committed、独立 warning 一致；UI 显示可重试警告，不能重复提交或谎称回滚。失败候选 index 仅映射同代冻结列表，重开没有候选时匿名显示。
