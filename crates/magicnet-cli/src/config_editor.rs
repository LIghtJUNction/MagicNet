use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};

use crate::service::apply_config;
use crate::webui_payload::MAX_WEBUI_PAYLOAD_BYTES;
use crate::{decode_base64, write_secret_file, write_text_file, App};

const VALIDATOR_TIMEOUT: Duration = Duration::from_secs(20);
const TEMPLATE_FETCH_TIMEOUT: Duration = Duration::from_secs(45);
const TEMPLATE_MAX_BYTES: usize = 1024 * 1024;
const MAGIC_SINGBOX_TEMPLATE_URL: &str = "https://raw.githubusercontent.com/LIghtJUNction/MagicSingBox/9d354b0717636271eaa4bb1a3cbe5bb93cafd8f5/config.json";
const MAGIC_SINGBOX_TEMPLATE_SHA256: &str =
    "8e91177e9222b2e5dee91ec849716757601156a28e7a056e6091ab5c71e102a5";
const STANDALONE_CONFIG_MARKER: &str = ".config/sing-box/standalone-config";
const TAILSCALE_AUTH_PATH: &str = ".config/sing-box/tailscale-auth.json";
static CONFIG_EDITOR_STAGE_SEQUENCE: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn config_editor(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or_default();
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    match action {
        "path" => {
            let path = config_path(app, target)?;
            println!("{}", path.display());
            Ok(())
        }
        "get" => {
            let text = read_current_config(app, target)?.unwrap_or_else(|| default_config(target));
            print!("{text}");
            Ok(())
        }
        "validate" => {
            let path = config_path(app, target)?;
            validate_config(app, target, &path)?;
            println!("[info] {target} config validation passed");
            Ok(())
        }
        "save" => {
            let path = config_path(app, target)?;
            save_config(app, target, &path, args)
        }
        "save-file" => {
            let path = config_path(app, target)?;
            save_config_file(app, target, &path, args)
        }
        "sync-template" | "sync" => sync_template(app, target),
        _ => Err(
            "Usage: cli config-editor {get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|webui-payload-path]"
                .to_string(),
        ),
    }
}

fn save_config(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let payload = args.get(2).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli config-editor save sing-box <base64-config>".to_string());
    }
    let bytes = decode_base64(payload)?;
    let text = String::from_utf8(bytes).map_err(|err| format!("config is not UTF-8: {err}"))?;
    let protected = protect_tailscale_auth_keys(app, &text)?;
    commit_config_text(app, target, path, protected.as_bytes(), "input")?;
    mark_standalone_config(app)
}

fn save_config_file(app: &App, target: &str, path: &Path, args: &[String]) -> Result<(), String> {
    let tmp = args.get(2).map(PathBuf::from).unwrap_or_default();
    if tmp.as_os_str().is_empty() {
        return Err("Usage: cli config-editor save-file sing-box <webui-payload-path>".to_string());
    }
    let (source, _tmp_directory) = open_webui_payload_source(app, &tmp)?;
    let mut bytes = Vec::new();
    source
        .take(MAX_WEBUI_PAYLOAD_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("read WebUI config payload: {err}"))?;
    if bytes.len() as u64 > MAX_WEBUI_PAYLOAD_BYTES {
        return Err(format!(
            "WebUI config payload exceeds the {MAX_WEBUI_PAYLOAD_BYTES} byte limit"
        ));
    }
    let text = String::from_utf8(bytes).map_err(|err| format!("config is not UTF-8: {err}"))?;
    let protected = protect_tailscale_auth_keys(app, &text)?;
    commit_config_text(app, target, path, protected.as_bytes(), "input")?;
    mark_standalone_config(app)
}

fn protect_tailscale_auth_keys(app: &App, text: &str) -> Result<String, String> {
    let Ok(mut config) = serde_json::from_str::<JsonValue>(text) else {
        return Ok(text.to_string());
    };
    let mut keys = fs::read_to_string(app.moddir.join(TAILSCALE_AUTH_PATH))
        .ok()
        .and_then(|current| serde_json::from_str::<JsonValue>(&current).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    let mut changed = false;
    if let Some(endpoints) = config
        .get_mut("endpoints")
        .and_then(JsonValue::as_array_mut)
    {
        for endpoint in endpoints {
            let Some(object) = endpoint.as_object_mut() else {
                continue;
            };
            if object.get("type").and_then(JsonValue::as_str) != Some("tailscale") {
                continue;
            }
            let tag = object
                .get("tag")
                .and_then(JsonValue::as_str)
                .unwrap_or_default()
                .to_string();
            if let Some(auth_key) = object.remove("auth_key") {
                changed = true;
                if !tag.is_empty() && auth_key.as_str().is_some_and(|value| !value.is_empty()) {
                    keys.insert(tag, auth_key);
                }
            }
        }
    }
    if !changed {
        return Ok(text.to_string());
    }
    let protected_keys = serde_json::to_string(&JsonValue::Object(keys))
        .map_err(|err| format!("serialize protected Tailscale auth keys: {err}"))?;
    write_secret_file(app, Path::new(TAILSCALE_AUTH_PATH), &protected_keys)?;
    serde_json::to_string_pretty(&config)
        .map(|value| format!("{value}\n"))
        .map_err(|err| format!("serialize sing-box config: {err}"))
}

fn mark_standalone_config(app: &App) -> Result<(), String> {
    write_text_file(app, Path::new(STANDALONE_CONFIG_MARKER), "validated\n")
}

/// Open an externally supplied config source only from the WebUI-owned
/// payload namespace. Internal config staging uses `trusted_tmp_directory`,
/// but never broadens this public `save-file` boundary.
fn open_webui_payload_source(app: &App, tmp: &Path) -> Result<(File, File), String> {
    let tmp_path = app.moddir.join(".tmp");
    let webui_payload_path = tmp_path.join("webui-payload");
    if tmp.parent() != Some(webui_payload_path.as_path()) {
        return Err(
            "config-editor save-file only accepts direct files under $MODDIR/.tmp/webui-payload"
                .to_string(),
        );
    }
    let name = direct_webui_payload_name(&webui_payload_path, tmp)?;
    let tmp_directory = trusted_tmp_directory(app)?;
    let directory = ensure_directory_at(&tmp_directory, OsStr::new("webui-payload"), 0o700)?;
    let file = open_no_follow_file_at(&directory, &name)?;
    require_private_webui_payload_source(&file)?;
    Ok((file, directory))
}

fn direct_webui_payload_name(payload_directory: &Path, tmp: &Path) -> Result<OsString, String> {
    if tmp.parent() != Some(payload_directory) {
        return Err(
            "config-editor save-file only accepts direct files under $MODDIR/.tmp/webui-payload"
                .to_string(),
        );
    }
    let name = tmp
        .file_name()
        .ok_or_else(|| "config-editor save-file requires a WebUI payload filename".to_string())?;
    crate::webui_payload::validate_payload_name(name)?;
    Ok(name.to_os_string())
}

fn open_module_root(app: &App) -> Result<File, String> {
    open_no_follow_directory(&app.moddir, "module root")
}

fn open_no_follow_directory(path: &Path, description: &str) -> Result<File, String> {
    let path_c = cstring_from_os_str(path.as_os_str(), description)?;
    let fd = unsafe {
        libc::open(
            path_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open {description} {}: {}",
            path.display(),
            io::Error::last_os_error()
        ));
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    if !directory
        .metadata()
        .map_err(|err| format!("stat {description} {}: {err}", path.display()))?
        .is_dir()
    {
        return Err(format!(
            "{description} is not a directory: {}",
            path.display()
        ));
    }
    Ok(directory)
}

fn trusted_tmp_directory(app: &App) -> Result<File, String> {
    let root = open_module_root(app)?;
    ensure_directory_at(&root, OsStr::new(".tmp"), 0o700)
}

fn ensure_directory_at(parent: &File, name: &OsStr, mode: u32) -> Result<File, String> {
    let name_c = cstring_from_os_str(name, "directory name")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), mode) };
    if created != 0 && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
        return Err(format!(
            "create trusted directory: {}",
            io::Error::last_os_error()
        ));
    }
    let directory = open_directory_at(parent, name)?;
    directory
        .set_permissions(fs::Permissions::from_mode(mode))
        .map_err(|err| format!("secure trusted directory: {err}"))?;
    Ok(directory)
}

fn open_directory_at(parent: &File, name: &OsStr) -> Result<File, String> {
    let name_c = cstring_from_os_str(name, "directory name")?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open trusted directory component: {}",
            io::Error::last_os_error()
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_config_destination_directory(app: &App, target: &str) -> Result<File, String> {
    config_target_filename(target)?;
    let root = open_module_root(app)?;
    let config = ensure_directory_at(&root, OsStr::new(".config"), 0o700)?;
    ensure_directory_at(&config, OsStr::new("sing-box"), 0o700)
}

fn config_target_filename(target: &str) -> Result<&'static str, String> {
    match target {
        "sing-box" | "singbox" | "all" => Ok("config.json"),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn open_no_follow_file_at(directory: &File, name: &OsStr) -> Result<File, String> {
    let file = open_no_follow_file_at_raw(directory, name).map_err(|err| {
        format!(
            "open trusted temporary file {}: {err}",
            name.to_string_lossy()
        )
    })?;
    require_regular_file(
        &file,
        "config-editor save-file requires a regular temporary file",
    )?;
    Ok(file)
}

fn open_no_follow_file_at_raw(directory: &File, name: &OsStr) -> io::Result<File> {
    let name_c = CString::new(name.as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "temporary filename contains an unsupported NUL byte",
        )
    })?;
    // O_NONBLOCK lets us inspect and reject a named pipe without hanging while
    // preserving ordinary regular-file behavior.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn require_regular_file(file: &File, error_prefix: &str) -> Result<(), String> {
    if !file
        .metadata()
        .map_err(|err| format!("inspect staged config file: {err}"))?
        .file_type()
        .is_file()
    {
        return Err(error_prefix.to_string());
    }
    Ok(())
}

fn require_private_webui_payload_source(file: &File) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|err| format!("inspect WebUI payload source: {err}"))?;
    if !metadata.file_type().is_file() || metadata.nlink() != 1 {
        return Err("config-editor save-file requires a private regular WebUI payload".to_string());
    }
    Ok(())
}

fn cstring_from_os_str(value: &OsStr, description: &str) -> Result<CString, String> {
    CString::new(value.as_bytes())
        .map_err(|_| format!("{description} contains an unsupported NUL byte"))
}

fn validate_config_from_open_file(
    app: &App,
    target: &str,
    file: &File,
    directory: &File,
) -> Result<(), String> {
    // Both fds are intentionally inheritable: the validator resolves these
    // procfs paths to the already-open file and directory rather than looking
    // up the user-supplied path a second time.
    let config_path = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
    let data_directory = PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()));
    validate_config_with_data_directory(app, target, &config_path, Some(&data_directory))
}

/// Copy a validated input descriptor into a brand-new, owned inode under the
/// final config directory, validate that immutable snapshot, then atomically
/// rename the snapshot into place. The caller-owned source inode is never
/// linked into the destination, so later hard-link writes cannot change bytes
/// that were already accepted by the validator.
fn validate_and_commit_open_config_file(
    app: &App,
    target: &str,
    path: &Path,
    source: &File,
) -> Result<(), String> {
    let name = OsStr::new(config_target_filename(target)?);
    let directory = open_config_destination_directory(app, target)?;
    let (snapshot, staged_name) = snapshot_config_file(source, &directory)?;
    let result = (|| {
        // sing-box resolves relative rule-set and UI paths from its data
        // directory. The candidate may originate in a private temporary
        // namespace, but after commit it lives beside the existing rules
        // under .config/sing-box. Validate against that final directory so
        // the check sees the same resources as the runtime.
        validate_config_from_open_file(app, target, &snapshot, &directory)?;
        backup_config_at(&directory, name)?;
        commit_staged_config_file(&directory, &staged_name, name, path)
    })();
    let cleanup = if result.is_err() {
        remove_staged_config_file(&directory, &staged_name)
    } else {
        Ok(())
    };
    finish_with_cleanup(result, cleanup, "config snapshot")
}

fn commit_staged_config_file(
    directory: &File,
    staged_name: &OsStr,
    name: &OsStr,
    path: &Path,
) -> Result<(), String> {
    let staged_c = cstring_from_os_str(staged_name, "staged config filename")?;
    let name_c = cstring_from_os_str(name, "config filename")?;
    let renamed = unsafe {
        libc::renameat(
            directory.as_raw_fd(),
            staged_c.as_ptr(),
            directory.as_raw_fd(),
            name_c.as_ptr(),
        )
    };
    if renamed == 0 {
        return Ok(());
    }

    let error = io::Error::last_os_error();
    Err(format!("save config {}: {error}", path.display()))
}

fn snapshot_config_file(file: &File, directory: &File) -> Result<(File, OsString), String> {
    let (mut snapshot, staged_name) = create_staged_config_file(directory, "snapshot")?;
    if let Err(err) = copy_file_into_staging(file, &mut snapshot) {
        return finish_with_cleanup(
            Err(err),
            remove_staged_config_file(directory, &staged_name),
            "config snapshot",
        );
    }
    Ok((snapshot, staged_name))
}

fn create_staged_config_file(directory: &File, role: &str) -> Result<(File, OsString), String> {
    for _ in 0..16 {
        let staged_name = OsString::from(format!(
            ".config-editor-{role}-{}-{}",
            std::process::id(),
            CONFIG_EDITOR_STAGE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let staged_c = cstring_from_os_str(&staged_name, "staged config filename")?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                staged_c.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd >= 0 {
            let file = unsafe { File::from_raw_fd(fd) };
            if let Err(err) = file.set_permissions(fs::Permissions::from_mode(0o600)) {
                let cleanup = remove_staged_config_file(directory, &staged_name);
                return finish_with_cleanup(
                    Err(format!("secure staged config: {err}")),
                    cleanup,
                    "config staging",
                );
            }
            return Ok((file, staged_name));
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(format!("stage validated config: {error}"));
        }
    }
    Err("stage validated config: no unique staging name available".to_string())
}

fn copy_file_into_staging(source: &File, staging: &mut File) -> Result<(), String> {
    let mut source = source;
    source
        .seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek config source: {err}"))?;
    staging
        .set_len(0)
        .map_err(|err| format!("truncate staged config: {err}"))?;
    staging
        .seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek staged config: {err}"))?;

    let mut buffer = [0_u8; 8192];
    loop {
        let read = source
            .read(&mut buffer)
            .map_err(|err| format!("read config source: {err}"))?;
        if read == 0 {
            break;
        }
        staging
            .write_all(&buffer[..read])
            .map_err(|err| format!("write staged config: {err}"))?;
    }
    staging
        .sync_all()
        .map_err(|err| format!("sync staged config: {err}"))?;
    staging
        .seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek staged config: {err}"))?;
    Ok(())
}

fn remove_staged_config_file(directory: &File, name: &OsStr) -> Result<(), String> {
    let name_c = cstring_from_os_str(name, "staged config filename")?;
    let removed = unsafe { libc::unlinkat(directory.as_raw_fd(), name_c.as_ptr(), 0) };
    if removed == 0 {
        Ok(())
    } else {
        Err(format!(
            "remove staged config: {}",
            io::Error::last_os_error()
        ))
    }
}

fn commit_config_text(
    app: &App,
    target: &str,
    path: &Path,
    bytes: &[u8],
    role: &str,
) -> Result<(), String> {
    with_generated_config_input(app, role, bytes, |source, _directory| {
        validate_and_commit_open_config_file(app, target, path, source)
    })?;
    println!(
        "[info] Saved and validated {target} config: {}\n[info] Runtime policy changes can be applied from the control/app pages.",
        path.display()
    );
    Ok(())
}

fn with_generated_config_input<T>(
    app: &App,
    role: &str,
    bytes: &[u8],
    commit: impl FnOnce(&File, &File) -> Result<T, String>,
) -> Result<T, String> {
    let directory = trusted_tmp_directory(app)?;
    let (mut input, name) = create_staged_config_file(&directory, role)?;
    let result = (|| {
        write_bytes_into_staging(&mut input, bytes)?;
        commit(&input, &directory)
    })();
    finish_with_cleanup(
        result,
        remove_staged_config_file(&directory, &name),
        "generated config input",
    )
}

fn write_bytes_into_staging(file: &mut File, bytes: &[u8]) -> Result<(), String> {
    file.set_len(0)
        .map_err(|err| format!("truncate staged config: {err}"))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek staged config: {err}"))?;
    file.write_all(bytes)
        .map_err(|err| format!("write staged config: {err}"))?;
    file.sync_all()
        .map_err(|err| format!("sync staged config: {err}"))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek staged config: {err}"))?;
    Ok(())
}

fn finish_with_cleanup<T>(
    result: Result<T, String>,
    cleanup: Result<(), String>,
    label: &str,
) -> Result<T, String> {
    match (result, cleanup) {
        (Ok(value), Ok(())) => Ok(value),
        (Ok(_), Err(cleanup)) => Err(format!("{label} cleanup failed: {cleanup}")),
        (Err(primary), Ok(())) => Err(primary),
        (Err(primary), Err(cleanup)) => {
            Err(format!("{primary}; {label} cleanup failed: {cleanup}"))
        }
    }
}

fn backup_config_at(directory: &File, name: &OsStr) -> Result<(), String> {
    let source = match open_no_follow_file_at_raw(directory, name) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(format!("open existing config for backup: {err}")),
    };
    require_regular_file(&source, "refusing to back up a non-regular config file")?;

    let backup_name = backup_name(name);
    let (mut backup, staged_name) = create_staged_config_file(directory, "backup")?;
    if let Err(err) = copy_file_into_staging(&source, &mut backup) {
        return finish_with_cleanup(
            Err(err),
            remove_staged_config_file(directory, &staged_name),
            "config backup",
        );
    }
    drop(backup);

    let staged_c = cstring_from_os_str(&staged_name, "staged backup filename")?;
    let backup_c = cstring_from_os_str(&backup_name, "config backup filename")?;
    let renamed = unsafe {
        libc::renameat(
            directory.as_raw_fd(),
            staged_c.as_ptr(),
            directory.as_raw_fd(),
            backup_c.as_ptr(),
        )
    };
    if renamed == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    finish_with_cleanup(
        Err(format!("replace config backup: {error}")),
        remove_staged_config_file(directory, &staged_name),
        "config backup",
    )
}

fn backup_name(name: &OsStr) -> OsString {
    let mut backup = name.to_os_string();
    backup.push(".bak");
    backup
}

fn sync_template(app: &App, target: &str) -> Result<(), String> {
    match target {
        "all" => {
            sync_template_one(app, "sing-box")?;
            Ok(())
        }
        "sing-box" | "singbox" => sync_template_one(app, "sing-box"),
        _ => Err("Usage: cli config-editor sync-template <sing-box|all>".to_string()),
    }
}

fn sync_template_one(app: &App, target: &str) -> Result<(), String> {
    let path = config_path(app, target)?;
    let url = upstream_template_url(target)?;
    let template = fetch_template(&url)?;
    let current = read_current_config(app, target)?.unwrap_or_default();
    let merged = prepare_template(target, &template, &current)?;
    commit_config_text(app, target, &path, merged.as_bytes(), "template")?;
    apply_config(app)?;
    println!(
        "[info] Synced {target} template from {url}\n[info] Preserved subscription-facing config and re-applied runtime rules."
    );
    Ok(())
}

fn read_current_config(app: &App, target: &str) -> Result<Option<String>, String> {
    let directory = open_config_destination_directory(app, target)?;
    let name = OsStr::new(config_target_filename(target)?);
    let mut file = match open_no_follow_file_at_raw(&directory, name) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(format!("open current config: {err}")),
    };
    require_regular_file(&file, "refusing to read a non-regular config file")?;
    let mut text = String::new();
    file.read_to_string(&mut text)
        .map_err(|err| format!("read current config: {err}"))?;
    Ok(Some(text))
}

fn upstream_template_url(target: &str) -> Result<String, String> {
    match target {
        "sing-box" => Ok(MAGIC_SINGBOX_TEMPLATE_URL.to_string()),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn fetch_template(url: &str) -> Result<String, String> {
    let mut command = Command::new("curl");
    command
        .arg("-fsSL")
        .arg("--proto")
        .arg("=https")
        .arg("--proto-redir")
        .arg("=https")
        .arg("--max-filesize")
        .arg(TEMPLATE_MAX_BYTES.to_string())
        .arg("--max-time")
        .arg(TEMPLATE_FETCH_TIMEOUT.as_secs().to_string())
        .arg(url);
    let output = run_with_timeout(command, TEMPLATE_FETCH_TIMEOUT + Duration::from_secs(5))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            "fetch template failed: curl command failed".to_string()
        } else {
            format!("fetch template failed: {stderr}")
        });
    }
    if output.stdout.len() > TEMPLATE_MAX_BYTES {
        return Err(format!(
            "fetch template failed: response exceeds {TEMPLATE_MAX_BYTES} byte limit"
        ));
    }
    verify_template_hash(&output.stdout)?;
    String::from_utf8(output.stdout).map_err(|err| format!("template is not UTF-8: {err}"))
}

fn verify_template_hash(template: &[u8]) -> Result<(), String> {
    verify_expected_sha256(
        template,
        MAGIC_SINGBOX_TEMPLATE_SHA256,
        "upstream sing-box template",
    )
}

fn verify_expected_sha256(bytes: &[u8], expected: &str, subject: &str) -> Result<(), String> {
    let actual = format!("{:x}", Sha256::digest(bytes));
    if actual.eq_ignore_ascii_case(expected) {
        Ok(())
    } else {
        Err(format!("{subject} SHA-256 verification failed"))
    }
}

fn prepare_template(target: &str, template: &str, current: &str) -> Result<String, String> {
    match target {
        "sing-box" => preserve_singbox_subscription_config(template, current),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn preserve_singbox_subscription_config(template: &str, current: &str) -> Result<String, String> {
    let mut template_json: JsonValue = serde_json::from_str(template)
        .map_err(|err| format!("upstream sing-box template is invalid JSON: {err}"))?;
    let Ok(current_json) = serde_json::from_str::<JsonValue>(current) else {
        return serde_json::to_string_pretty(&template_json)
            .map_err(|err| format!("serialize sing-box template: {err}"));
    };
    if let Some(outbounds) = current_json.get("outbounds").cloned() {
        let Some(object) = template_json.as_object_mut() else {
            return Err("upstream sing-box template is not a JSON object".to_string());
        };
        object.insert("outbounds".to_string(), outbounds);
    }
    if let Some(endpoints) = current_json.get("endpoints").cloned() {
        let Some(object) = template_json.as_object_mut() else {
            return Err("upstream sing-box template is not a JSON object".to_string());
        };
        object.insert("endpoints".to_string(), endpoints);
    }
    serde_json::to_string_pretty(&template_json)
        .map(|text| format!("{text}\n"))
        .map_err(|err| format!("serialize sing-box template: {err}"))
}

fn config_path(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "sing-box" | "singbox" | "all" => Ok(app.moddir.join(".config/sing-box/config.json")),
        _ => Err("config target must be sing-box".to_string()),
    }
}

fn default_config(_target: &str) -> String {
    r#"{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7892
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "magicnet0",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "exclude_uid": [
        0
      ],
      "route_exclude_address": [
        "192.168.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8",
        "fd7a:115c:a1e0::/48"
      ],
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "zashboard"
    }
  }
}
"#
    .to_string()
}

fn validate_config(app: &App, target: &str, _path: &Path) -> Result<(), String> {
    let directory = open_config_destination_directory(app, target)?;
    let name = OsStr::new(config_target_filename(target)?);
    let file = open_no_follow_file_at(&directory, name)?;
    validate_config_from_open_file(app, target, &file, &directory)
}

fn validate_config_with_data_directory(
    app: &App,
    target: &str,
    path: &Path,
    data_directory: Option<&Path>,
) -> Result<(), String> {
    let bin = match target {
        "sing-box" | "singbox" | "all" => app.moddir.join("bin/sing-box"),
        _ => return Err("config target must be sing-box".to_string()),
    };
    if !bin.exists() {
        return Err(format!("validator missing: {}", bin.display()));
    }
    let mut command = Command::new(bin);
    command.arg("check").arg("-c").arg(path);
    if let Some(data_directory) = data_directory {
        command.arg("-D").arg(data_directory);
    }
    let output = run_with_timeout(command, VALIDATOR_TIMEOUT)?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        Err(format!("config validation failed\n{stdout}\n{stderr}"))
    }
}

fn run_with_timeout(
    mut command: Command,
    timeout: Duration,
) -> Result<std::process::Output, String> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("run validator: {err}"))?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|err| format!("read validator output: {err}"))
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "config validation timed out after {}s",
                    timeout.as_secs()
                ));
            }
            Err(err) => return Err(format!("wait validator: {err}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos();
        App::for_test(std::env::temp_dir().join(format!(
            "magicnet-config-editor-test-{}-{stamp}",
            std::process::id()
        )))
    }

    #[test]
    fn default_sing_box_config_uses_mixed_tun_stack() {
        let config: serde_json::Value =
            serde_json::from_str(&default_config("sing-box")).expect("parse default config");
        let tun = config["inbounds"]
            .as_array()
            .and_then(|inbounds| inbounds.iter().find(|inbound| inbound["tag"] == "tun-in"))
            .expect("default TUN inbound");

        assert_eq!(tun["stack"].as_str(), Some("mixed"));
        assert_eq!(tun["exclude_uid"], serde_json::json!([0]));
        assert!(tun["route_exclude_address"]
            .as_array()
            .is_some_and(|routes| routes.iter().any(|route| route == "127.0.0.0/8")));
        assert!(tun["route_exclude_address"]
            .as_array()
            .is_some_and(|routes| routes.iter().any(|route| route == "::1/128")));
    }

    #[test]
    fn preserves_singbox_outbounds_block() {
        let template = r#"{
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {}
}
"#;
        let current = r#"{
  "outbounds": [
    { "type": "selector", "tag": "proxy" }
  ]
}
"#;
        let merged = preserve_singbox_subscription_config(template, current).unwrap();
        assert!(merged.contains("\"tag\": \"proxy\""));
        assert!(merged.contains("\"inbounds\": []"));
        assert!(merged.contains("\"route\": {}"));
    }

    #[test]
    fn template_hash_validation_rejects_mismatched_bytes() {
        let fixture = b"immutable template fixture";
        let expected = format!("{:x}", Sha256::digest(fixture));
        assert!(verify_expected_sha256(fixture, &expected, "fixture").is_ok());
        assert!(verify_expected_sha256(b"tampered", &expected, "fixture").is_err());
    }

    #[test]
    fn save_file_rejects_intermediate_and_final_symlink_escapes() {
        let app = temp_app();
        let payload_dir = app.moddir.join(".tmp/webui-payload");
        let outside = app.moddir.join("outside");
        fs::create_dir_all(&payload_dir).expect("create WebUI payload directory");
        fs::create_dir_all(&outside).expect("create outside directory");

        let victim = outside.join("victim.json");
        let final_symlink = payload_dir.join("candidate.json");
        fs::write(&victim, "preserve me").expect("write outside victim");
        symlink(&victim, &final_symlink).expect("create final symlink");
        assert!(
            open_webui_payload_source(&app, &final_symlink).is_err(),
            "final symlink must not be opened"
        );
        assert_eq!(
            fs::read_to_string(&victim).expect("read outside victim"),
            "preserve me"
        );

        let intermediate_symlink = payload_dir.join("escape");
        symlink(&outside, &intermediate_symlink).expect("create intermediate symlink");
        assert!(
            open_webui_payload_source(&app, &intermediate_symlink.join("candidate.json")).is_err(),
            "nested paths must not bypass the trusted directory boundary"
        );
    }

    #[test]
    fn save_file_accepts_only_the_webui_payload_temp_namespace() {
        let app = temp_app();
        let tmp = app.moddir.join(".tmp");
        let payload_dir = app.moddir.join(".tmp/webui-payload");
        let subscription_dir = app.moddir.join(".tmp/webui-subscription");
        let nested_dir = payload_dir.join("nested");
        fs::create_dir_all(&payload_dir).expect("create payload directory");
        fs::create_dir_all(&subscription_dir).expect("create subscription directory");
        fs::create_dir_all(&nested_dir).expect("create nested payload directory");
        let payload = payload_dir.join("candidate.json");
        let general_tmp = tmp.join("candidate.json");
        let subscription = subscription_dir.join("candidate.json");
        let nested = nested_dir.join("candidate.json");
        fs::write(&payload, "payload config").expect("write payload config");
        fs::write(&general_tmp, "general temporary config")
            .expect("write general temporary config");
        fs::write(&subscription, "subscription config").expect("write subscription config");
        fs::write(&nested, "nested payload config").expect("write nested payload config");

        assert!(
            open_webui_payload_source(&app, &payload).is_ok(),
            "direct webui payload file must be accepted"
        );
        assert!(
            open_webui_payload_source(&app, &general_tmp).is_err(),
            "general .tmp files must not be accepted as a config source"
        );
        assert!(
            open_webui_payload_source(&app, &subscription).is_err(),
            "subscription namespace must not be accepted as a config source"
        );
        assert!(
            open_webui_payload_source(&app, &nested).is_err(),
            "nested WebUI payload paths must not be accepted as a config source"
        );
    }

    #[test]
    fn validation_resolves_relative_resources_from_final_config_directory() {
        let app = temp_app();
        let bin_dir = app.moddir.join("bin");
        let payload_dir = app.moddir.join(".tmp/webui-payload");
        let rules_dir = app.moddir.join(".config/sing-box/rules");
        fs::create_dir_all(&bin_dir).expect("create bin directory");
        fs::create_dir_all(&payload_dir).expect("create WebUI payload directory");
        fs::create_dir_all(&rules_dir).expect("create final rules directory");

        let validator = bin_dir.join("sing-box");
        fs::write(
            &validator,
            r#"#!/bin/sh
config=
data=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c) config=$2; shift 2 ;;
    -D) data=$2; shift 2 ;;
    *) shift ;;
  esac
done
test -r "$config"
test -r "$data/rules/required.srs"
"#,
        )
        .expect("write fake validator");
        let mut permissions = fs::metadata(&validator)
            .expect("stat fake validator")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&validator, permissions).expect("make fake validator executable");

        fs::write(rules_dir.join("required.srs"), "compiled rule set")
            .expect("write final relative resource");
        let payload = payload_dir.join("candidate.json");
        fs::write(&payload, "{}\n").expect("write candidate config");

        let (source, _source_directory) =
            open_webui_payload_source(&app, &payload).expect("open candidate config");
        let target = config_path(&app, "sing-box").expect("resolve config target");
        validate_and_commit_open_config_file(&app, "sing-box", &target, &source)
            .expect("validate candidate against final config directory");

        assert_eq!(
            fs::read_to_string(target).expect("read committed config"),
            "{}\n"
        );
    }

    #[test]
    fn save_file_rejects_hard_linked_webui_payloads() {
        let app = temp_app();
        let payload_dir = app.moddir.join(".tmp/webui-payload");
        let original = app.moddir.join("original.json");
        let payload = payload_dir.join("candidate.json");
        fs::create_dir_all(&payload_dir).expect("create payload directory");
        fs::write(&original, "preserve me").expect("write original payload");
        fs::hard_link(&original, &payload).expect("create payload hard link");

        assert!(open_webui_payload_source(&app, &payload).is_err());
        assert_eq!(
            fs::read_to_string(original).expect("read original payload"),
            "preserve me"
        );
    }

    #[test]
    fn config_destination_rejects_intermediate_symlinks() {
        let app = temp_app();
        let outside = app.moddir.join("outside");
        fs::create_dir_all(&app.moddir).expect("create module directory");
        fs::create_dir_all(&outside).expect("create outside directory");
        symlink(&outside, app.moddir.join(".config")).expect("create config symlink");

        assert!(open_config_destination_directory(&app, "sing-box").is_err());
        assert!(
            !outside.join("sing-box").exists(),
            "destination setup must not create through a .config symlink"
        );

        let second = temp_app();
        let second_outside = second.moddir.join("outside");
        fs::create_dir_all(second.moddir.join(".config")).expect("create config directory");
        fs::create_dir_all(&second_outside).expect("create second outside directory");
        symlink(&second_outside, second.moddir.join(".config/sing-box"))
            .expect("create sing-box symlink");

        assert!(open_config_destination_directory(&second, "sing-box").is_err());
        assert!(
            !second_outside.join("config.json").exists(),
            "destination setup must not create through a sing-box symlink"
        );
    }

    #[test]
    fn generated_config_input_never_writes_through_a_legacy_stage_symlink() {
        let app = temp_app();
        let tmp = app.moddir.join(".tmp");
        let victim = app.moddir.join("victim");
        let legacy = tmp.join("config-editor-sing-box.tmp");
        fs::create_dir_all(&tmp).expect("create temporary directory");
        fs::write(&victim, "preserve me").expect("write victim");
        symlink(&victim, &legacy).expect("create legacy stage symlink");

        with_generated_config_input(&app, "input", b"new config", |file, _directory| {
            assert_eq!(file.metadata().expect("stat generated input").len(), 10);
            Ok::<(), String>(())
        })
        .expect("write generated config input safely");

        assert_eq!(
            fs::read_to_string(&victim).expect("read victim"),
            "preserve me"
        );
        assert!(fs::symlink_metadata(legacy)
            .expect("stat legacy stage")
            .file_type()
            .is_symlink());
    }

    #[test]
    fn save_file_snapshot_is_immutable_after_same_inode_mutation() {
        let app = temp_app();
        let payload_dir = app.moddir.join(".tmp/webui-payload");
        fs::create_dir_all(&payload_dir).expect("create WebUI payload directory");
        let candidate = payload_dir.join("candidate.json");
        fs::write(&candidate, "validated contents").expect("write candidate");
        let (validated_file, _tmp_directory) =
            open_webui_payload_source(&app, &candidate).expect("open trusted candidate");
        let target = config_path(&app, "sing-box").expect("config target");
        let directory =
            open_config_destination_directory(&app, "sing-box").expect("open config target parent");
        let (snapshot, staged_name) =
            snapshot_config_file(&validated_file, &directory).expect("copy immutable snapshot");

        let alias = payload_dir.join("candidate-alias.json");
        fs::hard_link(&candidate, &alias).expect("link same candidate inode");
        fs::write(&alias, "attacker same-inode mutation").expect("mutate candidate inode");
        let target_name = OsStr::new("config.json");

        commit_staged_config_file(&directory, &staged_name, target_name, &target)
            .expect("commit the immutable snapshot");
        drop(snapshot);

        assert_eq!(
            fs::read_to_string(target).expect("read committed target"),
            "validated contents"
        );
    }

    #[test]
    fn backup_replaces_a_symlink_without_following_its_target() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let target = config_path(&app, "sing-box").expect("config target");
        let directory =
            open_config_destination_directory(&app, "sing-box").expect("open config parent");
        fs::write(&target, "old config").expect("write current config");
        let victim = app.moddir.join("outside-victim");
        let backup = target.with_file_name("config.json.bak");
        fs::write(&victim, "preserve me").expect("write backup victim");
        symlink(&victim, &backup).expect("create backup symlink");

        backup_config_at(&directory, OsStr::new("config.json"))
            .expect("replace backup entry safely");

        assert_eq!(
            fs::read_to_string(&victim).expect("read backup victim"),
            "preserve me"
        );
        assert!(
            !fs::symlink_metadata(&backup)
                .expect("stat backup")
                .file_type()
                .is_symlink(),
            "backup path must be replaced rather than followed"
        );
        assert_eq!(
            fs::read_to_string(backup).expect("read backup"),
            "old config"
        );
    }
}
