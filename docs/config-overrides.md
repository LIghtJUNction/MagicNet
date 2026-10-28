# Persistent JSON configuration overrides

## Control contract

The override editor stores user intent separately from generated subscriptions.
The payload is a JSON object using JSON Merge Patch semantics: object keys merge,
arrays replace, and `null` removes a key. An empty object resets all overrides.
It is not a full replacement configuration. A complete configuration object is
accepted as a patch, subject to the managed-field checks below.

Managed transparent inbounds and the local management API remain owned by
MagicNet. A patch must not change their effective values. Switching `tun|ebpf`
continues to use the explicit, rollback-capable transparent-mode operation.
No shell fragments, JavaScript, or remote code are evaluated.

## Persistence and recovery

- `.config/magicnet/config-override.json` contains the saved draft schema, revision and patch.
- `.config/magicnet/config-override-active.json` contains the explicitly selected
  intent. The watcher and startup materialize only this version, so saving a
  draft does not activate it. Both files store user intent, not observations.
- A private materialization checkpoint records the pre-override base and last
  generated result. It is recovery evidence, never a public state interface.
- `.state/machines/overrides.state` is the sole canonical status projection.
  It contains validity, configured revision, materialized revision and pending
  status only; no JSON values, paths, domains, credentials or error text.
- Each materialization removes the previous patch using its checkpoint before
  applying the current patch. Unrelated edits and newly imported subscription
  values survive. A field changed by another writer becomes the new base for that field; reset
  preserves that newer value instead of restoring stale subscription data.
- Config, intent and checkpoint changes use the existing staged multi-file
  transaction. Files publish by atomic replacement; cross-file readers use the
  machine interface rather than assume multiple renames are jointly atomic.
- Materialization occurs after normal runtime helpers and before sing-box starts.
  Reset removes only override effects; subscription sources and other settings
  remain intact.

## Machine writes

This feature explicitly extends the previously read-only JSON dispatcher.
The first mutation family is `override`; unrelated JSON writes remain rejected.

- `override.status`: privacy-safe configured/materialized/running status.
- `override.inspect`: explicit private patch read, including revision.
- `override.preview`: validate a patch and return a redacted change summary.
- `override.set`: validate and persist a complete patch with expected revision.
- `override.reset`: persist an empty patch with expected revision.
- `override.apply`: select the expected saved revision and apply runtime config.

All calls use the schema-1 envelope and a single JSON value on stdout. Diagnostics
stay on stderr. Mutation inputs arrive from a bounded private payload file (MCP accepts the
same object in its authenticated tool arguments); secrets must not appear in command arguments or command previews.

Set/reset use optimistic concurrency: the caller supplies the revision returned
by inspect. Repeating an identical desired state succeeds without incrementing
its revision. A different stale write returns `override.conflict`. The operation
lock is bounded and returns `override.busy`; it never waits indefinitely.
Malformed input, protected fields, validation failure, persistence failure and
apply failure have distinct normalized error codes. Failed validation writes
nothing. An activation failure rolls back the configuration and checkpoint when their
revision and contents still prove ownership. Conflicting external changes stop
automatic rollback with `override.rollback_conflict` rather than overwrite them.
The saved intent remains pending; a failed-revision hold prevents an automatic
retry loop. It never reports a failed new configuration as running.

Saving and activating are distinct results. Configured and materialized settings
are not proof of a running process: running status requires the existing runtime
fingerprint and service readiness evidence. MCP and WebUI consume these same
commands and expose pending activation explicitly.


### Example

```json
{
  "log": { "level": "info" },
  "dns": { "cache_capacity": 8192 }
}
```

Read the revision, preview the patch, save with `expected_revision`, then apply.
The WebUI combines the last two actions in **Save and apply**; **Reset overrides**
saves an empty patch and applies it. Saving alone keeps a visible pending state.

Managed inbounds, the hotspot selector and discovered source rules, Clash API and cache-file settings cannot be changed by this
editor. Use their dedicated controls. Arrays are replaced in full, including
outbound arrays: a patch that pins an entire outbound list intentionally takes
precedence over newly imported nodes until it is changed or reset.

The backup export includes override intent. Private materialization checkpoints
are local recovery evidence and are not exported. Application preserves the
existing stopped/running intent; it does not start a deliberately stopped core.

## 结构化增量分流（schema 1）

原有 JSON Merge Patch 对普通字段继续生效。保留扩展键 `$magicnet_routing` 只接受 `schema: 1`、`rules` 和 `outbounds`，在交给内核前编译并移除该键，不向内核透传。

~~~json
{"$magicnet_routing":{"schema":1,"rules":[{"kind":"domain","value":"example.com","outbound":"My route"},{"kind":"app","value":"com.example.reader","outbound":"My route"}],"outbounds":[{"type":"selector","tag":"My route","outbounds":["proxy","direct"],"default":"proxy"}]}}
~~~

最多 256 条规则、64 个自定义出口、每组 128 个成员；名称不为空、不含控制字符，最多 256 UTF-8 字节；域名使用 ASCII/Punycode 域后缀，应用使用带点包名。规则以 `(kind,value)` 唯一，目标必须存在。自定义 tag 不得覆盖订阅、内置出口或 endpoint；组/绕行引用不得缺失或成环。支持 selector/urltest 与 SOCKS、HTTP、Shadowsocks、Trojan、VLESS、VMess、Hysteria2、TUIC、AnyTLS 的受限结构化字段，最终以锁定内核的真实校验为准；不允许任意顶层内核字段混入这个扩展。WebUI 提供常用类型，复杂协议仍可经完整覆写编辑器处理。

编译保留原数组及其相对次序。应用与域名规则位于显式模式、DNS 劫持、LAN 和 Tailnet 保护之后、普通业务分类之前。DNS 使用相同应用/域名条件与次序；拦截目标拒绝解析，其余目标复制固定的加密 DNS 模板并显式 detour 到该目标，使自定义组切换时解析仍走该组。直接链默认选择本地加密 DNS 模板，其余选择远端模板；模板选择基于配置，运行时组选择不改写模板地址。缺模板或 DNS tag 碰撞必须拒绝，不能悄悄改用其他出口。

新出口、DNS server、路由与 DNS 规则的精确归属只保存在私密 checkpoint 的 `routing_owned`。重新生成时先去除自身上次生成项，再叠加当前意图，保留订阅与其他写者的新内容；已归属项被外部改成不同内容时返回 `override.routing_conflict`。撤销删除自己的项，不删除新增的订阅项。该 checkpoint 是恢复输入，不是公共状态接口。

错误码包括 `override.routing_invalid|routing_limit|routing_tag_collision|routing_target_missing|routing_cycle|routing_duplicate|routing_dns_missing|routing_conflict`。preview 失败不落盘。继续使用既有 revision、锁、set/apply/reset、原子发布与回滚协议，不新增机器写命令；停止的服务保持停止。`override.inspect.routing_targets` 只供显式私密编辑，返回 tag/type，不返回凭据。
