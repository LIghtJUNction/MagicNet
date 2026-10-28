# MCP 工具的完整公开 Schema

固定源码 release CLI 在隔离宿主目录的认证 tools/list 实际返回。只含公开接口，不含用户配置；保留名称、类型、界限、required/enum/additionalProperties 与 hints。

~~~json
[
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Show MagicNet service status",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_status"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run a MagicNet CLI command with explicit argv. This is restricted to the MagicNet CLI binary, not a shell.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "args": {
          "items": {
            "type": "string"
          },
          "maxItems": 24,
          "minItems": 1,
          "type": "array"
        }
      },
      "required": [
        "args"
      ],
      "type": "object"
    },
    "name": "magicnet_cli"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run service status/start/ensure/stop/restart/toggle/logs, optionally with a target such as current or sing-box.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "enum": [
            "status",
            "start",
            "ensure",
            "stop",
            "restart",
            "toggle",
            "logs"
          ],
          "type": "string"
        },
        "target": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_service_control"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Confirm MagicNet uses the sing-box core. Only sing-box is supported.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "core": {
          "enum": [
            "sing-box"
          ],
          "type": "string"
        }
      },
      "required": [
        "core"
      ],
      "type": "object"
    },
    "name": "magicnet_core_select"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Apply runtime config helpers.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_config_apply"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Read generated sing-box config through the config editor.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "target": {
          "enum": [
            "sing-box"
          ],
          "type": "string"
        }
      },
      "required": [
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_config_get"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Validate sing-box config.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "target": {
          "enum": [
            "sing-box",
            "all"
          ],
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_config_validate"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Sync sing-box config from the bundled upstream template.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "target": {
          "enum": [
            "sing-box"
          ],
          "type": "string"
        }
      },
      "required": [
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_config_sync_template"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Validate and save sing-box config from base64 text.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "content_base64": {
          "type": "string"
        },
        "target": {
          "enum": [
            "sing-box"
          ],
          "type": "string"
        }
      },
      "required": [
        "target",
        "content_base64"
      ],
      "type": "object"
    },
    "name": "magicnet_config_save_base64"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Explicitly switch MagicNet transparent capture between tun (default, magicnet0) and ebpf (local cgroup plus shared TC when a confirmed downstream interface exists). The operation is atomic and rolls back on failure; auto is not supported.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "mode": {
          "enum": [
            "tun",
            "ebpf"
          ],
          "type": "string"
        }
      },
      "required": [
        "mode"
      ],
      "type": "object"
    },
    "name": "magicnet_transparent_set"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Re-apply transparent proxy rules.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_transparent_apply"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run MagicNet health diagnostics",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_health"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show MagicNet community and manual blocklist state",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_block_list"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Enable or disable MagicNet blocklist.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "enabled": {
          "type": "boolean"
        }
      },
      "required": [
        "enabled"
      ],
      "type": "object"
    },
    "name": "magicnet_block_set_enabled"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Enable or disable community blocklist rules.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "enabled": {
          "type": "boolean"
        }
      },
      "required": [
        "enabled"
      ],
      "type": "object"
    },
    "name": "magicnet_block_set_community"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Download and apply the community blocklist",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_block_update"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Add a blocked domain suffix.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "suffix": {
          "type": "string"
        }
      },
      "required": [
        "suffix"
      ],
      "type": "object"
    },
    "name": "magicnet_block_add_domain"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Remove a blocked domain suffix.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "suffix": {
          "type": "string"
        }
      },
      "required": [
        "suffix"
      ],
      "type": "object"
    },
    "name": "magicnet_block_remove_domain"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Locally allow/exclude one community block rule.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "rule": {
          "type": "string"
        }
      },
      "required": [
        "rule"
      ],
      "type": "object"
    },
    "name": "magicnet_block_allow_rule"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Remove a local allow/exclude override for one community block rule.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "rule": {
          "type": "string"
        }
      },
      "required": [
        "rule"
      ],
      "type": "object"
    },
    "name": "magicnet_block_unallow_rule"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show blocklist diff.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_block_diff"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Apply blocklist rules to current configs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_block_apply"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show configured sing-box subscription URLs",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_subscription_list"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set one subscription URL for sing-box.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "target": {
          "enum": [
            "sing-box"
          ],
          "type": "string"
        },
        "url": {
          "type": "string"
        }
      },
      "required": [
        "target",
        "url"
      ],
      "type": "object"
    },
    "name": "magicnet_subscription_set"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set sing-box subscription URLs from newline-separated text",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "content": {
          "type": "string"
        }
      },
      "required": [
        "content"
      ],
      "type": "object"
    },
    "name": "magicnet_subscription_set_singbox_lines"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Update sing-box subscriptions.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "target": {
          "enum": [
            "sing-box",
            "all"
          ],
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_subscription_update"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Update all subscriptions and providers.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_subscription_update_all"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Export MagicNet configuration backup as base64. Password is optional and may be empty.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "password": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_backup_export"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Restore MagicNet configuration backup from base64. Password may be '-' for empty.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "content_base64": {
          "type": "string"
        },
        "password": {
          "type": "string"
        }
      },
      "required": [
        "content_base64"
      ],
      "type": "object"
    },
    "name": "magicnet_backup_restore_base64"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run MagicNet domestic and global connectivity checks",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_pingtest"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run direct and proxy throughput tests. Downloads at most 10 MiB total; use intentionally to avoid unexpected data consumption.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_speedtest"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show Android network interfaces, routes, forwarding and MagicNet topology",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_topology"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show Android route and rule snapshot.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_sysroute_snapshot"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show bundled eCapture binary status and kernel prerequisites.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_ecapture_status"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Show eCapture help for tls, gotls, nspr, or pcap.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "command": {
          "enum": [
            "tls",
            "gotls",
            "nspr",
            "pcap"
          ],
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_ecapture_help"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run a bounded eCapture TLS plaintext/event capture. Output is written under MagicNet .log.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "duration_seconds": {
          "maximum": 60,
          "minimum": 1,
          "type": "integer"
        },
        "pid": {
          "type": "string"
        },
        "uid": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_ecapture_tls"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run a bounded eCapture Go TLS plaintext/event capture. Output is written under MagicNet .log.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "duration_seconds": {
          "maximum": 60,
          "minimum": 1,
          "type": "integer"
        },
        "pid": {
          "type": "string"
        },
        "uid": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_ecapture_gotls"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Run a bounded eCapture pcap capture on an interface. The pcapng file is written under MagicNet .log.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "duration_seconds": {
          "maximum": 60,
          "minimum": 1,
          "type": "integer"
        },
        "filter": {
          "type": "string"
        },
        "ifname": {
          "type": "string"
        }
      },
      "required": [
        "ifname"
      ],
      "type": "object"
    },
    "name": "magicnet_ecapture_pcap"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Generate MagicNet support bundle context.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_support_bundle"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "List MagicNet per-app policy state.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_app_list"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Search installed Android packages.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "query": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_app_packages"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set per-app policy mode.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "mode": {
          "enum": [
            "blacklist",
            "whitelist"
          ],
          "type": "string"
        }
      },
      "required": [
        "mode"
      ],
      "type": "object"
    },
    "name": "magicnet_app_mode"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Add a package to proxy or bypass app policy.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "package": {
          "type": "string"
        },
        "target": {
          "enum": [
            "proxy",
            "bypass"
          ],
          "type": "string"
        }
      },
      "required": [
        "package",
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_app_add"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Add multiple packages to proxy or bypass app policy.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "packages": {
          "items": {
            "type": "string"
          },
          "maxItems": 200,
          "minItems": 1,
          "type": "array"
        },
        "target": {
          "enum": [
            "proxy",
            "bypass"
          ],
          "type": "string"
        }
      },
      "required": [
        "packages",
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_app_add_many"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Remove a package from proxy or bypass app policy.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "package": {
          "type": "string"
        },
        "target": {
          "enum": [
            "proxy",
            "bypass"
          ],
          "type": "string"
        }
      },
      "required": [
        "package",
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_app_remove"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Apply per-app policy to current configs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_app_apply"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Control MagicNet MCP status, enable, disable, start, stop, restart, or logs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "enum": [
            "status",
            "enable",
            "disable",
            "start",
            "stop",
            "restart",
            "logs"
          ],
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_mcp_control"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Call core API helpers: groups, conns, stats, close-all, or ui.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "enum": [
            "groups",
            "conns",
            "stats",
            "close-all",
            "ui"
          ],
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_api"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Show WebUI panel status.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_webui_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Verify WebUI panel files.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_webui_verify"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Install a SHA-256-pinned local core WebUI panel from a download URL.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "name": {
          "type": "string"
        },
        "sha256": {
          "type": "string"
        },
        "url": {
          "type": "string"
        }
      },
      "required": [
        "url",
        "sha256"
      ],
      "type": "object"
    },
    "name": "magicnet_webui_install_local"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "List MagicNet runtime log files and known log aliases",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_log_list"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Read the tail of a MagicNet runtime log. Sources include sing-box, mcp, fswatch, kernel, service, or a log filename under .log. MCP always redacts secrets and URLs; the redact argument cannot disable that.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "lines": {
          "maximum": 1000,
          "minimum": 1,
          "type": "integer"
        },
        "redact": {
          "type": "boolean"
        },
        "source": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_log_read"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Collect a redacted MagicNet debug snapshot with MCP status, service status, health checks, listeners, routes, log inventory, and recent core/MCP logs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "lines": {
          "maximum": 300,
          "minimum": 20,
          "type": "integer"
        }
      },
      "type": "object"
    },
    "name": "magicnet_debug_snapshot"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "List files under the MagicNet module directory",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "path": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_file_list"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read a text file under the MagicNet module directory",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "path": {
          "type": "string"
        }
      },
      "type": "object"
    },
    "name": "magicnet_file_read"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read supported schema-1 commands and features.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_capabilities"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read official MagicNet module update state, including whether a manager-staged update requires reboot. This tool does not check or install releases.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_module_update_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read configured/effective transparent dataplane readiness.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_transparent_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read DNS policy status.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_dns_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read capability-detected OS network policy counts; effective application DNS is a separate observation.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_network_access_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Explicitly enumerate configured OS network restrictions and their package groups. Contains installed package names; do not attach to public reports.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_network_access_inspect"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read configured and effective network settings, including DNS capture port and TUN CIDRs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_network_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Explicitly probe kernel DNS capture prerequisites with a bounded deadline; returns redacted capability tokens without changing policy or networking.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_network_preflight"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read subscription state without private URLs.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_subscription_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read Wi-Fi policy status without SSID/BSSID.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_wifi_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read hotspot proxy intent and reconciled forwarding state without interface names or client identities.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_hotspot_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read redacted override status.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_override_status"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Explicitly read private override JSON and revision. Do not include this result in diagnostics.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_override_inspect"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Validate a JSON Merge Patch without changing configuration. Arrays replace; null deletes.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "patch": {
          "type": "object"
        }
      },
      "required": [
        "patch"
      ],
      "type": "object"
    },
    "name": "magicnet_override_preview"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": false
    },
    "description": "Validate and save complete persistent override intent using expected_revision. Does not activate it.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "expected_revision": {
          "minimum": 0,
          "type": "integer"
        },
        "patch": {
          "type": "object"
        }
      },
      "required": [
        "patch",
        "expected_revision"
      ],
      "type": "object"
    },
    "name": "magicnet_override_set"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": false
    },
    "description": "Reset only override intent using expected_revision. Subscription and other settings remain. Apply separately.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "expected_revision": {
          "minimum": 0,
          "type": "integer"
        }
      },
      "required": [
        "expected_revision"
      ],
      "type": "object"
    },
    "name": "magicnet_override_reset"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": false,
      "readOnlyHint": false
    },
    "description": "Activate the saved override through the shared lifecycle controller; may briefly interrupt connections.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "expected_revision": {
          "minimum": 0,
          "type": "integer"
        }
      },
      "required": [
        "expected_revision"
      ],
      "type": "object"
    },
    "name": "magicnet_override_apply"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set IPv6 strategy, MTU and UDP timeout; restarts the core.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "ipv6_mode": {
          "enum": [
            "ipv4_only",
            "prefer_ipv4",
            "prefer_ipv6"
          ],
          "type": "string"
        },
        "mtu": {
          "maximum": 1500,
          "minimum": 1280,
          "type": "integer"
        },
        "udp_timeout": {
          "enum": [
            "1m",
            "3m",
            "5m",
            "10m",
            "15m",
            "30m"
          ],
          "type": "string"
        }
      },
      "required": [
        "ipv6_mode",
        "mtu",
        "udp_timeout"
      ],
      "type": "object"
    },
    "name": "magicnet_network_set"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set the DNS profile; restarts the core.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "profile": {
          "enum": [
            "default",
            "cloudflare-doh",
            "cloudflare-dot",
            "cloudflare-udp"
          ],
          "type": "string"
        }
      },
      "required": [
        "profile"
      ],
      "type": "object"
    },
    "name": "magicnet_dns_set"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Probe a public domain through the local proxy. HTTP errors are distinct from transport failures.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "domain": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        }
      },
      "required": [
        "domain"
      ],
      "type": "object"
    },
    "name": "magicnet_dns_test"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "List available node names; private configuration metadata.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_node_list"
  },
  {
    "annotations": {
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false,
      "readOnlyHint": true
    },
    "description": "Read the current proxy selector choice; private configuration metadata.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {},
      "type": "object"
    },
    "name": "magicnet_node_current"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Measure one node with the configured HTTP delay endpoint. This updates delay history.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "name": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        }
      },
      "required": [
        "name"
      ],
      "type": "object"
    },
    "name": "magicnet_node_test"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Select a node in a named group and persist the choice.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "group": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        },
        "node": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        }
      },
      "required": [
        "group",
        "node"
      ],
      "type": "object"
    },
    "name": "magicnet_selector_select"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Close a specific connection by its ID.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "id": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        }
      },
      "required": [
        "id"
      ],
      "type": "object"
    },
    "name": "magicnet_connection_close"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Set automatic subscription refresh interval.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "hours": {
          "enum": [
            "off",
            "12",
            "24",
            "48",
            "72"
          ],
          "type": "string"
        }
      },
      "required": [
        "hours"
      ],
      "type": "object"
    },
    "name": "magicnet_subscription_schedule"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Add or remove a domain-suffix routing rule.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "enum": [
            "add-domain",
            "remove-domain"
          ],
          "type": "string"
        },
        "domain": {
          "maxLength": 256,
          "minLength": 1,
          "type": "string"
        },
        "target": {
          "enum": [
            "proxy",
            "direct",
            "block",
            "warp"
          ],
          "type": "string"
        }
      },
      "required": [
        "action",
        "target",
        "domain"
      ],
      "type": "object"
    },
    "name": "magicnet_route_domain"
  },
  {
    "annotations": {
      "destructiveHint": true,
      "idempotentHint": false,
      "openWorldHint": true,
      "readOnlyHint": false
    },
    "description": "Control maintenance supervisors independently of the proxy core.",
    "inputSchema": {
      "additionalProperties": false,
      "properties": {
        "action": {
          "enum": [
            "status",
            "start",
            "stop",
            "restart"
          ],
          "type": "string"
        },
        "target": {
          "enum": [
            "fswatch",
            "wifi-policy",
            "all"
          ],
          "type": "string"
        }
      },
      "required": [
        "action",
        "target"
      ],
      "type": "object"
    },
    "name": "magicnet_supervisor_control"
  }
]
~~~
