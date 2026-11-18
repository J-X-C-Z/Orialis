//! Durable Orialis delivery transport. A legacy `received` ACK proves acceptance,
//! not server persistence: the pinned server only broadcasts these extensions.
use anyhow::{Context, Result, bail, ensure};
use futures_util::{SinkExt, StreamExt};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    future::Future,
    path::Path,
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

pub type DeliveryFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;
pub const MAX_DELIVERY_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryIdentity {
    pub owner: String,
    pub server_url: String,
    pub device_id: String,
    credential_digest: String,
}
impl DeliveryIdentity {
    pub fn new(owner: &str, server_url: &str, device_id: &str, token: &str) -> Result<Self> {
        id(owner)?;
        id(device_id)?;
        let url = reqwest::Url::parse(server_url)?;
        ensure!(
            matches!(url.scheme(), "ws" | "wss")
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "invalid gateway URL"
        );
        ensure!(
            !token.trim().is_empty() && !token.contains(['\r', '\n']),
            "delivery credential required"
        );
        Ok(Self {
            owner: owner.into(),
            server_url: url.to_string(),
            device_id: device_id.into(),
            credential_digest: digest(token.as_bytes()),
        })
    }
    fn fingerprint(&self) -> Result<String> {
        Ok(digest(&serde_json::to_vec(self)?))
    }
    fn check_token(&self, token: &str) -> Result<()> {
        ensure!(
            digest(token.as_bytes()) == self.credential_digest,
            "delivery credential differs from journal identity"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryKind {
    Cron,
    Proactive,
    Standalone,
}
impl DeliveryKind {
    pub fn wire_type(&self) -> &'static str {
        match self {
            Self::Cron => "cron.delivery",
            Self::Proactive => "proactive.delivery",
            Self::Standalone => "delivery.send",
        }
    }
    pub fn capability(&self) -> &'static str {
        match self {
            Self::Cron => "cron_delivery",
            Self::Proactive => "proactive_delivery",
            Self::Standalone => "proactive_delivery",
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryTarget {
    pub owner: String,
    pub device_id: String,
    pub conversation_id: String,
}
impl DeliveryTarget {
    pub fn validate(&self, identity: &DeliveryIdentity) -> Result<()> {
        id(&self.conversation_id)?;
        ensure!(
            self.owner == identity.owner && self.device_id == identity.device_id,
            "delivery target owner/device mismatch"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryBody {
    pub content: String,
    #[serde(default)]
    pub attachments: Vec<crate::attachments::AttachmentMetadata>,
    #[serde(default)]
    pub metadata: Value,
}
impl DeliveryBody {
    pub fn text(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            attachments: vec![],
            metadata: Value::Null,
        }
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.content.trim().is_empty() || !self.attachments.is_empty(),
            "empty delivery"
        );
        ensure!(
            self.content.len() <= 256 * 1024 && self.attachments.len() <= 16,
            "delivery content exceeds limit"
        );
        ensure!(
            self.metadata.is_null() || self.metadata.is_object(),
            "delivery metadata must be object"
        );
        for attachment in &self.attachments {
            attachment.validate()?;
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_DELIVERY_BYTES,
            "delivery exceeds byte limit"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryRequest {
    pub delivery_id: String,
    pub target: DeliveryTarget,
    pub kind: DeliveryKind,
    pub body: DeliveryBody,
}
impl DeliveryRequest {
    pub fn frame(&self) -> Result<Value> {
        id(&self.delivery_id)?;
        self.body.validate()?;
        let mut frame = json!({"version":1,"type":self.kind.wire_type(),"delivery_id":self.delivery_id,"conversation_id":self.target.conversation_id,"content":self.body.content});
        if !self.body.attachments.is_empty() {
            frame["attachments"] = serde_json::to_value(&self.body.attachments)?;
        }
        if !self.body.metadata.is_null() {
            frame["metadata"] = self.body.metadata.clone();
        }
        ensure!(
            serde_json::to_vec(&frame)?.len() <= MAX_DELIVERY_BYTES,
            "delivery wire frame exceeds limit"
        );
        Ok(frame)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum DeliveryStatus {
    Pending,
    Acknowledged { status: String },
    Cancelled,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeliveryRecord {
    pub request: DeliveryRequest,
    pub status: DeliveryStatus,
}
#[derive(Clone, Copy, Debug)]
pub struct DeliveryLimits {
    pub max_records: usize,
    pub max_pending_bytes: usize,
}
impl Default for DeliveryLimits {
    fn default() -> Self {
        Self {
            max_records: 8192,
            max_pending_bytes: 32 * 1024 * 1024,
        }
    }
}

pub(crate) fn id(value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= 200 && !value.chars().any(char::is_control),
        "invalid delivery/schedule ID"
    );
    Ok(())
}
pub(crate) fn digest(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}
/// Holds an exclusive process lease, as well as SQLite serialization. Multiple
/// objects must share this Arc, never open the same file as a second service.
pub(crate) struct OwnedDatabase {
    connection: Mutex<Connection>,
    _lease: Option<File>,
}
impl OwnedDatabase {
    pub(crate) fn open(path: &Path, identity: &str) -> Result<Self> {
        let connection = crate::private_db::open_private(path)?;
        let lease = if path == Path::new(":memory:") {
            None
        } else {
            #[cfg(unix)]
            {
                use std::os::{
                    fd::AsRawFd,
                    unix::fs::{MetadataExt, OpenOptionsExt},
                };
                let mut name = path.as_os_str().to_os_string();
                name.push(".owner-lock");
                let file = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(name)?;
                let meta = file.metadata()?;
                ensure!(
                    meta.is_file()
                        && meta.mode() & 0o777 == 0o600
                        && meta.nlink() == 1
                        && meta.uid() == unsafe { libc::geteuid() },
                    "unsafe scheduler/delivery lease file"
                );
                ensure!(
                    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                    "scheduler/delivery journal already owned by another service"
                );
                Some(file)
            }
            #[cfg(not(unix))]
            {
                bail!("scheduler/delivery disk leases require Unix");
            }
        };
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS module_identity(id INTEGER PRIMARY KEY CHECK(id=1),fingerprint TEXT NOT NULL);")?;
        let previous: Option<String> = connection
            .query_row(
                "SELECT fingerprint FROM module_identity WHERE id=1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            ensure!(
                previous == identity,
                "journal belongs to a different owner/server/device/credential"
            );
        } else {
            connection.execute("INSERT INTO module_identity VALUES(1,?1)", [identity])?;
        }
        Ok(Self {
            connection: Mutex::new(connection),
            _lease: lease,
        })
    }
    pub(crate) async fn call<T, F>(self: &Arc<Self>, f: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    {
        let inner = self.clone();
        tokio::task::spawn_blocking(move || {
            let mut connection = inner
                .connection
                .lock()
                .map_err(|_| anyhow::anyhow!("journal lock poisoned"))?;
            f(&mut connection)
        })
        .await?
    }
}
#[derive(Clone)]
pub struct DeliveryOutbox {
    pub(crate) db: Arc<OwnedDatabase>,
    pub identity: DeliveryIdentity,
    limits: DeliveryLimits,
    standalone_gate: Arc<tokio::sync::Mutex<()>>,
}
impl DeliveryOutbox {
    pub async fn open(
        path: impl AsRef<Path>,
        identity: DeliveryIdentity,
        limits: DeliveryLimits,
    ) -> Result<Self> {
        ensure!(
            limits.max_records > 0 && limits.max_pending_bytes >= MAX_DELIVERY_BYTES,
            "invalid delivery limits"
        );
        let path = path.as_ref().to_owned();
        let fingerprint = identity.fingerprint()?;
        let db = Arc::new(
            tokio::task::spawn_blocking(move || {
                OwnedDatabase::open(&path, &format!("delivery:{fingerprint}"))
            })
            .await??,
        );
        db.call(|db|{db.execute_batch("CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY,request TEXT NOT NULL,digest TEXT NOT NULL,status TEXT NOT NULL,ack_status TEXT,bytes INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS deliveries_pending ON deliveries(status); CREATE INDEX IF NOT EXISTS deliveries_pending_id ON deliveries(status,id);")?;Ok(())}).await?;
        Ok(Self {
            db,
            identity,
            limits,
            standalone_gate: Arc::new(tokio::sync::Mutex::new(())),
        })
    }
    /// Stable IDs are tombstones: same ID + changed target/content is rejected,
    /// including after ACK or cancellation. No automatic tombstone pruning.
    pub async fn enqueue(&self, request: DeliveryRequest) -> Result<DeliveryStatus> {
        request.target.validate(&self.identity)?;
        request.frame()?;
        let serialized = serde_json::to_string(&request)?;
        let hash = digest(serialized.as_bytes());
        let limits = self.limits;
        self.db.call(move|db|{
            if let Some(record)=record(db,&request.delivery_id)?{ensure!(record.request==request,"delivery ID reused with changed payload/target");return Ok(record.status)}
            let (count,bytes):(usize,usize)=db.query_row("SELECT COUNT(*),COALESCE(SUM(CASE WHEN status='pending' THEN bytes ELSE 0 END),0) FROM deliveries",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
            ensure!(count<limits.max_records && bytes.saturating_add(serialized.len())<=limits.max_pending_bytes,"delivery outbox capacity exhausted");
            db.execute("INSERT INTO deliveries VALUES(?1,?2,?3,'pending',NULL,?4)",params![request.delivery_id,serialized,hash,serialized.len()])?;Ok(DeliveryStatus::Pending)
        }).await
    }
    pub async fn inspect(&self, delivery_id: &str) -> Result<Option<DeliveryRecord>> {
        let key = delivery_id.to_owned();
        self.db.call(move |db| record(db, &key)).await
    }
    pub async fn pending(&self, limit: usize) -> Result<Vec<DeliveryRecord>> {
        ensure!((1..=256).contains(&limit), "invalid delivery page size");
        self.db
            .call(move |db| {
                let mut q = db.prepare_cached(
                    "SELECT request FROM deliveries WHERE status='pending' ORDER BY rowid LIMIT ?1",
                )?;
                let values = q
                    .query_map([limit], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                values
                    .into_iter()
                    .map(|s| {
                        Ok(DeliveryRecord {
                            request: serde_json::from_str(&s)?,
                            status: DeliveryStatus::Pending,
                        })
                    })
                    .collect()
            })
            .await
    }
    /// Stable keyset paging for a bounded fair transport pump. The cursor need
    /// not still be pending; callers wrap after a short page.
    pub async fn pending_after(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<DeliveryRecord>> {
        ensure!((1..=256).contains(&limit), "invalid delivery page size");
        let after = after.unwrap_or("").to_owned();
        self.db.call(move |db| {
            let mut q=db.prepare_cached("SELECT request FROM deliveries WHERE status='pending' AND id>?1 ORDER BY id LIMIT ?2")?;
            let values=q.query_map(params![after,limit],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            values.into_iter().map(|s|Ok(DeliveryRecord {request:serde_json::from_str(&s)?,status:DeliveryStatus::Pending})).collect()
        }).await
    }
    /// Feed only frames from the authenticated connection for this identity.
    /// Positive receipt is distinct from message persistence or mobile display.
    pub async fn acknowledge(&self, frame: Value) -> Result<bool> {
        ensure!(
            frame["version"] == 1 && frame["type"] == "delivery.ack",
            "not a delivery receipt"
        );
        let key = frame["delivery_id"]
            .as_str()
            .context("delivery receipt ID missing")?
            .to_owned();
        id(&key)?;
        self.db
            .call(move |db| {
                let Some(row) = record(db, &key)? else {
                    return Ok(false);
                };
                ensure!(
                    frame["conversation_id"].as_str() == Some(&row.request.target.conversation_id),
                    "delivery receipt conversation mismatch or missing"
                );
                let status = frame["status"]
                    .as_str()
                    .context("delivery receipt status missing")?;
                ensure!(
                    matches!(status, "received" | "accepted" | "duplicate"),
                    "delivery rejected: {status}"
                );
                db.execute(
                    "UPDATE deliveries SET status='acknowledged',ack_status=?2 WHERE id=?1",
                    params![key, status],
                )?;
                Ok(true)
            })
            .await
    }
    pub async fn cancel(&self, delivery_id: &str) -> Result<bool> {
        let key = delivery_id.to_owned();
        self.db
            .call(move |db| {
                Ok(db.execute(
                    "UPDATE deliveries SET status='cancelled' WHERE id=?1 AND status='pending'",
                    [key],
                )? == 1)
            })
            .await
    }
    /// Standalone mode requires exclusive ownership of the *remote device*
    /// transport. The host must not call this beside a live chat WS writer: the
    /// server replaces connections for an identical device ID. No auto fallback.
    pub async fn send_standalone(
        &self,
        delivery_id: &str,
        token: &str,
        deadline: Duration,
    ) -> Result<DeliveryStatus> {
        ensure!(
            deadline >= Duration::from_millis(10) && deadline <= Duration::from_secs(300),
            "invalid delivery deadline"
        );
        self.identity.check_token(token)?;
        let _transport_guard = self
            .standalone_gate
            .try_lock()
            .context("standalone device transport already in use")?;
        let row = self
            .inspect(delivery_id)
            .await?
            .context("unknown delivery ID")?;
        if row.status != DeliveryStatus::Pending {
            return Ok(row.status);
        }
        let mut request = self.identity.server_url.clone().into_client_request()?;
        request
            .headers_mut()
            .insert("Authorization", format!("Bearer {token}").parse()?);
        let identity = self.identity.clone();
        let outbox = self.clone();
        tokio::time::timeout(deadline,async move{
            let (mut socket,_)=tokio_tungstenite::connect_async(request).await?;
            let hello=json!({"version":1,"type":"hello","device_id":identity.device_id,"client":"hermes","plugin_version":"rust-delivery-v1","platform":"rust","capabilities":[row.request.kind.capability()]});
            socket.send(Message::Text(serde_json::to_string(&hello)?.into())).await?;
            let mut negotiated=false;
            while let Some(frame)=socket.next().await {
                match frame? {
                    Message::Ping(data)=>{socket.send(Message::Pong(data)).await?;}
                    Message::Text(text)=>{
                        ensure!(text.len()<=MAX_DELIVERY_BYTES,"oversized delivery response");let value:Value=serde_json::from_str(&text)?;
                        if !negotiated{
                            ensure!(value["type"]=="hello_ack" && value["version"]==1,"delivery handshake did not return hello_ack");
                            let caps=value["capabilities"].as_array().context("delivery capabilities missing")?;
                            ensure!(caps.iter().any(|cap|cap.as_str()==Some(row.request.kind.capability())),"server does not support requested delivery capability");
                            // Recheck cancellation immediately before the send.
                            if outbox.inspect(&row.request.delivery_id).await?.context("delivery disappeared")?.status!=DeliveryStatus::Pending{let _=socket.close(None).await;return Ok(DeliveryStatus::Cancelled)}
                            socket.send(Message::Text(serde_json::to_string(&row.request.frame()?)?.into())).await?;negotiated=true;
                        }else if value["type"]=="delivery.ack" && value["delivery_id"]==row.request.delivery_id{
                            outbox.acknowledge(value).await?;let _=socket.close(None).await;
                            return Ok(outbox.inspect(&row.request.delivery_id).await?.context("receipt disappeared")?.status)
                        }else if value["type"]=="ping"{socket.send(Message::Text(json!({"version":1,"type":"pong"}).to_string().into())).await?;}else if value["type"]=="error"{bail!("delivery server rejected frame");}
                    }
                    Message::Close(_)=>bail!("delivery connection closed before receipt"),
                    _=>{}
                }
            }
            bail!("delivery connection ended before receipt")
        }).await.context("delivery receipt timeout; outcome unknown, keep durable frame")?
    }
}
fn record(db: &Connection, key: &str) -> Result<Option<DeliveryRecord>> {
    let row: Option<(String, String, Option<String>)> = db
        .query_row(
            "SELECT request,status,ack_status FROM deliveries WHERE id=?1",
            [key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    row.map(|(request, status, ack)| {
        Ok(DeliveryRecord {
            request: serde_json::from_str(&request)?,
            status: match status.as_str() {
                "pending" => DeliveryStatus::Pending,
                "cancelled" => DeliveryStatus::Cancelled,
                "acknowledged" => DeliveryStatus::Acknowledged {
                    status: ack.context("ACK status absent")?,
                },
                _ => bail!("invalid delivery state"),
            },
        })
    })
    .transpose()
}
