//! Durable, correlated parent replies on the host's authenticated chat socket.
//!
//! This is an immutable transport receipt, not a provider/tool/upload queue.
//! Delivery ACKs have no meaning here. Only an exact `message.ack: received`
//! establishes server commit, including when it arrives after local suppression.
use crate::{
    delivery::{DeliveryIdentity, DeliveryOutbox, OwnedDatabase, digest, id},
    journal::ProvenChatAnchor,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{sync::Arc, time::Duration};
use tokio::sync::Semaphore;

pub const MAX_REPLY_BYTES: usize = 1024 * 1024;
pub const MAX_REPLY_TEXT_BYTES: usize = 256 * 1024;
const PREFIX: &str = "parent-reply:";
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS continuation_replies(
 message_id TEXT PRIMARY KEY, source_id TEXT NOT NULL UNIQUE, input_id TEXT NOT NULL UNIQUE,
 conversation TEXT NOT NULL, request TEXT NOT NULL, anchor_fingerprint TEXT NOT NULL,
 bytes INTEGER NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt_ms INTEGER NOT NULL DEFAULT 0, rejection_count INTEGER NOT NULL DEFAULT 0,
 last_rejected_attempt INTEGER NOT NULL DEFAULT 0, diagnostic TEXT,
 max_attempts INTEGER NOT NULL, base_backoff_ms INTEGER NOT NULL, max_backoff_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS continuation_replies_pending ON continuation_replies(state,message_id,next_attempt_ms);
CREATE INDEX IF NOT EXISTS continuation_replies_conversation ON continuation_replies(conversation,state);
CREATE TABLE IF NOT EXISTS continuation_reply_totals(
 id INTEGER PRIMARY KEY CHECK(id=1), records INTEGER NOT NULL, bytes INTEGER NOT NULL
);
INSERT OR IGNORE INTO continuation_reply_totals SELECT 1,COUNT(*),COALESCE(SUM(bytes),0) FROM continuation_replies;
CREATE TRIGGER IF NOT EXISTS continuation_reply_added AFTER INSERT ON continuation_replies
 BEGIN UPDATE continuation_reply_totals SET records=records+1,bytes=bytes+NEW.bytes WHERE id=1; END;
";

/// Host-resolved lineage. `root_input_id` is the real user message ID, not the
/// continuation queue's historical hashed root-budget key.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ReplySource {
    pub notification_id: String,
    pub input_id: String,
    pub parent_input_id: String,
    pub root_input_id: String,
    pub session_id: String,
    pub conversation_id: String,
    pub generation: i64,
    pub outcome_digest: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ReplyRequest {
    pub source: ReplySource,
    pub frame: Value,
    /// Local durable upload receipt IDs, not remote attachment IDs.
    pub artifact_ids: Vec<String>,
}
impl ReplyRequest {
    pub fn message_id(&self) -> String {
        self.frame["message_id"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReplyStatus {
    Pending,
    Delivered,
    Rejected,
    Uncertain,
    Suppressed,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplyRecord {
    pub request: ReplyRequest,
    pub status: ReplyStatus,
    pub attempts: u32,
    pub next_attempt_at_ms: i64,
    pub rejection_count: u32,
    pub diagnostic: Option<String>,
}
#[derive(Clone, Copy, Debug)]
pub struct ReplyLimits {
    pub max_records: usize,
    /// Includes terminal rows: dedup identities and immutable payloads are never
    /// evicted just to admit new work.
    pub max_retained_bytes: usize,
    /// Hard maximum is initial send plus two retries. Persisted for each row.
    pub max_attempts: u32,
    pub base_backoff: Duration,
    pub max_backoff: Duration,
}
impl Default for ReplyLimits {
    fn default() -> Self {
        Self {
            max_records: 8192,
            max_retained_bytes: 32 * 1024 * 1024,
            max_attempts: 3,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(30),
        }
    }
}
impl ReplyLimits {
    fn validate(&self) -> Result<()> {
        ensure!(
            (1..=100_000).contains(&self.max_records),
            "invalid reply retention count"
        );
        ensure!(
            (1024..=1024 * 1024 * 1024).contains(&self.max_retained_bytes),
            "invalid reply retention bytes"
        );
        ensure!(
            (1..=3).contains(&self.max_attempts),
            "reply attempts must be between one and three"
        );
        ensure!(
            self.base_backoff >= Duration::from_millis(1)
                && self.max_backoff >= self.base_backoff
                && self.max_backoff <= Duration::from_secs(3600),
            "invalid reply backoff"
        );
        Ok(())
    }
}
#[derive(Clone)]
pub struct ContinuationReplyOutbox {
    db: Arc<OwnedDatabase>,
    identity: DeliveryIdentity,
    limits: ReplyLimits,
    namespace: String,
    operations: Arc<Semaphore>,
}
impl ContinuationReplyOutbox {
    /// Reuses the private, identity-bound SQLite lease. Do not open a second
    /// service on the same file. At most 32 of our DB operations are admitted.
    pub async fn from_delivery(outbox: &DeliveryOutbox, limits: ReplyLimits) -> Result<Self> {
        limits.validate()?;
        let namespace = reply_namespace(&outbox.identity)?;
        // DeliveryOutbox exposes its identity fields publicly. Verify the actual
        // durable binding, not just that caller-mutable in-memory description.
        let binding = format!(
            "delivery:{}",
            digest(&serde_json::to_vec(&outbox.identity)?)
        );
        outbox
            .db
            .call(move |db| {
                let stored: String = db.query_row(
                    "SELECT fingerprint FROM module_identity WHERE id=1",
                    [],
                    |r| r.get(0),
                )?;
                ensure!(
                    stored == binding,
                    "reply outbox identity differs from its durable database binding"
                );
                db.execute_batch(SCHEMA)?;
                Ok(())
            })
            .await?;
        Ok(Self {
            db: outbox.db.clone(),
            identity: outbox.identity.clone(),
            limits,
            namespace,
            operations: Arc::new(Semaphore::new(32)),
        })
    }
    async fn db<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let permit = self.operations.clone().acquire_owned().await?;
        // The permit lives inside spawn_blocking. Once admitted, cancellation
        // cannot release the bound early or cancel a partially committed write.
        self.db
            .call(move |db| {
                let _permit = permit;
                operation(db)
            })
            .await
    }
    pub fn message_id(&self, source: &str) -> String {
        format!("{PREFIX}{}:{source}", self.namespace)
    }
    /// Deterministic identity helper; no credential is included in a wire ID.
    /// Enqueue independently verifies this ID against its durable binding.
    pub fn message_id_for(identity: &DeliveryIdentity, source: &str) -> Result<String> {
        let key = format!("{PREFIX}{}:{source}", reply_namespace(identity)?);
        id(source)?;
        ensure!(
            key.len() <= 160,
            "reply wire ID exceeds local 160-byte limit"
        );
        Ok(key)
    }
    pub fn is_reply_id(message_id: &str) -> bool {
        message_id.starts_with(PREFIX)
    }

    /// Public callers cannot supply a fake chat anchor: the opaque capability
    /// comes from durable, server/device/owner-bound original Journal provenance.
    /// The host additionally proves the source's runtime lineage/current permit.
    pub async fn enqueue(
        &self,
        request: ReplyRequest,
        anchor: &ProvenChatAnchor,
    ) -> Result<ReplyStatus> {
        ensure!(
            anchor.is_bound_to(
                &self.identity.server_url,
                &self.identity.device_id,
                &self.identity.owner
            ),
            "reply anchor owner/server/device mismatch"
        );
        ensure!(
            anchor.message_id() == request.source.root_input_id
                && anchor.conversation_id() == request.source.conversation_id,
            "reply source differs from proven chat anchor"
        );
        validate_request(&request, &self.message_id(&request.source.notification_id))?;
        let anchor_fingerprint = anchor.payload_fingerprint().to_owned();
        let serialized = serde_json::to_string(&request)?;
        let limits = self.limits;
        self.db(move |db| {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let key = request.message_id();
            let existing: Option<(String,String)> = tx.query_row(
                "SELECT request,anchor_fingerprint FROM continuation_replies WHERE message_id=?1 OR source_id=?2 OR input_id=?3 LIMIT 1",
                params![key,request.source.notification_id,request.source.input_id], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
            if let Some((old,old_anchor)) = existing {
                ensure!(old == serialized && old_anchor == anchor_fingerprint,
                    "reply identity reused with changed source, anchor or immutable frame");
                return Ok(read_record(&tx,&key)?.context("reply identity conflict")?.status);
            }
            let (count,bytes):(usize,usize) = tx.query_row(
                "SELECT records,bytes FROM continuation_reply_totals WHERE id=1",[],|r| Ok((r.get(0)?,r.get(1)?)))?;
            ensure!(count < limits.max_records && bytes.saturating_add(serialized.len()) <= limits.max_retained_bytes,
                "continuation reply retention capacity exhausted; dedup identities retained");
            tx.execute("INSERT INTO continuation_replies(message_id,source_id,input_id,conversation,request,anchor_fingerprint,bytes,state,max_attempts,base_backoff_ms,max_backoff_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,'pending',?8,?9,?10)",
                params![key,request.source.notification_id,request.source.input_id,request.source.conversation_id,serialized,anchor_fingerprint,serialized.len(),limits.max_attempts,limits.base_backoff.as_millis() as i64,limits.max_backoff.as_millis() as i64])?;
            tx.commit()?;
            Ok(ReplyStatus::Pending)
        }).await
    }
    pub async fn inspect(&self, message_id: &str) -> Result<Option<ReplyRecord>> {
        let key = message_id.to_owned();
        self.db(move |db| read_record(db, &key)).await
    }
    /// Bounded keyset page. A removed/ACKed/suppressed cursor need not still be
    /// pending. Wrap on a short page; future-due rows never block later due IDs.
    pub async fn pending_after(
        &self,
        after: Option<&str>,
        limit: usize,
        now_ms: i64,
    ) -> Result<Vec<ReplyRecord>> {
        ensure!(
            (1..=256).contains(&limit) && now_ms >= 0,
            "invalid reply page or time"
        );
        let after = after.unwrap_or("").to_owned();
        self.db(move |db| {
            let mut statement=db.prepare_cached("SELECT request,state,attempts,next_attempt_ms,rejection_count,diagnostic FROM continuation_replies WHERE state='pending' AND message_id>?1 AND next_attempt_ms<=?2 ORDER BY message_id LIMIT ?3")?;
            let rows=statement.query_map(params![after,now_ms,limit],raw_record)?.collect::<rusqlite::Result<Vec<_>>>()?;
            rows.into_iter().map(decode_record).collect()
        }).await
    }
    /// Must run under the host's current source/stop fence immediately before a
    /// bounded socket write. A crash after this commit consumes an attempt; it
    /// never reruns provider effects and replay always uses the stored frame.
    pub async fn prepare_send(&self, message_id: &str, now_ms: i64) -> Result<Option<Value>> {
        ensure!(now_ms >= 0, "invalid reply time");
        let key = message_id.to_owned();
        let namespace = self.namespace.clone();
        self.db(move |db| {
            let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let Some(row)=read_record(&tx,&key)? else { return Ok(None); };
            if row.status != ReplyStatus::Pending || row.next_attempt_at_ms > now_ms { return Ok(None); }
            let expected=format!("{PREFIX}{namespace}:{}",row.request.source.notification_id);
            if row.request.message_id()!=key || validate_request(&row.request,&expected).is_err() {
                tx.execute("UPDATE continuation_replies SET state='suppressed',diagnostic='stored reply identity or frame is invalid for current binding; immutable receipt retained' WHERE message_id=?1",[&key])?;
                tx.commit()?;
                return Ok(None);
            }
            let (maximum,base,cap):(u32,i64,i64)=tx.query_row(
                "SELECT max_attempts,base_backoff_ms,max_backoff_ms FROM continuation_replies WHERE message_id=?1",[&key],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
            if row.attempts >= maximum {
                tx.execute("UPDATE continuation_replies SET state='uncertain',diagnostic='ACK absent after bounded immutable replay; server commit unknown' WHERE message_id=?1",[&key])?;
                tx.commit()?;
                return Ok(None);
            }
            let attempts=row.attempts+1;
            let backoff=base.saturating_mul(1_i64 << (attempts-1)).min(cap);
            tx.execute("UPDATE continuation_replies SET attempts=?2,next_attempt_ms=?3,diagnostic=NULL WHERE message_id=?1",
                params![key,attempts,now_ms.saturating_add(backoff)])?;
            tx.commit()?;
            Ok(Some(row.request.frame))
        }).await
    }
    /// Feed ONLY receipts read from this identity's authenticated host socket.
    /// `delivery.ack`, other statuses, uncorrelated IDs, and unsent rows cannot
    /// manufacture persistence. A late ACK wins over every local terminal state.
    pub async fn acknowledge(&self, frame: Value) -> Result<bool> {
        ensure!(
            frame["version"] == 1
                && frame["type"] == "message.ack"
                && frame["status"] == "received",
            "not a positive correlated message receipt"
        );
        let key = frame["message_id"]
            .as_str()
            .context("message receipt ID missing")?
            .to_owned();
        id(&key)?;
        self.db(move |db| Ok(db.execute(
            "UPDATE continuation_replies SET state='delivered',diagnostic=NULL WHERE message_id=?1 AND attempts>0",[key])? == 1)).await
    }
    /// The server uses REPLY_REJECTED for both transient DB errors and permanent
    /// authorization/identity failures. Do not guess permanence from its text.
    /// Retry only the exact saved frame, at most initial + two total sends.
    pub async fn reject(&self, frame: Value, now_ms: i64) -> Result<bool> {
        ensure!(
            now_ms >= 0
                && frame["version"] == 1
                && frame["type"] == "error"
                && frame["code"] == "REPLY_REJECTED",
            "not a correlated reply rejection"
        );
        let key = frame["reply_to"]
            .as_str()
            .context("reply rejection ID missing")?
            .to_owned();
        id(&key)?;
        self.db(move |db| {
            let tx=db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let Some(row)=read_record(&tx,&key)? else { return Ok(false); };
            if row.attempts == 0 { return Ok(false); }
            if row.status != ReplyStatus::Pending { return Ok(true); }
            let (maximum,last):(u32,u32)=tx.query_row(
                "SELECT max_attempts,last_rejected_attempt FROM continuation_replies WHERE message_id=?1",[&key],|r| Ok((r.get(0)?,r.get(1)?)))?;
            if last == row.attempts { return Ok(true); }
            let (state,diagnostic)=if row.attempts >= maximum {
                ("rejected","REPLY_REJECTED after bounded replay; failure permanence unknown; late ACK remains valid")
            } else { ("pending","REPLY_REJECTED; immutable retry pending; failure permanence unknown") };
            // Preserve the already committed backoff. Duplicate rejection frames
            // cannot consume attempts or postpone a retry indefinitely.
            tx.execute("UPDATE continuation_replies SET state=?2,last_rejected_attempt=attempts,rejection_count=rejection_count+1,diagnostic=?3 WHERE message_id=?1",params![key,state,diagnostic])?;
            tx.commit()?;
            Ok(true)
        }).await
    }
    pub async fn suppress(&self, message_id: &str, reason: &str) -> Result<bool> {
        validate_reason(reason)?;
        let key = message_id.to_owned();
        let reason = reason.to_owned();
        self.db(move |db| Ok(db.execute("UPDATE continuation_replies SET state='suppressed',diagnostic=?2 WHERE message_id=?1 AND state NOT IN ('delivered','suppressed')",params![key,reason])? == 1)).await
    }
    pub async fn suppress_conversation(&self, conversation: &str, reason: &str) -> Result<usize> {
        id(conversation)?;
        validate_reason(reason)?;
        let conversation = conversation.to_owned();
        let reason = reason.to_owned();
        self.db(move |db| Ok(db.execute("UPDATE continuation_replies SET state='suppressed',diagnostic=?2 WHERE conversation=?1 AND state NOT IN ('delivered','suppressed')",params![conversation,reason])?)).await
    }
}
fn validate_reason(reason: &str) -> Result<()> {
    ensure!(
        !reason.trim().is_empty() && reason.len() <= 1024,
        "invalid reply suppression reason"
    );
    Ok(())
}
fn reply_namespace(identity: &DeliveryIdentity) -> Result<String> {
    let server = reqwest::Url::parse(&identity.server_url)?.to_string();
    let encoded = serde_json::to_vec(&serde_json::json!([
        "parent-reply-v1",
        server,
        identity.device_id,
        identity.owner
    ]))?;
    Ok(digest(&encoded)[..32].to_owned())
}
fn validate_request(request: &ReplyRequest, expected_message_id: &str) -> Result<()> {
    let source = &request.source;
    for key in [
        &source.notification_id,
        &source.input_id,
        &source.parent_input_id,
        &source.root_input_id,
        &source.session_id,
        &source.conversation_id,
    ] {
        id(key)?;
    }
    ensure!(
        source.generation >= 0
            && source.outcome_digest.len() == 64
            && source
                .outcome_digest
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
        "invalid reply source generation or outcome digest"
    );
    ensure!(
        source.input_id
            == format!(
                "parent-continuation-{}",
                &digest(source.notification_id.as_bytes())[..40]
            ),
        "reply input does not belong to notification source"
    );
    let key = request.message_id();
    id(&key)?;
    ensure!(
        key == expected_message_id && key.len() <= 160,
        "reply wire ID identity mismatch or exceeds 160-byte limit"
    );
    let frame = &request.frame;
    let object = frame.as_object().context("reply frame is not an object")?;
    ensure!(
        object.keys().all(|key| matches!(
            key.as_str(),
            "version"
                | "type"
                | "message_id"
                | "reply_to"
                | "conversation_id"
                | "content"
                | "attachments"
        )),
        "unexpected reply frame fields"
    );
    ensure!(
        frame["version"] == 1
            && frame["type"] == "message.reply"
            && frame["message_id"].as_str() == Some(&key)
            && frame["reply_to"].as_str() == Some(&source.root_input_id)
            && frame["conversation_id"].as_str() == Some(&source.conversation_id),
        "reply frame correlation/source mismatch"
    );
    let content = frame["content"]
        .as_str()
        .context("reply content must be text")?;
    ensure!(
        content.len() <= MAX_REPLY_TEXT_BYTES,
        "reply content exceeds local byte limit"
    );
    let attachments = if let Some(attachments) = object.get("attachments") {
        attachments
            .as_array()
            .context("reply attachments must be an array")?
            .as_slice()
    } else {
        &[]
    };
    ensure!(
        !content.trim().is_empty() || !attachments.is_empty(),
        "empty reply"
    );
    ensure!(
        attachments.len() <= 16,
        "reply attachment count exceeds protocol limit"
    );
    ensure!(
        request.artifact_ids.len() == attachments.len(),
        "reply artifact receipt count differs from attachments"
    );
    let mut artifact_ids = std::collections::BTreeSet::new();
    for artifact_id in &request.artifact_ids {
        id(artifact_id)?;
        ensure!(
            artifact_ids.insert(artifact_id),
            "duplicate reply artifact receipt ID"
        );
    }
    for attachment in attachments {
        let object = attachment.as_object().context("invalid reply attachment")?;
        ensure!(
            object.keys().all(|key| matches!(
                key.as_str(),
                "id" | "name" | "mime_type" | "size" | "download_url"
            )),
            "unexpected reply attachment fields"
        );
        for field in ["id", "name", "mime_type", "download_url"] {
            ensure!(
                attachment[field]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty()),
                "reply attachment field missing"
            );
        }
        ensure!(
            attachment["name"].as_str().unwrap().chars().count() <= 180
                && attachment["size"].as_i64().is_some_and(|n| n > 0),
            "invalid reply attachment name or size"
        );
        let mime = attachment["mime_type"]
            .as_str()
            .unwrap()
            .to_ascii_lowercase();
        ensure!(
            mime.starts_with("image/")
                || mime.starts_with("text/")
                || matches!(
                    mime.as_str(),
                    "application/pdf"
                        | "application/json"
                        | "application/xml"
                        | "application/octet-stream"
                        | "application/zip"
                ),
            "unsupported reply attachment MIME type"
        );
    }
    ensure!(
        crate::json_encoded_len(frame)? <= MAX_REPLY_BYTES,
        "reply frame exceeds local byte limit"
    );
    Ok(())
}
type RawRecord = (String, String, u32, i64, u32, Option<String>);
fn raw_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<RawRecord> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
    ))
}
fn decode_record(
    (request, status, attempts, next_attempt_at_ms, rejection_count, diagnostic): RawRecord,
) -> Result<ReplyRecord> {
    Ok(ReplyRecord {
        request: serde_json::from_str(&request)?,
        status: serde_json::from_value(Value::String(status))?,
        attempts,
        next_attempt_at_ms,
        rejection_count,
        diagnostic,
    })
}
fn read_record(db: &Connection, key: &str) -> Result<Option<ReplyRecord>> {
    db.prepare_cached("SELECT request,state,attempts,next_attempt_ms,rejection_count,diagnostic FROM continuation_replies WHERE message_id=?1")?
        .query_row([key],raw_record).optional()?.map(decode_record).transpose()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{delivery::DeliveryLimits, journal::Journal};
    use serde_json::json;
    use std::path::Path;

    #[tokio::test]
    async fn admitted_write_survives_cancelled_caller_and_retains_admission_permit() -> Result<()> {
        let identity = DeliveryIdentity::new("owner", "ws://127.0.0.1:1234/ws", "device", "token")?;
        let delivery =
            DeliveryOutbox::open(Path::new(":memory:"), identity, DeliveryLimits::default())
                .await?;
        let outbox =
            ContinuationReplyOutbox::from_delivery(&delivery, ReplyLimits::default()).await?;
        let journal =
            Journal::open(Path::new(":memory:"), "ws://127.0.0.1:1234/ws|device|owner").await?;
        journal.claim("chat:root",&json!({"version":1,"type":"message.send","message_id":"root","conversation_id":"chat","content":"original"})).await?;
        let anchor = journal.proven_chat_anchor("root", "chat").await?.unwrap();
        let message_id = outbox.message_id("cancel");
        let req = ReplyRequest {
            source: ReplySource {
                notification_id: "cancel".into(),
                input_id: format!("parent-continuation-{}", &digest(b"cancel")[..40]),
                parent_input_id: "root".into(),
                root_input_id: "root".into(),
                session_id: "session".into(),
                conversation_id: "chat".into(),
                generation: 0,
                outcome_digest: digest(b"result"),
            },
            frame: json!({"version":1,"type":"message.reply","message_id":message_id,"reply_to":"root","conversation_id":"chat","content":"committed after caller cancellation"}),
            artifact_ids: vec![],
        };
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let database = delivery.db.clone();
        let blocker = tokio::spawn(async move {
            database
                .call(move |_| {
                    let _ = started_tx.send(());
                    release_rx.recv()?;
                    Ok(())
                })
                .await
        });
        started_rx.await?;
        let enqueue_outbox = outbox.clone();
        let write = tokio::spawn(async move { enqueue_outbox.enqueue(req, &anchor).await });
        tokio::time::timeout(Duration::from_secs(5), async {
            while outbox.operations.available_permits() == 32 {
                tokio::task::yield_now().await;
            }
        })
        .await?;
        write.abort();
        assert!(write.await.unwrap_err().is_cancelled());
        assert_eq!(
            outbox.operations.available_permits(),
            31,
            "cancelled producer must not bypass operation bound"
        );
        release_tx.send(())?;
        blocker.await??;
        let _drained = outbox.operations.clone().acquire_many_owned(32).await?;
        drop(_drained);
        assert_eq!(
            outbox.inspect(&message_id).await?.unwrap().status,
            ReplyStatus::Pending
        );
        journal.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn pending_cursor_query_uses_bounded_keyset_index() -> Result<()> {
        let identity = DeliveryIdentity::new("owner", "ws://127.0.0.1:1234/ws", "device", "token")?;
        let delivery =
            DeliveryOutbox::open(Path::new(":memory:"), identity, DeliveryLimits::default())
                .await?;
        let outbox =
            ContinuationReplyOutbox::from_delivery(&delivery, ReplyLimits::default()).await?;
        let plans=outbox.db(|db| {
            let mut query=db.prepare("EXPLAIN QUERY PLAN SELECT request,state,attempts,next_attempt_ms,rejection_count,diagnostic FROM continuation_replies WHERE state='pending' AND message_id>?1 AND next_attempt_ms<=?2 ORDER BY message_id LIMIT ?3")?;
            Ok(query.query_map(params!["parent-reply:cursor",100,32],|r| r.get::<_,String>(3))?.collect::<rusqlite::Result<Vec<_>>>()?)
        }).await?;
        assert!(
            plans
                .iter()
                .any(|p| p.contains("continuation_replies_pending") && p.contains("SEARCH")),
            "{plans:?}"
        );
        assert!(
            !plans.iter().any(|p| p.contains("TEMP B-TREE")),
            "{plans:?}"
        );
        Ok(())
    }
}
