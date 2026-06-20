# MagicNet Device MCP

MagicNet exposes a Streamable HTTP MCP server from the Android module. The
project-level `.mcp.json` points to the local forwarded endpoint:

```json
{
  "mcpServers": {
    "magicnet-device": {
      "url": "http://127.0.0.1:8766/mcp"
    }
  }
}
```

Before using it from the workstation, make sure the phone is connected and the
module MCP service is enabled:

```sh
adb devices
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp enable"'
adb forward tcp:8766 tcp:8766
```

Quick smoke test:

```sh
curl -sS -X POST http://127.0.0.1:8766/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

The config does not store subscriptions, tokens, device serials, or other
private runtime data.
