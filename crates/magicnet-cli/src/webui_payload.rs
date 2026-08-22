use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::{decode_base64, App};

pub(crate) const MAX_WEBUI_PAYLOAD_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Copy)]
enum PayloadNamespace {
    Tmp,
    Subscription,
}

impl PayloadNamespace {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "tmp" => Ok(Self::Tmp),
            "subscription" => Ok(Self::Subscription),
            _ => Err("invalid WebUI payload namespace".to_string()),
        }
    }

    fn directory_name(self) -> &'static str {
        match self {
            Self::Tmp => "webui-payload",
            Self::Subscription => "webui-subscription",
        }
    }
}

pub(crate) fn webui_payload_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "create" => {
            let namespace = payload_namespace_arg(args, 1)?;
            let name = payload_name_arg(args, 2)?;
            if args.len() != 3 {
                return Err(payload_usage());
            }
            let path = create_payload(app, namespace, name)?;
            // The path is intentionally the only output from create. It is an
            // absolute path under an owned namespace and can be handed to the
            // existing file-path-only CLI consumers without exposing data.
            println!("{}", path.display());
            Ok(())
        }
        "append" => {
            let namespace = payload_namespace_arg(args, 1)?;
            let name = payload_name_arg(args, 2)?;
            let chunk = args.get(3).ok_or_else(payload_usage)?;
            if args.len() != 4 {
                return Err(payload_usage());
            }
            append_payload(app, namespace, name, chunk)
        }
        "remove" => {
            let namespace = payload_namespace_arg(args, 1)?;
            let name = payload_name_arg(args, 2)?;
            if args.len() != 3 {
                return Err(payload_usage());
            }
            remove_payload(app, namespace, name)
        }
        "apply-subscription" => {
            let name = payload_name_arg(args, 1)?;
            if args.len() != 2 {
                return Err(payload_usage());
            }
            consume_subscription_payload_with(app, name, |bytes| {
                crate::subscriptions::apply_webui_subscription_payload(app, bytes)
            })
        }
        "apply-subscription-source" => {
            let name = payload_name_arg(args, 1)?;
            if args.len() != 2 {
                return Err(payload_usage());
            }
            consume_subscription_payload_with(app, name, |bytes| {
                crate::subscriptions::apply_webui_subscription_source_payload(app, bytes)
            })
        }
        _ => Err(payload_usage()),
    }
}

fn payload_usage() -> String {
    "Usage: cli webui payload {create <tmp|subscription> <safe-basename>|append <tmp|subscription> <safe-basename> <base64-chunk>|remove <tmp|subscription> <safe-basename>|apply-subscription <safe-basename>|apply-subscription-source <safe-basename>}"
        .to_string()
}

fn payload_namespace_arg(args: &[String], index: usize) -> Result<PayloadNamespace, String> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(payload_usage)
        .and_then(PayloadNamespace::parse)
}

fn payload_name_arg(args: &[String], index: usize) -> Result<&OsStr, String> {
    let name = args.get(index).ok_or_else(payload_usage)?;
    let name = OsStr::new(name.as_str());
    validate_payload_name(name)?;
    Ok(name)
}

pub(crate) fn validate_payload_name(name: &OsStr) -> Result<(), String> {
    let bytes = name.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 128
        || bytes[0] == b'.'
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("invalid WebUI payload filename".to_string());
    }
    Ok(())
}

fn create_payload(app: &App, namespace: PayloadNamespace, name: &OsStr) -> Result<PathBuf, String> {
    let directory = payload_directory(app, namespace)?;
    let name_c = cstring_from_os_str(name, "payload filename")?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err("create WebUI payload failed".to_string());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    require_private_payload_file(&file)?;
    secure_file_mode(&file)?;
    drop(file);
    absolute_payload_path(app, namespace, name)
}

fn append_payload(
    app: &App,
    namespace: PayloadNamespace,
    name: &OsStr,
    chunk: &str,
) -> Result<(), String> {
    // Decode every chunk separately. This makes base64 padding local to the
    // chunk and produces a normal raw file for path-based CLI consumers.
    let bytes = decode_base64(chunk).map_err(|_| "invalid WebUI payload chunk".to_string())?;
    let directory = payload_directory(app, namespace)?;
    let mut file = open_payload_file(
        &directory,
        name,
        libc::O_WRONLY | libc::O_APPEND | libc::O_NONBLOCK | libc::O_CLOEXEC,
    )?;
    secure_file_mode(&file)?;
    lock_payload_file(&file)?;
    ensure_current_payload_file(&directory, name, &file)?;
    let current_size = file
        .metadata()
        .map_err(|_| "inspect WebUI payload failed".to_string())?
        .len();
    if current_size.saturating_add(bytes.len() as u64) > MAX_WEBUI_PAYLOAD_BYTES {
        return Err(match namespace {
            PayloadNamespace::Subscription => {
                "WebUI subscription payload exceeds the 8 MiB limit".to_string()
            }
            PayloadNamespace::Tmp => "WebUI temporary payload exceeds the 8 MiB limit".to_string(),
        });
    }
    file.write_all(&bytes)
        .map_err(|_| "append WebUI payload failed".to_string())
}

fn remove_payload(app: &App, namespace: PayloadNamespace, name: &OsStr) -> Result<(), String> {
    let directory = payload_directory(app, namespace)?;
    remove_payload_at(&directory, name)
}

fn consume_subscription_payload_with<T>(
    app: &App,
    name: &OsStr,
    apply: impl FnOnce(&[u8]) -> Result<T, String>,
) -> Result<T, String> {
    let bytes = take_payload(app, PayloadNamespace::Subscription, name)?;
    apply(&bytes)
}

/// Read and remove an owned payload before handing its bytes to a consumer.
/// Removing first means validation or application failures cannot leave a
/// private payload on the device for a later, unintended invocation.
fn take_payload(app: &App, namespace: PayloadNamespace, name: &OsStr) -> Result<Vec<u8>, String> {
    let directory = payload_directory(app, namespace)?;
    let mut file = open_payload_file(
        &directory,
        name,
        libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC,
    )?;
    lock_payload_file(&file)?;
    ensure_current_payload_file(&directory, name, &file)?;
    unlink_payload_at(&directory, name)?;
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_WEBUI_PAYLOAD_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "read WebUI payload failed".to_string())
        .and_then(|_| {
            if bytes.len() as u64 > MAX_WEBUI_PAYLOAD_BYTES {
                Err("WebUI payload exceeds the 8 MiB limit".to_string())
            } else {
                Ok(())
            }
        })?;
    Ok(bytes)
}

fn remove_payload_at(directory: &File, name: &OsStr) -> Result<(), String> {
    let file = open_payload_file(
        directory,
        name,
        libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC,
    )?;
    lock_payload_file(&file)?;
    ensure_current_payload_file(directory, name, &file)?;
    unlink_payload_at(directory, name)
}

fn lock_payload_file(file: &File) -> Result<(), String> {
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
        Ok(())
    } else {
        Err("lock WebUI payload failed".to_string())
    }
}

fn ensure_current_payload_file(directory: &File, name: &OsStr, file: &File) -> Result<(), String> {
    let current = open_payload_file(
        directory,
        name,
        libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC,
    )?;
    let expected = file
        .metadata()
        .map_err(|_| "inspect WebUI payload failed".to_string())?;
    let observed = current
        .metadata()
        .map_err(|_| "inspect WebUI payload failed".to_string())?;
    if expected.dev() == observed.dev() && expected.ino() == observed.ino() {
        Ok(())
    } else {
        Err("WebUI payload changed during operation".to_string())
    }
}

fn unlink_payload_at(directory: &File, name: &OsStr) -> Result<(), String> {
    let name_c = cstring_from_os_str(name, "payload filename")?;
    if unsafe { libc::unlinkat(directory.as_raw_fd(), name_c.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err("remove WebUI payload failed".to_string())
    }
}

fn payload_directory(app: &App, namespace: PayloadNamespace) -> Result<File, String> {
    let moddir = open_no_follow_directory(&app.moddir)?;
    let tmp = ensure_private_directory(&moddir, OsStr::new(".tmp"))?;
    ensure_private_directory(&tmp, OsStr::new(namespace.directory_name()))
}

fn ensure_private_directory(parent: &File, name: &OsStr) -> Result<File, String> {
    let name_c = cstring_from_os_str(name, "payload directory")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), 0o700) };
    if created != 0 && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
        return Err("create WebUI payload directory failed".to_string());
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("open WebUI payload directory failed".to_string());
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    secure_directory_mode(&directory)?;
    Ok(directory)
}

fn open_no_follow_directory(path: &Path) -> Result<File, String> {
    let path_c = cstring_from_os_str(path.as_os_str(), "payload root directory")?;
    let fd = unsafe {
        libc::open(
            path_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("open WebUI payload root failed".to_string());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_payload_file(directory: &File, name: &OsStr, flags: i32) -> Result<File, String> {
    let name_c = cstring_from_os_str(name, "payload filename")?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name_c.as_ptr(),
            flags | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err("open WebUI payload failed".to_string());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    require_private_payload_file(&file)?;
    Ok(file)
}

fn require_private_payload_file(file: &File) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|_| "inspect WebUI payload failed".to_string())?;
    if !metadata.file_type().is_file() || metadata.nlink() != 1 {
        return Err("WebUI payload must be a private regular file".to_string());
    }
    Ok(())
}

fn secure_file_mode(file: &File) -> Result<(), String> {
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| "secure WebUI payload failed".to_string())
}

fn secure_directory_mode(directory: &File) -> Result<(), String> {
    directory
        .set_permissions(fs::Permissions::from_mode(0o700))
        .map_err(|_| "secure WebUI payload directory failed".to_string())
}

fn absolute_payload_path(
    app: &App,
    namespace: PayloadNamespace,
    name: &OsStr,
) -> Result<PathBuf, String> {
    let root = if app.moddir.is_absolute() {
        app.moddir.clone()
    } else {
        std::env::current_dir()
            .map_err(|_| "resolve WebUI payload path failed".to_string())?
            .join(&app.moddir)
    };
    Ok(root
        .join(".tmp")
        .join(namespace.directory_name())
        .join(name))
}

fn cstring_from_os_str(value: &OsStr, description: &str) -> Result<CString, String> {
    CString::new(value.as_bytes())
        .map_err(|_| format!("{description} contains an unsupported NUL byte"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos();
        App::for_test(std::env::temp_dir().join(format!(
            "magicnet-webui-payload-test-{}-{stamp}",
            std::process::id()
        )))
    }

    #[test]
    fn create_uses_a_private_absolute_controlled_path() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");

        let path = create_payload(&app, PayloadNamespace::Tmp, OsStr::new("config.json"))
            .expect("create payload");

        assert!(path.is_absolute());
        assert_eq!(path, app.moddir.join(".tmp/webui-payload/config.json"));
        assert_eq!(
            fs::metadata(&path)
                .expect("stat payload")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn append_decodes_each_base64_chunk_into_the_payload_file() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let name = OsStr::new("chunked.txt");
        let path = create_payload(&app, PayloadNamespace::Tmp, name).expect("create payload");

        append_payload(
            &app,
            PayloadNamespace::Tmp,
            name,
            &crate::encode_base64(b"first "),
        )
        .expect("append first chunk");
        append_payload(
            &app,
            PayloadNamespace::Tmp,
            name,
            &crate::encode_base64(b"second"),
        )
        .expect("append second chunk");

        assert_eq!(fs::read(path).expect("read raw payload"), b"first second");
    }

    #[test]
    fn create_refuses_collisions_without_replacing_existing_bytes() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let directory = payload_directory(&app, PayloadNamespace::Tmp).expect("open namespace");
        let existing = app.moddir.join(".tmp/webui-payload/existing.json");
        fs::write(&existing, "preserve me").expect("write existing payload");

        assert!(create_payload(&app, PayloadNamespace::Tmp, OsStr::new("existing.json")).is_err());
        assert_eq!(
            fs::read_to_string(existing).expect("read existing payload"),
            "preserve me"
        );
        drop(directory);
    }

    #[test]
    fn namespace_symlink_is_rejected_without_creating_a_target_file() {
        let app = temp_app();
        let tmp = app.moddir.join(".tmp");
        let outside = app.moddir.join("outside");
        fs::create_dir_all(&tmp).expect("create temporary root");
        fs::create_dir_all(&outside).expect("create outside directory");
        symlink(&outside, tmp.join("webui-payload")).expect("create namespace symlink");

        assert!(create_payload(&app, PayloadNamespace::Tmp, OsStr::new("escape.json")).is_err());
        assert!(!outside.join("escape.json").exists());
    }

    #[test]
    fn concurrent_appends_are_serialized_without_lost_chunks() {
        let app = temp_app();
        let root = app.moddir.clone();
        fs::create_dir_all(&root).unwrap();
        let name = OsStr::new("concurrent.payload");
        let path = create_payload(&app, PayloadNamespace::Tmp, name).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
        let mut workers = Vec::new();
        for chunk in ["QUFB", "QkJC"] {
            let worker_app = App::for_test(root.clone());
            let worker_barrier = barrier.clone();
            workers.push(std::thread::spawn(move || {
                worker_barrier.wait();
                append_payload(
                    &worker_app,
                    PayloadNamespace::Tmp,
                    OsStr::new("concurrent.payload"),
                    chunk,
                )
            }));
        }
        barrier.wait();
        for worker in workers {
            worker.join().unwrap().unwrap();
        }
        let bytes = fs::read(path).unwrap();
        assert!(bytes == b"AAABBB" || bytes == b"BBBAAA");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn append_and_remove_refuse_symlinks_without_touching_their_targets() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let directory = payload_directory(&app, PayloadNamespace::Tmp).expect("open namespace");
        let victim = app.moddir.join("victim.txt");
        let link = app.moddir.join(".tmp/webui-payload/link.json");
        fs::write(&victim, "preserve me").expect("write victim");
        symlink(&victim, &link).expect("create payload symlink");

        let encoded = crate::encode_base64(b"replacement");
        assert!(append_payload(
            &app,
            PayloadNamespace::Tmp,
            OsStr::new("link.json"),
            &encoded
        )
        .is_err());
        assert!(remove_payload(&app, PayloadNamespace::Tmp, OsStr::new("link.json")).is_err());
        assert_eq!(
            fs::read_to_string(victim).expect("read victim"),
            "preserve me"
        );
        assert!(fs::symlink_metadata(link)
            .expect("stat link")
            .file_type()
            .is_symlink());
        drop(directory);
    }

    #[test]
    fn temporary_payload_is_bounded_like_subscription_payload() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let name = OsStr::new("large.tmp");
        create_payload(&app, PayloadNamespace::Tmp, name).expect("create payload");
        let chunk = vec![b'x'; MAX_WEBUI_PAYLOAD_BYTES as usize];
        append_payload(
            &app,
            PayloadNamespace::Tmp,
            name,
            &crate::encode_base64(&chunk),
        )
        .expect("append payload up to limit");
        assert!(append_payload(
            &app,
            PayloadNamespace::Tmp,
            name,
            &crate::encode_base64(b"x"),
        )
        .is_err());
    }

    #[test]
    fn oversized_payload_is_removed_after_bounded_read() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let name = OsStr::new("oversized.tmp");
        let path = create_payload(&app, PayloadNamespace::Tmp, name).expect("create payload");
        let directory = payload_directory(&app, PayloadNamespace::Tmp).expect("open namespace");
        let mut file = open_payload_file(
            &directory,
            name,
            libc::O_WRONLY | libc::O_APPEND | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
        .expect("open payload");
        file.write_all(&vec![b'x'; (MAX_WEBUI_PAYLOAD_BYTES + 1) as usize])
            .expect("write oversized fixture");
        drop(file);
        drop(directory);

        let result = take_payload(&app, PayloadNamespace::Tmp, name);
        assert_eq!(result.unwrap_err(), "WebUI payload exceeds the 8 MiB limit");
        assert!(!path.exists());
    }

    #[test]
    #[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
    fn append_and_remove_refuse_hard_linked_payloads_without_mutating_them() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let _directory = payload_directory(&app, PayloadNamespace::Tmp).expect("open namespace");
        let original = app.moddir.join(".tmp/webui-payload/original.json");
        let linked = app.moddir.join(".tmp/webui-payload/linked.json");
        fs::write(&original, "preserve me").expect("write original payload");
        fs::hard_link(&original, &linked).expect("create payload hard link");

        let encoded = crate::encode_base64(b"replacement");
        assert!(append_payload(
            &app,
            PayloadNamespace::Tmp,
            OsStr::new("linked.json"),
            &encoded
        )
        .is_err());
        assert!(remove_payload(&app, PayloadNamespace::Tmp, OsStr::new("linked.json")).is_err());
        assert_eq!(
            fs::read_to_string(&original).expect("read original payload"),
            "preserve me"
        );
    }

    #[test]
    fn subscription_payload_is_removed_before_apply_failure() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).expect("create module directory");
        let name = OsStr::new("subscription.txt");
        let path = create_payload(&app, PayloadNamespace::Subscription, name)
            .expect("create subscription payload");
        append_payload(
            &app,
            PayloadNamespace::Subscription,
            name,
            &crate::encode_base64(b"https://example.com/sub\n"),
        )
        .expect("append subscription payload");

        let error = consume_subscription_payload_with(&app, name, |bytes| {
            assert_eq!(bytes, b"https://example.com/sub\n");
            Err::<(), _>("apply rejected".to_string())
        })
        .unwrap_err();

        assert_eq!(error, "apply rejected");
        assert!(!path.exists());
    }
}
