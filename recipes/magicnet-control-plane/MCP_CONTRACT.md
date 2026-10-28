# MCP

默认关闭；显式 enable 后在 loopback 暴露 /mcp，独立 bearer secret 认证，凭据来自私密配置，不能从 argv/通用读文件泄漏。主机访问走显式 ADB forward；未认证请求不得作为验收通过。

支持 initialize 版本协商 2025-03-26 / 2025-06-18、ping、tools/list、tools/call、resources/list/read、prompts/list/get；通知 HTTP 202，不产生 JSON-RPC 回复，不执行工具。广告的 readOnly/destructive/idempotent/openWorld hints 不是授权。服务器独立校验类型、必填、枚举、数值界限、数组长度和未知属性。
机器结果在 structuredContent 保持 schema-1，兼容 text；资源 URI 不是文件路径。
资源固定为 magicnet://status/service、transparent、dns、network、subscription、wifi、overrides。未知资源失败；自动资源脱敏。
prompts 包含 diagnose-network 与 edit-config-overrides，不嵌入真实配置。

generic magicnet_cli 是 argv 接口，不是 shell。拒绝 mcp secret、sub 私密 dump/user-agent/filter 默认值、人类 sub status 与 wifi 默认/status/list/check/watch、config-editor 私密 getter、backup 默认 export、override/wifi/network-access inspect、原始 service/mcp logs、diagnose（包括尾随参数）和 __ 开头的内部命令名。普通节点名/SSID 可以以 __ 开头，不能误伤参数。
file_list/read 拒绝 .config/sing-box、密钥及临时/备份别名、Wi-Fi 列表、module-update 意图、.log、私密 journal/identity/download/transaction/installer/wifi-policy 状态树及 symlink 别名；.state/machines 可读。
log_read 必须脱敏 URL/凭据，redact=false 不能绕过；service/mcp logs named tool 也走脱敏路径。
私密配置、订阅、覆写检查、流量等保留明确 named tool，不在普通状态汇总自动调用。module-update 只有 named status；network-access 只有 named status/inspect，不暗加自动修复。
抓包、测速、连接关闭、备份、配置变更都是明确操作，不能被状态读取触发。

## 固定源码工具目录

下列名称来自源码登记扫描；参数合同按 CLI_REFERENCE、机器合同和各业务配方；重建时 tools/list 的 JSON Schema 必须完整描述这些接口的类型与界限，不能只返回工具名字。
- magicnet_api
- magicnet_app_add
- magicnet_app_add_many
- magicnet_app_apply
- magicnet_app_list
- magicnet_app_mode
- magicnet_app_packages
- magicnet_app_remove
- magicnet_backup_export
- magicnet_block_add_domain
- magicnet_block_allow_rule
- magicnet_block_apply
- magicnet_block_diff
- magicnet_block_list
- magicnet_block_remove_domain
- magicnet_block_set_community
- magicnet_block_set_enabled
- magicnet_block_unallow_rule
- magicnet_block_update
- magicnet_capabilities
- magicnet_cli
- magicnet_config_apply
- magicnet_config_get
- magicnet_config_sync_template
- magicnet_config_validate
- magicnet_connection_close
- magicnet_core_select
- magicnet_debug_snapshot
- magicnet_dns_set
- magicnet_dns_status
- magicnet_dns_test
- magicnet_ecapture_gotls
- magicnet_ecapture_help
- magicnet_ecapture_pcap
- magicnet_ecapture_status
- magicnet_ecapture_tls
- magicnet_file_list
- magicnet_file_read
- magicnet_health
- magicnet_hotspot_status
- magicnet_log_list
- magicnet_log_read
- magicnet_mcp_control
- magicnet_module_update_status
- magicnet_network_access_inspect
- magicnet_network_access_status
- magicnet_network_preflight
- magicnet_network_set
- magicnet_network_status
- magicnet_node_current
- magicnet_node_list
- magicnet_node_test
- magicnet_override_apply
- magicnet_override_inspect
- magicnet_override_preview
- magicnet_override_reset
- magicnet_override_set
- magicnet_override_status
- magicnet_pingtest
- magicnet_route_domain
- magicnet_selector_select
- magicnet_service_control
- magicnet_speedtest
- magicnet_status
- magicnet_subscription_list
- magicnet_subscription_schedule
- magicnet_subscription_set
- magicnet_subscription_set_singbox_lines
- magicnet_subscription_status
- magicnet_subscription_update
- magicnet_subscription_update_all
- magicnet_supervisor_control
- magicnet_support_bundle
- magicnet_sysroute_snapshot
- magicnet_topology
- magicnet_transparent_apply
- magicnet_transparent_set
- magicnet_transparent_status
- magicnet_webui_install_local
- magicnet_webui_status
- magicnet_webui_verify
- magicnet_wifi_status
