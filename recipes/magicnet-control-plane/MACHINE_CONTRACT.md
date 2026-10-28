# schema-1 机器合同

成功：schema=1、ok=true、command 为规范化命令名、data 为对象。失败：schema=1、ok=false、command、error.code、error.message；退出非零。输出前后不得有 banner、进度或第二个 JSON。重复 --json、未知命令/尾随参数必须是结构化失败。

service.status 分开报告受控进程 running/stopped/unknown、API.ready、readiness.dataplane 和 readiness.overall；仅两者已证实正常才整体 ready。生命周期包括 stopped/unknown/reconfiguring/ready/not_ready/running_unknown。前端不得自行按 PID 推断绿色状态。
tun 看 sysfs magicnet0；ebpf 刷新活动程序并检查当前进程的 cgroup/TC attachment，不拿能力探测冒充实际挂载。
hybrid 无下游时 local 可 ready，shared_tc=pending、shared_ready=false；配置了下游则必须全部验证。shared-only 缺下游不能 ready。local/shared 信号未知用 null，旧版本能力未协商不猜测。

## 私密边界

sub.status 只返回来源类型、计数、事务/刷新状态、reason 是否存在与合计；wifi.status 只有匹配/连接事实和名单计数。
sub.inspect 才含 URL、User-Agent、过滤器和提供者用量；wifi.inspect 才含 SSID/BSSID 编辑值。明确用户请求后安静读取，不能附到通用诊断、命令捕获或报错文本。
network-access.inspect 的包身份/候选也是私密。状态不返回原始 UID、节点名、凭据或失败原文。
用量按 URL 的摘要关联，不按列表位置；待提交事务不展示新用量；generation 或 URL 改变时拒绝混合快照。

## override 写协议

对象遵守 JSON Merge Patch：对象递归 merge，数组整体替换，null 删除，空对象 reset。
status 脱敏；inspect 读私密 patch/revision；preview-file 仅校验并给脱敏变化摘要；set-file/reset-file 需要 expected_revision；apply-file/apply 激活已保存版本。payload 经有界私密文件传递。
相同意图重复写不递增版本；stale 不同写 override.conflict；锁到期 override.busy。保护管理入站、API、hotspot selector、自动来源规则和 cache-file 等受控值。
.config/magicnet/config-override.json 保存草稿，config-override-active.json 保存选中意图。checkpoint 先去掉上次 patch，再应用当前 patch，保留新订阅与其他写者的新 base。
保存与运行分开；验证失败零写入。激活失败仅在 revision/内容证明归属时恢复 config/checkpoint，遇外部冲突报 override.rollback_conflict；保存意图仍 pending，失败版本不自动死循环重试。显式停止的核心保持停止。

## 多来源精确合同与增量能力

订阅字段、旧入口、公共/私密边界及本轮新增 subscription_batch_v1 的完整定义见 [SUBSCRIPTION_INTERFACE.md](SUBSCRIPTION_INTERFACE.md)。下列快照是旧实现的观察证据，不含该新增 feature；重建必须添加并实际协商它。保持 schema=1，旧字段语义不变，不增加未经设计的机器写入口。

## 稳定能力快照

下列 JSON 是本次运行固定源码的 release CLI 得到的完整公共 capabilities，不是手写假定。重建者必须实现这些能力或给出显式版本迁移，不能静默删除例外写接口。

~~~json
{
  "command": "machine.capabilities",
  "data": {
    "commands": [
      "app.inspect",
      "service.status",
      "core.status",
      "supervisor.status",
      "transparent.status",
      "dns.status",
      "network.status",
      "network.preflight",
      "network-access.status",
      "network-access.inspect",
      "network-access.check",
      "network-access.repair",
      "network-access.reapply",
      "network-access.rollback",
      "sub.status",
      "sub.inspect",
      "wifi.status",
      "wifi.inspect",
      "hotspot.status",
      "machine.capabilities",
      "tailscale.status",
      "override.status",
      "override.inspect",
      "override.preview",
      "override.set",
      "override.reset",
      "override.apply",
      "module-update.status",
      "module-update.check",
      "module-update.install"
    ],
    "features": [
      "versioned_envelope",
      "structured_errors",
      "redacted_status",
      "configured_effective_split",
      "privacy_safe_network_identifiers",
      "readiness_signals",
      "transparent_plane_readiness",
      "dns_capture_preflight",
      "additive_routing_overlay"
    ],
    "json_flag_positions": [
      "prefix",
      "suffix"
    ],
    "machine_schema": 1,
    "module_update_install": "detached-worker-staged-reboot-required",
    "module_update_source": "official-stable-github-release",
    "mutation_commands": [
      "override.preview",
      "override.set",
      "override.reset",
      "override.apply",
      "network-access.repair",
      "network-access.reapply",
      "network-access.rollback",
      "module-update.check",
      "module-update.install"
    ],
    "network_access_confirmation": "candidate-and-confirm-flag",
    "override_input": "private-payload-file",
    "override_patch_format": "json-merge-patch",
    "private_commands": [
      "sub.inspect",
      "wifi.inspect",
      "override.inspect",
      "network-access.inspect",
      "app.inspect"
    ],
    "read_only": false,
    "routing_overlay_key": "$magicnet_routing",
    "routing_overlay_schema": 1
  },
  "ok": true,
  "schema": 1
}
~~~

## 应用名称与增量分流能力

`--json app inspect`（规范命令 `app.inspect`）是显式私密只读接口，返回 `data.schema=1`、`scope="owner_user"` 和有界 `packages`，每项只有 `packageName`、`appLabel`；最大 4096 项、总输出 512 KiB、等待 15 秒。标签可回退包名；主用户范围不能冒充全部 Android 用户/工作资料。桥接缺失、不安全、不可用或输出无效分别用 `app.catalog_unsupported|catalog_unsafe|catalog_unavailable|catalog_invalid`，不得把未知当空清单成功。WebUI 只有在明确旧版/桥接不可用错误时回退包名读取，不把坏 JSON 当成功；清单不进入通用输出/诊断。

capabilities 的 commands/private_commands 包含 `app.inspect`；features 增加 `additive_routing_overlay`；`routing_overlay_key="$magicnet_routing"`、`routing_overlay_schema=1`，普通 `override_patch_format` 仍为 `json-merge-patch`。新增的结构化扩展与归属/回滚语义见路由配方；原始数组仍具有 Merge Patch 的整段替换语义，不把它冒充增量编辑。
