//! KernelSU hooks are thin process boundaries. Installation validates a
//! bounded manifest and copies only intent under a shared source lock. PIDs,
//! operation receipts, live locks and recovery journals are never transplanted.
use kamfw::{Change, Error, Guard, LockMode, Result, Root, Store, Transaction};
use magicnet_core::engine::{Engine, Platform, Request};
use magicnet_core::model::{Settings, SETTINGS};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::time::Duration;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: u32,
    kind: String,
    production: bool,
    module_id: String,
    version: String,
    revision: String,
    abi: String,
    files: Vec<Asset>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Asset {
    path: String,
    sha256: String,
    size: u64,
    mode: u32,
}

fn verify(root: &Root) -> Result<()> {
    let manifest: Manifest = root
        .read_json("manifest.json")?
        .ok_or_else(|| Error::new("invalid_package", "The package manifest is missing"))?;
    if manifest.schema != 1
        || manifest.kind != "isolated-candidate"
        || manifest.production
        || manifest.module_id != "MagicNetNext"
        || manifest.version.len() > 64
        || manifest.revision.len() != 40
        || !manifest.revision.bytes().all(|b| b.is_ascii_hexdigit())
        || !matches!(
            manifest.abi.as_str(),
            "aarch64-linux-android" | "x86_64-linux-android"
        )
        || manifest.files.is_empty()
        || manifest.files.len() > 1024
        || manifest
            .files
            .iter()
            .try_fold(0_u64, |sum, asset| sum.checked_add(asset.size))
            .is_none_or(|sum| sum > 512 * 1024 * 1024)
    {
        return Err(Error::new(
            "invalid_package",
            "The candidate package identity or manifest is invalid",
        ));
    }
    let mut names = BTreeSet::new();
    for asset in &manifest.files {
        if !names.insert(&asset.path)
            || !(asset.path.starts_with("bin/")
                || asset.path.starts_with("webroot/")
                || matches!(
                    asset.path.as_str(),
                    "module.prop"
                        | "module-id"
                        | "abi"
                        | "skip_mount"
                        | "customize.sh"
                        | "service.sh"
                        | "boot-completed.sh"
                        | "action.sh"
                        | "uninstall.sh"
                        | ".magicnet-candidate.json"
                ))
            || asset.size > 256 * 1024 * 1024
            || !matches!(asset.mode, 0o600 | 0o644 | 0o755)
        {
            return Err(Error::new(
                "invalid_package",
                "The package contains an unrecognized asset",
            ));
        }
        let file = root
            .open_file(&asset.path)?
            .ok_or_else(|| Error::new("invalid_package", "A package asset is missing"))?;
        let metadata = file
            .metadata()
            .map_err(|e| Error::io("Inspect package asset", e))?;
        if metadata.len() != asset.size {
            return Err(Error::new(
                "invalid_package",
                "A package asset has an unexpected size",
            ));
        }
        // Hash streaming input rather than allocating a whole core binary.
        use sha2::{Digest, Sha256};
        let mut hash = Sha256::new();
        let mut input = file.take(asset.size + 1);
        let mut buffer = [0_u8; 16384];
        let mut count = 0_u64;
        loop {
            let size = input
                .read(&mut buffer)
                .map_err(|e| Error::io("Verify package asset", e))?;
            if size == 0 {
                break;
            }
            hash.update(&buffer[..size]);
            count += size as u64;
        }
        if count != asset.size || format!("{:x}", hash.finalize()) != asset.sha256 {
            return Err(Error::new(
                "invalid_package",
                "A package asset did not match its checksum",
            ));
        }
    }
    for required in [
        "bin/magicnet-cli",
        "bin/sing-box",
        "bin/curl",
        "bin/yq",
        "webroot/index.html",
        ".magicnet-candidate.json",
        "module.prop",
        "module-id",
        "abi",
        "customize.sh",
        "service.sh",
        "boot-completed.sh",
        "action.sh",
        "uninstall.sh",
    ] {
        if !names.contains(&required.to_string()) {
            return Err(Error::new(
                "invalid_package",
                "A required package asset is not in the manifest",
            ));
        }
    }
    Ok(())
}

fn collect(
    root: &Root,
    directory: &str,
    depth: usize,
    files: &mut BTreeMap<String, Vec<u8>>,
    size: &mut usize,
) -> Result<()> {
    if depth > 6 {
        return Err(Error::new(
            "invalid_profile",
            "The intent directory is too deep",
        ));
    }
    for entry in root.list(directory, 128)? {
        let path = format!("{directory}/{}", entry.name);
        match entry.kind {
            kamfw::EntryKind::Directory => collect(root, &path, depth + 1, files, size)?,
            kamfw::EntryKind::File => {
                if entry
                    .name
                    .strip_prefix(".tmp-")
                    .is_some_and(kamfw::fs::valid_id)
                {
                    continue;
                }
                let bytes = root.read(&path, kamfw::fs::MAX_DOCUMENT)?.ok_or_else(|| {
                    Error::new(
                        "profile_changed",
                        "An intent file disappeared during transfer",
                    )
                })?;
                *size = size.saturating_add(bytes.len());
                if *size > 16 * 1024 * 1024 || files.len() >= 64 {
                    return Err(Error::new(
                        "profile_limit",
                        "The intent profile exceeds the upgrade bound",
                    ));
                }
                files.insert(path, bytes);
            }
            _ => {
                return Err(Error::new(
                    "unsafe_profile",
                    "Intent cannot contain links, devices or sockets",
                ))
            }
        }
    }
    Ok(())
}

fn install<P: Platform>(engine: &Engine<P>, previous: Option<&str>) -> Result<Value> {
    verify(&engine.root)?;
    let marker: Value = engine
        .root
        .read_json(".magicnet-candidate.json")?
        .ok_or_else(|| Error::new("invalid_package", "The candidate marker is missing"))?;
    if marker != json!({"schema":1,"kind":"isolated-candidate","version":2}) {
        return Err(Error::new(
            "invalid_package",
            "The candidate marker is invalid",
        ));
    }
    let mut files = BTreeMap::new();
    if let Some(previous) = previous {
        let source = Root::open(std::path::Path::new(previous))?;
        if source.path() == engine.root.path() {
            return Err(Error::new(
                "invalid_upgrade",
                "Source and destination must be different module directories",
            ));
        }
        if source.read_json::<Value>(".magicnet-candidate.json")? != Some(marker) {
            return Err(Error::new(
                "migration_required",
                "Legacy production data needs explicit migration; it was not overwritten",
            ));
        }
        let _source_lock = Guard::acquire(
            &source,
            ".state/lock",
            LockMode::Shared,
            Duration::from_secs(2),
            false,
        )?;
        collect(&source, ".config", 0, &mut files, &mut 0)?;
        let settings: Settings = serde_json::from_slice(files.get(SETTINGS).ok_or_else(|| {
            Error::new("invalid_profile", "The previous intent document is missing")
        })?)?;
        settings.validate()?;
    } else {
        if engine
            .root
            .read(SETTINGS, kamfw::fs::MAX_DOCUMENT)?
            .is_some()
        {
            engine.settings()?;
            return Ok(json!({"installed":true,"preserved":true,"production":false}));
        }
        files.insert(SETTINGS.into(), serde_json::to_vec(&Settings::default())?);
    }
    let _guard = Guard::acquire(
        &engine.root,
        ".state/lock",
        LockMode::Exclusive,
        Duration::from_secs(2),
        true,
    )?;
    Transaction::recover(&engine.root)?;
    if previous.is_some() {
        let mut current = BTreeMap::new();
        collect(&engine.root, ".config", 0, &mut current, &mut 0)?;
        if !current.is_empty() {
            if current == files {
                return Ok(
                    json!({"installed":true,"preserved":true,"upgraded":true,"production":false}),
                );
            }
            return Err(Error::new("upgrade_conflict", "The destination already contains a different intent profile; neither profile was overwritten"));
        }
    }
    let mut changes = Vec::new();
    for (path, value) in files {
        changes.push(Change {
            expected: engine
                .root
                .read(&path, kamfw::fs::MAX_DOCUMENT)?
                .as_ref()
                .map(|bytes| kamfw::sha256(bytes)),
            path,
            value: Some(value),
        });
    }
    if !changes.is_empty() {
        Transaction::commit(&engine.root, &kamfw::random_id()?, &changes)?;
    }
    Ok(
        json!({"installed":true,"upgraded":previous.is_some(),"production":false,"copied_files":changes.len()}),
    )
}

pub fn run<P: Platform>(engine: &Engine<P>, hook: &str, previous: Option<&str>) -> Result<Value> {
    if hook == "install" {
        return install(engine, previous);
    }
    if previous.is_some() {
        return Err(Error::new(
            "invalid_arguments",
            "Only installation accepts an upgrade source",
        ));
    }
    let method = match hook {
        "service" => "runtime.recover",
        "boot-completed" => {
            if engine.root.read("disable", 1)?.is_some() || engine.root.read("remove", 1)?.is_some()
            {
                "service.stop"
            } else if engine.settings()?.enabled {
                "service.start"
            } else {
                "runtime.recover"
            }
        }
        "action" => match engine.read("status")?["phase"].as_str() {
            Some("running") => "service.stop",
            Some("stopped") => "service.start",
            _ => "runtime.recover",
        },
        "uninstall" => "service.stop",
        _ => {
            return Err(Error::new(
                "unsupported_hook",
                "The lifecycle hook is not supported",
            ))
        }
    };
    let request = Request {
        schema: 1,
        id: kamfw::random_id()?,
        method: method.into(),
        expected_revision: Some(engine.settings()?.revision),
        params: Value::Null,
    };
    Ok(engine.handle(&request))
}
