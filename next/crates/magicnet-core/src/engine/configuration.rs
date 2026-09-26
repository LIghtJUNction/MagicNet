//! Persistent intent and all-or-nothing subscription mutations.
use super::*;

impl<P: Platform> Engine<P> {
    pub(super) fn mutate(&self, request: &Request, settings: &mut Settings) -> Result<Value> {
        match request.method.as_str() {
            "settings.replace" => {
                let mut candidate: Settings = serde_json::from_value(request.params.clone())?;
                candidate.validate()?;
                if candidate.enabled != settings.enabled {
                    return Err(Error::new(
                        "invalid_intent",
                        "Use service.start or service.stop to change the lifecycle intent",
                    ));
                }
                candidate.revision = settings.revision + 1;
                self.commit(&[self.change(SETTINGS, Some(serde_json::to_vec(&candidate)?))?])?;
                Ok(json!({"revision":candidate.revision,"applied":false}))
            }
            "sources.replace" => {
                let text = request
                    .params
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        Error::new("invalid_sources", "A complete URL list is required")
                    })?;
                let old_ids: Vec<String> = settings.sources.iter().map(|s| s.id.clone()).collect();
                settings.replace_sources(text)?;
                settings.revision += 1;
                let mut changes = vec![self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?];
                for id in old_ids {
                    if !settings.sources.iter().any(|s| s.id == id) {
                        changes.push(self.change(&format!(".config/nodes/{id}.json"), None)?);
                    }
                }
                self.commit(&changes)?;
                Ok(
                    json!({"revision":settings.revision,"source_count":settings.sources.len(),"applied":false}),
                )
            }
            "sources.import" => {
                let body = request
                    .params
                    .get("body")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        Error::new(
                            "invalid_subscription",
                            "A local subscription document is required",
                        )
                    })?;
                let id = "00000000000000000000000000000001";
                let decoded = self.platform.decode(&self.root, body.as_bytes())?;
                let parsed = subscription::parse_json(&decoded, id)?;
                settings.revision += 1;
                self.commit(&[
                    self.change(
                        ".config/nodes/local.json",
                        Some(serde_json::to_vec(&parsed.nodes)?),
                    )?,
                    self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?,
                ])?;
                Ok(
                    json!({"revision":settings.revision,"nodes":parsed.nodes.len(),"rejected":parsed.rejected,"applied":false}),
                )
            }
            "sources.refresh" => {
                let mut changes = Vec::new();
                let mut nodes = 0;
                let mut rejected = 0;
                let mut total_bytes = 0_usize;
                let deadline = std::time::Instant::now() + Duration::from_secs(20);
                let cancelled = || {
                    std::time::Instant::now() >= deadline
                        || self
                            .root
                            .read(".state/cancel", 64)
                            .ok()
                            .flatten()
                            .is_some_and(|id| id == request.id.as_bytes())
                };
                for source in settings.sources.iter().filter(|source| source.enabled) {
                    let bytes = self.platform.fetch(
                        &self.root,
                        &source.url,
                        &settings.user_agent,
                        &cancelled,
                    )?;
                    if cancelled() {
                        return Err(Error::new(
                            "cancelled",
                            "The refresh was cancelled or reached its total time budget",
                        )
                        .retry());
                    }
                    total_bytes = total_bytes.saturating_add(bytes.len());
                    if total_bytes > 8 * 1024 * 1024 {
                        return Err(Error::new(
                            "too_large",
                            "The complete subscription refresh exceeds its memory budget",
                        ));
                    }
                    let decoded = self.platform.decode(&self.root, &bytes)?;
                    let parsed = subscription::parse_json(&decoded, &source.id)?;
                    nodes += parsed.nodes.len();
                    if nodes > 4096 {
                        return Err(Error::new(
                            "too_many_nodes",
                            "The combined subscription exceeds 4096 nodes",
                        ));
                    }
                    rejected += parsed.rejected;
                    changes.push(self.change(
                        &format!(".config/nodes/{}.json", source.id),
                        Some(serde_json::to_vec(&parsed.nodes)?),
                    )?);
                }
                if changes.is_empty() {
                    return Err(Error::new(
                        "no_sources",
                        "No enabled subscription sources are configured",
                    ));
                }
                if cancelled() {
                    return Err(Error::new(
                        "cancelled",
                        "The refresh was cancelled before publishing its results",
                    )
                    .retry());
                }
                settings.revision += 1;
                changes.push(self.change(SETTINGS, Some(serde_json::to_vec(settings)?))?);
                self.commit(&changes)?;
                Ok(
                    json!({"revision":settings.revision,"nodes":nodes,"rejected":rejected,"applied":false}),
                )
            }
            "service.start" => {
                // A new explicit start can clear a settled stop, never an
                // in-flight operation's cancellation marker.
                self.root.remove(STOP)?;
                self.activate(settings)
            }
            "service.stop" => {
                self.settle_stop()?;
                Ok(
                    json!({"phase":"stopped","revision":self.settings()?.revision,"network_restoration":"not_verified"}),
                )
            }
            "runtime.recover" => {
                self.recover()?;
                self.read("status")
            }
            _ => Err(Error::new("unsupported_command", "Unknown operation")),
        }
    }
}
