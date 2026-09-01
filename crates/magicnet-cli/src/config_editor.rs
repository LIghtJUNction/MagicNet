use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq)]
struct SingboxRepository {
    url: String,
    reference: String,
    path: String,
    sha256: Option<String>,
}

use crate::service::apply_config;
use crate::webui_payload::MAX_WEBUI_PAYLOAD_BYTES;
use crate::{cstring_from_os_str, decode_base64, write_secret_file, write_text_file, App};

const VALIDATOR_TIMEOUT: Duration = Duration::from_secs(20);
const TEMPLATE_FETCH_TIMEOUT: Duration = Duration::from_secs(45);
const TEMPLATE_MAX_BYTES: usize = 1024 * 1024;
const VALIDATOR_OUTPUT_LIMIT: usize = 256 * 1024;
const CONFIG_REPOSITORY_MAX_BYTES: usize = 16 * 1024;
const MAGIC_SINGBOX_REPOSITORY: &str = "https://github.com/LIghtJUNction/MagicSingBox.git";
const MAGIC_SINGBOX_REPOSITORY_REF: &str = "63780ca3a96ee65af18b17aa87e11b536bbc5a73";
const MAGIC_SINGBOX_REPOSITORY_PATH: &str = "config.json";
const MAGIC_SINGBOX_REPOSITORY_SHA256: &str =
    "ba0f9057b2b6ac896a8783a5691388325306be066e81c4098d9f62d79ac7ee50";
const SINGBOX_REPOSITORY_CONFIG: &str = ".config/magicnet/singbox-config-repo.conf";
const STANDALONE_CONFIG_MARKER: &str = ".config/sing-box/standalone-config";
const TAILSCALE_AUTH_PATH: &str = ".config/sing-box/tailscale-auth.json";
static CONFIG_EDITOR_STAGE_SEQUENCE: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn config_editor(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or_default();
    if action == "repo" || action == "repository" {
        return config_repository(app, &args[1..]);
    }
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
            "Usage: cli config-editor {get|path|validate|save|save-file|sync-template} <sing-box|all> [base64-config|webui-payload-path] | repo {get|set|set-file|reset} [base64-json|webui-payload-path]"
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
    commit_standalone_config(app, target, path, &text)
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
    commit_standalone_config(app, target, path, &text)
}

fn commit_standalone_config(
    app: &App,
    target: &str,
    path: &Path,
    text: &str,
) -> Result<(), String> {
    let protected = protect_tailscale_auth_keys(app, text)?;
    commit_config_text(
        app,
        target,
        path,
        protected.text.as_bytes(),
        "input",
        protected.keys.as_deref(),
    )?;
    mark_standalone_config(app)
}

struct ProtectedConfig {
    text: String,
    keys: Option<String>,
}

fn protect_tailscale_auth_keys(app: &App, text: &str) -> Result<ProtectedConfig, String> {
    let Ok(mut config) = serde_json::from_str::<JsonValue>(text) else {
        return Ok(ProtectedConfig {
            text: text.to_string(),
            keys: None,
        });
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
        return Ok(ProtectedConfig {
            text: text.to_string(),
            keys: None,
        });
    }
    let protected_keys = serde_json::to_string(&JsonValue::Object(keys))
        .map_err(|err| format!("serialize protected Tailscale auth keys: {err}"))?;
    let text = serde_json::to_string_pretty(&config)
        .map(|value| format!("{value}\n"))
        .map_err(|err| format!("serialize sing-box config: {err}"))?;
    Ok(ProtectedConfig {
        text,
        keys: Some(protected_keys),
    })
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
#[cfg(test)]
fn validate_and_commit_open_config_file(
    app: &App,
    target: &str,
    path: &Path,
    source: &File,
) -> Result<(), String> {
    validate_and_commit_open_config_file_with(app, target, path, source, || Ok(()))
}

fn validate_and_commit_open_config_file_with(
    app: &App,
    target: &str,
    path: &Path,
    source: &File,
    before_commit: impl FnOnce() -> Result<(), String>,
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
        before_commit()?;
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
    protected_keys: Option<&str>,
) -> Result<(), String> {
    with_generated_config_input(app, role, bytes, |source, _directory| {
        validate_and_commit_open_config_file_with(app, target, path, source, || {
            if let Some(keys) = protected_keys {
                write_secret_file(app, Path::new(TAILSCALE_AUTH_PATH), keys)?;
            }
            Ok(())
        })
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

fn config_repository(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "get" => {
            let (repository, configured) = read_repository_config(app)?;
            let (host, path) = repository_identity(&repository.url)?;
            println!("source={}", if configured { "custom" } else { "default" });
            println!("host={host}");
            println!("repository={path}");
            println!("ref={}", repository.reference);
            println!("file={}", repository.path);
            println!(
                "sha256={}",
                if repository.sha256.is_some() {
                    "pinned"
                } else {
                    "none"
                }
            );
            Ok(())
        }
        "get-json" => {
            let (repository, _configured) = read_repository_config(app)?;
            let mut object = serde_json::Map::new();
            object.insert("url".to_string(), JsonValue::String(repository.url));
            object.insert(
                "reference".to_string(),
                JsonValue::String(repository.reference),
            );
            object.insert("path".to_string(), JsonValue::String(repository.path));
            if let Some(sha256) = repository.sha256 {
                object.insert("sha256".to_string(), JsonValue::String(sha256));
            }
            println!("{}", JsonValue::Object(object));
            Ok(())
        }
        "set" => {
            let payload = args.get(1).map(String::as_str).unwrap_or_default();
            if payload.is_empty() {
                return Err("Usage: cli config-editor repo set <base64-json>".to_string());
            }
            let bytes = decode_base64(payload)?;
            let text = String::from_utf8(bytes)
                .map_err(|err| format!("config repository payload is not UTF-8: {err}"))?;
            let repository = parse_repository_json(&text)?;
            write_repository_config(app, &repository)?;
            println!("[info] Config repository saved");
            Ok(())
        }
        "set-file" => {
            let path = args.get(1).map(PathBuf::from).unwrap_or_default();
            if path.as_os_str().is_empty() {
                return Err("Usage: cli config-editor repo set-file <webui-payload-path>".to_string());
            }
            let (source, _tmp_directory) = open_webui_payload_source(app, &path)?;
            let mut bytes = Vec::new();
            source
                .take((CONFIG_REPOSITORY_MAX_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|err| format!("read config repository payload: {err}"))?;
            if bytes.len() > CONFIG_REPOSITORY_MAX_BYTES {
                return Err(format!(
                    "config repository payload exceeds the {CONFIG_REPOSITORY_MAX_BYTES} byte limit"
                ));
            }
            let text = String::from_utf8(bytes)
                .map_err(|err| format!("config repository payload is not UTF-8: {err}"))?;
            let repository = parse_repository_json(&text)?;
            write_repository_config(app, &repository)?;
            println!("[info] Config repository saved");
            Ok(())
        }
        "reset" => {
            write_repository_config(app, &default_repository())?;
            println!("[info] Config repository reset to default");
            Ok(())
        }
        _ => Err(
            "Usage: cli config-editor repo {get|get-json|set|set-file|reset} [base64-json|webui-payload-path]"
                .to_string(),
        ),
    }
}

fn default_repository() -> SingboxRepository {
    SingboxRepository {
        url: MAGIC_SINGBOX_REPOSITORY.to_string(),
        reference: MAGIC_SINGBOX_REPOSITORY_REF.to_string(),
        path: MAGIC_SINGBOX_REPOSITORY_PATH.to_string(),
        sha256: Some(MAGIC_SINGBOX_REPOSITORY_SHA256.to_string()),
    }
}

fn repository_config_path(app: &App) -> PathBuf {
    app.moddir.join(SINGBOX_REPOSITORY_CONFIG)
}

fn read_repository_config(app: &App) -> Result<(SingboxRepository, bool), String> {
    let path = repository_config_path(app);
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            return Ok((default_repository(), false));
        }
        Err(err) => return Err(format!("inspect config repository settings: {err}")),
    };
    if !metadata.file_type().is_file() {
        return Err("config repository settings must be a regular file".to_string());
    }
    let bytes = fs::read(&path).map_err(|err| format!("read config repository settings: {err}"))?;
    if bytes.len() > CONFIG_REPOSITORY_MAX_BYTES {
        return Err(format!(
            "config repository settings exceed the {CONFIG_REPOSITORY_MAX_BYTES} byte limit"
        ));
    }
    let text = String::from_utf8(bytes)
        .map_err(|err| format!("config repository settings are not UTF-8: {err}"))?;
    Ok((parse_repository_conf(&text)?, true))
}

pub(crate) fn validate_repository_config_text(text: &str) -> bool {
    parse_repository_conf(text).is_ok()
}

fn parse_repository_conf(text: &str) -> Result<SingboxRepository, String> {
    let mut values = std::collections::BTreeMap::<&str, &str>::new();
    for (index, raw_line) in text.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| format!("invalid config repository setting at line {}", index + 1))?;
        let key = key.trim();
        let value = value.trim();
        if !matches!(
            key,
            "MAGICNET_SINGBOX_CONFIG_REPO_URL"
                | "MAGICNET_SINGBOX_CONFIG_REPO_REF"
                | "MAGICNET_SINGBOX_CONFIG_REPO_PATH"
                | "MAGICNET_SINGBOX_CONFIG_REPO_SHA256"
        ) {
            return Err(format!(
                "unknown config repository setting at line {}",
                index + 1
            ));
        }
        if values.insert(key, value).is_some() {
            return Err(format!(
                "duplicate config repository setting at line {}",
                index + 1
            ));
        }
    }
    let defaults = default_repository();
    repository_from_values(
        values
            .get("MAGICNET_SINGBOX_CONFIG_REPO_URL")
            .copied()
            .unwrap_or(&defaults.url),
        values
            .get("MAGICNET_SINGBOX_CONFIG_REPO_REF")
            .copied()
            .unwrap_or(&defaults.reference),
        values
            .get("MAGICNET_SINGBOX_CONFIG_REPO_PATH")
            .copied()
            .unwrap_or(&defaults.path),
        values
            .get("MAGICNET_SINGBOX_CONFIG_REPO_SHA256")
            .copied()
            .filter(|value| !value.is_empty()),
    )
}

fn parse_repository_json(text: &str) -> Result<SingboxRepository, String> {
    let value: JsonValue = serde_json::from_str(text)
        .map_err(|err| format!("config repository payload is invalid JSON: {err}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| "config repository payload must be a JSON object".to_string())?;
    let string_value = |key: &str| -> Result<Option<&str>, String> {
        match object.get(key) {
            None => Ok(None),
            Some(value) => value
                .as_str()
                .map(Some)
                .ok_or_else(|| format!("config repository field {key} must be a string")),
        }
    };
    let defaults = default_repository();
    let reference = string_value("ref")?;
    let reference_alias = string_value("reference")?;
    let reference = match (reference, reference_alias) {
        (Some(reference), Some(reference_alias)) if reference != reference_alias => {
            return Err("config repository ref and reference fields disagree".to_string());
        }
        (Some(reference), _) | (_, Some(reference)) => reference,
        (None, None) => &defaults.reference,
    };
    repository_from_values(
        string_value("url")?.unwrap_or(&defaults.url),
        reference,
        string_value("path")?.unwrap_or(&defaults.path),
        string_value("sha256")?.filter(|value| !value.is_empty()),
    )
}

fn repository_from_values(
    url: &str,
    reference: &str,
    path: &str,
    sha256: Option<&str>,
) -> Result<SingboxRepository, String> {
    let url = normalize_repository_url(url)?;
    let reference = validate_repository_component(reference, "ref", true)?;
    let path = validate_repository_component(path, "file", true)?;
    let mut sha256 = sha256
        .map(|value| {
            if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                Err("config repository sha256 must be 64 hexadecimal characters".to_string())
            } else {
                Ok(value.to_ascii_lowercase())
            }
        })
        .transpose()?;
    // The bundled repository is a trust anchor. Keep compatibility with the
    // pre-pin `main` setting by upgrading that exact legacy value, but never
    // allow the default source to remain mutable without an explicit digest.
    let mut reference = reference;
    if url == MAGIC_SINGBOX_REPOSITORY && sha256.is_none() {
        if path == MAGIC_SINGBOX_REPOSITORY_PATH && reference == "main" {
            reference = MAGIC_SINGBOX_REPOSITORY_REF.to_string();
            sha256 = Some(MAGIC_SINGBOX_REPOSITORY_SHA256.to_string());
        } else {
            return Err("default config repository requires a sha256 pin".to_string());
        }
    }
    Ok(SingboxRepository {
        url,
        reference,
        path,
        sha256,
    })
}

fn normalize_repository_url(value: &str) -> Result<String, String> {
    let rest = value
        .strip_prefix("https://")
        .ok_or_else(|| "config repository must use HTTPS".to_string())?;
    if rest.is_empty()
        || rest.contains(['?', '#', '@', ':', '\\', '\r', '\n'])
        || rest.ends_with('/')
    {
        return Err("config repository URL is invalid".to_string());
    }
    let (host, path) = rest
        .split_once('/')
        .ok_or_else(|| "config repository URL must include a repository path".to_string())?;
    if host != "github.com" && host != "gitlab.com" {
        return Err("config repository host must be github.com or gitlab.com".to_string());
    }
    let path = path.trim_end_matches(".git");
    if path.is_empty()
        || path.starts_with('/')
        || path.ends_with('/')
        || path.split('/').any(|part| {
            part.is_empty()
                || part == "."
                || part == ".."
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
    {
        return Err("config repository path is invalid".to_string());
    }
    if host == "github.com" && path.split('/').count() != 2 {
        return Err("GitHub repository URL must be https://github.com/<owner>/<repo>".to_string());
    }
    Ok(format!("https://{host}/{path}.git"))
}

fn validate_repository_component(
    value: &str,
    label: &str,
    allow_slash: bool,
) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 256
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b'\\')
        || value.starts_with('/')
        || value.ends_with('/')
        || value
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
        || (!allow_slash && value.contains('/'))
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'/'))
    {
        return Err(format!("config repository {label} is invalid"));
    }
    Ok(value.to_string())
}

fn repository_identity(url: &str) -> Result<(&str, &str), String> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| "config repository must use HTTPS".to_string())?;
    let (host, path) = rest
        .split_once('/')
        .ok_or_else(|| "config repository URL is invalid".to_string())?;
    Ok((host, path.trim_end_matches(".git")))
}

fn repository_file_url(repository: &SingboxRepository) -> Result<String, String> {
    let (host, repository_path) = repository_identity(&repository.url)?;
    let repository_path = repository_path.trim_end_matches('/');
    let path = &repository.path;
    match host {
        "github.com" => Ok(format!(
            "https://raw.githubusercontent.com/{repository_path}/{}/{path}",
            repository.reference
        )),
        "gitlab.com" => Ok(format!(
            "https://gitlab.com/{repository_path}/-/raw/{}/{path}",
            repository.reference
        )),
        _ => Err("config repository host is unsupported".to_string()),
    }
}

fn write_repository_config(app: &App, repository: &SingboxRepository) -> Result<(), String> {
    let mut text = format!(
        "MAGICNET_SINGBOX_CONFIG_REPO_URL={}\nMAGICNET_SINGBOX_CONFIG_REPO_REF={}\nMAGICNET_SINGBOX_CONFIG_REPO_PATH={}\n",
        repository.url, repository.reference, repository.path
    );
    if let Some(sha256) = &repository.sha256 {
        text.push_str(&format!("MAGICNET_SINGBOX_CONFIG_REPO_SHA256={sha256}\n"));
    }
    write_secret_file(app, Path::new(SINGBOX_REPOSITORY_CONFIG), &text)
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
    let repository = read_repository_config(app)?.0;
    let url = repository_file_url(&repository)?;
    let template = fetch_template(&url, repository.sha256.as_deref())?;
    let current = read_current_config(app, target)?.unwrap_or_default();
    let merged = prepare_template(target, &template, &current)?;
    commit_config_text(app, target, &path, merged.as_bytes(), "template", None)?;
    apply_config(app)?;
    println!(
        "[info] Synced {target} template from configured Git repository\n[info] Preserved subscription-facing config and re-applied runtime rules."
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

fn fetch_template(url: &str, expected_sha256: Option<&str>) -> Result<String, String> {
    fetch_template_with_curl(
        Path::new("curl"),
        url,
        expected_sha256,
        TEMPLATE_FETCH_TIMEOUT,
        TEMPLATE_FETCH_TIMEOUT + Duration::from_secs(5),
    )
}

fn fetch_template_with_curl(
    curl_program: &Path,
    url: &str,
    expected_sha256: Option<&str>,
    fetch_timeout: Duration,
    command_timeout: Duration,
) -> Result<String, String> {
    let mut command = Command::new(curl_program);
    command
        .arg("-fsSL")
        .arg("--proto")
        .arg("=https")
        .arg("--proto-redir")
        .arg("=https")
        .arg("--max-filesize")
        .arg(TEMPLATE_MAX_BYTES.to_string())
        .arg("--max-time")
        .arg(fetch_timeout.as_secs().max(1).to_string())
        .arg(url);
    let output = crate::run_bounded_command(command, command_timeout, TEMPLATE_MAX_BYTES + 1)
        .map_err(|_| "fetch template failed: repository request did not complete".to_string())?;
    if output.timed_out {
        return Err("fetch template failed: repository request timed out".to_string());
    }
    if output.truncated || output.stdout.len() > TEMPLATE_MAX_BYTES {
        return Err(format!(
            "fetch template failed: response exceeds {TEMPLATE_MAX_BYTES} byte limit"
        ));
    }
    let status = output.status.ok_or_else(|| {
        "fetch template failed: repository request had no exit status".to_string()
    })?;
    if !status.success() {
        return Err("fetch template failed: repository is unavailable".to_string());
    }
    if let Some(expected_sha256) = expected_sha256 {
        verify_expected_sha256(
            &output.stdout,
            expected_sha256,
            "configured sing-box template",
        )?;
    }
    String::from_utf8(output.stdout).map_err(|err| format!("template is not UTF-8: {err}"))
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

fn run_with_timeout(command: Command, timeout: Duration) -> Result<std::process::Output, String> {
    let output = crate::run_bounded_command(command, timeout, VALIDATOR_OUTPUT_LIMIT)
        .map_err(|err| format!("run validator: {err}"))?;
    if output.timed_out {
        return Err(format!(
            "config validation timed out after {}s",
            timeout.as_secs()
        ));
    }
    let status = output
        .status
        .ok_or_else(|| "validator exited without a status".to_string())?;
    Ok(std::process::Output {
        status,
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};

    use super::*;
    use crate::test_support::temp_app;

    #[test]
    fn validator_runner_drains_output_without_unbounded_retention(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut command = Command::new("sh");
        command.args([
            "-c",
            "chunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 16384 ]; do printf %s \"$chunk\"; i=$((i + 1)); done",
        ]);
        let output =
            run_with_timeout(command, Duration::from_secs(8)).map_err(std::io::Error::other)?;
        assert!(output.status.success());
        assert_eq!(
            output.stdout.len(),
            VALIDATOR_OUTPUT_LIMIT + "\n[output truncated]".len()
        );
        assert!(output.stdout.ends_with(b"[output truncated]"));
        Ok(())
    }

    #[test]
    fn template_fetch_checks_the_configured_hash() {
        let fixture = temp_app();
        let curl = fixture.moddir.join("curl");
        fs::write(
            &curl,
            "#!/bin/sh\nprintf '%s' '{\"inbounds\":[],\"outbounds\":[]}'\n",
        )
        .expect("curl fixture");
        fs::set_permissions(&curl, fs::Permissions::from_mode(0o755)).expect("curl executable");
        let expected = format!("{:x}", Sha256::digest(br#"{"inbounds":[],"outbounds":[]}"#));
        let template = fetch_template_with_curl(
            &curl,
            "https://github.com/example/repository/config.json",
            Some(&expected),
            Duration::from_secs(2),
            Duration::from_secs(3),
        )
        .expect("fetch fixture");
        assert!(template.contains("inbounds"));
    }

    #[test]
    fn template_fetch_rejects_timeout_and_nonzero_exit_without_partial_config() {
        let fixture = temp_app();
        let curl = fixture.moddir.join("curl");
        fs::write(&curl, "#!/bin/sh\nsleep 5\n").expect("slow curl fixture");
        fs::set_permissions(&curl, fs::Permissions::from_mode(0o755)).expect("curl executable");
        let timeout = fetch_template_with_curl(
            &curl,
            "https://github.com/example/repository/config.json",
            None,
            Duration::from_millis(20),
            Duration::from_millis(100),
        )
        .expect_err("slow fetch must time out");
        assert!(timeout.contains("timed out"));

        fs::write(&curl, "#!/bin/sh\nexit 22\n").expect("failing curl fixture");
        let unavailable = fetch_template_with_curl(
            &curl,
            "https://github.com/example/repository/config.json",
            None,
            Duration::from_secs(2),
            Duration::from_secs(3),
        )
        .expect_err("nonzero fetch must fail");
        assert!(unavailable.contains("unavailable"));

        fs::write(
            &curl,
            "#!/bin/sh\nchunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 131072 ]; do printf %s \"$chunk\"; i=$((i + 1)); done\n",
        )
        .expect("oversized curl fixture");
        let oversized = fetch_template_with_curl(
            &curl,
            "https://github.com/example/repository/config.json",
            None,
            Duration::from_secs(2),
            Duration::from_secs(3),
        )
        .expect_err("oversized fetch must fail");
        assert!(oversized.contains("exceeds"));
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
    fn tailscale_keys_are_staged_in_memory_until_config_validation(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let app = temp_app();
        let protected = protect_tailscale_auth_keys(
            &app,
            r#"{"endpoints":[{"type":"tailscale","tag":"tailscale","auth_key":"tskey-secret"}]}"#,
        )
        .map_err(std::io::Error::other)?;

        assert!(!protected.text.contains("tskey-secret"));
        assert!(protected
            .keys
            .as_deref()
            .is_some_and(|keys| keys.contains("tskey-secret")));
        assert!(!app.moddir.join(TAILSCALE_AUTH_PATH).exists());
        Ok(())
    }

    #[test]
    fn preserves_singbox_outbounds_block() -> Result<(), Box<dyn std::error::Error>> {
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
        let merged = preserve_singbox_subscription_config(template, current)
            .map_err(std::io::Error::other)?;
        assert!(merged.contains("\"tag\": \"proxy\""));
        assert!(merged.contains("\"inbounds\": []"));
        assert!(merged.contains("\"route\": {}"));
        Ok(())
    }

    #[test]
    fn template_hash_validation_rejects_mismatched_bytes() {
        let fixture = b"immutable template fixture";
        let expected = format!("{:x}", Sha256::digest(fixture));
        assert!(verify_expected_sha256(fixture, &expected, "fixture").is_ok());
        assert!(verify_expected_sha256(b"tampered", &expected, "fixture").is_err());
    }

    #[test]
    fn repository_defaults_to_magic_singbox_and_builds_a_raw_url() {
        let repository = default_repository();
        assert_eq!(repository.url, MAGIC_SINGBOX_REPOSITORY);
        assert_eq!(
            repository_file_url(&repository).expect("default repository URL"),
            "https://raw.githubusercontent.com/LIghtJUNction/MagicSingBox/63780ca3a96ee65af18b17aa87e11b536bbc5a73/config.json"
        );
        assert_eq!(
            repository.sha256.as_deref(),
            Some(MAGIC_SINGBOX_REPOSITORY_SHA256)
        );
    }

    #[test]
    fn repository_settings_accept_custom_github_and_gitlab_repositories() {
        let github = parse_repository_json(
            r#"{"url":"https://github.com/example/magic-config.git","ref":"feature/v2","path":"configs/sing-box.json"}"#,
        )
        .expect("custom GitHub repository");
        assert_eq!(
            repository_file_url(&github).expect("custom GitHub raw URL"),
            "https://raw.githubusercontent.com/example/magic-config/feature/v2/configs/sing-box.json"
        );

        let gitlab = parse_repository_json(
            r#"{"url":"https://gitlab.com/example/team/magic-config","ref":"stable","path":"config.json"}"#,
        )
        .expect("custom GitLab repository");
        assert_eq!(
            repository_file_url(&gitlab).expect("custom GitLab raw URL"),
            "https://gitlab.com/example/team/magic-config/-/raw/stable/config.json"
        );

        let exported = parse_repository_json(
            r#"{"url":"https://github.com/example/magic-config.git","reference":"feature/v2","path":"configs/sing-box.json"}"#,
        )
        .expect("get-json output must be accepted again");
        assert_eq!(exported.reference, "feature/v2");
    }

    #[test]
    fn repository_settings_reject_downgrade_credentials_and_path_escape() {
        assert!(parse_repository_json(r#"{"url":"http://github.com/example/repo"}"#).is_err());
        assert!(
            parse_repository_json(r#"{"url":"https://user:pass@github.com/example/repo"}"#)
                .is_err()
        );
        assert!(parse_repository_json(
            r#"{"url":"https://github.com/example/repo","path":"../config.json"}"#
        )
        .is_err());
        assert!(parse_repository_json(r#"{"url":"https://example.invalid/repo"}"#).is_err());
        assert!(parse_repository_json(
            r#"{"url":"https://github.com/example/repo","ref":"main","reference":"stable"}"#
        )
        .is_err());
        let legacy_default = parse_repository_json(
            r#"{"url":"https://github.com/LIghtJUNction/MagicSingBox.git","ref":"main","path":"config.json"}"#,
        )
        .expect("legacy default must be upgraded to its pin");
        assert_eq!(legacy_default.reference, MAGIC_SINGBOX_REPOSITORY_REF);
        assert_eq!(
            legacy_default.sha256.as_deref(),
            Some(MAGIC_SINGBOX_REPOSITORY_SHA256)
        );
        assert!(parse_repository_json(
            r#"{"url":"https://github.com/LIghtJUNction/MagicSingBox.git","ref":"stable","path":"config.json"}"#
        )
        .is_err());
    }

    #[test]
    fn repository_settings_are_read_without_printing_the_repository_url() {
        let text = "MAGICNET_SINGBOX_CONFIG_REPO_URL=https://github.com/example/repo.git\nMAGICNET_SINGBOX_CONFIG_REPO_REF=main\nMAGICNET_SINGBOX_CONFIG_REPO_PATH=config.json\n";
        let parsed = parse_repository_conf(text).expect("repository settings");
        assert_eq!(parsed.reference, "main");
        assert_eq!(parsed.path, "config.json");
        assert_eq!(repository_identity(&parsed.url).unwrap().0, "github.com");
    }

    #[test]
    fn repository_settings_reject_a_symlink_without_reading_its_target() {
        let fixture = temp_app();
        let path = repository_config_path(&fixture);
        fs::create_dir_all(path.parent().expect("repository parent"))
            .expect("repository directory");
        let target = fixture.moddir.join("repository-target.conf");
        fs::write(
            &target,
            "MAGICNET_SINGBOX_CONFIG_REPO_URL=https://github.com/example/repo.git\nMAGICNET_SINGBOX_CONFIG_REPO_REF=main\nMAGICNET_SINGBOX_CONFIG_REPO_PATH=config.json\n",
        )
        .expect("repository target");
        symlink(&target, &path).expect("repository symlink");
        let error = read_repository_config(&fixture).expect_err("symlink must be rejected");
        assert!(error.contains("regular file"));
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
    #[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
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
    #[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
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
