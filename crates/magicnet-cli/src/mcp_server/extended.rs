//! Typed entry points and privacy-safe MCP resources.
use super::rpc::run_cli;
use crate::{App, Server};
use serde_json::{json, Value};

const RESOURCES: &[(&str, &str, &str)] = &[
    ("service", "Service readiness", "service"),
    ("transparent", "Transparent dataplane", "transparent"),
    ("dns", "DNS policy", "dns"),
    ("network", "Network policy", "network"),
    ("subscription", "Subscription status (redacted)", "sub"),
    ("wifi", "Wi-Fi policy status (redacted)", "wifi"),
    ("overrides", "Configuration override status", "override"),
];

pub(crate) fn resources() -> Value {
    json!({"resources": RESOURCES.iter().map(|(name,title,_)| json!({
        "uri":format!("magicnet://status/{name}"),"name":name,"description":title,"mimeType":"application/json"
    })).collect::<Vec<_>>()})
}

pub(crate) fn read_resource(server: &Server, uri: &str) -> Result<Value, &'static str> {
    let (_, _, command) = RESOURCES
        .iter()
        .find(|(name, _, _)| uri == format!("magicnet://status/{name}"))
        .ok_or("unknown resource")?;
    let text = run_cli(server, &["--json", command, "status"]);
    let (body, rc) = text.rsplit_once("\nrc=").ok_or("invalid status response")?;
    if rc.trim() != "0" {
        return Err("status request failed");
    }
    let data: Value = serde_json::from_str(body.trim()).map_err(|_| "invalid status response")?;
    if data["schema"] != 1 || data["ok"] != true {
        return Err("status request failed");
    }
    Ok(json!({"contents":[{"uri":uri,"mimeType":"application/json","text":data.to_string()}]}))
}

pub(crate) fn prompts() -> Value {
    json!({"prompts":[
        {"name":"diagnose-network","description":"Evidence-first Android network diagnosis without exposing private traffic."},
        {"name":"edit-config-overrides","description":"Inspect, preview, save and apply persistent JSON overrides safely."}
    ]})
}

pub(crate) fn prompt(name: &str) -> Result<Value, &'static str> {
    let text = match name {
        "diagnose-network" => "Read magicnet service, transparent, DNS and network status resources first. Distinguish configured policy from effective dataplane readiness. Inspect bounded redacted logs; correlate timestamps and test one hypothesis at a time. Treat URL-test delay as an HTTP timing measurement, not ICMP RTT. Do not change nodes, service state, subscriptions or capture private TLS payloads without the user's authorization. Never print credentials or private traffic identifiers.",
        "edit-config-overrides" => "Use magicnet_override_inspect only when the user requests editing: it contains private configuration. Explain JSON Merge Patch semantics: object merge, array replacement, null deletion. Preserve managed inbounds and local management API. Preview the proposed patch, then save using its expected_revision; on conflict reload and reconcile instead of overwriting. Apply the saved revision separately and check service readiness. Reset clears only the override. Never attach the patch or secrets to diagnostic reports.",
        _ => return Err("unknown prompt"),
    };
    Ok(json!({"messages":[{"role":"user","content":{"type":"text","text":text}}]}))
}

pub(crate) fn override_tool(server: &Server, action: &str, args: &Value) -> String {
    let app = App::from_module_root(server.moddir.clone());
    let result = match action {
        "status" => crate::overrides::status(&app),
        "inspect" => crate::overrides::inspect(&app),
        "preview" => crate::overrides::preview(&app, args),
        "set" => crate::overrides::save(&app, args, false),
        "reset" => crate::overrides::save(&app, args, true),
        "apply" => crate::overrides::apply(&app, args["expected_revision"].as_u64()),
        _ => Err("override.invalid_request"),
    };
    if matches!(action, "set" | "reset" | "apply") && crate::state::reconcile(&app).is_err() {
        return format!(
            "{}\nrc=1",
            json!({"schema":1,"ok":false,"command":format!("override.{action}"),"error":{"code":"override.reconcile_failed","message":"state publication failed; refresh before retrying"}})
        );
    }
    match result {
        Ok(data) => format!(
            "{}\nrc=0",
            json!({"schema":1,"ok":true,"command":format!("override.{action}"),"data":data})
        ),
        Err(code) => format!(
            "{}\nrc=1",
            json!({"schema":1,"ok":false,"command":format!("override.{action}"),"error":{"code":code,"message":crate::overrides::message(code)}})
        ),
    }
}
