//! Explicit operator-owned bridge + companion sync. No network under a Core DB lock.
use crate::{
    Store,
    profile_bridge::{BridgeConfig, BridgeReport, ProfileBridge},
    profile_sync::{self, Request, Response, SyncConfig, SyncOutcome},
};
use anyhow::{Context, Result, ensure};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoordinatorConfig {
    pub database: PathBuf,
    pub bridge: BridgeConfig,
    pub sync: SyncConfig,
}
#[derive(Debug, Serialize)]
pub struct CoordinatorReport {
    pub before: BridgeReport,
    pub synchronization: Option<SyncOutcome>,
    pub after: Option<BridgeReport>,
    /// A failed exchange may already have committed remotely. Retry only through
    /// the same lineage-aware protocol; never rerun Agent/model work here.
    pub synchronization_error: Option<String>,
    pub after_error: Option<String>,
}
impl CoordinatorReport {
    pub fn exit_code(&self) -> i32 {
        if self.synchronization_error.is_some() || self.after_error.is_some() {
            return 1;
        }
        if !self.before.ready_for_sync()
            || self
                .synchronization
                .as_ref()
                .is_none_or(|v| !v.conflicts.is_empty())
            || self.after.as_ref().is_none_or(|v| !v.ready_for_sync())
        {
            return 2;
        }
        0
    }
}
fn open_bound(path: &Path, expected_scope: &str) -> Result<Store> {
    ensure!(
        path.is_absolute() && path.is_file(),
        "coordinator requires an existing absolute Agent database"
    );
    // open_private checks ownership, hard links, mode, ancestors and SQLite
    // companions. It explicitly trusts other processes running as the same UID.
    let db = crate::private_db::open_private(path)?;
    db.busy_timeout(std::time::Duration::from_millis(250))?;
    let binding: Option<(String, String, String)> = db
        .query_row(
            "SELECT origin,device,owner_id FROM account_binding WHERE id=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .context("coordinator requires an already authenticated Agent account binding")?;
    let (origin, device, user) = binding.context("Agent account binding is absent")?;
    let scope = format!(
        "{:x}",
        Sha256::digest(format!("{origin}\0{device}\0{user}").as_bytes())
    );
    ensure!(
        scope == expected_scope,
        "profile coordinator owner does not match the Agent account"
    );
    Store::from_private_connection(db)
}
fn cycle<F>(config: &CoordinatorConfig, synchronize: F) -> Result<CoordinatorReport>
where
    F: FnOnce(&SyncConfig) -> Result<SyncOutcome>,
{
    let bridge = ProfileBridge::new(config.bridge.clone())?;
    ensure!(
        std::fs::canonicalize(&config.sync.profile)? == bridge.profile(),
        "bridge and sync profiles must be identical"
    );
    let before = {
        let mut store = open_bound(&config.database, &config.bridge.owner)?;
        store.reconcile_profile(&bridge)?
    }; // Store/SQLite connection is dropped before any transport invocation.
    let mut report = CoordinatorReport {
        before,
        synchronization: None,
        after: None,
        synchronization_error: None,
        after_error: None,
    };
    if !report.before.ready_for_sync() {
        return Ok(report);
    }
    match synchronize(&config.sync) {
        Ok(value) => report.synchronization = Some(value),
        Err(error) => report.synchronization_error = Some(format!("{error:#}")),
    }
    // Re-read the same account binding after transport. Do not retain an open
    // transaction across an SSH wait, or assume a failed response means no apply.
    match open_bound(&config.database, &config.bridge.owner)
        .and_then(|mut store| store.reconcile_profile(&bridge))
    {
        Ok(value) => report.after = Some(value),
        Err(error) => report.after_error = Some(format!("{error:#}")),
    }
    Ok(report)
}
pub fn run(config: &CoordinatorConfig) -> Result<CoordinatorReport> {
    cycle(config, profile_sync::run_sync)
}
pub fn run_with_transport<F>(config: &CoordinatorConfig, transport: F) -> Result<CoordinatorReport>
where
    F: FnOnce(&Request) -> Result<Response>,
{
    cycle(config, |sync| {
        profile_sync::run_sync_with_transport(sync, transport)
    })
}
