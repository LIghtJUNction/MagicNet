pub(crate) const TOOLS_JSON: &str = r#"{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_subscription_list","description":"Show configured sing-box and mihomo subscription URLs","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_subscription_set","description":"Set one subscription URL for sing-box or mihomo. For mihomo, provider is optional and updates the matching proxy-provider in config.yaml when supplied.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","mihomo","clash"]},"url":{"type":"string"},"provider":{"type":"string"}},"required":["target","url"]}},
{"name":"magicnet_subscription_set_singbox_lines","description":"Set sing-box subscription URLs from newline-separated text","inputSchema":{"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}},
{"name":"magicnet_backup_export","description":"Export MagicNet configuration backup as base64. Password is optional and may be empty.","inputSchema":{"type":"object","properties":{"password":{"type":"string"}}}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_topology","description":"Show Android network interfaces, routes, forwarding and MagicNet topology","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_write","description":"Hot-update a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
{"name":"magicnet_file_write_base64","description":"Hot-update a file from base64 content under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content_base64":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","content_base64"]}},
{"name":"magicnet_file_chmod","description":"Change permissions for a file or directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","mode"]}},
{"name":"magicnet_dir_make","description":"Create a directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"magicnet_webui_build","description":"Run MagicNet WebUI build hook to rebuild webroot after hot-updating frontend files","inputSchema":{"type":"object","properties":{}}}
]}"#;
