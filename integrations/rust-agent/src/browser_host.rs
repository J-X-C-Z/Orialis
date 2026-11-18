//! Least-authority operator configuration for the restricted local render tools.
//! This does not attest, launch, discover or sandbox a supplied browser process.
use crate::browser_tools::BrowserConfig;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{path::Path, time::Duration};

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Mode {
    RestrictedLocalRender,
}

/// Owner, session/generation, artifact paths and tool-image capabilities are
/// supplied by the authenticated host, never configurable here or by the model.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserHostConfig {
    mode: Mode,
    disposable_endpoint: String,
    rpc_timeout_ms: Option<u64>,
    idle_timeout_secs: Option<u64>,
    max_sessions: Option<usize>,
    max_tabs: Option<usize>,
    max_state_entries: Option<usize>,
}

impl BrowserHostConfig {
    /// Parse before authentication/network activity. The endpoint remains trusted
    /// operator input, not evidence of Chromium isolation or process ownership.
    pub fn parse(raw: &str, database: &Path) -> Result<BrowserConfig> {
        ensure!(
            raw.len() <= 16 * 1024,
            "browser host configuration exceeds limit"
        );
        let value: Self =
            serde_json::from_str(raw).context("invalid restricted local render configuration")?;
        let Mode::RestrictedLocalRender = value.mode;
        ensure!(
            database != Path::new(":memory:") && database.file_name().is_some(),
            "browser host requires an owner-bound disk database"
        );
        let database = if database.is_absolute() {
            database.to_owned()
        } else {
            std::env::current_dir()?.join(database)
        };
        let mut config = BrowserConfig::disposable_endpoint(
            value.disposable_endpoint,
            database.with_extension("browser-artifacts"),
        );
        if let Some(v) = value.rpc_timeout_ms {
            config.timeout = Duration::from_millis(v);
        }
        if let Some(v) = value.idle_timeout_secs {
            config.idle_timeout = Duration::from_secs(v);
        }
        if let Some(v) = value.max_sessions {
            config.max_sessions = v;
        }
        if let Some(v) = value.max_tabs {
            config.max_tabs = v;
        }
        if let Some(v) = value.max_state_entries {
            config.max_state_entries = v;
        }
        config.validate()?;
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn valid() -> serde_json::Value {
        json!({"mode":"restricted_local_render","disposable_endpoint":"ws://127.0.0.1:1234/devtools/browser/disposable"})
    }
    #[test]
    fn explicit_mode_and_endpoint_only_without_ambient_authority() {
        let config =
            BrowserHostConfig::parse(&valid().to_string(), Path::new("owner.sqlite")).unwrap();
        assert!(config.artifact_dir.is_absolute());
        assert_eq!(
            config.artifact_dir.file_name().unwrap(),
            "owner.browser-artifacts"
        );
        assert_eq!(config.max_state_entries, 8192);
        for key in [
            "owner",
            "session",
            "generation",
            "artifact_dir",
            "profile",
            "launch",
            "safe_browser",
            "egress",
            "native_images",
            "vault",
            "headers",
            "token",
        ] {
            let mut value = valid();
            value[key] = json!("forbidden");
            assert!(
                BrowserHostConfig::parse(&value.to_string(), Path::new("owner.sqlite")).is_err(),
                "{key}"
            );
        }
        for key in ["mode", "disposable_endpoint"] {
            let mut value = valid();
            value.as_object_mut().unwrap().remove(key);
            assert!(
                BrowserHostConfig::parse(&value.to_string(), Path::new("owner.sqlite")).is_err()
            );
        }
        assert!(BrowserHostConfig::parse(&valid().to_string(), Path::new(":memory:")).is_err());
    }
    #[test]
    fn bounded_host_config_fails_closed() {
        for (key, v) in [
            ("mode", json!("general_browser")),
            (
                "disposable_endpoint",
                json!("http://127.0.0.1:9222/json/version"),
            ),
            (
                "disposable_endpoint",
                json!("ws://localhost:1234/devtools/browser/a"),
            ),
            ("rpc_timeout_ms", json!(0)),
            ("rpc_timeout_ms", json!(60001)),
            ("idle_timeout_secs", json!(0)),
            ("idle_timeout_secs", json!(3601)),
            ("max_sessions", json!(0)),
            ("max_sessions", json!(17)),
            ("max_tabs", json!(33)),
            ("max_state_entries", json!(0)),
            ("max_state_entries", json!(100001)),
        ] {
            let mut value = valid();
            value[key] = v;
            assert!(
                BrowserHostConfig::parse(&value.to_string(), Path::new("owner.sqlite")).is_err(),
                "{key}"
            );
        }
        assert!(BrowserHostConfig::parse(&" ".repeat(16385), Path::new("owner.sqlite")).is_err());
    }
}
