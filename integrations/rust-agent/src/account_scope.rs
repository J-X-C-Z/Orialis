//! Owner-bound storage for a configured Orialis account. The owner is obtained
//! from the authenticated server, never from a model, conversation payload or
//! device display name. Credential rotation does not change an account's scope.
use anyhow::{Context, Result, ensure};
use reqwest::{Client, Url};
use rusqlite::{OptionalExtension, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{path::Path, time::Duration};
#[derive(Clone)]
pub struct OwnerVerifier {
    client: Client,
    endpoint: Url,
    device: String,
    expected: Option<String>,
}
#[derive(Clone)]
pub struct VerifiedOwner {
    origin: String,
    device: String,
    user: String,
}
impl std::fmt::Debug for VerifiedOwner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("VerifiedOwner([redacted])")
    }
}
impl VerifiedOwner {
    pub fn scope(&self) -> String {
        format!(
            "{:x}",
            Sha256::digest(format!("{}\0{}\0{}", self.origin, self.device, self.user).as_bytes())
        )
    }
}
impl OwnerVerifier {
    pub fn new(server: &str, device: &str, token: &str, expected: Option<String>) -> Result<Self> {
        ensure!(
            !token.trim().is_empty() && crate::wire::valid_device(device),
            "owner verification requires configured credentials/device"
        );
        let mut endpoint = Url::parse(server)?;
        ensure!(
            endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none(),
            "invalid account server URL"
        );
        let secure = matches!(endpoint.scheme(), "https" | "wss");
        ensure!(
            secure
                || matches!(
                    endpoint.host_str(),
                    Some("127.0.0.1" | "localhost" | "[::1]")
                ),
            "owner verification requires HTTPS except loopback"
        );
        endpoint
            .set_scheme(if secure { "https" } else { "http" })
            .map_err(|_| anyhow::anyhow!("invalid account server scheme"))?;
        endpoint.set_path("/api/v1/auth/session");
        let mut headers = reqwest::header::HeaderMap::new();
        let mut auth = reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))?;
        auth.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, auth);
        // Deliberately no X-Orialis-Device-ID: development header auth can shadow
        // the bearer and resolve a different owner than the agent token.
        let client = Client::builder()
            .default_headers(headers)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            client,
            endpoint,
            device: device.into(),
            expected,
        })
    }
    pub async fn verify(&self) -> Result<VerifiedOwner> {
        let mut response = self
            .client
            .get(self.endpoint.clone())
            .send()
            .await
            .context("account verification unavailable")?;
        ensure!(
            response.status().as_u16() == 200,
            "account verification refused"
        );
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            ensure!(
                bytes.len() + chunk.len() <= 16384,
                "invalid account verification response"
            );
            bytes.extend_from_slice(&chunk);
        }
        let value: Value =
            serde_json::from_slice(&bytes).context("invalid account verification response")?;
        let user = value["userId"]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 160)
            .context("verified account lacks owner identity")?;
        ensure!(
            self.expected.as_deref().is_none_or(|s| s == user),
            "verified owner does not match configured owner"
        );
        Ok(VerifiedOwner {
            origin: self.endpoint.origin().ascii_serialization(),
            device: self.device.clone(),
            user: user.into(),
        })
    }
}
/// Bind before opening the history/journal actors. Existing unbound history must
/// be reviewed/migrated explicitly; silently attaching it to a new owner is unsafe.
pub fn bind_store(path: &Path, owner: &VerifiedOwner) -> Result<()> {
    let mut db = crate::private_db::open_private(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    tx.execute_batch("CREATE TABLE IF NOT EXISTS account_binding(id INTEGER PRIMARY KEY CHECK(id=1),origin TEXT NOT NULL,device TEXT NOT NULL,owner_id TEXT NOT NULL)")?;
    let prior: Option<(String, String, String)> = tx
        .query_row(
            "SELECT origin,device,owner_id FROM account_binding WHERE id=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    if let Some((origin, device, user)) = prior {
        ensure!(
            origin == owner.origin && device == owner.device && user == owner.user,
            "stored account binding does not match verified owner"
        );
    } else {
        for table in ["sessions", "memories", "jobs", "migration_manifests"] {
            let exists: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
                [table],
                |r| r.get(0),
            )?;
            if exists {
                let count: i64 =
                    tx.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
                ensure!(
                    count == 0,
                    "existing unbound history requires explicit migration review before account binding"
                );
            }
        }
        tx.execute(
            "INSERT INTO account_binding(id,origin,device,owner_id) VALUES(1,?1,?2,?3)",
            params![owner.origin, owner.device, owner.user],
        )?;
    }
    tx.commit()?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Json, Router, extract::State, http::HeaderMap, routing::get};
    use serde_json::json;
    use std::sync::{Arc, Mutex};
    #[tokio::test]
    async fn owner_probe_uses_bearer_not_development_header_and_binds() -> Result<()> {
        let owner = Arc::new(Mutex::new("owner-a".to_string()));
        let endpoint = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("ws://{}/api/v1/agent/ws", endpoint.local_addr()?);
        async fn session(
            State(owner): State<Arc<Mutex<String>>>,
            headers: HeaderMap,
        ) -> Json<Value> {
            assert_eq!(headers["authorization"], "Bearer synthetic-token");
            assert!(headers.get("x-orialis-device-id").is_none());
            Json(json!({"userId":owner.lock().unwrap().clone(),"username":"synthetic"}))
        }
        let app = Router::new()
            .route("/api/v1/auth/session", get(session))
            .with_state(owner.clone());
        let task = tokio::spawn(async move { axum::serve(endpoint, app).await.unwrap() });
        let verify = OwnerVerifier::new(&url, "TE_ST_Rust", "synthetic-token", None)?;
        let first = verify.verify().await?;
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("state.sqlite");
        bind_store(&path, &first)?;
        bind_store(&path, &first)?;
        *owner.lock().unwrap() = "owner-b".into();
        let next = verify.verify().await?;
        assert_ne!(first.scope(), next.scope());
        assert!(bind_store(&path, &next).is_err());
        assert!(
            OwnerVerifier::new(
                &url,
                "TE_ST_Rust",
                "synthetic-token",
                Some("owner-a".into())
            )?
            .verify()
            .await
            .is_err()
        );
        task.abort();
        Ok(())
    }
    #[test]
    fn unbound_private_history_is_not_silently_adopted() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("state.sqlite");
        let mut store = crate::Store::open(&path)?;
        store.load_session("old")?;
        drop(store);
        let owner = VerifiedOwner {
            origin: "https://example.invalid".into(),
            device: "TE_ST_Rust".into(),
            user: "owner-a".into(),
        };
        assert!(bind_store(&path, &owner).is_err());
        let db = crate::private_db::open_private(&path)?;
        let rows: i64 = db.query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))?;
        assert_eq!(rows, 1);
        Ok(())
    }
}
