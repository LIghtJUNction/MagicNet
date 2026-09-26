//! Machine-first candidate CLI. Its writable root must carry an explicit
//! migration marker; it cannot accidentally overwrite the installed v1 module.
mod deployment;
mod platform;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use kamfw::{Error, Result, Root};
use magicnet_core::engine::{Engine, Request};
use serde_json::{json, Value};
use std::{
    io::{self, Read, Write},
    path::PathBuf,
};

fn input(base64: bool) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    io::stdin()
        .take(8 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| Error::io("Read request", e))?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(Error::new(
            "too_large",
            "The request exceeds its input bound",
        ));
    }
    if base64 {
        STANDARD.decode(bytes).map_err(|_| {
            Error::new(
                "invalid_request",
                "The transport payload is not valid base64",
            )
        })
    } else {
        Ok(bytes)
    }
}

fn main_result() -> Result<Value> {
    let mut args = std::env::args().skip(1);
    let mut root_path = None;
    let mut method = None;
    let mut transport = None;
    let mut experimental = false;
    let mut initialize = false;
    let mut worker = None;
    let mut hook = None;
    let mut previous = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" if root_path.is_none() => {
                root_path = Some(PathBuf::from(args.next().ok_or_else(|| {
                    Error::new("invalid_arguments", "--root needs an absolute directory")
                })?))
            }
            "--request-stdin" if transport.is_none() => transport = Some(false),
            "--request-base64-stdin" if transport.is_none() => transport = Some(true),
            "--experimental-runtime" => experimental = true,
            "--hook" if hook.is_none() => {
                hook =
                    Some(args.next().ok_or_else(|| {
                        Error::new("invalid_arguments", "The hook name is missing")
                    })?)
            }
            "--upgrade-from" if previous.is_none() => {
                previous = Some(args.next().ok_or_else(|| {
                    Error::new("invalid_arguments", "The upgrade source is missing")
                })?)
            }
            "--worker" if worker.is_none() => {
                worker = Some(args.next().ok_or_else(|| {
                    Error::new("invalid_arguments", "The worker needs a generation")
                })?)
            }
            "--initialize-candidate" => initialize = true,
            "--json" => (),
            "capabilities" | "status" | "settings" | "operation" | "diagnostics"
                if method.is_none() =>
            {
                method = Some(arg)
            }
            "--version" => {
                return Ok(
                    json!({"schema":1,"ok":true,"command":"version","data":{"version":env!("CARGO_PKG_VERSION"),"stage":"candidate","production":false}}),
                )
            }
            _ => {
                return Err(Error::new(
                    "unsupported_command",
                    "Unsupported arguments; no legacy command or shell fallback was executed",
                ))
            }
        }
    }
    if usize::from(method.is_some())
        + usize::from(transport.is_some())
        + usize::from(initialize)
        + usize::from(worker.is_some())
        + usize::from(hook.is_some())
        != 1
    {
        return Err(Error::new(
            "invalid_arguments",
            "Select exactly one read command, request transport, or candidate initialization",
        ));
    }
    let path = root_path.ok_or_else(|| {
        Error::new(
            "invalid_arguments",
            "An explicit --root is required; the installed module is never guessed",
        )
    })?;
    let root = Root::open(&path)?;
    if let Some(hook) = hook {
        if ![
            "install",
            "service",
            "boot-completed",
            "action",
            "uninstall",
        ]
        .contains(&hook.as_str())
        {
            return Err(Error::new("unsupported_hook", "Unknown lifecycle hook"));
        }
        if root.read_json::<Value>(".magicnet-candidate.json")?
            != Some(json!({"schema":1,"kind":"isolated-candidate","version":2}))
        {
            return Err(Error::new(
                "migration_required",
                "Lifecycle hooks require a verified candidate directory",
            ));
        }
        let engine = Engine {
            root,
            platform: platform::Native { experimental },
        };
        let data = deployment::run(&engine, &hook, previous.as_deref())?;
        if data.get("schema") == Some(&json!(1)) && data.get("ok").is_some() {
            return Ok(data);
        }
        return Ok(json!({"schema":1,"ok":true,"command":format!("hook.{hook}"),"data":data}));
    }
    if previous.is_some() {
        return Err(Error::new(
            "invalid_arguments",
            "Upgrade sources are only valid with an installation hook",
        ));
    }

    if let Some(generation) = worker {
        platform::Native::worker(&root, &generation)?;
        return Ok(json!({"schema":1,"ok":true,"command":"worker","data":{"exited":true}}));
    }
    if initialize {
        // Never bootstrap on top of installed modules or an unrecognized data
        // directory. The caller creates a new private empty directory first.
        let entries: Vec<_> = std::fs::read_dir(&path)
            .map_err(|e| Error::io("Inspect candidate directory", e))?
            .collect();
        if !entries.is_empty() {
            return Err(Error::new(
                "root_not_empty",
                "Candidate initialization requires an empty directory",
            ));
        }
        root.write_json(
            ".magicnet-candidate.json",
            &json!({"schema":1,"kind":"isolated-candidate","version":2}),
        )?;
        return Ok(
            json!({"schema":1,"ok":true,"command":"initialize","data":{"production":false}}),
        );
    }
    let request = if let Some(encoded) = transport {
        serde_json::from_slice::<Request>(&input(encoded)?)?
    } else {
        Request {
            schema: 1,
            id: kamfw::random_id()?,
            method: method.unwrap_or_default(),
            expected_revision: None,
            params: Value::Null,
        }
    };
    if !kamfw::fs::valid_id(&request.id) || request.method.len() > 64 {
        return Err(Error::new(
            "invalid_request",
            "Request identity or method is invalid",
        ));
    }
    let read_only = [
        "capabilities",
        "status",
        "settings",
        "operation",
        "diagnostics",
    ]
    .contains(&request.method.as_str());
    if !read_only {
        let marker: Value = root.read_json(".magicnet-candidate.json")?.ok_or_else(|| {
            Error::new(
                "migration_required",
                "Writes require an explicitly initialized isolated candidate directory",
            )
        })?;
        if marker != json!({"schema":1,"kind":"isolated-candidate","version":2}) {
            return Err(Error::new(
                "invalid_root",
                "The candidate root marker is invalid",
            ));
        }
    }
    Ok(Engine {
        root,
        platform: platform::Native { experimental },
    }
    .handle(&request))
}

fn main() {
    let value = main_result()
        .unwrap_or_else(|error| json!({"schema":1,"ok":false,"command":"request","error":error}));
    let success = value["ok"] == true;
    let output = serde_json::to_vec(&value).unwrap_or_else(|_| {
        br#"{"schema":1,"ok":false,"error":{"code":"serialization_failed"}}"#.to_vec()
    });
    let mut stdout = io::stdout().lock();
    if stdout
        .write_all(&output)
        .and_then(|()| stdout.write_all(b"\n"))
        .is_err()
    {
        std::process::exit(74);
    }
    std::process::exit(if success { 0 } else { 1 });
}
