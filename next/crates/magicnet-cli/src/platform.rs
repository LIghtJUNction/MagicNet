//! Explicitly selected native tools. No inherited proxy, arbitrary shell,
//! unknown PID cleanup, or automatic Android-acceptance claim.
use kamfw::process::{normalize_arguments, Identity, Observation};
use kamfw::run::{execute, execute_cancelable, Spec};
use kamfw::{Error, Result, Root};
use magicnet_core::engine::Platform;
use std::os::unix::{fs::MetadataExt, process::CommandExt};
use std::{
    fs,
    io::Read,
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub struct Native {
    pub experimental: bool,
}
impl Native {
    fn binary(root: &Root, name: &str) -> Result<PathBuf> {
        let path = format!("bin/{name}");
        let file = root.open_file(&path)?.ok_or_else(|| {
            Error::new(
                "missing_dependency",
                "A required private module binary is missing",
            )
        })?;
        let metadata = file
            .metadata()
            .map_err(|e| Error::io("Inspect module executable", e))?;
        if metadata.mode() & 0o111 == 0 {
            return Err(Error::new(
                "invalid_dependency",
                "The selected module tool is not executable",
            ));
        }
        Ok(root.path().join(path))
    }
    fn generation(root: &Root, id: &str) -> Result<PathBuf> {
        if !kamfw::fs::valid_id(id) {
            return Err(Error::new(
                "invalid_generation",
                "The generation ID is invalid",
            ));
        }
        let path = format!(".state/generations/{id}/config.json");
        if root.open_file(&path)?.is_none() {
            return Err(Error::new(
                "missing_generation",
                "The immutable candidate configuration is missing",
            ));
        }
        Ok(root.path().join(path))
    }
    fn runtime_gate(&self) -> Result<()> {
        if !self.experimental {
            return Err(Error::new("acceptance_required", "Native activation is gated until Android acceptance and legacy migration are complete"));
        }
        Ok(())
    }
    fn arguments(root: &Root, generation: &str) -> Result<Vec<String>> {
        Ok(vec![
            "run".into(),
            "-c".into(),
            Self::generation(root, generation)?
                .to_string_lossy()
                .into_owned(),
            "-D".into(),
            root.path().to_string_lossy().into_owned(),
        ])
    }
}
impl Platform for Native {
    fn validate(&self, root: &Root, generation: &str) -> Result<()> {
        self.runtime_gate()?;
        let mut spec = Spec::new(Self::binary(root, "sing-box")?).args([
            "check".into(),
            "-c".into(),
            Self::generation(root, generation)?
                .to_string_lossy()
                .into_owned(),
        ]);
        spec.directory = Some(root.path().into());
        spec.timeout = Duration::from_secs(10);
        let output = execute(&spec)?;
        if output.code != 0 {
            return Err(Error::new(
                "invalid_config",
                "The installed core rejected the candidate; the previous runtime was not replaced",
            ));
        }
        Ok(())
    }
    fn launch(&self, root: &Root, generation: &str) -> Result<Identity> {
        self.runtime_gate()?;
        let binary = Self::binary(root, "sing-box")?;
        let metadata =
            fs::metadata(&binary).map_err(|e| Error::io("Inspect dataplane executable", e))?;
        // This candidate adapter intentionally has no unbounded log sink.
        // Dataplane log streaming/rotation remains a migration gate.
        let mut command = Command::new(&binary);
        command
            .args(Self::arguments(root, generation)?)
            .current_dir(root.path())
            .env_clear()
            .env("PATH", "/system/bin:/system/xbin:/usr/bin:/bin")
            .env("HOME", root.path())
            .env("LANG", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                libc::umask(0o077);
                Ok(())
            });
        }
        let mut child = command
            .spawn()
            .map_err(|e| Error::io("Launch owned dataplane", e))?;
        let pid = child.id();
        let identity = Identity::capture(pid);
        if let Some(_status) = child
            .try_wait()
            .map_err(|e| Error::io("Inspect dataplane startup", e))?
        {
            return Err(
                Error::new("startup_failed", "The dataplane exited during startup").changed(),
            );
        }
        let identity = identity.map_err(|error| error.changed())?;
        if identity.executable_device != metadata.dev()
            || identity.executable_inode != metadata.ino()
        {
            return Err(Error::new(
                "ownership_unknown",
                "The spawned executable changed; recovery evidence must be retained",
            )
            .changed());
        }
        // Dropping Child neither kills nor waits. Exact generation discovery
        // covers a crash before this identity is durably published.
        Ok(identity)
    }
    fn find(&self, root: &Root, generation: &str) -> Result<Option<Identity>> {
        let binary = Self::binary(root, "sing-box")?;
        let metadata =
            fs::metadata(&binary).map_err(|e| Error::io("Inspect dataplane executable", e))?;
        let mut arguments = vec![binary.to_string_lossy().into_owned().into_bytes()];
        arguments.extend(
            Self::arguments(root, generation)?
                .into_iter()
                .map(String::into_bytes),
        );
        let entries = fs::read_dir("/proc").map_err(|e| Error::io("Inspect process table", e))?;
        let mut found = None;
        let mut count = 0;
        for entry in entries {
            let entry = entry.map_err(|e| Error::io("Read process table", e))?;
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|s| s.parse::<u32>().ok())
            else {
                continue;
            };
            count += 1;
            if count > 65536 {
                return Err(Error::new(
                    "process_limit",
                    "Process discovery exceeded its bound",
                ));
            }
            let executable = match fs::metadata(entry.path().join("exe")) {
                Ok(value) => value,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
                    ) =>
                {
                    continue
                }
                Err(error) => return Err(Error::io("Inspect process executable", error)),
            };
            if executable.dev() != metadata.dev() || executable.ino() != metadata.ino() {
                continue;
            }
            let mut raw = Vec::new();
            let file = match fs::File::open(entry.path().join("cmdline")) {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(Error::io("Inspect matching process", error)),
            };
            file.take(16385)
                .read_to_end(&mut raw)
                .map_err(|e| Error::io("Read matching process identity", e))?;
            if raw.len() > 16384 {
                return Err(Error::new(
                    "ownership_unknown",
                    "Matching process arguments exceed the ownership bound",
                ));
            }
            if normalize_arguments(&raw)? != arguments {
                continue;
            }
            let identity = Identity::capture(pid)?;
            if found.replace(identity).is_some() {
                return Err(Error::new(
                    "ambiguous_owner",
                    "More than one process owns the same immutable generation",
                ));
            }
        }
        Ok(found)
    }
    fn observe(&self, identity: &Identity) -> Observation {
        identity.observe()
    }
    fn ready(&self, _root: &Root, _generation: &str, identity: &Identity) -> Result<()> {
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            if identity.observe() != Observation::Running {
                return Err(Error::new(
                    "startup_failed",
                    "The dataplane did not remain alive through its startup observation",
                )
                .changed());
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        // Deliberately process-only. Status never equates this with restored
        // Android routing, DNS capture, successful login, or app connectivity.
        Ok(())
    }
    fn stop(&self, identity: &Identity) -> Result<()> {
        identity.stop(Duration::from_secs(15))
    }
    fn fetch(
        &self,
        root: &Root,
        url: &str,
        user_agent: &str,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Vec<u8>> {
        magicnet_core::model::validate_url(url)?;
        if user_agent.is_empty()
            || user_agent.len() > 256
            || user_agent.chars().any(char::is_control)
        {
            return Err(Error::new(
                "invalid_user_agent",
                "The user agent must be one bounded line",
            ));
        }
        let escape = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
        // URL and authorization query are sent only on stdin, never in argv.
        // -q first prevents ~/.curlrc; env_clear + noproxy explicitly bypass
        // user HTTP proxies. Kernel transparent interception is not bypassed.
        let mut spec = Spec::new(Self::binary(root, "curl")?).args(["-q", "--config", "-"]);
        spec.input = format!("url = \"{}\"\nuser-agent = \"{}\"\nproxy = \"\"\nnoproxy = \"*\"\nproto = \"=http,https\"\nproto-redir = \"=http,https\"\nmax-redirs = 3\nmax-time = 10\nconnect-timeout = 5\nmax-filesize = 8388608\nfail\nsilent\nshow-error\nlocation\n", escape(url), escape(user_agent)).into_bytes();
        spec.timeout = Duration::from_secs(12);
        spec.output_limit = kamfw::fs::MAX_DOCUMENT;
        let output = execute_cancelable(&spec, cancelled)?;
        if output.code != 0 {
            return Err(Error::new(
                "subscription_fetch_failed",
                "A subscription fetch failed; all previously validated source caches were retained",
            )
            .retry());
        }
        Ok(output.stdout)
    }
    fn decode(&self, root: &Root, bytes: &[u8]) -> Result<Vec<u8>> {
        if bytes.len() > kamfw::fs::MAX_DOCUMENT {
            return Err(Error::new(
                "too_large",
                "The subscription exceeds its document limit",
            ));
        }
        if serde_json::from_slice::<serde_json::Value>(bytes).is_ok() {
            return Ok(bytes.into());
        }
        let mut spec = Spec::new(Self::binary(root, "yq")?).args(["eval", "-o=json", ".", "-"]);
        spec.input = bytes.into();
        spec.output_limit = kamfw::fs::MAX_DOCUMENT;
        spec.timeout = Duration::from_secs(5);
        let output = execute(&spec)?;
        if output.code != 0 {
            return Err(Error::new(
                "invalid_subscription",
                "The installed YAML decoder rejected the document",
            ));
        }
        // Native structural validation follows; a parser exit code alone is
        // not proof that a document contains supported nodes.
        Ok(output.stdout)
    }
}
