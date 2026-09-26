//! Private intent documents. These are never copied into public diagnostics.
use kamfw::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

pub const SETTINGS: &str = ".config/settings.json";
pub const MAX_SOURCES: usize = 32;
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    #[default]
    Tun,
    Ebpf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub id: String,
    pub url: String,
    pub enabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub schema: u32,
    pub revision: u64,
    pub enabled: bool,
    pub mode: Mode,
    pub user_agent: String,
    pub sources: Vec<Source>,
    /// A native sing-box template supplied explicitly by the module owner.
    /// Subscription documents can supply nodes, never this privileged template.
    pub template: Value,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            schema: 1,
            revision: 0,
            enabled: false,
            mode: Mode::Tun,
            user_agent: "MagicNet/2".into(),
            sources: Vec::new(),
            template: serde_json::json!({
                "log": {"level": "warn", "timestamp": true},
                "dns": {"servers": [{"type": "local", "tag": "local"}]},
                "inbounds": [{"type": "tun", "tag": "tun-in", "interface_name": "magicnet0",
                    "address": ["172.19.0.1/30"], "mtu": 1400, "auto_route": true,
                    "auto_redirect": true, "strict_route": true, "stack": "mixed"}],
                "outbounds": [
                    {"type": "selector", "tag": "proxy", "outbounds": ["direct", "block"], "default": "block"},
                    {"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
                "route": {"auto_detect_interface": true, "final": "proxy", "rules": [
                    {"port": 53, "action": "hijack-dns"}, {"action": "sniff"},
                    {"ip_is_private": true, "outbound": "direct"}]}
            }),
        }
    }
}

pub fn validate_url(url: &str) -> Result<()> {
    if url.len() > 4096 || url.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(Error::new(
            "invalid_url",
            "A subscription URL is too long or contains whitespace",
        ));
    }
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .ok_or_else(|| Error::new("invalid_url", "Subscription URLs must use HTTP or HTTPS"))?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.is_empty()
        || authority.contains('@')
        || authority.contains('\\')
        || rest.contains('#')
        || url.bytes().any(|b| b == b'"' || b == b'\\')
    {
        return Err(Error::new(
            "invalid_url",
            "The subscription URL authority or escaping is invalid",
        ));
    }
    // Numeric IP servers, including bracketed IPv6, are deliberately accepted.
    if authority.starts_with('[') {
        let end = authority
            .find(']')
            .ok_or_else(|| Error::new("invalid_url", "An IPv6 URL needs a closing bracket"))?;
        authority[1..end]
            .parse::<std::net::Ipv6Addr>()
            .map_err(|_| Error::new("invalid_url", "The IPv6 URL host is invalid"))?;
        let tail = &authority[end + 1..];
        if !tail.is_empty() && !tail.strip_prefix(':').is_some_and(valid_port) {
            return Err(Error::new(
                "invalid_url",
                "The subscription URL port is invalid",
            ));
        }
    } else {
        let mut host_port = authority.split(':');
        let host = host_port.next().unwrap_or_default();
        if host.is_empty()
            || !host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
            || host_port.next().is_some_and(|port| !valid_port(port))
            || host_port.next().is_some()
        {
            return Err(Error::new(
                "invalid_url",
                "The subscription URL host or port is invalid",
            ));
        }
    }
    Ok(())
}
fn valid_port(port: &str) -> bool {
    port.parse::<u16>().is_ok_and(|p| p > 0)
}

impl Settings {
    pub fn validate(&self) -> Result<()> {
        if self.schema != 1
            || self.revision >= 9_007_199_254_740_990
            || self.sources.len() > MAX_SOURCES
        {
            return Err(Error::new(
                "invalid_settings",
                "The settings schema, revision or source count is invalid",
            ));
        }
        if self.user_agent.is_empty()
            || self.user_agent.len() > 256
            || self.user_agent.chars().any(char::is_control)
        {
            return Err(Error::new(
                "invalid_user_agent",
                "The user agent must be one bounded line",
            ));
        }
        let mut ids = BTreeSet::new();
        let mut urls = BTreeSet::new();
        for source in &self.sources {
            if !kamfw::fs::valid_id(&source.id)
                || !ids.insert(&source.id)
                || !urls.insert(&source.url)
            {
                return Err(Error::new(
                    "invalid_sources",
                    "Sources must have unique IDs and URLs",
                ));
            }
            validate_url(&source.url)?;
        }
        let template = self
            .template
            .as_object()
            .ok_or_else(|| Error::new("invalid_config", "The native template must be an object"))?;
        if !template.get("outbounds").is_some_and(Value::is_array)
            || serde_json::to_vec(&self.template)?.len() > 2 * 1024 * 1024
        {
            return Err(Error::new(
                "invalid_config",
                "The native template is missing outbounds or exceeds its limit",
            ));
        }
        Ok(())
    }

    /// Replace the complete URL list while retaining identities for unchanged
    /// URLs. A removal is a real removal, not an append-only UI operation.
    pub fn replace_sources(&mut self, text: &str) -> Result<()> {
        if text.len() > MAX_SOURCES * 4097 {
            return Err(Error::new(
                "too_large",
                "The subscription list is too large",
            ));
        }
        let mut result = Vec::new();
        let mut seen = BTreeSet::new();
        for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
            validate_url(line)?;
            if !seen.insert(line) {
                continue;
            }
            let source = self
                .sources
                .iter()
                .find(|old| old.url == line)
                .cloned()
                .unwrap_or(Source {
                    id: kamfw::random_id()?,
                    url: line.into(),
                    enabled: true,
                });
            result.push(source);
        }
        if result.len() > MAX_SOURCES {
            return Err(Error::new(
                "too_many_sources",
                "At most 32 subscription sources are accepted",
            ));
        }
        self.sources = result;
        self.validate()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replace_is_transactional_and_preserves_unchanged_ids() {
        let mut s = Settings::default();
        s.replace_sources("https://a.test/x\r\nhttp://192.0.2.1:8080/x\nhttps://a.test/x")
            .unwrap();
        let id = s.sources[1].id.clone();
        s.replace_sources("http://192.0.2.1:8080/x").unwrap();
        assert_eq!(s.sources.len(), 1);
        assert_eq!(s.sources[0].id, id);
        assert!(s.replace_sources("file:///etc/passwd").is_err());
        assert_eq!(s.sources[0].id, id);
        s.replace_sources("").unwrap();
        assert!(s.sources.is_empty());
    }
    #[test]
    fn numeric_ipv6_and_custom_user_agent() {
        for url in [
            "http://192.0.2.1/s?token=x%2By",
            "https://[2001:db8::1]:443/x",
        ] {
            validate_url(url).unwrap();
        }
        for url in [
            "https://",
            "https://host:0/x",
            "https://u:p@host/x",
            "https://x/\ny",
            "ftp://x",
            "https://x/#fragment",
        ] {
            assert!(validate_url(url).is_err(), "{url}");
        }
        let s = Settings {
            user_agent: "ok\r\nInjected: x".into(),
            ..Settings::default()
        };
        assert!(s.validate().is_err());
    }
}
