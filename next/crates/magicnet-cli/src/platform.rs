//! Explicitly selected native tools. No inherited proxy, arbitrary shell,
//! unknown PID cleanup, or automatic Android-acceptance claim.
use kamfw::process::{Identity, Observation};
use kamfw::run::{execute, execute_cancelable, Spec};
use kamfw::{Error, Result, Root};
use magicnet_core::engine::Platform;
use std::os::unix::fs::MetadataExt;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

pub struct Native {
    pub experimental: bool,
}
impl Native {
    pub fn worker(root: &Root, generation: &str) -> Result<()> {
        let mut spec =
            Spec::new(Self::binary(root, "sing-box")?).args(Self::arguments(root, generation)?);
        spec.directory = Some(root.path().into());
        spec.env
            .insert("HOME".into(), root.path().to_string_lossy().into_owned());
        kamfw::worker::serve(root, generation, &spec)
    }

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
        let _ = Self::binary(root, "sing-box")?;
        let executable =
            std::env::current_exe().map_err(|e| Error::io("Locate native worker executable", e))?;
        kamfw::worker::launch(root, generation, &executable)
    }
    fn find(&self, root: &Root, generation: &str) -> Result<Option<Identity>> {
        let Some(record) = kamfw::worker::record(root, generation)? else {
            return Ok(None);
        };
        if kamfw::worker::observation(root, generation) == Observation::Absent {
            Ok(None)
        } else {
            Ok(Some(record.supervisor))
        }
    }
    fn observe(&self, root: &Root, identity: &Identity) -> Observation {
        kamfw::worker::generation(root, identity)
            .map(|id| kamfw::worker::observation(root, &id))
            .unwrap_or(Observation::Unknown)
    }
    fn ready(&self, root: &Root, generation: &str, identity: &Identity) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut alive_since = None;
        while Instant::now() < deadline {
            if let Ok(record) = kamfw::worker::inspect(root, generation) {
                if record.supervisor != *identity {
                    return Err(
                        Error::new("ownership_changed", "Startup control peer changed").changed(),
                    );
                }
                match record.child.as_ref().map(Identity::observe) {
                    Some(Observation::Running) => {
                        let since = alive_since.get_or_insert_with(Instant::now);
                        if since.elapsed() >= Duration::from_millis(500) {
                            return Ok(());
                        }
                    }
                    Some(Observation::Absent | Observation::Foreign) => {
                        return Err(Error::new(
                            "startup_failed",
                            "The owned dataplane exited during startup",
                        )
                        .changed())
                    }
                    _ => {
                        alive_since = None;
                    }
                }
            } else if self.observe(root, identity) == Observation::Absent {
                return Err(
                    Error::new("startup_failed", "The owned worker exited during startup")
                        .changed(),
                );
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        Err(Error::new(
            "startup_timeout",
            "The dataplane did not finish its process startup observation",
        )
        .changed())
    }
    fn stop(&self, root: &Root, identity: &Identity) -> Result<()> {
        let generation = kamfw::worker::generation(root, identity)?;
        kamfw::worker::stop(root, &generation, Duration::from_secs(15))
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
        let document = magicnet_core::subscription::share::document(bytes)?;
        if serde_json::from_slice::<serde_json::Value>(&document).is_ok() {
            return Ok(document);
        }
        let mut spec = Spec::new(Self::binary(root, "yq")?).args(["eval", "-o=json", ".", "-"]);
        spec.input = document;
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
