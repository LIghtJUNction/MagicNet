use std::collections::HashSet;
use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, ToSocketAddrs};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{
    clean_module_lines, clear_node_cache, cstring_from_os_str, decode_base64,
    first_clean_module_line, read_proc_text_bounded, run_magicnet_function,
    run_subscription_source_update_from_inherited_fd, run_subscription_update_from_inherited_fd,
    write_text_file, App, MAX_PROC_STAT_BYTES,
};

const MAX_SINGBOX_SUBSCRIPTION_URLS: usize = 5;
const MAX_SUBSCRIPTION_USER_AGENT_BYTES: usize = 256;
const MAX_SUBSCRIPTION_FILTERS: usize = 32;
const MAX_SUBSCRIPTION_FILTER_BYTES: usize = 64;
const MAX_LOCAL_SUBSCRIPTION_BYTES: usize = 8 * 1024 * 1024;
const SUBSCRIPTION_USER_AGENT_PATH: &str = ".config/sing-box/subscription.user-agent";
const SUBSCRIPTION_FILTER_PATH: &str = ".config/sing-box/subscription-filter.list";
const SUBSCRIPTION_URL_PATH: &str = ".config/sing-box/subscription.url";
const SELECTOR_REPLAY_WARNING: &str =
    "subscription committed, but saved selector choices could not be replayed";
static SUBSCRIPTION_CANDIDATE_SEQUENCE: AtomicUsize = AtomicUsize::new(0);

fn subscription_update_outcome(
    update: Result<(), String>,
    replay: Result<(), String>,
) -> Result<Option<&'static str>, String> {
    update?;
    Ok(replay.err().map(|_| SELECTOR_REPLAY_WARNING))
}

fn finish_subscription_update(app: &App, update: Result<(), String>) -> Result<(), String> {
    update?;
    clear_node_cache(app);
    let replay = crate::selector_store::replay(app).map(|_| ());
    if let Some(warning) = subscription_update_outcome(Ok(()), replay)? {
        eprintln!("[warning] {warning}");
    }
    Ok(())
}

pub fn setup_subscription(app: &App, url: &str) -> Result<(), String> {
    if url.is_empty() {
        return Err("Usage: cli setup <subscription-url>".to_string());
    }
    validate_subscription_url(url)?;
    apply_subscription_text(app, &format!("{url}\n"))
}

pub fn sub_set(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let url = match target {
        "sing-box" | "singbox" => args.get(3).map(String::as_str).unwrap_or_default(),
        _ => return Err("Usage: cli sub set sing-box <url>".to_string()),
    };
    if url.is_empty() {
        return Err("Usage: cli sub set sing-box <url>".to_string());
    }
    validate_subscription_url(url)?;
    apply_subscription_text(app, &format!("{url}\n"))
}

pub fn sub_set_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub set-file sing-box <base64-lines>".to_string());
    }
    match target {
        "sing-box" | "singbox" => {}
        _ => return Err("set-file supports sing-box only".to_string()),
    }
    let text = normalized_subscription_payload(payload)?;
    apply_subscription_text(app, &text)
}

pub fn sub_user_agent(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("get") {
        "get" => {
            println!("{}", subscription_user_agent(app));
            Ok(())
        }
        "set" => {
            let encoded = args.get(3).map(String::as_str).unwrap_or_default();
            if encoded.is_empty() {
                return Err("Usage: cli sub user-agent set <base64-value>".to_string());
            }
            let bytes = decode_base64(encoded)?;
            let value = String::from_utf8(bytes)
                .map_err(|err| format!("subscription User-Agent is not UTF-8: {err}"))?;
            let value = value.trim();
            validate_subscription_user_agent(value)?;
            write_text_file(
                app,
                Path::new(SUBSCRIPTION_USER_AGENT_PATH),
                &format!("{value}\n"),
            )
        }
        "clear" => write_text_file(app, Path::new(SUBSCRIPTION_USER_AGENT_PATH), ""),
        _ => Err("Usage: cli sub user-agent {get|set <base64-value>|clear}".to_string()),
    }
}

pub fn sub_filter(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("list") {
        "list" => {
            for value in subscription_filters(app) {
                println!("{value}");
            }
            Ok(())
        }
        "set" => {
            let encoded = args.get(3).map(String::as_str).unwrap_or_default();
            if encoded.is_empty() {
                return Err("Usage: cli sub filter set <base64-lines>".to_string());
            }
            let bytes = decode_base64(encoded)?;
            let value = String::from_utf8(bytes)
                .map_err(|err| format!("subscription filters are not UTF-8: {err}"))?;
            let value = normalize_subscription_filter_text(&value)?;
            write_text_file(app, Path::new(SUBSCRIPTION_FILTER_PATH), &value)
        }
        "clear" => write_text_file(app, Path::new(SUBSCRIPTION_FILTER_PATH), ""),
        _ => Err("Usage: cli sub filter {list|set <base64-lines>|clear}".to_string()),
    }
}

/// Resolve a validated subscription hostname through Android's libc resolver.
///
/// The shell fetcher pins curl to these addresses with `--resolve`, so DNS is
/// completed before the privileged request and every returned address can be
/// rejected if it targets a private or special-use network.
pub fn sub_resolve_host(args: &[String]) -> Result<(), String> {
    let host = args.get(2).map(String::as_str).unwrap_or_default();
    let port = args.get(3).map(String::as_str).unwrap_or_default();
    if host.is_empty() || port.is_empty() {
        return Err("Usage: cli sub resolve-host <hostname> <port>".to_string());
    }
    validate_subscription_host(host)?;
    let port = parse_subscription_port(port)?;
    let resolved = (host, port)
        .to_socket_addrs()
        .map_err(|_| "Subscription hostname resolution failed".to_string())?
        .map(|address| address.ip())
        .collect::<HashSet<_>>();
    validate_resolved_subscription_addresses(&resolved)?;

    let mut addresses = resolved.into_iter().collect::<Vec<_>>();
    addresses.sort_by_key(ToString::to_string);
    for address in addresses {
        println!("{address}");
    }
    Ok(())
}

pub fn sub_apply_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub apply-file sing-box <base64-lines>".to_string());
    }
    if !matches!(target, "sing-box" | "singbox") {
        return Err("apply-file supports sing-box only".to_string());
    }
    let text = normalized_subscription_payload(payload)?;
    apply_subscription_text(app, &text)
}

/// Apply raw UTF-8 subscription text from the private WebUI payload helper.
/// The helper has already bound the input to a regular, module-owned file and
/// removed that file before this path is entered; this function deliberately
/// accepts no caller-controlled path or shell argument.
pub(crate) fn apply_webui_subscription_payload(app: &App, bytes: &[u8]) -> Result<(), String> {
    let payload = std::str::from_utf8(bytes)
        .map_err(|_| "WebUI subscription payload is not valid UTF-8".to_string())?;
    let text = normalized_subscription_text(payload)?;
    apply_subscription_text(app, &text)
}

pub(crate) fn apply_webui_subscription_source_payload(
    app: &App,
    bytes: &[u8],
) -> Result<(), String> {
    if bytes.len() > MAX_LOCAL_SUBSCRIPTION_BYTES {
        return Err("local subscription source exceeds the 8 MiB limit".to_string());
    }
    let payload = std::str::from_utf8(bytes)
        .map_err(|_| "local subscription source is not valid UTF-8".to_string())?;
    if payload.trim().is_empty() {
        return Err("local subscription source is empty".to_string());
    }
    if payload.contains('\0') {
        return Err("local subscription source contains a NUL byte".to_string());
    }
    let text = if payload.ends_with('\n') {
        payload.to_string()
    } else {
        format!("{payload}\n")
    };
    let result = with_subscription_candidate(app, &text, |candidate_fd| {
        run_subscription_source_update_from_inherited_fd(app, candidate_fd)
    });
    if result.is_ok() {
        let _ = fs::remove_file(app.moddir.join(".config/sing-box/standalone-config"));
    }
    finish_subscription_update(app, result)
}

fn apply_subscription_text(app: &App, text: &str) -> Result<(), String> {
    let result = with_subscription_candidate(app, text, |candidate_fd| {
        run_subscription_update_from_inherited_fd(app, candidate_fd)
    });
    if result.is_ok() {
        let _ = fs::remove_file(app.moddir.join(".config/sing-box/standalone-config"));
    }
    finish_subscription_update(app, result)
}

fn with_subscription_candidate<T>(
    app: &App,
    text: &str,
    activate: impl FnOnce(RawFd) -> Result<T, String>,
) -> Result<T, String> {
    let candidate = write_subscription_candidate(app, text)?;
    let result = activate(candidate.fd());
    drop(candidate);
    result
}

/// An unlinked candidate inode retained only by this process's descriptor.
/// `with_subscription_candidate` keeps it alive until the update shell exits.
struct SubscriptionCandidate {
    file: File,
}

impl SubscriptionCandidate {
    fn fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }
}

fn write_subscription_candidate(app: &App, text: &str) -> Result<SubscriptionCandidate, String> {
    let directory = subscription_candidate_temp_directory(app)?;
    let (mut file, name) = create_subscription_candidate_file(&directory)?;
    let write_result = (|| {
        require_private_subscription_candidate(&file)?;
        file.write_all(text.as_bytes())
            .map_err(|_| "write subscription candidate failed".to_string())?;
        file.sync_all()
            .map_err(|_| "sync subscription candidate failed".to_string())?;
        file.seek(SeekFrom::Start(0))
            .map_err(|_| "rewind subscription candidate failed".to_string())
    })();
    if let Err(err) = write_result {
        return discard_named_subscription_candidate(&directory, &name, err);
    }
    if let Err(err) = require_private_subscription_candidate(&file) {
        return discard_named_subscription_candidate(&directory, &name, err);
    }
    // Once this fd-only input is unlinked, the legacy shell glob has no name
    // to race or remove. Its inherited `/proc/self/fd/<n>` handle is the sole
    // route by which the update transaction can read these bytes.
    remove_subscription_candidate(&directory, &name)?;
    clear_close_on_exec(&file)?;
    Ok(SubscriptionCandidate { file })
}

fn subscription_candidate_temp_directory(app: &App) -> Result<File, String> {
    let root = open_subscription_module_root(app)?;
    let tmp = ensure_subscription_directory_at(&root, OsStr::new(".tmp"), 0o700)?;
    ensure_subscription_directory_at(&tmp, OsStr::new("subscription-candidates"), 0o700)
}

fn open_subscription_module_root(app: &App) -> Result<File, String> {
    let path = cstring_from_os_str(app.moddir.as_os_str(), "subscription module root")?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("open subscription module root failed".to_string());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn ensure_subscription_directory_at(
    parent: &File,
    name: &OsStr,
    mode: u32,
) -> Result<File, String> {
    let name_c = cstring_from_os_str(name, "subscription directory")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), mode) };
    if created != 0 && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
        return Err("create subscription candidate directory failed".to_string());
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("open subscription candidate directory failed".to_string());
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    directory
        .set_permissions(fs::Permissions::from_mode(mode))
        .map_err(|_| "secure subscription candidate directory failed".to_string())?;
    Ok(directory)
}

fn create_subscription_candidate_file(directory: &File) -> Result<(File, OsString), String> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| format!("system clock before epoch: {err}"))?
        .as_nanos();
    for _ in 0..16 {
        let name = OsString::from(format!(
            "{}-{nonce}-{}.url",
            std::process::id(),
            SUBSCRIPTION_CANDIDATE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let name_c = cstring_from_os_str(&name, "subscription candidate filename")?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name_c.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd >= 0 {
            let file = unsafe { File::from_raw_fd(fd) };
            if let Err(err) = require_private_subscription_candidate(&file) {
                return discard_named_subscription_candidate(directory, &name, err);
            }
            if let Err(err) = file.set_permissions(fs::Permissions::from_mode(0o600)) {
                return discard_named_subscription_candidate(
                    directory,
                    &name,
                    format!("secure subscription candidate: {err}"),
                );
            }
            return Ok((file, name));
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
            return Err("create subscription candidate failed".to_string());
        }
    }
    Err("create subscription candidate failed".to_string())
}

fn remove_subscription_candidate(directory: &File, name: &OsStr) -> Result<(), String> {
    let metadata = subscription_candidate_metadata(directory, name)
        .map_err(|_| "inspect subscription candidate failed".to_string())?;
    if !is_regular_file(&metadata) || metadata.st_nlink != 1 {
        return Err("refusing non-private subscription candidate".to_string());
    }
    unlink_subscription_candidate(directory, name)
}

fn discard_named_subscription_candidate<T>(
    directory: &File,
    name: &OsStr,
    primary: String,
) -> Result<T, String> {
    match remove_subscription_candidate(directory, name) {
        Ok(()) => Err(primary),
        Err(cleanup) => Err(format!(
            "{primary}; subscription candidate cleanup failed: {cleanup}"
        )),
    }
}

fn subscription_candidate_metadata(directory: &File, name: &OsStr) -> io::Result<libc::stat> {
    let name_c = CString::new(name.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid candidate filename"))?;
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    let status = unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name_c.as_ptr(),
            &mut metadata,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if status == 0 {
        Ok(metadata)
    } else {
        Err(io::Error::last_os_error())
    }
}

fn unlink_subscription_candidate(directory: &File, name: &OsStr) -> Result<(), String> {
    let name_c = cstring_from_os_str(name, "subscription candidate filename")?;
    let removed = unsafe { libc::unlinkat(directory.as_raw_fd(), name_c.as_ptr(), 0) };
    if removed == 0 {
        Ok(())
    } else {
        Err("remove subscription candidate failed".to_string())
    }
}

fn require_private_subscription_candidate(file: &File) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|_| "inspect subscription candidate failed".to_string())?;
    if !metadata.file_type().is_file() || metadata.nlink() != 1 {
        return Err("refusing non-private subscription candidate".to_string());
    }
    Ok(())
}

fn clear_close_on_exec(file: &File) -> Result<(), String> {
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) };
    if flags < 0 {
        return Err("inspect subscription candidate descriptor failed".to_string());
    }
    let updated =
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, flags & !libc::FD_CLOEXEC) };
    if updated < 0 {
        return Err("make subscription candidate descriptor inheritable failed".to_string());
    }
    Ok(())
}

fn is_regular_file(metadata: &libc::stat) -> bool {
    (metadata.st_mode & libc::S_IFMT) == libc::S_IFREG
}

fn normalized_subscription_payload(payload: &str) -> Result<String, String> {
    let bytes = decode_base64(payload)?;
    let text =
        String::from_utf8(bytes).map_err(|err| format!("subscription text is not UTF-8: {err}"))?;
    normalized_subscription_text(&text)
}

fn normalized_subscription_text(text: &str) -> Result<String, String> {
    let mut seen = HashSet::new();
    let mut lines = Vec::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        validate_subscription_url(line)?;
        if seen.insert(line.to_string()) {
            lines.push(line.to_string());
            if lines.len() > MAX_SINGBOX_SUBSCRIPTION_URLS {
                return Err(format!(
                    "sing-box subscription URL list supports at most {MAX_SINGBOX_SUBSCRIPTION_URLS} entries"
                ));
            }
        }
    }
    if lines.is_empty() {
        return Err("sing-box subscription URL list is empty".to_string());
    }
    Ok(format!("{}\n", lines.join("\n")))
}

pub fn sub_list(app: &App) {
    for (idx, url) in clean_module_lines(app, Path::new(SUBSCRIPTION_URL_PATH))
        .unwrap_or_default()
        .iter()
        .enumerate()
    {
        println!("sing-box.{}={}", idx + 1, url);
    }
    println!(
        "sing-box={}",
        first_clean_module_line(app, Path::new(SUBSCRIPTION_URL_PATH))
    );
    println!("user-agent={}", subscription_user_agent(app));
    for (idx, value) in subscription_filters(app).iter().enumerate() {
        println!("filter.{}={value}", idx + 1);
    }
}

pub fn sub_get(app: &App, target: &str) {
    let _ = target;
    println!(
        "{}",
        first_clean_module_line(app, Path::new(SUBSCRIPTION_URL_PATH))
    );
}

pub fn sub_update(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("sing-box") {
        "sing-box" | "singbox" | "all" => update_singbox_subscription(app),
        _ => Err("Usage: cli sub update <sing-box|all>".to_string()),
    }
}

pub fn sub_update_all(app: &App) -> Result<(), String> {
    update_singbox_subscription(app)
}

pub fn sub_status(app: &App) -> Result<(), String> {
    run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_status",
    )
}

pub fn sub_schedule(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("status") {
        "status" => run_magicnet_function(app, "magicnet_subscription_schedule_report"),
        "set" => {
            let value = args.get(3).map(String::as_str).unwrap_or_default();
            if !matches!(value, "off" | "12" | "24" | "48" | "72") {
                return Err("Usage: cli sub schedule set <off|12|24|48|72>".to_string());
            }
            run_magicnet_function(app, &format!("magicnet_subscription_schedule_set {value}"))
        }
        _ => Err("Usage: cli sub schedule {status|set <off|12|24|48|72>}".to_string()),
    }
}

fn update_singbox_subscription(app: &App) -> Result<(), String> {
    let update = run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription",
    );
    finish_subscription_update(app, update)
}

pub(crate) fn cleanup_stale_update_lock(app: &App) {
    cleanup_stale_update_lock_from_proc(app, Path::new("/proc"));
}

fn cleanup_stale_update_lock_from_proc(app: &App, proc_root: &Path) {
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let owner_path = lock.join("owner");
    let Ok(owner) = fs::read_to_string(&owner_path) else {
        return;
    };
    let mut fields = owner.trim().split(':');
    let Some(pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
        return;
    };
    let Some(expected_start) = fields
        .next()
        .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
    else {
        return;
    };
    let proc_dir = proc_root.join(pid.to_string());
    let definitely_dead = if !proc_dir.is_dir() {
        true
    } else {
        let stat = match read_proc_text_bounded(&proc_dir.join("stat"), MAX_PROC_STAT_BYTES) {
            Ok(stat) => stat,
            Err(_) if !proc_dir.is_dir() => String::new(),
            Err(_) => return,
        };
        if stat.is_empty() {
            true
        } else {
            let Some(close) = stat.rfind(')') else {
                return;
            };
            let Some(state) = stat[close + 1..].split_whitespace().next() else {
                return;
            };
            let Some(live_start) = crate::proc_start_time(&stat) else {
                return;
            };
            state == "Z" || live_start != expected_start
        }
    };
    if !definitely_dead {
        return;
    }
    if fs::read_to_string(&owner_path)
        .ok()
        .as_deref()
        .map(str::trim)
        == Some(owner.trim())
    {
        let _ = fs::remove_file(&owner_path);
        let _ = fs::remove_dir(&lock);
    }
}

pub(crate) fn sub_target_file(app: &App, _target: &str) -> PathBuf {
    app.moddir.join(".config/sing-box/subscription.url")
}

fn subscription_user_agent(app: &App) -> String {
    crate::utils::clean_module_lines(app, Path::new(SUBSCRIPTION_USER_AGENT_PATH))
        .unwrap_or_default()
        .into_iter()
        .next()
        .unwrap_or_default()
}

fn subscription_filters(app: &App) -> Vec<String> {
    crate::utils::clean_module_lines(app, Path::new(SUBSCRIPTION_FILTER_PATH)).unwrap_or_default()
}

pub(crate) fn normalize_subscription_filter_text(value: &str) -> Result<String, String> {
    let mut seen = HashSet::new();
    let mut filters = Vec::new();
    for raw in value.lines() {
        let filter = raw.trim();
        if filter.is_empty() {
            continue;
        }
        if filter.len() > MAX_SUBSCRIPTION_FILTER_BYTES {
            return Err(format!(
                "subscription filter must be at most {MAX_SUBSCRIPTION_FILTER_BYTES} bytes"
            ));
        }
        if filter.chars().any(char::is_control) {
            return Err("subscription filter must not contain control characters".to_string());
        }
        let folded = filter.to_lowercase();
        if seen.insert(folded) {
            filters.push(filter.to_string());
        }
        if filters.len() > MAX_SUBSCRIPTION_FILTERS {
            return Err(format!(
                "subscription filter list supports at most {MAX_SUBSCRIPTION_FILTERS} entries"
            ));
        }
    }
    if filters.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!("{}\n", filters.join("\n")))
    }
}

pub(crate) fn validate_subscription_user_agent(value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err("Subscription User-Agent must not be empty; use clear instead".to_string());
    }
    if value.len() > MAX_SUBSCRIPTION_USER_AGENT_BYTES {
        return Err(format!(
            "Subscription User-Agent must be at most {MAX_SUBSCRIPTION_USER_AGENT_BYTES} bytes"
        ));
    }
    if value.chars().any(char::is_control) {
        return Err("Subscription User-Agent must not contain control characters".to_string());
    }
    Ok(())
}

pub(crate) fn validate_subscription_url(url: &str) -> Result<(), String> {
    let authority = parse_subscription_authority(url)?;
    if let Ok(address) = IpAddr::from_str(authority.host) {
        if !is_public_subscription_address(address) {
            return Err(
                "Subscription URL must not target a private or special-use address".to_string(),
            );
        }
    }
    Ok(())
}

/// Empty files are valid local-only restores. Non-empty lines must pass the
/// same HTTPS/public-host policy as `cli sub set`.
pub(crate) fn validate_restored_subscription_urls(text: &str) -> Result<(), String> {
    if text.contains('\0') {
        return Err("subscription URL list must not contain NUL bytes".to_string());
    }
    let mut count = 0_usize;
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        validate_subscription_url(line)?;
        count += 1;
        if count > MAX_SINGBOX_SUBSCRIPTION_URLS {
            return Err(format!(
                "sing-box subscription URL list supports at most {MAX_SINGBOX_SUBSCRIPTION_URLS} entries"
            ));
        }
    }
    Ok(())
}

struct SubscriptionAuthority<'a> {
    host: &'a str,
    port: u16,
}

/// Parse only the authority needed for URL policy. DNS resolution and pinning
/// happen immediately before the privileged device-side curl invocation.
fn parse_subscription_authority(url: &str) -> Result<SubscriptionAuthority<'_>, String> {
    let (scheme, remainder) = url
        .split_once("://")
        .ok_or_else(|| "Subscription URL must use HTTPS".to_string())?;
    if !scheme.eq_ignore_ascii_case("https") {
        return Err("Subscription URL must use HTTPS".to_string());
    }
    if url.chars().any(char::is_whitespace) || url.chars().any(char::is_control) {
        return Err(
            "Subscription URL must not contain whitespace or control characters".to_string(),
        );
    }
    let authority_end = remainder.find(['/', '?', '#']).unwrap_or(remainder.len());
    let authority = &remainder[..authority_end];
    if authority.is_empty() || authority.contains('@') {
        return Err(
            "Subscription URL authority must not be empty or include credentials".to_string(),
        );
    }

    let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
        let closing = bracketed
            .find(']')
            .ok_or_else(|| "Subscription URL has an invalid IPv6 authority".to_string())?;
        let host = &bracketed[..closing];
        let suffix = &bracketed[closing + 1..];
        if !suffix.is_empty() && !suffix.starts_with(':') {
            return Err("Subscription URL has an invalid IPv6 authority".to_string());
        }
        let port = parse_subscription_port(suffix)?;
        if !matches!(IpAddr::from_str(host), Ok(IpAddr::V6(_))) {
            return Err("Subscription URL has an invalid IPv6 address".to_string());
        }
        (host, port)
    } else {
        let (host, port_suffix) = authority
            .rsplit_once(':')
            .map_or((authority, ""), |(host, port)| (host, port));
        if host.contains(':') {
            return Err("Subscription URL has an invalid authority".to_string());
        }
        validate_subscription_host(host)?;
        (host, parse_subscription_port(port_suffix)?)
    };

    Ok(SubscriptionAuthority { host, port })
}

/// Download an HTTPS URL with the same public-address and redirect policy as
/// subscription fetches: resolve first, reject private targets, pin curl with
/// `--resolve`, and refuse redirects that could re-target the request.
pub(crate) fn download_pinned_https_url(
    url: &str,
    max_bytes: usize,
    connect_timeout_secs: u64,
    max_time_secs: u64,
) -> Result<Vec<u8>, String> {
    validate_subscription_url(url)?;
    let authority = parse_subscription_authority(url)?;
    let resolved = (authority.host, authority.port)
        .to_socket_addrs()
        .map_err(|_| "HTTPS hostname resolution failed".to_string())?
        .map(|address| address.ip())
        .collect::<HashSet<_>>();
    validate_resolved_subscription_addresses(&resolved)?;

    let mut addresses = resolved.into_iter().collect::<Vec<_>>();
    addresses.sort_by_key(ToString::to_string);
    let resolve_args = addresses
        .into_iter()
        .map(|address| {
            let pinned = match address {
                IpAddr::V6(v6) => format!("[{v6}]"),
                IpAddr::V4(v4) => v4.to_string(),
            };
            format!("{}:{}:{pinned}", authority.host, authority.port)
        })
        .collect::<Vec<_>>();

    let max_bytes_arg = max_bytes.to_string();
    let connect_timeout = connect_timeout_secs.to_string();
    let max_time = max_time_secs.to_string();
    let mut command = Command::new("curl");
    command.args([
        "-fsS",
        "--noproxy",
        "*",
        "--max-redirs",
        "0",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--max-filesize",
        &max_bytes_arg,
        "--connect-timeout",
        &connect_timeout,
        "--max-time",
        &max_time,
    ]);
    for resolve in &resolve_args {
        command.args(["--resolve", resolve]);
    }
    command.arg(url);
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|err| format!("run curl: {err}"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "capture HTTPS download failed".to_string())?;
    let mut bytes = Vec::with_capacity(max_bytes.min(64 * 1024));
    stdout
        .by_ref()
        .take((max_bytes + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("read HTTPS download: {err}"))?;
    if bytes.len() > max_bytes {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("HTTPS download exceeds {max_bytes} byte limit"));
    }
    let output = child
        .wait_with_output()
        .map_err(|err| format!("wait for curl: {err}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim();
        return Err(if detail.is_empty() {
            format!(
                "curl exited with status {}",
                output.status.code().unwrap_or(1)
            )
        } else {
            format!("curl failed: {detail}")
        });
    }
    Ok(bytes)
}

fn parse_subscription_port(suffix: &str) -> Result<u16, String> {
    if suffix.is_empty() {
        return Ok(443);
    }
    let value = suffix.strip_prefix(':').unwrap_or(suffix);
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("Subscription URL has an invalid port".to_string());
    }
    let port = value
        .parse::<u16>()
        .map_err(|_| "Subscription URL has an invalid port".to_string())?;
    if port == 0 {
        return Err("Subscription URL has an invalid port".to_string());
    }
    Ok(port)
}

fn validate_subscription_host(host: &str) -> Result<(), String> {
    if let Ok(address) = IpAddr::from_str(host) {
        return if is_public_subscription_address(address) {
            Ok(())
        } else {
            Err("Subscription URL must not target a private or special-use address".to_string())
        };
    }
    if host.is_empty()
        || host.len() > 253
        || host.starts_with('.')
        || host.ends_with('.')
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err("Subscription URL has an invalid hostname".to_string());
    }
    // Reject non-canonical numeric spellings such as 127.1 and 0x7f000001,
    // which curl may interpret as an IP address despite not being DNS names.
    if host
        .bytes()
        .all(|byte| byte.is_ascii_digit() || byte == b'.')
        || (host.len() > 2
            && host[..2].eq_ignore_ascii_case("0x")
            && host[2..].bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return Err("Subscription URL has an invalid hostname".to_string());
    }
    Ok(())
}

fn is_public_subscription_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => {
            let [first, second, third, _] = address.octets();
            !(first == 0
                || first == 10
                || first == 127
                || first >= 224
                || (first == 100 && (64..=127).contains(&second))
                || (first == 169 && second == 254)
                || (first == 172 && (16..=31).contains(&second))
                || (first == 192
                    && (second == 0
                        || second == 2
                        || second == 168
                        || (second == 31 && third == 196)
                        || (second == 52 && third == 193)
                        || (second == 88 && third == 99)
                        || (second == 175 && third == 48)))
                || (first == 198 && ((18..=19).contains(&second) || second == 51))
                || (first == 203 && second == 0 && third == 113))
        }
        IpAddr::V6(address) => {
            if let Some(mapped) = address.to_ipv4_mapped() {
                return is_public_subscription_address(IpAddr::V4(mapped));
            }
            let segments = address.segments();
            let first = segments[0];
            !(address.is_unspecified()
                || address.is_loopback()
                || address.is_multicast()
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80
                // Documentation, benchmarking, discard, Teredo, and
                // well-known NAT64 ranges are not routable subscription
                // endpoints and must not be treated as public addresses.
                || (first == 0x0100 && segments[1..4] == [0, 0, 0])
                || (first == 0x0064
                    && segments[1] == 0xff9b
                    && segments[2..6] == [0, 0, 0, 0])
                || (first == 0x2001 && segments[1] == 0)
                || (first == 0x2001 && segments[1] == 2 && segments[2] == 0)
                || (first == 0x2001 && segments[1] == 0xdb8)
                || (first == 0x2001
                    && (segments[1] & 0xfff0) == 0x0010)
                || (first == 0x2001
                    && (segments[1] & 0xfff0) == 0x0020))
        }
    }
}

fn validate_resolved_subscription_addresses(addresses: &HashSet<IpAddr>) -> Result<(), String> {
    if addresses.is_empty() {
        return Err("Subscription hostname returned no addresses".to_string());
    }
    if addresses
        .iter()
        .any(|address| !is_public_subscription_address(*address))
    {
        return Err(
            "Subscription hostname resolved to a private or special-use address".to_string(),
        );
    }
    Ok(())
}

#[cfg(test)]
#[path = "../tests/internal/subscriptions.rs"]
mod tests;
