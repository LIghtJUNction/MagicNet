use std::collections::HashSet;
use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, Seek, SeekFrom, Write};
use std::net::{IpAddr, ToSocketAddrs};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{
    clean_lines, clear_node_cache, decode_base64, first_clean_line, run_magicnet_function,
    run_subscription_update_from_inherited_fd, write_text_file, App,
};

const MAX_SINGBOX_SUBSCRIPTION_URLS: usize = 5;
const MAX_SUBSCRIPTION_USER_AGENT_BYTES: usize = 256;
const MAX_SUBSCRIPTION_FILTERS: usize = 32;
const MAX_SUBSCRIPTION_FILTER_BYTES: usize = 64;
const SUBSCRIPTION_USER_AGENT_PATH: &str = ".config/sing-box/subscription.user-agent";
const SUBSCRIPTION_FILTER_PATH: &str = ".config/sing-box/subscription-filter.list";
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
        _ => Err(
            "Usage: cli sub user-agent {get|set <base64-value>|clear}".to_string(),
        ),
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
    validate_subscription_hostname(host)?;
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

fn apply_subscription_text(app: &App, text: &str) -> Result<(), String> {
    let result = with_subscription_candidate(app, text, |candidate_fd| {
        run_subscription_update_from_inherited_fd(app, candidate_fd)
    });
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
    let path = CString::new(app.moddir.as_os_str().as_bytes())
        .map_err(|_| "subscription module root contains an unsupported NUL byte".to_string())?;
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
    let name_c = subscription_cstring(name, "subscription directory")?;
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
        let name_c = subscription_cstring(&name, "subscription candidate filename")?;
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
    let name_c = subscription_cstring(name, "subscription candidate filename")?;
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

fn subscription_cstring(value: &OsStr, description: &str) -> Result<CString, String> {
    CString::new(value.as_bytes())
        .map_err(|_| format!("{description} contains an unsupported NUL byte"))
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
    Ok(format!("{}\n", lines.join("\n")))
}

pub fn sub_list(app: &App) {
    for (idx, url) in clean_lines(app.moddir.join(".config/sing-box/subscription.url"))
        .iter()
        .enumerate()
    {
        println!("sing-box.{}={}", idx + 1, url);
    }
    println!(
        "sing-box={}",
        first_clean_line(app.moddir.join(".config/sing-box/subscription.url"))
    );
    println!("user-agent={}", subscription_user_agent(app));
    for (idx, value) in subscription_filters(app).iter().enumerate() {
        println!("filter.{}={value}", idx + 1);
    }
}

pub fn sub_get(app: &App, target: &str) {
    println!("{}", first_clean_line(sub_target_file(app, target)));
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
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let owner_path = lock.join("owner");
    let Ok(owner) = fs::read_to_string(&owner_path) else {
        return;
    };
    let mut fields = owner.trim().split(':');
    let pid = fields.next().and_then(|value| value.parse::<u32>().ok());
    let expected_start = fields.next();
    let live_start = pid
        .and_then(|pid| fs::read_to_string(format!("/proc/{pid}/stat")).ok())
        .and_then(|stat| stat.split_whitespace().nth(21).map(str::to_string));
    if expected_start.is_some() && live_start.as_deref() == expected_start {
        return;
    }
    if fs::read_to_string(&owner_path)
        .ok()
        .as_deref()
        .map(str::trim)
        == Some(owner.trim())
    {
        let _ = fs::remove_dir_all(lock);
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
    crate::utils::clean_module_lines(app, Path::new(SUBSCRIPTION_FILTER_PATH))
        .unwrap_or_default()
}

pub(crate) fn normalize_subscription_filter_text(value: &str) -> Result<String, String> {
    let mut seen = HashSet::new();
    let mut filters = Vec::new();
    for raw in value.lines() {
        let filter = raw.trim();
        if filter.is_empty() {
            continue;
        }
        if filter.as_bytes().len() > MAX_SUBSCRIPTION_FILTER_BYTES {
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
    if value.as_bytes().len() > MAX_SUBSCRIPTION_USER_AGENT_BYTES {
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

struct SubscriptionAuthority<'a> {
    host: &'a str,
    port: u16,
}

/// Parse only the authority needed for URL policy. DNS resolution and pinning
/// happen immediately before the privileged device-side curl invocation.
fn parse_subscription_authority(url: &str) -> Result<SubscriptionAuthority<'_>, String> {
    let remainder = url
        .strip_prefix("https://")
        .ok_or_else(|| "Subscription URL must use HTTPS".to_string())?;
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
        validate_subscription_hostname(host)?;
        (host, parse_subscription_port(port_suffix)?)
    };

    Ok(SubscriptionAuthority { host, port })
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

fn validate_subscription_hostname(host: &str) -> Result<(), String> {
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
            let [first, second, ..] = address.octets();
            !(first == 0
                || first == 10
                || first == 127
                || first >= 224
                || (first == 100 && (64..=127).contains(&second))
                || (first == 169 && second == 254)
                || (first == 172 && (16..=31).contains(&second))
                || (first == 192 && second == 168)
                || (first == 198 && (18..=19).contains(&second)))
        }
        IpAddr::V6(address) => {
            if let Some(mapped) = address.to_ipv4_mapped() {
                return is_public_subscription_address(IpAddr::V4(mapped));
            }
            let first = address.segments()[0];
            !(address.is_unspecified()
                || address.is_loopback()
                || address.is_multicast()
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80)
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
mod tests {
    use std::fs;
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("magicnet-cli-test-{stamp}"));
        fs::create_dir_all(&dir).expect("create module directory");
        App::for_test(dir)
    }

    #[test]
    fn subscription_url_validation_requires_public_https_without_credentials() {
        validate_subscription_url("https://example.com/sub?profile=abc").unwrap();
        validate_subscription_url("https://example.com:8443/sub").unwrap();
        assert!(validate_subscription_url("http://example.com/sub").is_err());
        assert!(validate_subscription_url("https://user:secret@example.com/sub").is_err());
        assert!(validate_subscription_url("https://127.0.0.1:8080/sub").is_err());
        assert!(validate_subscription_url("ftp://example.com/sub").is_err());
        assert!(validate_subscription_url("https://example.com/a b").is_err());
    }

    #[test]
    fn subscription_authority_rejects_malformed_ports_and_ipv6_authorities() {
        assert_eq!(
            parse_subscription_authority("https://example.com:8443/sub")
                .expect("valid explicit port")
                .port,
            8443
        );
        for url in [
            "https://example.com:0/sub",
            "https://example.com:not-a-port/sub",
            "https://[::1]8443/sub",
            "https://[not-an-ip]/sub",
            "https://example.com:443:1/sub",
        ] {
            assert!(
                parse_subscription_authority(url).is_err(),
                "{url} must fail"
            );
        }
    }

    #[test]
    fn subscription_address_policy_rejects_private_and_special_use_addresses() {
        for address in [
            "0.0.0.0",
            "10.0.0.1",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "192.168.0.1",
            "224.0.0.1",
            "::",
            "::1",
            "fc00::1",
            "fe80::1",
            "ff02::1",
            "::ffff:127.0.0.1",
        ] {
            let address = IpAddr::from_str(address).expect("valid fixture address");
            assert!(
                !is_public_subscription_address(address),
                "{address} must be rejected"
            );
        }
        for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
            let address = IpAddr::from_str(address).expect("valid fixture address");
            assert!(
                is_public_subscription_address(address),
                "{address} must remain permitted"
            );
        }
    }

    #[test]
    fn resolved_subscription_addresses_fail_closed() {
        let public = HashSet::from([
            IpAddr::from_str("1.1.1.1").unwrap(),
            IpAddr::from_str("2606:4700:4700::1111").unwrap(),
        ]);
        validate_resolved_subscription_addresses(&public).unwrap();

        let mixed = HashSet::from([
            IpAddr::from_str("1.1.1.1").unwrap(),
            IpAddr::from_str("127.0.0.1").unwrap(),
        ]);
        assert!(validate_resolved_subscription_addresses(&mixed).is_err());
        assert!(validate_resolved_subscription_addresses(&HashSet::new()).is_err());
    }

    #[test]
    fn subscription_user_agent_is_validated_and_persisted() {
        let app = temp_app();
        let value = "sing-box/1.12.0 (Android)";
        let encoded = crate::encode_base64(value.as_bytes());

        sub_user_agent(
            &app,
            &[
                "sub".to_string(),
                "user-agent".to_string(),
                "set".to_string(),
                encoded,
            ],
        )
        .expect("set subscription User-Agent");

        assert_eq!(subscription_user_agent(&app), value);
        assert_eq!(
            fs::read_to_string(app.moddir.join(SUBSCRIPTION_USER_AGENT_PATH)).unwrap(),
            format!("{value}\n")
        );

        sub_user_agent(
            &app,
            &[
                "sub".to_string(),
                "user-agent".to_string(),
                "clear".to_string(),
            ],
        )
        .expect("clear subscription User-Agent");
        assert_eq!(subscription_user_agent(&app), "");
    }

    #[test]
    fn subscription_filters_are_normalized_deduplicated_and_persisted() {
        let app = temp_app();
        let encoded = crate::encode_base64("免费\nFREE\nfree\n香港\n".as_bytes());

        sub_filter(
            &app,
            &[
                "sub".to_string(),
                "filter".to_string(),
                "set".to_string(),
                encoded,
            ],
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(app.moddir.join(SUBSCRIPTION_FILTER_PATH)).unwrap(),
            "免费\nFREE\n香港\n"
        );
        assert_eq!(subscription_filters(&app), ["免费", "FREE", "香港"]);
    }

    #[test]
    fn subscription_filters_reject_oversized_or_excessive_entries() {
        assert!(normalize_subscription_filter_text(&"x".repeat(65)).is_err());
        let too_many = (0..=MAX_SUBSCRIPTION_FILTERS)
            .map(|index| format!("filter-{index}"))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(normalize_subscription_filter_text(&too_many).is_err());
    }

    #[test]
    fn subscription_user_agent_rejects_controls_and_oversized_values() {
        assert!(validate_subscription_user_agent("sing-box\ninjected").is_err());
        assert!(validate_subscription_user_agent(&"x".repeat(257)).is_err());
        assert!(validate_subscription_user_agent("").is_err());
    }

    #[test]
    fn set_file_dedupes_and_trims_singbox_subscription_lines() {
        let payload = crate::encode_base64(
            b"\nhttps://example.com/a\nhttps://example.com/a\n  https://example.com/b  \n",
        );
        let text = normalized_subscription_payload(&payload).unwrap();
        assert_eq!(text, "https://example.com/a\nhttps://example.com/b\n");
    }

    #[test]
    fn webui_raw_subscription_text_uses_the_same_normalization_rules() {
        let text = normalized_subscription_text(
            "\nhttps://example.com/a\nhttps://example.com/a\n  https://example.com/b  \n",
        )
        .expect("normalize WebUI payload text");

        assert_eq!(text, "https://example.com/a\nhttps://example.com/b\n");
        assert!(normalized_subscription_text("vmess://not-a-subscription\n").is_err());
    }

    #[test]
    fn set_file_rejects_non_http_subscription_lines() {
        let app = temp_app();
        let payload = crate::encode_base64(b"vmess://not-a-subscription-file-entry\n");

        let err = sub_set_file(
            &app,
            &[
                "sub".to_string(),
                "set-file".to_string(),
                "sing-box".to_string(),
                payload,
            ],
        )
        .unwrap_err();

        assert!(err.contains("must use HTTPS"), "{err}");
    }

    #[test]
    fn set_file_rejects_more_than_five_singbox_subscription_lines() {
        let app = temp_app();
        let payload = crate::encode_base64(
            b"https://example.com/1\nhttps://example.com/2\nhttps://example.com/3\nhttps://example.com/4\nhttps://example.com/5\nhttps://example.com/6\n",
        );

        let err = sub_set_file(
            &app,
            &[
                "sub".to_string(),
                "set-file".to_string(),
                "sing-box".to_string(),
                payload,
            ],
        )
        .unwrap_err();

        assert!(err.contains("at most 5 entries"), "{err}");
    }

    #[test]
    fn candidate_activation_failure_never_writes_the_active_url() {
        let app = temp_app();
        let directory = app.moddir.join(".tmp/subscription-candidates");
        let error =
            with_subscription_candidate(&app, "https://example.com/sub\n", |candidate_fd| {
                assert_eq!(
                    fs::read_to_string(format!("/proc/self/fd/{candidate_fd}")).unwrap(),
                    "https://example.com/sub\n"
                );
                assert!(
                    fs::read_dir(&directory)
                        .expect("read anonymous candidate directory")
                        .next()
                        .is_none(),
                    "candidate must be unlinked before activation"
                );
                Err::<(), _>("activation rejected".to_string())
            })
            .unwrap_err();

        assert_eq!(error, "activation rejected");
        assert!(!sub_target_file(&app, "sing-box").exists());
        assert!(fs::read_dir(&directory)
            .expect("read anonymous candidate directory")
            .next()
            .is_none());
    }

    #[test]
    fn committed_update_with_selector_replay_failure_is_success_with_warning() {
        let outcome =
            subscription_update_outcome(Ok(()), Err("fixture selector replay failure".to_string()))
                .unwrap();

        assert_eq!(outcome, Some(SELECTOR_REPLAY_WARNING));
    }

    #[test]
    fn failed_update_stays_failed_even_when_replay_would_succeed() {
        let error =
            subscription_update_outcome(Err("update failed".to_string()), Ok(())).unwrap_err();

        assert_eq!(error, "update failed");
    }

    #[test]
    fn anonymous_subscription_candidate_is_private_and_readable_by_a_child() {
        let app = temp_app();
        let candidate =
            write_subscription_candidate(&app, "https://example.com/private\n").unwrap();
        let metadata = candidate.file.metadata().expect("stat anonymous candidate");
        let directory = app.moddir.join(".tmp/subscription-candidates");

        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(
            metadata.nlink(),
            0,
            "candidate must be unlinked before spawn"
        );
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert!(
            fs::read_dir(&directory)
                .expect("read anonymous candidate directory")
                .next()
                .is_none(),
            "no lexical candidate file may remain"
        );

        let fd_path = format!("/proc/self/fd/{}", candidate.fd());
        let output = Command::new("sh")
            .arg("-c")
            .arg("cat \"$1\"")
            .arg("sh")
            .arg(&fd_path)
            .output()
            .expect("spawn child reader");

        assert!(output.status.success(), "child reader failed: {output:?}");
        assert_eq!(output.stdout.as_slice(), b"https://example.com/private\n");
    }

    #[test]
    fn candidate_temp_root_symlink_is_rejected_without_creating_outside_files() {
        let app = temp_app();
        let outside = app.moddir.join("outside");
        fs::create_dir_all(&app.moddir).expect("create module directory");
        fs::create_dir_all(&outside).expect("create outside directory");
        symlink(&outside, app.moddir.join(".tmp")).expect("create temporary-root symlink");

        assert!(write_subscription_candidate(&app, "https://example.com/sub\n").is_err());
        assert!(
            !outside.join("subscription-candidates").exists(),
            "candidate setup must not traverse a .tmp symlink"
        );
    }

    #[test]
    fn candidate_temp_directory_symlink_is_rejected_without_creating_outside_files() {
        let app = temp_app();
        let outside = app.moddir.join("outside");
        let parent = app.moddir.join(".tmp");
        fs::create_dir_all(&parent).expect("create candidate parent");
        fs::create_dir_all(&outside).expect("create outside directory");
        symlink(&outside, parent.join("subscription-candidates"))
            .expect("create candidate directory symlink");

        assert!(write_subscription_candidate(&app, "https://example.com/sub\n").is_err());
        assert!(
            fs::read_dir(&outside)
                .expect("read outside directory")
                .next()
                .is_none(),
            "candidate setup must not traverse the candidate directory symlink"
        );
    }
}
