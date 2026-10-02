use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};

use crate::Server;

const MAX_FILE_READ_BYTES: u64 = 1024 * 1024;

pub(crate) fn file_list(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    if secret_read_denied(&path, &server.moddir) {
        return "refusing to read a secret file".to_string();
    }
    let mut rows = Vec::new();
    let entries = match fs::read_dir(&path) {
        Ok(entries) => entries,
        Err(err) => return format!("not a directory: {rel}: {err}"),
    };
    for entry in entries.flatten().take(1001) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let suffix = if file_type.is_dir() { "/" } else { "" };
        let entry_path = entry.path();
        if secret_read_denied(&entry_path, &server.moddir) {
            continue;
        }
        let display = entry_path
            .strip_prefix(&server.moddir)
            .unwrap_or(entry_path.as_path())
            .display()
            .to_string();
        rows.push(format!("{display}{suffix}"));
    }
    rows.sort_unstable();
    if rows.len() > 200 {
        rows.truncate(200);
        rows.push("[listing truncated]".to_string());
    }
    rows.join("\n")
}

pub(crate) fn file_read(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    if secret_read_denied(&path, &server.moddir) {
        return "refusing to read a secret file".to_string();
    }
    let file = match open_regular_file(&path) {
        Ok(file) => file,
        Err(err) => return format!("not a file: {rel}: {err}"),
    };
    let mut bytes = Vec::new();
    if let Err(err) = file.take(MAX_FILE_READ_BYTES + 1).read_to_end(&mut bytes) {
        return format!("read file failed: {rel}: {err}");
    }
    if bytes.len() as u64 > MAX_FILE_READ_BYTES {
        return format!("file too large: {rel} (max {MAX_FILE_READ_BYTES} bytes)");
    };
    String::from_utf8_lossy(&bytes)
        .lines()
        .take(240)
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn open_regular_file(path: &Path) -> io::Result<fs::File> {
    let invalid_type = || io::Error::new(io::ErrorKind::InvalidInput, "not a regular file");
    if !fs::symlink_metadata(path)?.is_file() {
        return Err(invalid_type());
    }
    // A FIFO substituted after the metadata check must not block a worker in open().
    // Both callers have already resolved in-module symlinks to their target paths.
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(invalid_type());
    }
    Ok(file)
}

fn module_path(server: &Server, rel: &str) -> Result<std::path::PathBuf, String> {
    let root = fs::canonicalize(&server.moddir)
        .map_err(|err| format!("module root unavailable: {err}"))?;
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        return Ok(root);
    }
    let path = Path::new(rel);
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return Err("invalid path".to_string()),
        }
    }
    if private_module_path(path) {
        return Err("refusing to read a secret file".to_string());
    }
    let resolved = fs::canonicalize(server.moddir.join(path))
        .map_err(|err| format!("path not found: {rel}: {err}"))?;
    if !resolved.starts_with(&root) {
        return Err("path escapes module directory".to_string());
    }
    Ok(resolved)
}

fn secret_read_denied(path: &Path, root: &Path) -> bool {
    let Ok(root) = fs::canonicalize(root) else {
        return true;
    };
    if path.strip_prefix(&root).is_ok_and(private_module_path) {
        return true;
    }
    // Resolve first so a same-module alias cannot bypass the filename denylist.
    let Ok(path) = fs::canonicalize(path) else {
        return true;
    };
    let Ok(relative) = path.strip_prefix(&root) else {
        return true;
    };
    private_module_path(relative)
}

fn private_module_path(relative: &Path) -> bool {
    let Some(names) = relative
        .components()
        .map(|component| component.as_os_str().to_str().map(str::to_ascii_lowercase))
        .collect::<Option<Vec<_>>>()
    else {
        return true;
    };
    // These trees contain credentials under arbitrary names: subscription
    // journals use old-url/input-source, caches hold node passwords, and
    // recovery checkpoints copy whole configs. Public state is in machines/.
    if names.windows(2).any(|pair| {
        (pair[0] == ".config" && private_name_or_copy(&pair[1], "sing-box"))
            || (pair[0] == ".state"
                && [
                    "sing-box",
                    "transparent-transaction",
                    "override-materialization",
                    "install-config",
                    "install-onboarding",
                ]
                .iter()
                .any(|name| private_name_or_copy(&pair[1], name)))
    }) {
        return true;
    }
    names.iter().any(|name| {
        [
            "mcp.conf",
            ".env",
            "secret",
            "subscription.url",
            "subscription.local",
            "warp.conf",
            "warp-endpoint.json",
            "singbox-config-repo.conf",
            "config-override.json",
            "config-override-active.json",
        ]
        .iter()
        .any(|secret| private_name_or_copy(name, secret))
            || name.ends_with("-auth.json")
            || name.contains("-auth.json.")
            || name.starts_with(".magicnet-app-")
            || name.starts_with(".config-editor-")
    })
}

fn private_name_or_copy(name: &str, private: &str) -> bool {
    name.strip_prefix(private)
        .is_some_and(|suffix| suffix.is_empty() || suffix.starts_with('.'))
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;
    use std::fs;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, OpenOptionsExt};
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use super::*;

    fn test_server(name: &str) -> (Server, PathBuf) {
        let root =
            std::env::temp_dir().join(format!("magicnet-mcp-files-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let server = Server {
            moddir: root.clone(),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };
        (server, root)
    }

    #[test]
    fn file_read_rejects_symlink_escape() {
        let (server, root) = test_server("symlink");
        let outside = root
            .parent()
            .unwrap()
            .join(format!("magicnet-mcp-outside-{}", std::process::id()));
        fs::write(&outside, "outside").unwrap();
        symlink(&outside, root.join("escape")).unwrap();

        assert_eq!(
            file_read(&server, "escape"),
            "path escapes module directory"
        );

        let _ = fs::remove_file(outside);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn file_read_rejects_unbounded_files() {
        let (server, root) = test_server("size");
        fs::write(
            root.join("large"),
            vec![b'x'; (MAX_FILE_READ_BYTES + 1) as usize],
        )
        .unwrap();

        let result = file_read(&server, "large");
        assert!(result.starts_with("file too large: large"));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn file_read_rejects_secret_files_and_aliases() {
        let (server, root) = test_server("secrets");
        fs::create_dir_all(root.join(".config/magicnet")).unwrap();
        fs::create_dir_all(root.join(".config/sing-box")).unwrap();
        fs::write(
            root.join(".config/magicnet/mcp.conf"),
            "MAGICNET_MCP_SECRET=hidden",
        )
        .unwrap();
        fs::write(
            root.join(".config/sing-box/subscription.url"),
            "https://example.invalid/sub",
        )
        .unwrap();
        fs::write(
            root.join(".config/sing-box/subscription.local"),
            "proxies: []\n",
        )
        .unwrap();
        fs::write(
            root.join(".config/sing-box/tailscale-auth.json"),
            "{\"authKey\":\"hidden\"}",
        )
        .unwrap();
        fs::write(
            root.join(".config/magicnet/.env"),
            "MAGICNET_SINGBOX_SUBSCRIPTION_URL=hidden",
        )
        .unwrap();
        fs::write(
            root.join(".config/magicnet/warp-endpoint.json"),
            "{\"private_key\":\"hidden\"}",
        )
        .unwrap();
        fs::write(root.join("notes.txt"), "visible").unwrap();
        symlink(
            root.join(".config/magicnet/mcp.conf"),
            root.join("alias.conf"),
        )
        .unwrap();

        for path in [
            ".config/magicnet/mcp.conf",
            ".config/magicnet/.env",
            ".config/magicnet/warp-endpoint.json",
            ".config/sing-box/subscription.url",
            ".config/sing-box/subscription.local",
            ".config/sing-box/tailscale-auth.json",
            "alias.conf",
        ] {
            assert_eq!(
                file_read(&server, path),
                "refusing to read a secret file",
                "{path}"
            );
        }
        assert_eq!(file_read(&server, "notes.txt"), "visible");
        let listing = file_list(&server, "");
        assert!(listing.contains("notes.txt"), "{listing}");
        assert!(
            !listing.contains("alias.conf") && !listing.contains("mcp.conf"),
            "{listing}"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn file_reads_reject_private_recovery_copies_and_preserve_public_state() {
        let (server, root) = test_server("recovery-secrets");
        let private_paths = [
            ".config/sing-box/config.json",
            ".config/sing-box/config.json.bak",
            ".config/magicnet/mcp.conf.bak",
            ".config/magicnet/config-override.json",
            ".config/magicnet/config-override-active.json",
            ".config/magicnet/.magicnet-app-123-0.tmp",
            ".config/magicnet/tailscale-auth.json.bak",
            ".state/sing-box/subscription-transaction/old-url",
            ".state/sing-box/subscription-transaction/input-source",
            ".state/sing-box/subscription-transaction/old-local",
            ".state/sing-box/subscription-transaction.new.123/old-url",
            ".state/sing-box/subscription-work/sources/1.yaml",
            ".state/sing-box/subscription-cache/fixture.yaml",
            ".state/sing-box/subscription-candidates/candidate.json",
            ".state/sing-box/last-good-config.json",
            ".state/sing-box/tailscale/tailscaled.state",
            ".state/transparent-transaction/old-config.json",
            ".state/transparent-transaction.new.123/old-config.json",
            ".state/override-materialization/checkpoint.json",
            ".state/install-onboarding.fixture/baseline-subscription.url",
            ".state/install-config.123/outbounds.json",
        ];
        for (index, path) in private_paths.iter().enumerate() {
            let target = root.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(&target, "private-fixture").unwrap();
            let alias = format!("recovery-alias-{index}");
            symlink(&target, root.join(&alias)).unwrap();
            for requested in [*path, alias.as_str()] {
                assert_eq!(
                    file_read(&server, requested),
                    "refusing to read a secret file",
                    "{requested}"
                );
            }
        }
        for directory in [
            ".config/sing-box",
            ".state/sing-box/subscription-transaction",
            ".state/transparent-transaction",
            ".state/override-materialization",
        ] {
            assert_eq!(
                file_list(&server, directory),
                "refusing to read a secret file"
            );
        }
        let public = ".state/machines/subscription.state";
        fs::create_dir_all(root.join(".state/machines")).unwrap();
        fs::write(root.join(public), "schema=1\nsource_kind=remote\n").unwrap();
        fs::write(root.join("notes.txt"), "visible").unwrap();
        // A sensitive requested name remains private even when its symlink
        // points at an ordinary file rather than a sensitive target path.
        symlink(root.join("notes.txt"), root.join("mcp.conf")).unwrap();
        assert_eq!(
            file_read(&server, "mcp.conf"),
            "refusing to read a secret file"
        );
        assert_eq!(file_read(&server, public), "schema=1\nsource_kind=remote");
        assert!(file_list(&server, ".state/machines").contains(public));
        let listing = file_list(&server, "");
        assert!(listing.contains("notes.txt"), "{listing}");
        assert!(
            !listing.contains("recovery-alias-") && !listing.contains("mcp.conf"),
            "{listing}"
        );
        fs::remove_dir_all(root).unwrap();
    }

    fn assert_fifo_rejected(name: &str, read: fn(&Server) -> String) {
        let (server, root) = test_server(name);
        fs::create_dir_all(root.join(".log")).unwrap();
        let fifo = root.join(".log/pipe.log");
        let fifo_name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        let (sender, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = sender.send(read(&server));
        });
        let result = receiver.recv_timeout(Duration::from_secs(2));
        if result.is_err() {
            // Unblock the old blocking open/read so a regression cannot hang the suite.
            let _ = fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&fifo);
        }
        fs::remove_dir_all(root).unwrap();
        let result = result.expect("FIFO reads must finish without a writer");
        worker.join().unwrap();
        assert!(result.contains("not a regular file"), "{result}");
    }

    #[test]
    fn file_read_rejects_fifo_without_waiting_for_a_writer() {
        assert_fifo_rejected("file-fifo", |server| file_read(server, ".log/pipe.log"));
    }

    #[test]
    fn log_read_rejects_fifo_without_waiting_for_a_writer() {
        assert_fifo_rejected("log-fifo", |server| {
            crate::logs::log_read(server, "pipe", 10, false)
        });
    }

    #[test]
    fn file_and_log_reads_preserve_regular_file_contents() {
        let (server, root) = test_server("regular");
        fs::create_dir_all(root.join(".log")).unwrap();
        fs::write(root.join(".log/example.log"), "first\nsecond\nthird\n").unwrap();
        symlink(root.join(".log/example.log"), root.join("internal-link")).unwrap();
        assert_eq!(file_read(&server, "internal-link"), "first\nsecond\nthird");
        assert_eq!(
            crate::logs::log_read(&server, "example", 2, false),
            "second\nthird"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
