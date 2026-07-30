use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, ErrorKind, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::App;

pub(crate) fn command_text_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    compact_command_output(&command_text_full_timeout(program, args, timeout))
}

pub(crate) fn command_text_full_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => return format!("{program} not available: {err}"),
    };
    let stdout_reader = child.stdout.take().map(spawn_output_reader);
    let stderr_reader = child.stderr.take().map(spawn_output_reader);
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return match join_output_readers(stdout_reader, stderr_reader) {
                    Ok((stdout, stderr)) => merge_command_output(&stdout, &stderr),
                    Err(err) => err,
                };
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(40)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = join_output_readers(stdout_reader, stderr_reader);
                return format!("timeout after {}ms", timeout.as_millis());
            }
            Err(err) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = join_output_readers(stdout_reader, stderr_reader);
                return format!("wait failed: {err}");
            }
        }
    }
}

type OutputReader = thread::JoinHandle<std::io::Result<Vec<u8>>>;

fn spawn_output_reader<R>(mut reader: R) -> OutputReader
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut output = Vec::new();
        reader.read_to_end(&mut output)?;
        Ok(output)
    })
}

fn join_output_readers(
    stdout: Option<OutputReader>,
    stderr: Option<OutputReader>,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let stdout = join_output_reader(stdout, "stdout");
    let stderr = join_output_reader(stderr, "stderr");
    match (stdout, stderr) {
        (Ok(stdout), Ok(stderr)) => Ok((stdout, stderr)),
        (Err(err), _) | (_, Err(err)) => Err(err),
    }
}

fn join_output_reader(reader: Option<OutputReader>, name: &str) -> Result<Vec<u8>, String> {
    match reader {
        Some(reader) => match reader.join() {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(err)) => Err(format!("read failed: {name}: {err}")),
            Err(_) => Err(format!("read failed: {name} reader thread panicked")),
        },
        None => Err(format!("read failed: {name} pipe unavailable")),
    }
}

pub(crate) fn clean_lines(path: PathBuf) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

/// Reads a text file through the same module-root fd boundary used by the
/// writers. Missing or malformed ordinary list files retain `clean_lines`'
/// empty-list semantics, while symlinks, nonregular files, and hard links are
/// rejected instead of being silently followed.
pub(crate) fn clean_module_lines(app: &App, relative: &Path) -> Result<Vec<String>, String> {
    let target = split_module_relative_file(relative)?;
    let directory = open_module_directory(app, &target.directory)?;
    let Some(mut file) = open_existing_private_module_file(&directory, &target.name)? else {
        return Ok(Vec::new());
    };
    let mut text = String::new();
    if file.read_to_string(&mut text).is_err() {
        return Ok(Vec::new());
    }
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect())
}

pub(crate) fn first_clean_line(path: PathBuf) -> String {
    clean_lines(path).into_iter().next().unwrap_or_default()
}

/// Writes an ordinary file below `app.moddir` without resolving any
/// caller-supplied absolute path. Every component must be a normal relative
/// component and is opened from the module root descriptor with `O_NOFOLLOW`.
pub(crate) fn write_text_file(app: &App, relative: &Path, text: &str) -> Result<(), String> {
    write_module_file(app, relative, text, ModuleFileKind::Text)
}

/// Like [`write_text_file`], but makes the final file exactly `0600` before
/// its first byte is written. This is for WireGuard keys, tokens, and other
/// on-disk secrets that must never be world-readable.
pub(crate) fn write_secret_file(app: &App, relative: &Path, text: &str) -> Result<(), String> {
    write_module_file(app, relative, text, ModuleFileKind::Secret)
}

#[derive(Clone, Copy)]
enum ModuleFileKind {
    Text,
    Secret,
}

fn write_module_file(
    app: &App,
    relative: &Path,
    text: &str,
    kind: ModuleFileKind,
) -> Result<(), String> {
    let mut components = module_relative_components(relative)?;
    let name = components
        .pop()
        .expect("nonempty module-relative path has a final component");
    let mut directory = open_module_root(app)?;
    for component in components {
        directory = ensure_module_directory_at(&directory, component)?;
    }

    // No O_TRUNC is used: bind and validate the final inode first, then
    // truncate the already-open descriptor. This rejects symlinks, devices,
    // directories, and hard-linked files before any existing bytes change.
    let mut file = open_module_output_file(&directory, name, kind)?;
    require_private_regular_module_file(&file)?;
    if matches!(kind, ModuleFileKind::Secret) {
        // `openat(..., 0600)` is still filtered by the process umask. Set the
        // exact final mode before truncating or writing secret material.
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|err| format!("secure module secret: {err}"))?;
    }
    file.set_len(0)
        .map_err(|err| format!("truncate module file: {err}"))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|err| format!("seek module file: {err}"))?;
    file.write_all(text.as_bytes())
        .map_err(|err| format!("write module file: {err}"))
}

fn module_relative_components(relative: &Path) -> Result<Vec<&OsStr>, String> {
    let components = normal_module_components(relative)?;
    if components.is_empty() {
        Err("module file path must be a nonempty normal relative path".to_string())
    } else {
        Ok(components)
    }
}

fn normal_module_components(relative: &Path) -> Result<Vec<&OsStr>, String> {
    let mut components = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => components.push(name),
            Component::CurDir
            | Component::ParentDir
            | Component::RootDir
            | Component::Prefix(_) => {
                return Err("module path must contain only normal relative components".to_string())
            }
        }
    }
    Ok(components)
}

fn open_module_root(app: &App) -> Result<File, String> {
    let path = module_cstring(app.moddir.as_os_str(), "module root")?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!("open module root: {}", io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn ensure_module_directory_at(parent: &File, name: &OsStr) -> Result<File, String> {
    let name = module_cstring(name, "module directory name")?;
    let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o755) };
    if result != 0 && io::Error::last_os_error().kind() != ErrorKind::AlreadyExists {
        return Err(format!(
            "create module directory: {}",
            io::Error::last_os_error()
        ));
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open module directory: {}",
            io::Error::last_os_error()
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_module_output_file(
    directory: &File,
    name: &OsStr,
    kind: ModuleFileKind,
) -> Result<File, String> {
    let name = module_cstring(name, "module file name")?;
    let flags = libc::O_WRONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    let create_mode = match kind {
        ModuleFileKind::Text => 0o666,
        ModuleFileKind::Secret => 0o600,
    };
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CREAT | libc::O_EXCL,
            create_mode,
        )
    };
    if fd >= 0 {
        return Ok(unsafe { File::from_raw_fd(fd) });
    }
    let create_error = io::Error::last_os_error();
    if create_error.kind() != ErrorKind::AlreadyExists {
        return Err(format!("create module file: {create_error}"));
    }

    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(format!("open module file: {}", io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn require_private_regular_module_file(file: &File) -> Result<(), String> {
    private_regular_module_file_identity(file).map(|_| ())
}

fn private_regular_module_file_identity(file: &File) -> Result<ModuleFileIdentity, String> {
    let metadata = file
        .metadata()
        .map_err(|err| format!("inspect module file: {err}"))?;
    if !metadata.file_type().is_file() || metadata.nlink() != 1 {
        return Err("refusing non-private regular module file".to_string());
    }
    Ok(ModuleFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn module_cstring(value: &OsStr, description: &str) -> Result<CString, String> {
    CString::new(value.as_bytes())
        .map_err(|_| format!("{description} contains an unsupported NUL byte"))
}

pub(crate) fn clear_node_cache(app: &App) {
    let _ = fs::remove_file(app.moddir.join(".tmp/magicnet-node-list.cache"));
}

pub(crate) fn read_kv(path: PathBuf) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        map.insert(key.trim().to_string(), value);
    }
    map
}

/// Whether a value is inert when written unquoted into a `.`-sourced
/// `KEY=VALUE` conf: only characters the shell cannot act on. These confs hold
/// simple tokens (flags, enums, numbers, plain URLs); anything a source could
/// interpret — spaces, quotes, `$`, backticks, `;`, `|`, `&`, redirects,
/// globs — is rejected. Every writer of a sourced conf must go through this
/// single definition so the allowlist cannot drift between call sites.
pub(crate) fn shell_inert_conf_value(value: &str) -> bool {
    value.chars().all(|c| {
        matches!(c,
            'A'..='Z' | 'a'..='z' | '0'..='9'
            | '.' | '-' | '_' | ':' | '/' | '?' | '=' | '%' | '+' | '@' | ',')
    })
}

pub(crate) fn write_kv(
    app: &App,
    relative: &Path,
    values: &[(&str, String)],
) -> Result<(), String> {
    let text = values
        .iter()
        .map(|(key, value)| format!("{key}={value}\n"))
        .collect::<String>();
    write_text_file(app, relative, &text)
}

const MODULE_TRANSACTION_STAGING_PARENT: &str = ".tmp";
const MODULE_TRANSACTION_STAGING_DIRECTORY: &str = "magicnet-app-transaction";

/// Replaces ordinary module files as one recoverable transaction. All targets
/// must be distinct strict relative paths below the same module directory.
/// New contents and backups stay in a private module-root staging directory,
/// so no stage name is ever resolved through the target directory.
pub(crate) fn replace_module_text_files_transactionally(
    app: &App,
    replacements: &[(&Path, &str)],
) -> Result<(), String> {
    replace_module_text_files_transactionally_with_rename(
        app,
        replacements,
        rename_module_transaction_entry,
    )
}

struct ModuleRelativeFile {
    directory: PathBuf,
    name: OsString,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct ModuleFileIdentity {
    device: u64,
    inode: u64,
}

struct ModuleTransactionStage {
    name: OsString,
    identity: ModuleFileIdentity,
}

enum ModuleTransactionCommit {
    Created {
        new_identity: ModuleFileIdentity,
    },
    Replaced {
        backup: ModuleTransactionStage,
        new_identity: ModuleFileIdentity,
    },
}

struct ModuleTransactionCommitFailure {
    message: String,
    cleanup_stage: Option<ModuleTransactionStage>,
}

#[derive(Clone, Copy)]
enum ModuleTransactionRename {
    NoReplace,
    Exchange,
}

enum ModuleFileSnapshot {
    Missing,
    Present { identity: ModuleFileIdentity },
}

fn replace_module_text_files_transactionally_with_rename<F>(
    app: &App,
    replacements: &[(&Path, &str)],
    rename: F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    replace_module_text_files_transactionally_with_operations(
        app,
        replacements,
        write_and_sync_module_transaction_stage,
        rename,
    )
}

#[cfg(test)]
fn replace_module_text_files_transactionally_with_stage_writer<W>(
    app: &App,
    replacements: &[(&Path, &str)],
    stage_writer: W,
) -> Result<(), String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
{
    replace_module_text_files_transactionally_with_operations(
        app,
        replacements,
        stage_writer,
        rename_module_transaction_entry,
    )
}

fn replace_module_text_files_transactionally_with_operations<W, F>(
    app: &App,
    replacements: &[(&Path, &str)],
    mut stage_writer: W,
    mut rename: F,
) -> Result<(), String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    if replacements.len() < 2 {
        return Err("module transaction requires at least two targets".to_string());
    }
    let targets = replacements
        .iter()
        .map(|(relative, _)| split_module_relative_file(relative))
        .collect::<Result<Vec<_>, _>>()?;
    let target_directory = &targets[0].directory;
    if targets
        .iter()
        .any(|target| target.directory.as_path() != target_directory.as_path())
        || targets
            .iter()
            .enumerate()
            .any(|(index, target)| {
                targets[..index]
                    .iter()
                    .any(|seen| seen.name.as_os_str() == target.name.as_os_str())
            })
    {
        return Err(
            "module transaction targets must be distinct files in one directory".to_string(),
        );
    }
    let module_root = open_module_root(app)?;
    let directory = open_module_directory_from_root(
        module_root
            .try_clone()
            .map_err(|err| format!("clone module root directory: {err}"))?,
        target_directory,
    )?;
    let names = targets
        .into_iter()
        .map(|target| target.name)
        .collect::<Vec<_>>();
    let contents = replacements
        .iter()
        .map(|(_, text)| text.as_bytes())
        .collect::<Vec<_>>();
    let snapshots = names
        .iter()
        .map(|name| snapshot_module_transaction_target(&directory, name))
        .collect::<Result<Vec<_>, _>>()?;
    let staging_directory = open_module_transaction_staging_directory(&module_root, &directory)?;
    let mut stages = std::iter::repeat_with(|| None)
        .take(names.len())
        .collect::<Vec<Option<ModuleTransactionStage>>>();
    let mut committed = std::iter::repeat_with(|| None)
        .take(names.len())
        .collect::<Vec<Option<ModuleTransactionCommit>>>();

    for index in 0..stages.len() {
        match create_module_transaction_stage(
            &staging_directory,
            index + 1,
            contents[index],
            &mut stage_writer,
        ) {
            Ok(stage) => stages[index] = Some(stage),
            Err(err) => {
                let cleanup = cleanup_module_transaction_stages(&staging_directory, &mut stages);
                return Err(module_transaction_error(err, cleanup));
            }
        }
    }

    for index in 0..stages.len() {
        let stage = stages[index]
            .take()
            .expect("each module transaction stage exists before commit");
        let commit = match commit_module_transaction_stage(
            &staging_directory,
            &directory,
            &names[index],
            &snapshots[index],
            stage,
            &mut rename,
        ) {
            Ok(commit) => commit,
            Err(failure) => {
                let mut recovery = Vec::new();
                if let Some(stage) = failure.cleanup_stage {
                    if let Err(err) =
                        remove_module_transaction_stage(&staging_directory, &stage.name)
                    {
                        recovery.push(err);
                    }
                }
                for rollback_index in (0..index).rev() {
                    if let Some(commit) = committed[rollback_index].take() {
                        if let Err(restore_err) = rollback_module_transaction_commit(
                            &staging_directory,
                            &directory,
                            &names[rollback_index],
                            commit,
                            rollback_index + 1,
                            &mut rename,
                        ) {
                            recovery.push(restore_err);
                        }
                    }
                }
                recovery.extend(cleanup_module_transaction_stages(
                    &staging_directory,
                    &mut stages,
                ));
                return Err(module_transaction_error(
                    format!("replace module transaction: {}", failure.message),
                    recovery,
                ));
            }
        };
        committed[index] = Some(commit);
    }

    let cleanup = cleanup_module_transaction_commits(&staging_directory, &mut committed);
    if cleanup.is_empty() {
        Ok(())
    } else {
        Err(module_transaction_error(
            "replace module transaction committed but private staging cleanup failed".to_string(),
            cleanup,
        ))
    }
}

fn split_module_relative_file(relative: &Path) -> Result<ModuleRelativeFile, String> {
    let mut components = module_relative_components(relative)?;
    let name = components
        .pop()
        .expect("nonempty module-relative path has a final component")
        .to_os_string();
    let mut directory = PathBuf::new();
    for component in components {
        directory.push(component);
    }
    Ok(ModuleRelativeFile { directory, name })
}

fn open_module_directory(app: &App, relative: &Path) -> Result<File, String> {
    open_module_directory_from_root(open_module_root(app)?, relative)
}

fn open_module_directory_from_root(mut directory: File, relative: &Path) -> Result<File, String> {
    for component in normal_module_components(relative)? {
        directory = ensure_module_directory_at(&directory, component)?;
    }
    Ok(directory)
}

fn snapshot_module_transaction_target(
    directory: &File,
    name: &OsStr,
) -> Result<ModuleFileSnapshot, String> {
    let Some(file) = open_existing_private_module_file(directory, name)? else {
        return Ok(ModuleFileSnapshot::Missing);
    };
    let identity = private_regular_module_file_identity(&file)?;
    Ok(ModuleFileSnapshot::Present { identity })
}

fn open_existing_private_module_file(
    directory: &File,
    name: &OsStr,
) -> Result<Option<File>, String> {
    let name = module_cstring(name, "module transaction file name")?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let err = io::Error::last_os_error();
        if err.kind() == ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(format!("open module transaction target: {err}"));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    require_private_regular_module_file(&file)?;
    Ok(Some(file))
}

fn open_module_transaction_staging_directory(
    module_root: &File,
    target_directory: &File,
) -> Result<File, String> {
    let temporary = ensure_private_module_directory_at(
        module_root,
        OsStr::new(MODULE_TRANSACTION_STAGING_PARENT),
    )?;
    let staging = ensure_private_module_directory_at(
        &temporary,
        OsStr::new(MODULE_TRANSACTION_STAGING_DIRECTORY),
    )?;
    let target_device = target_directory
        .metadata()
        .map_err(|err| format!("inspect module transaction target directory: {err}"))?
        .dev();
    let staging_device = staging
        .metadata()
        .map_err(|err| format!("inspect module transaction staging directory: {err}"))?
        .dev();
    if target_device != staging_device {
        return Err(
            "module transaction staging directory is not on the target filesystem".to_string(),
        );
    }
    Ok(staging)
}

fn ensure_private_module_directory_at(parent: &File, name: &OsStr) -> Result<File, String> {
    let name = module_cstring(name, "module transaction staging directory name")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
    if created != 0 {
        let err = io::Error::last_os_error();
        if err.kind() != ErrorKind::AlreadyExists {
            return Err(format!(
                "create private module transaction directory: {err}"
            ));
        }
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open private module transaction directory: {}",
            io::Error::last_os_error()
        ));
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    secure_private_module_transaction_directory(&directory)?;
    Ok(directory)
}

fn secure_private_module_transaction_directory(directory: &File) -> Result<(), String> {
    let metadata = directory
        .metadata()
        .map_err(|err| format!("inspect private module transaction directory: {err}"))?;
    if !metadata.file_type().is_dir() {
        return Err("refusing non-directory module transaction staging entry".to_string());
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(
            "refusing module transaction staging directory not owned by this user".to_string(),
        );
    }
    directory
        .set_permissions(fs::Permissions::from_mode(0o700))
        .map_err(|err| format!("secure module transaction staging directory: {err}"))?;
    let mode = directory
        .metadata()
        .map_err(|err| format!("inspect secured module transaction directory: {err}"))?
        .mode()
        & 0o7777;
    if mode != 0o700 {
        return Err("module transaction staging directory is not private".to_string());
    }
    Ok(())
}

fn create_module_transaction_stage<W>(
    staging_directory: &File,
    slot: usize,
    contents: &[u8],
    stage_writer: &mut W,
) -> Result<ModuleTransactionStage, String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
{
    let stage = module_transaction_stage_name(slot);
    let stage_c = module_cstring(&stage, "module transaction stage name")?;
    let fd = unsafe {
        libc::openat(
            staging_directory.as_raw_fd(),
            stage_c.as_ptr(),
            libc::O_WRONLY
                | libc::O_CREAT
                | libc::O_EXCL
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(format!(
            "create module transaction stage: {}",
            io::Error::last_os_error()
        ));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let result = prepare_module_transaction_stage(&file)
        .and_then(|identity| stage_writer(&mut file, contents).map(|()| identity));
    drop(file);
    match result {
        Ok(identity) => Ok(ModuleTransactionStage {
            name: stage,
            identity,
        }),
        Err(err) => match remove_module_transaction_stage(staging_directory, &stage) {
            Ok(()) => Err(err),
            Err(cleanup_err) => Err(module_transaction_error(err, vec![cleanup_err])),
        },
    }
}

fn prepare_module_transaction_stage(file: &File) -> Result<ModuleFileIdentity, String> {
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("secure module transaction stage: {err}"))?;
    let identity = private_regular_module_file_identity(file)?;
    let mode = file
        .metadata()
        .map_err(|err| format!("inspect module transaction stage: {err}"))?
        .permissions()
        .mode()
        & 0o777;
    if mode != 0o600 {
        return Err("module transaction stage is not private".to_string());
    }
    Ok(identity)
}

fn write_and_sync_module_transaction_stage(file: &mut File, contents: &[u8]) -> Result<(), String> {
    file.write_all(contents)
        .map_err(|err| format!("write module transaction stage: {err}"))?;
    file.sync_all()
        .map_err(|err| format!("sync module transaction stage: {err}"))
}

fn module_transaction_stage_name(slot: usize) -> OsString {
    OsString::from(format!(".magicnet-app-{}-{slot}.tmp", std::process::id()))
}

fn module_transaction_recovery_stage_name(slot: usize) -> OsString {
    OsString::from(format!(
        ".magicnet-app-{}-{slot}-rollback.tmp",
        std::process::id()
    ))
}

fn module_transaction_stage_identity(
    staging_directory: &File,
    name: &OsStr,
) -> Result<ModuleFileIdentity, String> {
    let Some(file) = open_existing_private_module_file(staging_directory, name)? else {
        return Err("private module transaction stage disappeared".to_string());
    };
    private_regular_module_file_identity(&file)
}

fn commit_module_transaction_stage<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    snapshot: &ModuleFileSnapshot,
    stage: ModuleTransactionStage,
    rename: &mut F,
) -> Result<ModuleTransactionCommit, ModuleTransactionCommitFailure>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    match snapshot {
        ModuleFileSnapshot::Missing => match rename(
            ModuleTransactionRename::NoReplace,
            staging_directory,
            &stage.name,
            target_directory,
            target_name,
        ) {
            Ok(()) => Ok(ModuleTransactionCommit::Created {
                new_identity: stage.identity,
            }),
            Err(err) => Err(ModuleTransactionCommitFailure {
                message: err,
                cleanup_stage: Some(stage),
            }),
        },
        ModuleFileSnapshot::Present { identity, .. } => {
            let expected_identity = *identity;
            if let Err(err) = rename(
                ModuleTransactionRename::Exchange,
                staging_directory,
                &stage.name,
                target_directory,
                target_name,
            ) {
                return Err(ModuleTransactionCommitFailure {
                    message: err,
                    cleanup_stage: Some(stage),
                });
            }
            match module_transaction_stage_identity(staging_directory, &stage.name) {
                Ok(observed_identity) if observed_identity == expected_identity => {
                    Ok(ModuleTransactionCommit::Replaced {
                        backup: ModuleTransactionStage {
                            name: stage.name,
                            identity: expected_identity,
                        },
                        new_identity: stage.identity,
                    })
                }
                Ok(_) | Err(_) => {
                    let message = "module transaction target changed during commit".to_string();
                    match restore_failed_module_transaction_exchange(
                        staging_directory,
                        target_directory,
                        target_name,
                        &stage,
                        rename,
                    ) {
                        Ok(()) => Err(ModuleTransactionCommitFailure {
                            message,
                            cleanup_stage: Some(stage),
                        }),
                        Err(recovery_err) => Err(ModuleTransactionCommitFailure {
                            message: format!("{message}; {recovery_err}"),
                            cleanup_stage: None,
                        }),
                    }
                }
            }
        }
    }
}

fn restore_failed_module_transaction_exchange<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    stage: &ModuleTransactionStage,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    rename(
        ModuleTransactionRename::Exchange,
        staging_directory,
        &stage.name,
        target_directory,
        target_name,
    )
    .map_err(|err| format!("restore changed module transaction target: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &stage.name) {
        Ok(identity) if identity == stage.identity => Ok(()),
        Ok(_) | Err(_) => Err(
            "module transaction target changed while restoring; retained private staging entry"
                .to_string(),
        ),
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn rename_module_transaction_entry(
    operation: ModuleTransactionRename,
    source_directory: &File,
    source: &OsStr,
    destination_directory: &File,
    destination: &OsStr,
) -> Result<(), String> {
    let source = module_cstring(source, "module transaction source name")?;
    let destination = module_cstring(destination, "module transaction destination name")?;
    let flags: libc::c_uint = match operation {
        ModuleTransactionRename::NoReplace => 1,
        ModuleTransactionRename::Exchange => 2,
    };
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_directory.as_raw_fd(),
            source.as_ptr(),
            destination_directory.as_raw_fd(),
            destination.as_ptr(),
            flags,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error().to_string())
    }
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn rename_module_transaction_entry(
    operation: ModuleTransactionRename,
    source_directory: &File,
    source: &OsStr,
    destination_directory: &File,
    destination: &OsStr,
) -> Result<(), String> {
    let _ = (
        operation,
        source_directory,
        source,
        destination_directory,
        destination,
    );
    Err("atomic module transaction rename is unavailable on this platform".to_string())
}

fn rollback_module_transaction_commit<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    commit: ModuleTransactionCommit,
    slot: usize,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    match commit {
        ModuleTransactionCommit::Created { new_identity } => {
            rollback_created_module_transaction_target(
                staging_directory,
                target_directory,
                target_name,
                new_identity,
                slot,
                rename,
            )
        }
        ModuleTransactionCommit::Replaced {
            backup,
            new_identity,
        } => rollback_replaced_module_transaction_target(
            staging_directory,
            target_directory,
            target_name,
            &backup,
            new_identity,
            rename,
        ),
    }
}

fn rollback_created_module_transaction_target<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    new_identity: ModuleFileIdentity,
    slot: usize,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    let recovery_name = module_transaction_recovery_stage_name(slot);
    rename(
        ModuleTransactionRename::NoReplace,
        target_directory,
        target_name,
        staging_directory,
        &recovery_name,
    )
    .map_err(|err| format!("capture module transaction target for rollback: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &recovery_name) {
        Ok(identity) if identity == new_identity => {
            remove_module_transaction_stage(staging_directory, &recovery_name)
        }
        Ok(_) | Err(_) => {
            let message = "module transaction target changed during rollback".to_string();
            match rename(
                ModuleTransactionRename::NoReplace,
                staging_directory,
                &recovery_name,
                target_directory,
                target_name,
            ) {
                Ok(()) => Err(message),
                Err(recovery_err) => Err(format!(
                    "{message}; retained private staging entry: {recovery_err}"
                )),
            }
        }
    }
}

fn rollback_replaced_module_transaction_target<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    backup: &ModuleTransactionStage,
    new_identity: ModuleFileIdentity,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    rename(
        ModuleTransactionRename::Exchange,
        staging_directory,
        &backup.name,
        target_directory,
        target_name,
    )
    .map_err(|err| format!("restore module transaction target: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &backup.name) {
        Ok(identity) if identity == new_identity => {
            remove_module_transaction_stage(staging_directory, &backup.name)
        }
        Ok(_) | Err(_) => Err(
            "module transaction target changed during rollback; retained private staging entry"
                .to_string(),
        ),
    }
}

fn cleanup_module_transaction_stages(
    staging_directory: &File,
    stages: &mut [Option<ModuleTransactionStage>],
) -> Vec<String> {
    let mut errors = Vec::new();
    for stage in stages.iter_mut() {
        if let Some(stage) = stage.take() {
            if let Err(err) = remove_module_transaction_stage(staging_directory, &stage.name) {
                errors.push(err);
            }
        }
    }
    errors
}

fn cleanup_module_transaction_commits(
    staging_directory: &File,
    commits: &mut [Option<ModuleTransactionCommit>],
) -> Vec<String> {
    let mut errors = Vec::new();
    for commit in commits.iter_mut() {
        let Some(commit) = commit.take() else {
            continue;
        };
        if let ModuleTransactionCommit::Replaced { backup, .. } = commit {
            if let Err(err) = remove_module_transaction_stage(staging_directory, &backup.name) {
                errors.push(err);
            }
        }
    }
    errors
}

fn remove_module_transaction_stage(staging_directory: &File, name: &OsStr) -> Result<(), String> {
    let name = module_cstring(name, "module transaction stage name")?;
    let removed = unsafe { libc::unlinkat(staging_directory.as_raw_fd(), name.as_ptr(), 0) };
    if removed == 0 {
        Ok(())
    } else {
        let err = io::Error::last_os_error();
        if err.kind() == ErrorKind::NotFound {
            Ok(())
        } else {
            Err(format!("remove private module transaction stage: {err}"))
        }
    }
}

fn module_transaction_error(primary: String, recovery_errors: Vec<String>) -> String {
    if recovery_errors.is_empty() {
        primary
    } else {
        format!("{primary}; rollback failed: {}", recovery_errors.join("; "))
    }
}

fn merge_command_output(stdout: &[u8], stderr: &[u8]) -> String {
    let mut text = String::from_utf8_lossy(stdout).trim().to_string();
    let err = String::from_utf8_lossy(stderr).trim().to_string();
    if text.is_empty() {
        text = err;
    } else if !err.is_empty() {
        text.push_str("; ");
        text.push_str(&err);
    }
    text
}

fn compact_command_output(output: &str) -> String {
    output
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no output")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::Write;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use crate::App;

    use super::{
        command_text_full_timeout, command_text_timeout, compact_command_output,
        merge_command_output, module_transaction_stage_name, rename_module_transaction_entry,
        replace_module_text_files_transactionally,
        replace_module_text_files_transactionally_with_rename,
        replace_module_text_files_transactionally_with_stage_writer, write_secret_file,
        write_text_file, MODULE_TRANSACTION_STAGING_DIRECTORY, MODULE_TRANSACTION_STAGING_PARENT,
    };

    fn test_directory(label: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "magicnet-utils-{label}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock is after the Unix epoch")
                .as_nanos()
        ));
        fs::create_dir_all(&directory).expect("create test directory");
        directory
    }

    fn test_app(label: &str) -> (App, PathBuf) {
        let directory = test_directory(label);
        let module_root = directory.join("module");
        fs::create_dir_all(&module_root).expect("create module root");
        (App::for_test(module_root), directory)
    }

    #[test]
    fn full_output_preserves_trimmed_stdout_and_appends_trimmed_stderr() {
        assert_eq!(
            merge_command_output(b"  first\nsecond  \n", b"  warning\n  "),
            "first\nsecond; warning"
        );
    }

    #[test]
    fn compact_output_keeps_the_last_nonempty_line() {
        assert_eq!(
            compact_command_output("first\n\n  final; warning  \n"),
            "final; warning"
        );
    }

    #[test]
    fn compact_output_keeps_timeout_errors_byte_for_byte() {
        assert_eq!(
            compact_command_output("timeout after 5000ms"),
            "timeout after 5000ms"
        );
    }

    #[test]
    fn full_and_compact_helpers_share_process_output_semantics() {
        let args = ["-c", "printf 'first\\nsecond'; printf 'warning' >&2"];
        let full = command_text_full_timeout("sh", &args, Duration::from_secs(1));
        let compact = command_text_timeout("sh", &args, Duration::from_secs(1));

        assert_eq!(
            (full, compact),
            (
                "first\nsecond; warning".to_string(),
                "second; warning".to_string()
            )
        );
    }

    #[test]
    fn full_output_drains_more_than_pipe_capacity_without_waiting_for_timeout() {
        let script = "chunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 8192 ]; do printf %s \"$chunk\"; i=$((i + 1)); done";
        let started = Instant::now();
        let output = command_text_full_timeout("sh", &["-c", script], Duration::from_secs(8));

        assert_eq!(
            (output.len(), started.elapsed() < Duration::from_secs(4)),
            (32 * 8192, true)
        );
    }

    #[test]
    fn builtin_infinite_loop_times_out_promptly_and_exactly() {
        let started = Instant::now();
        let output = command_text_full_timeout(
            "sh",
            &["-c", "while :; do :; done"],
            Duration::from_millis(120),
        );

        assert_eq!(
            (output, started.elapsed() < Duration::from_secs(2)),
            ("timeout after 120ms".to_string(), true)
        );
    }

    #[test]
    fn write_secret_file_replaces_contents_and_restricts_existing_mode() {
        let (app, directory) = test_app("replace-secret");
        let relative = Path::new(".config/magicnet/secret");
        let path = app.moddir.join(relative);
        fs::create_dir_all(path.parent().expect("secret parent")).expect("create secret parent");
        fs::write(&path, "old value").expect("write existing file");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
            .expect("broaden existing file permissions");

        write_secret_file(&app, relative, "replacement value").expect("replace secret file");

        let contents = fs::read_to_string(&path).expect("read replacement contents");
        let mode = fs::metadata(&path)
            .expect("stat replacement file")
            .permissions()
            .mode()
            & 0o777;
        fs::remove_dir_all(&directory).expect("remove test directory");

        assert_eq!(contents, "replacement value");
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn write_secret_file_creates_a_new_0600_file() {
        let (app, directory) = test_app("new-secret");
        let relative = Path::new(".config/magicnet/secret");
        let path = app.moddir.join(relative);

        write_secret_file(&app, relative, "new value").expect("create secret file");

        let contents = fs::read_to_string(&path).expect("read new secret");
        let mode = fs::metadata(&path)
            .expect("stat new secret")
            .permissions()
            .mode()
            & 0o777;
        fs::remove_dir_all(&directory).expect("remove test directory");

        assert_eq!(contents, "new value");
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn write_secret_file_refuses_a_final_symlink_without_touching_its_target() {
        let (app, directory) = test_app("secret-final-symlink");
        let victim = directory.join("victim");
        let relative = Path::new(".config/magicnet/secret");
        let path = app.moddir.join(relative);
        fs::create_dir_all(path.parent().expect("secret parent")).expect("create secret parent");
        fs::write(&victim, "preserve me").expect("write victim");
        symlink(&victim, &path).expect("create secret symlink");

        let err = write_secret_file(&app, relative, "replacement").expect_err("refuse symlink");
        let contents = fs::read_to_string(&victim).expect("read victim");
        fs::remove_dir_all(&directory).expect("remove test directory");

        assert!(err.contains("module file"), "unexpected error: {err}");
        assert_eq!(contents, "preserve me");
    }

    #[test]
    fn write_secret_file_refuses_a_hard_linked_target_without_mutating_it() {
        let (app, directory) = test_app("secret-final-hardlink");
        let original = directory.join("original");
        let relative = Path::new(".config/magicnet/secret");
        let linked = app.moddir.join(relative);
        fs::create_dir_all(linked.parent().expect("secret parent")).expect("create secret parent");
        fs::write(&original, "preserve me").expect("write original");
        fs::hard_link(&original, &linked).expect("create hard link");

        let err = write_secret_file(&app, relative, "replacement").expect_err("refuse hard link");

        assert!(err.contains("non-private"), "unexpected error: {err}");
        assert_eq!(
            fs::read_to_string(&original).expect("read original"),
            "preserve me"
        );
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn write_text_file_refuses_final_symlink_and_hard_link() {
        for link_kind in ["symlink", "hardlink"] {
            let (app, directory) = test_app(&format!("text-final-{link_kind}"));
            let victim = directory.join("victim");
            let relative = Path::new(".config/magicnet/text.conf");
            let path = app.moddir.join(relative);
            fs::create_dir_all(path.parent().expect("text parent")).expect("create text parent");
            fs::write(&victim, "preserve me").expect("write victim");
            match link_kind {
                "symlink" => symlink(&victim, &path).expect("create text symlink"),
                "hardlink" => fs::hard_link(&victim, &path).expect("create text hard link"),
                _ => unreachable!(),
            }

            assert!(write_text_file(&app, relative, "replacement").is_err());
            assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
            fs::remove_dir_all(&directory).expect("remove test directory");
        }
    }

    #[test]
    fn module_writers_reject_intermediate_symlinks() {
        assert_intermediate_symlinks_rejected("text", write_text_file);
        assert_intermediate_symlinks_rejected("secret", write_secret_file);
    }

    #[test]
    fn module_writers_reject_non_relative_paths() {
        let (app, directory) = test_app("relative-paths");
        for path in [
            Path::new("../escape"),
            Path::new("/escape"),
            Path::new("./escape"),
        ] {
            assert!(write_text_file(&app, path, "nope").is_err());
            assert!(write_secret_file(&app, path, "nope").is_err());
        }
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn module_transaction_replaces_both_app_lists() {
        let (app, directory) = test_app("transaction-success");
        let (bypass, proxy) = prepare_transaction_app_lists(&app);

        replace_module_text_files_transactionally(&app, &[
            (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ])
        .expect("replace app lists");

        assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
        assert_eq!(fs::read_to_string(&proxy).unwrap(), "new-proxy\n");
        assert_no_transaction_stages(&app);
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn module_transaction_rolls_back_three_files_after_injected_third_replace_failure() {
        let (app, directory) = test_app("transaction-rollback");
        let (bypass, proxy) = prepare_transaction_app_lists(&app);
        let direct = bypass
            .parent()
            .expect("app list directory")
            .join("app-direct.list");
        fs::write(&direct, "old-direct\n").expect("write direct fixture");
        let mut replace_count = 0usize;

        let error = replace_module_text_files_transactionally_with_rename(
            &app,
            &[
                (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
                (Path::new(".config/magicnet/app-direct.list"), "new-direct\n"),
            ],
            |operation, source_directory, source, destination_directory, destination| {
                replace_count += 1;
                if replace_count == 3 {
                    Err("injected third replace failure".to_string())
                } else {
                    rename_module_transaction_entry(
                        operation,
                        source_directory,
                        source,
                        destination_directory,
                        destination,
                    )
                }
            },
        )
        .expect_err("third replacement must fail");

        assert!(error.contains("injected third replace failure"), "{error}");
        assert_eq!(fs::read_to_string(&bypass).unwrap(), "old-bypass\n");
        assert_eq!(fs::read_to_string(&proxy).unwrap(), "old-proxy\n");
        assert_eq!(fs::read_to_string(&direct).unwrap(), "old-direct\n");
        assert_no_transaction_stages(&app);
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn module_transaction_cleans_private_stage_after_injected_write_or_sync_failure() {
        let (write_app, write_directory) = test_app("transaction-stage-write-failure");
        let (write_bypass, write_proxy) = prepare_transaction_app_lists(&write_app);
        let write_error = replace_module_text_files_transactionally_with_stage_writer(
            &write_app,
            &[
                (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ],
            |_file, _contents| Err("injected stage write failure".to_string()),
        )
        .expect_err("stage write failure must abort the transaction");
        assert!(
            write_error.contains("injected stage write failure"),
            "{write_error}"
        );
        assert_eq!(fs::read_to_string(&write_bypass).unwrap(), "old-bypass\n");
        assert_eq!(fs::read_to_string(&write_proxy).unwrap(), "old-proxy\n");
        assert_no_transaction_stages(&write_app);
        fs::remove_dir_all(&write_directory).expect("remove write-failure test directory");

        let (sync_app, sync_directory) = test_app("transaction-stage-sync-failure");
        let (sync_bypass, sync_proxy) = prepare_transaction_app_lists(&sync_app);
        let sync_error = replace_module_text_files_transactionally_with_stage_writer(
            &sync_app,
            &[
                (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ],
            |file, contents| {
                file.write_all(contents)
                    .expect("write private stage before injected sync failure");
                Err("injected stage sync failure".to_string())
            },
        )
        .expect_err("stage sync failure must abort the transaction");
        assert!(
            sync_error.contains("injected stage sync failure"),
            "{sync_error}"
        );
        assert_eq!(fs::read_to_string(&sync_bypass).unwrap(), "old-bypass\n");
        assert_eq!(fs::read_to_string(&sync_proxy).unwrap(), "old-proxy\n");
        assert_no_transaction_stages(&sync_app);
        fs::remove_dir_all(&sync_directory).expect("remove sync-failure test directory");
    }

    #[test]
    fn module_transaction_stages_are_isolated_from_target_directory() {
        let (app, directory) = test_app("transaction-stage-isolation");
        let (bypass, proxy) = prepare_transaction_app_lists(&app);
        let config = bypass.parent().expect("app list directory");
        let victim = directory.join("victim");
        let stage_name = module_transaction_stage_name(1);
        let target_directory_entry = config.join(Path::new(stage_name.as_os_str()));
        fs::write(&victim, "preserve me").expect("write victim");
        symlink(&victim, &target_directory_entry).expect("create target-directory stage symlink");

        replace_module_text_files_transactionally(&app, &[
            (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ])
        .expect("target-directory entry must not be a transaction stage source");

        assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
        assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
        assert_eq!(fs::read_to_string(&proxy).unwrap(), "new-proxy\n");
        assert!(fs::symlink_metadata(&target_directory_entry)
            .unwrap()
            .file_type()
            .is_symlink());
        let mode = fs::metadata(transaction_staging_directory(&app))
            .expect("stat private staging directory")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700);
        assert_no_transaction_stages(&app);
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn module_transaction_rejects_a_private_stage_collision_without_touching_its_target() {
        let (app, directory) = test_app("transaction-private-stage-collision");
        let (bypass, proxy) = prepare_transaction_app_lists(&app);
        let victim = directory.join("victim");
        let staging_directory = transaction_staging_directory(&app);
        let stage_name = module_transaction_stage_name(1);
        let stage = staging_directory.join(Path::new(stage_name.as_os_str()));
        fs::create_dir_all(&staging_directory).expect("create private staging fixture");
        fs::set_permissions(&staging_directory, fs::Permissions::from_mode(0o700))
            .expect("secure private staging fixture");
        fs::write(&victim, "preserve me").expect("write victim");
        symlink(&victim, &stage).expect("create private stage symlink");

        assert!(replace_module_text_files_transactionally(&app, &[
            (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ])
        .is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
        assert_eq!(fs::read_to_string(&bypass).unwrap(), "old-bypass\n");
        assert_eq!(fs::read_to_string(&proxy).unwrap(), "old-proxy\n");
        assert!(fs::symlink_metadata(&stage)
            .unwrap()
            .file_type()
            .is_symlink());
        fs::remove_dir_all(&directory).expect("remove test directory");
    }

    #[test]
    fn module_transaction_rejects_intermediate_symlinks_without_writing_outside() {
        for (case, linked_directory) in [("config", ".config"), ("magicnet", ".config/magicnet")] {
            let directory = test_directory(&format!("transaction-intermediate-{case}"));
            let module_root = directory.join("module");
            let outside = directory.join("outside");
            fs::create_dir_all(&module_root).expect("create module root");
            fs::create_dir_all(&outside).expect("create outside directory");
            let linked_directory = module_root.join(linked_directory);
            if let Some(parent) = linked_directory.parent() {
                fs::create_dir_all(parent).expect("create symlink parent");
            }
            symlink(&outside, &linked_directory).expect("create intermediate symlink");
            let app = App::for_test(module_root);

            assert!(replace_module_text_files_transactionally(&app, &[
                (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ])
            .is_err());
            assert!(fs::read_dir(&outside).unwrap().next().is_none());
            fs::remove_dir_all(&directory).expect("remove test directory");
        }
    }

    #[test]
    fn module_transaction_rejects_final_symlink_and_hard_link() {
        for link_kind in ["symlink", "hardlink"] {
            let (app, directory) = test_app(&format!("transaction-final-{link_kind}"));
            let (bypass, _) = prepare_transaction_app_lists(&app);
            let victim = directory.join("victim");
            fs::remove_file(&bypass).expect("remove fixture bypass list");
            fs::write(&victim, "preserve me").expect("write victim");
            match link_kind {
                "symlink" => symlink(&victim, &bypass).expect("create final symlink"),
                "hardlink" => fs::hard_link(&victim, &bypass).expect("create final hard link"),
                _ => unreachable!(),
            }

            assert!(replace_module_text_files_transactionally(&app, &[
                (Path::new(".config/magicnet/app-bypass.list"), "new-bypass\n"),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ])
            .is_err());
            assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
            fs::remove_dir_all(&directory).expect("remove test directory");
        }
    }

    fn prepare_transaction_app_lists(app: &App) -> (PathBuf, PathBuf) {
        let config = app.moddir.join(".config/magicnet");
        let bypass = config.join("app-bypass.list");
        let proxy = config.join("app-proxy.list");
        fs::create_dir_all(&config).expect("create app list directory");
        fs::write(&bypass, "old-bypass\n").expect("write bypass fixture");
        fs::write(&proxy, "old-proxy\n").expect("write proxy fixture");
        (bypass, proxy)
    }

    fn transaction_staging_directory(app: &App) -> PathBuf {
        app.moddir
            .join(MODULE_TRANSACTION_STAGING_PARENT)
            .join(MODULE_TRANSACTION_STAGING_DIRECTORY)
    }

    fn assert_no_transaction_stages(app: &App) {
        let staging_directory = transaction_staging_directory(app);
        assert!(
            staging_directory.is_dir(),
            "private staging directory was not created"
        );
        assert!(
            fs::read_dir(&staging_directory)
                .expect("read private staging directory")
                .next()
                .is_none(),
            "private staging directory still contains transaction entries"
        );
    }

    fn assert_intermediate_symlinks_rejected(
        writer_name: &str,
        writer: fn(&App, &Path, &str) -> Result<(), String>,
    ) {
        for (case, relative, linked_directory) in [
            ("config", ".config/magicnet/value", ".config"),
            ("magicnet", ".config/magicnet/value", ".config/magicnet"),
            ("sing-box", ".config/sing-box/value", ".config/sing-box"),
        ] {
            let directory = test_directory(&format!("intermediate-{writer_name}-{case}"));
            let module_root = directory.join("module");
            let outside = directory.join("outside");
            fs::create_dir_all(&module_root).expect("create module root");
            fs::create_dir_all(&outside).expect("create outside directory");
            let linked_directory = module_root.join(linked_directory);
            if let Some(parent) = linked_directory.parent() {
                fs::create_dir_all(parent).expect("create symlink parent");
            }
            symlink(&outside, &linked_directory).expect("create intermediate symlink");
            let app = App::for_test(module_root);

            assert!(writer(&app, Path::new(relative), "replacement").is_err());
            assert!(
                fs::read_dir(&outside)
                    .expect("read outside directory")
                    .next()
                    .is_none(),
                "{writer_name} writer followed {linked_directory:?}"
            );
            fs::remove_dir_all(&directory).expect("remove test directory");
        }
    }
}
