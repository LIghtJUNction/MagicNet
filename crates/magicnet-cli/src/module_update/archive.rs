//! Validate the fixed release archive format before any manager installation.
//!
//! ZIP directory parsing stays in process. Only bounded decompression of exact,
//! already validated entries uses a system/manager-owned unzip executable.
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use serde_json::Value;

const INVALID: &str = "module-update.invalid_archive";
const INCOMPATIBLE: &str = "module-update.incompatible";
const MAX_ARCHIVE: usize = 64 * 1024 * 1024;
const MAX_METADATA: usize = 128 * 1024;
// The current arm64 helper is about 6.6 MiB, before ZIP compression.
const MAX_HELPER: usize = 16 * 1024 * 1024;
const MAX_COMPONENT: u64 = 512 * 1024 * 1024;
const MAX_COMPONENT_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
const MAX_BUDGET: u64 = 4 * 1024 * 1024 * 1024;

#[derive(Debug)]
struct Entry {
    size: usize,
    kind: u32,
}

#[derive(Debug)]
struct Archive {
    entries: BTreeMap<String, Entry>,
    extracted_bytes: u64,
}

pub(super) fn validate(
    _app: &crate::App,
    path: &Path,
    version: &str,
    version_code: u64,
) -> Result<u64, &'static str> {
    let architecture = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "amd64"
    } else {
        return Err(INCOMPATIBLE);
    };
    validate_for_arch(path, version, version_code, architecture)
}

fn validate_for_arch(
    path: &Path,
    version: &str,
    version_code: u64,
    architecture: &str,
) -> Result<u64, &'static str> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| INVALID)?;
    let stat = file.metadata().map_err(|_| INVALID)?;
    if !stat.is_file() || stat.len() > MAX_ARCHIVE as u64 {
        return Err(INVALID);
    }
    let mut bytes = Vec::with_capacity(stat.len() as usize);
    file.take(MAX_ARCHIVE as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| INVALID)?;
    let archive = validate_bytes(&bytes)?;
    for required in [
        "module.prop",
        "components.json",
        "bin/magicnet-components",
        "customize.sh",
        "META-INF/com/google/android/update-binary",
        "META-INF/com/google/android/updater-script",
    ] {
        let entry = archive.entries.get(required).ok_or(INVALID)?;
        if entry.kind != 0 && entry.kind != 0o100000 {
            return Err(INVALID);
        }
    }
    let prop = read_entry(path, &archive, "module.prop", MAX_METADATA)?;
    validate_prop(&prop, version, version_code)?;
    let manifest = read_entry(path, &archive, "components.json", MAX_METADATA)?;
    let component_bytes = validate_manifest(&manifest, version, architecture)?;
    let helper = read_entry(path, &archive, "bin/magicnet-components", MAX_HELPER)?;
    validate_elf(&helper, architecture)?;
    if let Some(entry) = archive.entries.get("cli") {
        if entry.kind != 0o120000 || read_entry(path, &archive, "cli", 16)? != b"bin/magicnet-cli" {
            return Err(INVALID);
        }
    }
    archive
        .extracted_bytes
        .checked_add(component_bytes)
        .filter(|total| *total <= MAX_BUDGET)
        .ok_or(INVALID)
}

fn u16_at(bytes: &[u8], offset: usize) -> Result<u16, &'static str> {
    let part = bytes.get(offset..offset + 2).ok_or(INVALID)?;
    Ok(u16::from_le_bytes([part[0], part[1]]))
}

fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, &'static str> {
    let part = bytes.get(offset..offset + 4).ok_or(INVALID)?;
    Ok(u32::from_le_bytes([part[0], part[1], part[2], part[3]]))
}

fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 512
        && !name.starts_with('/')
        && name.bytes().all(|byte| {
            byte.is_ascii_graphic() && !matches!(byte, b'\\' | b':' | b'*' | b'?' | b'[' | b']')
        })
        && name
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn validate_bytes(bytes: &[u8]) -> Result<Archive, &'static str> {
    if !(22..=MAX_ARCHIVE).contains(&bytes.len()) {
        return Err(INVALID);
    }
    let lower = bytes.len().saturating_sub(22 + u16::MAX as usize);
    let end = (lower..=bytes.len() - 22)
        .rev()
        .find(|offset| {
            bytes.get(*offset..*offset + 4) == Some(b"PK\x05\x06")
                && u16_at(bytes, *offset + 20)
                    .is_ok_and(|comment| *offset + 22 + comment as usize == bytes.len())
        })
        .ok_or(INVALID)?;
    let count = u16_at(bytes, end + 10)? as usize;
    let central_size = u32_at(bytes, end + 12)? as usize;
    let central_start = u32_at(bytes, end + 16)? as usize;
    if u16_at(bytes, end + 4)? != 0
        || u16_at(bytes, end + 6)? != 0
        || u16_at(bytes, end + 8)? as usize != count
        || !(1..=4096).contains(&count)
        || central_size == u32::MAX as usize
        || central_start == u32::MAX as usize
        || central_start.checked_add(central_size) != Some(end)
    {
        return Err(INVALID);
    }
    let mut cursor = central_start;
    let mut entries = BTreeMap::new();
    let mut ranges = Vec::with_capacity(count);
    let mut extracted_bytes = 0_u64;
    for _ in 0..count {
        if bytes.get(cursor..cursor + 4) != Some(b"PK\x01\x02")
            || cursor.checked_add(46).is_none_or(|next| next > end)
        {
            return Err(INVALID);
        }
        let needed = u16_at(bytes, cursor + 6)?;
        let flags = u16_at(bytes, cursor + 8)?;
        let method = u16_at(bytes, cursor + 10)?;
        let crc = u32_at(bytes, cursor + 16)?;
        let compressed = u32_at(bytes, cursor + 20)? as usize;
        let size = u32_at(bytes, cursor + 24)? as usize;
        let name_size = u16_at(bytes, cursor + 28)? as usize;
        let extra_size = u16_at(bytes, cursor + 30)? as usize;
        let comment_size = u16_at(bytes, cursor + 32)? as usize;
        let external = u32_at(bytes, cursor + 38)?;
        let local = u32_at(bytes, cursor + 42)? as usize;
        let next = cursor
            .checked_add(46 + name_size + extra_size + comment_size)
            .filter(|next| *next <= end)
            .ok_or(INVALID)?;
        // Official packages use the normalized, extra-free ZIP32 format.
        // Reject descriptor/ZIP64/encryption/alternate-name extensions rather
        // than letting the manager's unzip interpret a different directory.
        if u16_at(bytes, cursor + 4)? >> 8 != 3
            || needed > 20
            || flags & !0x0800 != 0
            || !matches!(method, 0 | 8)
            || extra_size != 0
            || u16_at(bytes, cursor + 34)? != 0
            || compressed == u32::MAX as usize
            || size == u32::MAX as usize
            || local == u32::MAX as usize
            || (method == 0 && compressed != size)
            || (size > 0 && compressed == 0)
        {
            return Err(INVALID);
        }
        let raw_name = bytes
            .get(cursor + 46..cursor + 46 + name_size)
            .ok_or(INVALID)?;
        let name = std::str::from_utf8(raw_name).map_err(|_| INVALID)?;
        let directory = name.ends_with('/');
        let canonical = name.strip_suffix('/').unwrap_or(name);
        let kind = (external >> 16) & 0o170000;
        if !safe_name(canonical)
            || !matches!(kind, 0 | 0o100000 | 0o040000 | 0o120000)
            || (external >> 16) & 0o7000 != 0
            || (directory && (size != 0 || compressed != 0 || !matches!(kind, 0 | 0o040000)))
            || (!directory && (kind == 0o040000 || external & 0x10 != 0))
            || (kind == 0o120000 && (canonical != "cli" || size != 16))
            || entries.contains_key(canonical)
        {
            return Err(INVALID);
        }
        let local_header_end = local
            .checked_add(30)
            .filter(|end| *end <= central_start)
            .ok_or(INVALID)?;
        if bytes.get(local..local + 4) != Some(b"PK\x03\x04")
            || u16_at(bytes, local + 4)? != needed
            || u16_at(bytes, local + 6)? != flags
            || u16_at(bytes, local + 8)? != method
            || u32_at(bytes, local + 10)? != u32_at(bytes, cursor + 12)?
            || u32_at(bytes, local + 14)? != crc
            || u32_at(bytes, local + 18)? as usize != compressed
            || u32_at(bytes, local + 22)? as usize != size
            || u16_at(bytes, local + 26)? as usize != name_size
            || u16_at(bytes, local + 28)? != 0
        {
            return Err(INVALID);
        }
        let data_start = local_header_end.checked_add(name_size).ok_or(INVALID)?;
        let data_end = data_start
            .checked_add(compressed)
            .filter(|end| *end <= central_start)
            .ok_or(INVALID)?;
        if bytes.get(local_header_end..data_start) != Some(raw_name) {
            return Err(INVALID);
        }
        extracted_bytes = extracted_bytes
            .checked_add(size as u64)
            .filter(|total| *total <= MAX_ARCHIVE as u64)
            .ok_or(INVALID)?;
        ranges.push((local, data_end));
        entries.insert(
            canonical.to_string(),
            Entry {
                size,
                kind: if directory { 0o040000 } else { kind },
            },
        );
        cursor = next;
    }
    if cursor != end {
        return Err(INVALID);
    }
    ranges.sort_unstable();
    let mut previous_end = 0;
    for (start, end) in ranges {
        // Contiguity also excludes hidden local entries, executable prefixes,
        // data descriptors and ZIP64 records that consumers could disagree on.
        if start != previous_end {
            return Err(INVALID);
        }
        previous_end = end;
    }
    if previous_end != central_start {
        return Err(INVALID);
    }
    for name in entries.keys() {
        for (offset, _) in name.match_indices('/') {
            if entries
                .get(&name[..offset])
                .is_some_and(|entry| entry.kind != 0o040000)
            {
                return Err(INVALID);
            }
        }
    }
    Ok(Archive {
        entries,
        extracted_bytes,
    })
}

fn read_entry(
    path: &Path,
    archive: &Archive,
    name: &str,
    limit: usize,
) -> Result<Vec<u8>, &'static str> {
    let expected = archive.entries.get(name).ok_or(INVALID)?.size;
    if expected > limit {
        return Err(INVALID);
    }
    let (program, busybox) = trusted_unzip().ok_or(INVALID)?;
    let mut command = Command::new(program);
    if busybox {
        command.arg("unzip");
    }
    // Exact, constant entry names; no shell or PATH-based executable selection.
    command
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/usr/bin:/bin")
        .env("LC_ALL", "C")
        .arg("-p")
        .arg(path)
        .arg(name);
    let output = crate::run_bounded_command(command, Duration::from_secs(20), limit + 1)
        .map_err(|_| INVALID)?;
    if output.timed_out
        || output.truncated
        || !output.status.is_some_and(|status| status.success())
        || output.stdout.len() != expected
    {
        return Err(INVALID);
    }
    Ok(output.stdout)
}

fn trusted_unzip() -> Option<(&'static str, bool)> {
    #[cfg(target_os = "android")]
    let candidates = [
        ("/system/bin/unzip", false),
        ("/data/adb/ksu/bin/busybox", true),
        ("/data/adb/magisk/busybox", true),
        ("/data/adb/ap/bin/busybox", true),
    ];
    #[cfg(not(target_os = "android"))]
    let candidates = [("/usr/bin/unzip", false)];
    candidates
        .into_iter()
        .find(|(path, _)| fs::metadata(path).is_ok_and(|metadata| metadata.is_file()))
}

fn validate_prop(bytes: &[u8], version: &str, version_code: u64) -> Result<(), &'static str> {
    let text = std::str::from_utf8(bytes).map_err(|_| INVALID)?;
    if text
        .bytes()
        .any(|byte| byte == 0 || (byte.is_ascii_control() && !matches!(byte, b'\n' | b'\r')))
    {
        return Err(INVALID);
    }
    let mut fields = BTreeMap::new();
    for line in text
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let (key, value) = line.split_once('=').ok_or(INVALID)?;
        if fields.insert(key, value).is_some() {
            return Err(INVALID);
        }
    }
    if fields.get("id") != Some(&"MagicNet")
        || fields.get("version") != Some(&version)
        || fields
            .get("versionCode")
            .and_then(|code| code.parse::<u64>().ok())
            != Some(version_code)
    {
        return Err(INCOMPATIBLE);
    }
    Ok(())
}

fn hex_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn string_field<'a>(value: &'a Value, key: &str) -> Result<&'a str, &'static str> {
    value.get(key).and_then(Value::as_str).ok_or(INVALID)
}

fn managed_name(name: &str) -> bool {
    safe_name(name)
        && ((name.starts_with("bin/")
            && name.matches('/').count() == 1
            && name != "bin/magicnet-components")
            || [
                "webroot/",
                ".config/sing-box/zashboard/",
                ".config/sing-box/rules/",
            ]
            .iter()
            .any(|prefix| name.starts_with(prefix)))
}

fn validate_manifest(bytes: &[u8], version: &str, architecture: &str) -> Result<u64, &'static str> {
    let manifest: Value = serde_json::from_slice(bytes).map_err(|_| INVALID)?;
    if manifest.get("schema").and_then(Value::as_u64) != Some(1)
        || string_field(&manifest, "module")? != "MagicNet"
        || string_field(&manifest, "repository")? != "LIghtJUNction/MagicNet"
        || string_field(&manifest, "version")? != version
        || string_field(&manifest, "architecture")? != architecture
        || !matches!(architecture, "arm64" | "amd64")
    {
        return Err(INCOMPATIBLE);
    }
    let components = manifest
        .get("components")
        .and_then(Value::as_array)
        .filter(|components| !components.is_empty() && components.len() <= 128)
        .ok_or(INVALID)?;
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    let mut extracted = 0_u64;
    let mut cached = 0_u64;
    let mut has_cli = false;
    for component in components {
        let id = string_field(component, "id")?;
        let digest = string_field(component, "sha256")?;
        let asset = string_field(component, "asset")?;
        let size = component
            .get("size")
            .and_then(Value::as_u64)
            .filter(|size| (1..=MAX_COMPONENT).contains(size))
            .ok_or(INVALID)?;
        if id.is_empty()
            || id.len() > 80
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
            || !ids.insert(id)
            || !hex_hash(digest)
            || asset != format!("MagicNet-component-{id}-{digest}.zip")
        {
            return Err(INVALID);
        }
        cached = cached
            .checked_add(size)
            .filter(|total| *total <= MAX_COMPONENT_TOTAL)
            .ok_or(INVALID)?;
        let files = component
            .get("files")
            .and_then(Value::as_array)
            .filter(|files| !files.is_empty() && files.len() <= 20000)
            .ok_or(INVALID)?;
        for file in files {
            let name = string_field(file, "path")?;
            let file_digest = string_field(file, "sha256")?;
            let file_size = file
                .get("size")
                .and_then(Value::as_u64)
                .filter(|size| *size <= MAX_COMPONENT)
                .ok_or(INVALID)?;
            let mode = file.get("mode").and_then(Value::as_u64).ok_or(INVALID)?;
            if !managed_name(name)
                || !names.insert(name)
                || !hex_hash(file_digest)
                || !matches!(mode, 0o644 | 0o755 | 0o600 | 0o700)
            {
                return Err(INVALID);
            }
            extracted = extracted
                .checked_add(file_size)
                .filter(|total| *total <= MAX_COMPONENT_TOTAL)
                .ok_or(INVALID)?;
            if id == "bin-magicnet-cli"
                && name == "bin/magicnet-cli"
                && file_size >= 64
                && matches!(mode, 0o755 | 0o700)
            {
                has_cli = true;
            }
        }
    }
    if !has_cli {
        return Err(INVALID);
    }
    for name in &names {
        for (offset, _) in name.match_indices('/') {
            if names.contains(&name[..offset]) {
                return Err(INVALID);
            }
        }
    }
    extracted
        .checked_add(cached)
        .filter(|total| *total <= MAX_BUDGET)
        .ok_or(INVALID)
}

fn validate_elf(bytes: &[u8], architecture: &str) -> Result<(), &'static str> {
    if bytes.len() < 64
        || bytes.get(..7) != Some(b"\x7fELF\x02\x01\x01")
        || !matches!(u16_at(bytes, 16)?, 2 | 3)
    {
        return Err(INVALID);
    }
    let machine = u16_at(bytes, 18)?;
    if !matches!((architecture, machine), ("arm64", 183) | ("amd64", 62)) {
        return Err(INCOMPATIBLE);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Stored ZIP fixture construction intentionally uses no ZIP dependency.
    fn crc32(data: &[u8]) -> u32 {
        let mut crc = u32::MAX;
        for byte in data {
            crc ^= *byte as u32;
            for _ in 0..8 {
                crc = (crc >> 1) ^ (0xedb88320 & 0_u32.wrapping_sub(crc & 1));
            }
        }
        !crc
    }

    fn zip(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut central = Vec::new();
        for (name, data, mode) in entries {
            let offset = bytes.len() as u32;
            let name_size = name.len() as u16;
            let size = data.len() as u32;
            let crc = crc32(data).to_le_bytes();
            let mut local = [0_u8; 30];
            local[..4].copy_from_slice(b"PK\x03\x04");
            local[4..6].copy_from_slice(&20_u16.to_le_bytes());
            local[14..18].copy_from_slice(&crc);
            local[18..22].copy_from_slice(&size.to_le_bytes());
            local[22..26].copy_from_slice(&size.to_le_bytes());
            local[26..28].copy_from_slice(&name_size.to_le_bytes());
            bytes.extend(local);
            bytes.extend(name.as_bytes());
            bytes.extend(*data);
            let mut header = [0_u8; 46];
            header[..4].copy_from_slice(b"PK\x01\x02");
            header[4..6].copy_from_slice(&0x0314_u16.to_le_bytes());
            header[6..8].copy_from_slice(&20_u16.to_le_bytes());
            header[16..20].copy_from_slice(&crc);
            header[20..24].copy_from_slice(&size.to_le_bytes());
            header[24..28].copy_from_slice(&size.to_le_bytes());
            header[28..30].copy_from_slice(&name_size.to_le_bytes());
            header[38..42].copy_from_slice(&(mode << 16).to_le_bytes());
            header[42..46].copy_from_slice(&offset.to_le_bytes());
            central.extend(header);
            central.extend(name.as_bytes());
        }
        let mut end = [0_u8; 22];
        end[..4].copy_from_slice(b"PK\x05\x06");
        end[8..10].copy_from_slice(&(entries.len() as u16).to_le_bytes());
        end[10..12].copy_from_slice(&(entries.len() as u16).to_le_bytes());
        end[12..16].copy_from_slice(&(central.len() as u32).to_le_bytes());
        end[16..20].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
        bytes.extend(central);
        bytes.extend(end);
        bytes
    }

    fn manifest() -> Value {
        let hash = "a".repeat(64);
        serde_json::json!({ "schema": 1, "module": "MagicNet", "repository": "LIghtJUNction/MagicNet", "version": "v1.5.20", "architecture": "arm64", "components": [{ "id": "bin-magicnet-cli", "sha256": hash, "size": 1024, "asset": format!("MagicNet-component-bin-magicnet-cli-{hash}.zip"), "files": [{ "path": "bin/magicnet-cli", "sha256": hash, "size": 2048, "mode": 493 }] }] })
    }

    #[test]
    fn accepts_regular_files_and_only_exact_cli_link_shape() {
        let bytes = zip(&[
            ("module.prop", b"id=MagicNet\n", 0o100644),
            ("cli", b"bin/magicnet-cli", 0o120777),
        ]);
        assert_eq!(validate_bytes(&bytes).unwrap().entries.len(), 2);
        assert!(validate_bytes(&zip(&[("other", b"bin/magicnet-cli", 0o120777)])).is_err());
        assert!(validate_bytes(&zip(&[("cli", b"../x", 0o120777)])).is_err());
    }

    #[test]
    fn rejects_traversal_duplicates_and_parent_aliases() {
        for name in [
            "../x",
            "/absolute",
            "a/../x",
            "a//x",
            "a/./x",
            "a\\x",
            "a:x",
        ] {
            assert!(
                validate_bytes(&zip(&[(name, b"x", 0o100644)])).is_err(),
                "{name}"
            );
        }
        assert!(validate_bytes(&zip(&[("a", b"x", 0o100644), ("a", b"x", 0o100644)])).is_err());
        assert!(validate_bytes(&zip(&[("a", b"x", 0o100644), ("a/x", b"x", 0o100644)])).is_err());
        assert!(validate_bytes(&zip(&[
            ("cli", b"bin/magicnet-cli", 0o120777),
            ("cli/x", b"x", 0o100644)
        ]))
        .is_err());
    }

    #[test]
    fn rejects_mismatched_local_headers_encryption_zip64_and_overlap() {
        let original = zip(&[("a", b"x", 0o100644), ("b", b"x", 0o100644)]);
        for offset in [4, 6, 8, 10, 14, 18, 22, 26, 28, 30] {
            let mut bytes = original.clone();
            bytes[offset] ^= 1;
            assert!(validate_bytes(&bytes).is_err(), "offset {offset}");
        }
        let central = 64;
        for (offset, replacement) in [
            (central + 8, 1_u32),
            (central + 20, u32::MAX),
            (central + 24, u32::MAX),
            (central + 42, u32::MAX),
            (central + 47 + 42, 0),
        ] {
            let mut bytes = original.clone();
            bytes[offset..offset + 4].copy_from_slice(&replacement.to_le_bytes());
            assert!(validate_bytes(&bytes).is_err(), "central offset {offset}");
        }
    }

    #[test]
    fn rejects_extracted_size_overflow_trailing_data_and_entry_count() {
        let mut bytes = zip(&[("a", b"x", 0o100644)]);
        bytes.extend(b"trailing");
        assert!(validate_bytes(&bytes).is_err());
        let mut bytes = zip(&[("a", b"x", 0o100644)]);
        let end = bytes.len() - 22;
        bytes[end + 8..end + 10].copy_from_slice(&4097_u16.to_le_bytes());
        bytes[end + 10..end + 12].copy_from_slice(&4097_u16.to_le_bytes());
        assert!(validate_bytes(&bytes).is_err());
        let mut bytes = zip(&[("a", b"x", 0o100644)]);
        let central = 32;
        bytes[8..10].copy_from_slice(&8_u16.to_le_bytes());
        bytes[22..26].copy_from_slice(&((MAX_ARCHIVE + 1) as u32).to_le_bytes());
        bytes[central + 10..central + 12].copy_from_slice(&8_u16.to_le_bytes());
        bytes[central + 24..central + 28]
            .copy_from_slice(&((MAX_ARCHIVE + 1) as u32).to_le_bytes());
        assert!(validate_bytes(&bytes).is_err());
    }

    #[test]
    fn validates_release_identity_and_rejects_ambiguous_properties() {
        assert!(validate_prop(
            b"id=MagicNet\nversion=v1.5.20\nversionCode=42\n",
            "v1.5.20",
            42
        )
        .is_ok());
        assert_eq!(
            validate_prop(
                b"id=Other\nversion=v1.5.20\nversionCode=42\n",
                "v1.5.20",
                42
            ),
            Err(INCOMPATIBLE)
        );
        assert!(validate_prop(
            b"id=Other\nid=MagicNet\nversion=v1.5.20\nversionCode=42\n",
            "v1.5.20",
            42
        )
        .is_err());
        assert!(validate_prop(
            b"id=MagicNet\nversion=v1.5.21\nversionCode=42\n",
            "v1.5.20",
            42
        )
        .is_err());
        assert!(validate_prop(
            b"id=MagicNet\nversion=v1.5.20\nversionCode=41\n",
            "v1.5.20",
            42
        )
        .is_err());
    }

    #[test]
    fn validates_content_addressed_components_and_budget() {
        let original = manifest();
        assert_eq!(
            validate_manifest(&serde_json::to_vec(&original).unwrap(), "v1.5.20", "arm64"),
            Ok(3072)
        );
        for (pointer, value) in [
            ("/repository", serde_json::json!("Other/MagicNet")),
            ("/architecture", serde_json::json!("amd64")),
            (
                "/components/0/asset",
                serde_json::json!("https://example.test/file.zip"),
            ),
            ("/components/0/sha256", serde_json::json!("short")),
            ("/components/0/files/0/path", serde_json::json!("../x")),
            (
                "/components/0/files/0/path",
                serde_json::json!("bin/magicnet-components"),
            ),
            ("/components/0/size", serde_json::json!(MAX_COMPONENT + 1)),
            (
                "/components/0/files/0/size",
                serde_json::json!(MAX_COMPONENT + 1),
            ),
        ] {
            let mut invalid = original.clone();
            *invalid.pointer_mut(pointer).unwrap() = value;
            assert!(
                validate_manifest(&serde_json::to_vec(&invalid).unwrap(), "v1.5.20", "arm64")
                    .is_err(),
                "{pointer}"
            );
        }
        let mut duplicate = original.clone();
        let component = duplicate["components"][0].clone();
        duplicate["components"]
            .as_array_mut()
            .unwrap()
            .push(component);
        assert!(
            validate_manifest(&serde_json::to_vec(&duplicate).unwrap(), "v1.5.20", "arm64")
                .is_err()
        );
    }

    #[test]
    fn verifies_helper_elf_architecture() {
        let mut elf = vec![0; 64];
        elf[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        elf[16..18].copy_from_slice(&3_u16.to_le_bytes());
        elf[18..20].copy_from_slice(&183_u16.to_le_bytes());
        assert!(validate_elf(&elf, "arm64").is_ok());
        assert_eq!(validate_elf(&elf, "amd64"), Err(INCOMPATIBLE));
        elf[4] = 1;
        assert_eq!(validate_elf(&elf, "arm64"), Err(INVALID));
    }

    #[test]
    fn decompresses_crc_valid_core_and_rejects_wrong_link_and_architecture() {
        let app = crate::test_support::temp_app();
        let path = app.moddir.join("core.zip");
        let manifest = serde_json::to_vec(&manifest()).unwrap();
        let prop = b"id=MagicNet\nversion=v1.5.20\nversionCode=42\n";
        let mut elf = vec![0; 64];
        elf[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        elf[16..18].copy_from_slice(&3_u16.to_le_bytes());
        elf[18..20].copy_from_slice(&183_u16.to_le_bytes());
        let core = |target: &'static [u8]| {
            zip(&[
                ("module.prop", prop, 0o100644),
                ("components.json", &manifest, 0o100644),
                ("bin/magicnet-components", &elf, 0o100755),
                ("customize.sh", b"#!/bin/sh\n", 0o100755),
                (
                    "META-INF/com/google/android/update-binary",
                    b"#!/bin/sh\n",
                    0o100755,
                ),
                (
                    "META-INF/com/google/android/updater-script",
                    b"#MAGISK\n",
                    0o100644,
                ),
                ("cli", target, 0o120777),
            ])
        };
        let valid = core(b"bin/magicnet-cli");
        fs::write(&path, &valid).unwrap();
        assert!(validate_for_arch(&path, "v1.5.20", 42, "arm64").is_ok());
        assert_eq!(
            validate_for_arch(&path, "v1.5.20", 42, "amd64"),
            Err(INCOMPATIBLE)
        );
        fs::write(&path, core(b"bin/magicnet-xxx")).unwrap();
        assert_eq!(
            validate_for_arch(&path, "v1.5.20", 42, "arm64"),
            Err(INVALID)
        );
        let mut corrupt = valid;
        corrupt[30 + "module.prop".len()] ^= 1;
        fs::write(&path, corrupt).unwrap();
        assert_eq!(
            validate_for_arch(&path, "v1.5.20", 42, "arm64"),
            Err(INVALID)
        );
    }
}
