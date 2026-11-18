//! Durable Orialis input deduplication and reply outbox.
//!
//! A bounded, FIFO actor owns the SQLite connection on a dedicated OS thread.
//! Neither SQLite lock waits nor WAL fsyncs run on Tokio's network workers. A
//! successful mutation response means its FULL-synchronous transaction committed.
//! Cancelling a call after admission does not cancel its durable mutation: drain
//! aborted producers before calling [`Journal::interrupted`] on disconnect.
//!
//! The on-disk tables are compatible with the original inline agent journal.
//! Additive indexes and minimal real-chat provenance preserve existing history.
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::Value;
use std::{path::Path, time::Duration};
use tokio::sync::{mpsc, oneshot, watch};

/// Maximum accepted, not-yet-executing operations in the default journal actor.
/// Admission waits asynchronously when this queue is full.
pub const DEFAULT_QUEUE_CAPACITY: usize = 128;

const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS agent_identity(
        id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS jobs(
        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, state TEXT NOT NULL, frame TEXT
    );
    CREATE TABLE IF NOT EXISTS delivery_failures(
        reply_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chat_input_provenance(
        job_id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL, payload_fingerprint TEXT NOT NULL
    );";
const INDEXES: &str = "
    CREATE INDEX IF NOT EXISTS jobs_reply_id ON jobs(json_extract(frame,'$.message_id'));
    CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state);";
const INTERRUPTED: &str = "UPDATE jobs
    SET state=CASE WHEN state='queued' THEN 'retryable' ELSE 'uncertain' END
    WHERE state IN ('running','queued')";
const ACK: &str = "UPDATE jobs SET state='delivered'
    WHERE state IN ('ready','retry_wait') AND json_extract(frame,'$.message_id')=?1";
const REJECT_SELECT: &str = "SELECT frame FROM jobs
    WHERE json_extract(frame,'$.message_id')=?1 AND state='ready' ORDER BY rowid LIMIT 1";
const REJECT_UPDATE: &str = "UPDATE jobs SET state=?1
    WHERE json_extract(frame,'$.message_id')=?2 AND state='ready'";
const PREPARE_UPDATE: &str = "UPDATE jobs SET state='ready'
    WHERE json_extract(frame,'$.message_id')=?1 AND state='retry_wait'";
const PREPARE_SELECT: &str = "SELECT EXISTS(SELECT 1 FROM jobs
    WHERE json_extract(frame,'$.message_id')=?1 AND state='ready')";
const REPLAY: &str = "SELECT frame FROM jobs
    WHERE state IN ('ready','retry_wait') ORDER BY rowid";

type Operation = Box<dyn FnOnce(&mut Database) + Send + 'static>;
enum Command {
    Run(Operation),
    Shutdown,
}

/// Cloneable asynchronous handle to one durable journal actor.
///
/// Use one actor/process per server/device database. The database may also be
/// used by the agent's history store, which owns a different SQLite connection.
#[derive(Clone)]
pub struct Journal {
    commands: mpsc::Sender<Command>,
    stopped: watch::Receiver<bool>,
    identity: std::sync::Arc<str>,
}

/// Proof that this owner-bound journal admitted a valid real `message.send`.
/// It grants no new execution authority, and is deliberately not deserializable.
/// The source payload itself is not duplicated into the provenance table.
#[derive(Clone, Debug)]
pub struct ProvenChatAnchor {
    message_id: String,
    conversation_id: String,
    payload_fingerprint: String,
    journal_identity: std::sync::Arc<str>,
}
impl ProvenChatAnchor {
    pub fn message_id(&self) -> &str {
        &self.message_id
    }
    pub fn input_id(&self) -> &str {
        &self.message_id
    }
    pub fn conversation_id(&self) -> &str {
        &self.conversation_id
    }
    pub fn payload_fingerprint(&self) -> &str {
        &self.payload_fingerprint
    }
    pub fn is_bound_to(&self, server_url: &str, device: &str, owner: &str) -> bool {
        let mut parts = self.journal_identity.rsplitn(3, '|');
        let (Some(saved_owner), Some(saved_device), Some(saved_server)) =
            (parts.next(), parts.next(), parts.next())
        else {
            return false;
        };
        if saved_owner != owner || saved_device != device {
            return false;
        }
        match (
            reqwest::Url::parse(saved_server),
            reqwest::Url::parse(server_url),
        ) {
            (Ok(a), Ok(b)) => a == b && matches!(a.scheme(), "ws" | "wss"),
            _ => false,
        }
    }
}

/// Read-only diagnostic snapshot of a single job. Request payloads and their
/// fingerprints are intentionally not returned.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalEntry {
    pub state: String,
    pub frame: Option<Value>,
    pub rejection_attempts: u64,
}

impl Journal {
    pub async fn open(path: &Path, identity: &str) -> Result<Self> {
        Self::open_with_capacity(path, identity, DEFAULT_QUEUE_CAPACITY).await
    }

    /// Opens, validates, and recovers the journal entirely on its actor thread.
    pub async fn open_with_capacity(path: &Path, identity: &str, capacity: usize) -> Result<Self> {
        ensure!(capacity > 0, "journal queue capacity must be positive");
        let path = path.to_path_buf();
        let identity = identity.to_owned();
        let bound_identity: std::sync::Arc<str> = identity.as_str().into();
        let (commands, mut receiver) = mpsc::channel(capacity);
        let (ready_tx, ready_rx) = oneshot::channel();
        let (stopped_tx, stopped) = watch::channel(false);
        std::thread::Builder::new()
            .name("orialis-journal".into())
            .spawn(move || {
                let mut database = match Database::open(&path, &identity) {
                    Ok(database) => database,
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                // A cancelled open must not leave an otherwise unreachable actor.
                if ready_tx.send(Ok(())).is_err() {
                    return;
                }
                while let Some(command) = receiver.blocking_recv() {
                    match command {
                        Command::Run(operation) => operation(&mut database),
                        // Closing stops new admission but preserves all operations
                        // already admitted (including outstanding queue permits).
                        Command::Shutdown => receiver.close(),
                    }
                }
                // Close/checkpoint SQLite on this thread, before shutdown returns.
                drop(database);
                let _ = stopped_tx.send(true);
            })
            .context("start journal actor")?;
        ready_rx
            .await
            .context("journal actor stopped during open")??;
        Ok(Self {
            commands,
            stopped,
            identity: bound_identity,
        })
    }

    // Reserve admission before cloning potentially large payloads. Waiting
    // callers retain only their existing borrows, not additional frame copies.
    async fn call<T, F, G>(&self, build: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce() -> G,
        G: FnOnce(&mut Database) -> Result<T> + Send + 'static,
    {
        let permit = self
            .commands
            .reserve()
            .await
            .map_err(|_| anyhow::anyhow!("journal actor is closed"))?;
        let operation = build();
        let (reply_tx, reply_rx) = oneshot::channel();
        permit.send(Command::Run(Box::new(move |database| {
            // Once admitted, finish the mutation even if its caller is cancelled.
            let result = operation(database);
            let _ = reply_tx.send(result);
        })));
        reply_rx
            .await
            .context("journal actor stopped during operation")?
    }

    /// Returns the existing state/frame, or `(new, None)` for newly claimed work.
    /// Only `retryable` requests may run again, with an identical fingerprint.
    pub async fn claim(&self, id: &str, payload: &Value) -> Result<(String, Option<Value>)> {
        self.call(|| {
            let id = id.to_owned();
            let payload = payload.clone();
            move |database: &mut Database| database.claim(&id, &payload)
        })
        .await
    }

    /// Returns only recorded inbound provenance, never infers it from a root
    /// string, synthetic turn, outgoing reply or a legacy row without evidence.
    pub async fn proven_chat_anchor(
        &self,
        message_id: &str,
        conversation_id: &str,
    ) -> Result<Option<ProvenChatAnchor>> {
        ensure!(
            !message_id.trim().is_empty() && message_id.len() <= 160,
            "invalid chat anchor ID"
        );
        ensure!(
            !conversation_id.trim().is_empty() && conversation_id.len() <= 160,
            "invalid chat anchor conversation"
        );
        self.call(|| {
            let message_id = message_id.to_owned();
            let conversation_id = conversation_id.to_owned();
            let journal_identity = self.identity.clone();
            move |database: &mut Database| {
                let fingerprint: Option<String> = database.connection.prepare_cached(
                    "SELECT p.payload_fingerprint FROM chat_input_provenance p JOIN jobs j ON j.id=p.job_id
                     WHERE p.job_id=?1 AND p.message_id=?2 AND p.conversation_id=?3
                     AND p.payload_fingerprint=j.fingerprint"
                )?.query_row(params![format!("chat:{message_id}"), message_id, conversation_id], |r| r.get(0)).optional()?;
                Ok(fingerprint.map(|payload_fingerprint| ProvenChatAnchor { message_id, conversation_id, payload_fingerprint, journal_identity }))
            }
        }).await
    }

    /// Inspect without claiming, retrying, acknowledging, or otherwise changing
    /// the job. `id` includes its `chat:` or `memory:` prefix.
    pub async fn inspect(&self, id: &str) -> Result<Option<JournalEntry>> {
        self.call(|| {
            let id = id.to_owned();
            move |database: &mut Database| {
                let row: Option<(String, Option<String>, u64)> = database
                    .connection
                    .prepare_cached(
                        "SELECT state,frame,COALESCE((SELECT attempts FROM delivery_failures
                         WHERE reply_id=json_extract(jobs.frame,'$.message_id')),0)
                         FROM jobs WHERE id=?1",
                    )?
                    .query_row([id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
                    .optional()?;
                row.map(|(state, frame, rejection_attempts)| {
                    Ok(JournalEntry {
                        state,
                        frame: frame.map(|text| serde_json::from_str(&text)).transpose()?,
                        rejection_attempts,
                    })
                })
                .transpose()
            }
        })
        .await
    }

    pub async fn finish(&self, id: &str, frame: &Value) -> Result<()> {
        self.call(|| {
            let id = id.to_owned();
            let frame = frame.clone();
            move |database: &mut Database| database.store_frame(&id, &frame, "ready")
        })
        .await
    }

    /// Race-safe host terminal commit. Cancellation and a completing model may
    /// compete, but an already prepared/delivered final is never overwritten.
    pub async fn finish_if_pending(&self, id: &str, frame: &Value) -> Result<bool> {
        let id = id.to_owned();
        let frame = serde_json::to_string(frame)?;
        self.call(|| move |db: &mut Database| Ok(db.connection.execute(
            "UPDATE jobs SET state='ready',frame=?1 WHERE id=?2 AND state IN ('running','queued','uncertain','retryable')",
            params![frame,id])? == 1)).await
    }
    /// The host must first verify its durable Core receipt and input identity.
    /// This never certifies whether a tool may safely run again by itself.
    pub async fn resume_uncertain(&self, id: &str) -> Result<bool> {
        let id = id.to_owned();
        self.call(|| {
            move |db: &mut Database| {
                Ok(db.connection.execute(
                    "UPDATE jobs SET state='running',frame=NULL WHERE id=?1 AND state='uncertain'",
                    [id],
                )? == 1)
            }
        })
        .await
    }

    pub async fn retryable_if_pending(&self, id: &str, frame: &Value) -> Result<bool> {
        let id = id.to_owned();
        let frame = serde_json::to_string(frame)?;
        self.call(|| move |db: &mut Database| Ok(db.connection.execute(
            "UPDATE jobs SET state='retryable',frame=?1 WHERE id=?2 AND state IN ('running','uncertain')",
            params![frame,id])? == 1)).await
    }

    pub async fn retryable(&self, id: &str, frame: &Value) -> Result<()> {
        self.call(|| {
            let id = id.to_owned();
            let frame = frame.clone();
            move |database: &mut Database| database.store_frame(&id, &frame, "retryable")
        })
        .await
    }

    /// Authoritative successful message receipt, used to reconcile ancillary
    /// stores after a crash between this commit and their acknowledgement.
    pub async fn is_delivered(&self, reply_id: &str) -> Result<bool> {
        let reply_id = reply_id.to_owned();
        self.call(|| move|db:&mut Database| Ok(db.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM jobs WHERE state='delivered' AND json_extract(frame,'$.message_id')=?1)",
            [reply_id],|r|r.get(0))?)).await
    }

    pub async fn ack(&self, reply_id: &str) -> Result<()> {
        self.call(|| {
            let reply_id = reply_id.to_owned();
            move |database: &mut Database| {
                database
                    .connection
                    .prepare_cached(ACK)?
                    .execute([reply_id])?;
                Ok(())
            }
        })
        .await
    }

    /// Records one rejection of a ready final. At most two original-frame
    /// retries are allowed. Duplicate errors during backoff have no effect.
    pub async fn reject(&self, reply_id: &str) -> Result<Option<Value>> {
        self.call(|| {
            let reply_id = reply_id.to_owned();
            move |database: &mut Database| database.reject(&reply_id)
        })
        .await
    }

    /// Atomically releases a retry backoff and checks whether a final still
    /// needs sending. A late ACK during backoff makes this return false.
    pub async fn prepare_reply_send(&self, reply_id: &str) -> Result<bool> {
        self.call(|| {
            let reply_id = reply_id.to_owned();
            move |database: &mut Database| database.prepare_reply_send(&reply_id)
        })
        .await
    }

    /// Records chat admission/start. `id` is the wire message ID, without `chat:`.
    pub async fn queued(&self, id: &str, state: &str) -> Result<()> {
        ensure!(matches!(state, "queued" | "running"), "invalid queue state");
        self.call(|| {
            let id = format!("chat:{id}");
            let state = state.to_owned();
            move |database: &mut Database| {
                database
                    .connection
                    .prepare_cached(
                        "UPDATE jobs SET state=?1 WHERE id=?2 AND state IN ('running','queued')",
                    )?
                    .execute(params![state, id])?;
                Ok(())
            }
        })
        .await
    }

    /// Replays unsent finals/results in original journal insertion order, even
    /// when the state index partitions ready and retry-wait rows differently.
    pub async fn replay(&self) -> Result<Vec<Value>> {
        self.call(|| {
            |database: &mut Database| {
                let mut statement = database.connection.prepare_cached(REPLAY)?;
                let mut rows = statement.query([])?;
                let mut frames = Vec::new();
                while let Some(row) = rows.next()? {
                    let text: String = row.get(0)?;
                    frames.push(serde_json::from_str(&text)?);
                }
                Ok(frames)
            }
        })
        .await
    }

    /// Bounded reconnect replay ordered by insertion. The cursor is an opaque
    /// SQLite row ID, not a delivery receipt or event sequence. New outgoing
    /// frames use the host channel; a new connection starts the cursor at zero.
    pub async fn replay_page(&self, after_rowid: i64, limit: usize) -> Result<Vec<(i64, Value)>> {
        anyhow::ensure!(
            after_rowid >= 0 && (1..=256).contains(&limit),
            "invalid journal replay page"
        );
        self.call(|| move |database:&mut Database| {
            let mut query=database.connection.prepare_cached("SELECT rowid,frame FROM jobs WHERE rowid>?1 AND state IN ('ready','retry_wait') ORDER BY rowid LIMIT ?2")?;
            let rows=query.query_map(params![after_rowid,limit as i64],|row|Ok((row.get::<_,i64>(0)?,row.get::<_,String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
            rows.into_iter().map(|(id,frame)|Ok((id,serde_json::from_str(&frame)?))).collect()
        }).await
    }

    /// Mark only work with possible external effects uncertain. Queued work
    /// never began and is safe to claim again with the same fingerprint.
    pub async fn interrupted(&self) -> Result<()> {
        self.call(|| {
            |database: &mut Database| {
                database
                    .connection
                    .prepare_cached(INTERRUPTED)?
                    .execute([])?;
                Ok(())
            }
        })
        .await
    }

    pub async fn error_sent(&self, id: &str) -> Result<()> {
        self.call(|| {
            let id = format!("chat:{id}");
            move |database: &mut Database| {
                database
                    .connection
                    .prepare_cached(
                        "UPDATE jobs SET state='delivered' WHERE id=?1 AND state!='retryable'",
                    )?
                    .execute([id])?;
                Ok(())
            }
        })
        .await
    }

    pub async fn memory_sent(&self, id: &str) -> Result<()> {
        self.call(|| {
            let id = format!("memory:{id}");
            move |database: &mut Database| {
                database
                    .connection
                    .prepare_cached("UPDATE jobs SET state='delivered' WHERE id=?1")?
                    .execute([id])?;
                Ok(())
            }
        })
        .await
    }

    /// Stop admission, drain accepted work, and close SQLite. Applies to all
    /// clones; repeated shutdown calls are safe. Dropping every handle also
    /// drains the actor, but only this method waits for the close to complete.
    pub async fn shutdown(&self) -> Result<()> {
        let _ = self.commands.send(Command::Shutdown).await;
        let mut stopped = self.stopped.clone();
        stopped
            .wait_for(|value| *value)
            .await
            .context("journal actor exited unexpectedly")?;
        Ok(())
    }
}

struct Database {
    connection: Connection,
}

impl Database {
    fn open(path: &Path, identity: &str) -> Result<Self> {
        let mut connection = crate::private_db::open_private(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")?;
        connection.set_prepared_statement_cache_capacity(32);
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(SCHEMA)?;
        let found: Option<String> = transaction
            .query_row(
                "SELECT identity FROM agent_identity WHERE id=1",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(found) = found {
            ensure!(
                found == identity,
                "database belongs to another server/device; use a separate --db"
            );
        } else {
            transaction.execute("INSERT INTO agent_identity VALUES(1,?1)", [identity])?;
        }
        // All baseline writes serialized JSON or NULL. A malformed legacy frame
        // fails this migration transaction instead of silently deleting evidence.
        transaction.execute_batch(INDEXES)?;
        transaction.execute(INTERRUPTED, [])?;
        transaction.commit()?;
        Ok(Self { connection })
    }

    fn claim(&mut self, id: &str, payload: &Value) -> Result<(String, Option<Value>)> {
        let fingerprint = crate::wire::digest(&serde_json::to_string(payload)?);
        let anchor = real_chat_source(id, payload);
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing: Option<(String, String, Option<String>)> = transaction
            .prepare_cached("SELECT fingerprint,state,frame FROM jobs WHERE id=?1")?
            .query_row([id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .optional()?;
        let result = if let Some((stored_fingerprint, state, frame)) = existing {
            ensure!(
                stored_fingerprint == fingerprint,
                "request ID reused with different evidence"
            );
            if state == "retryable" {
                transaction
                    .prepare_cached("UPDATE jobs SET state='running',frame=NULL WHERE id=?1")?
                    .execute([id])?;
                ("new".into(), None)
            } else {
                (
                    state,
                    frame.map(|text| serde_json::from_str(&text)).transpose()?,
                )
            }
        } else {
            transaction
                .prepare_cached("INSERT INTO jobs(id,fingerprint,state) VALUES(?1,?2,'running')")?
                .execute(params![id, fingerprint])?;
            ("new".into(), None)
        };
        if let Some((message_id, conversation_id)) = anchor {
            let old: Option<(String,String,String)> = transaction.query_row(
                "SELECT message_id,conversation_id,payload_fingerprint FROM chat_input_provenance WHERE job_id=?1",
                [id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
            if let Some(old) = old {
                ensure!(
                    old == (message_id, conversation_id, fingerprint),
                    "inbound chat provenance changed"
                );
            } else {
                transaction.execute(
                    "INSERT INTO chat_input_provenance VALUES(?1,?2,?3,?4)",
                    params![id, message_id, conversation_id, fingerprint],
                )?;
            }
        }
        transaction.commit()?;
        Ok(result)
    }

    fn store_frame(&mut self, id: &str, frame: &Value, state: &str) -> Result<()> {
        self.connection
            .prepare_cached("UPDATE jobs SET state=?1,frame=?2 WHERE id=?3")?
            .execute(params![state, serde_json::to_string(frame)?, id])?;
        Ok(())
    }

    fn reject(&mut self, reply_id: &str) -> Result<Option<Value>> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let frame: Option<String> = transaction
            .prepare_cached(REJECT_SELECT)?
            .query_row([reply_id], |row| row.get(0))
            .optional()?;
        let Some(frame) = frame else {
            transaction.commit()?;
            return Ok(None);
        };
        let frame = serde_json::from_str(&frame)?;
        transaction
            .prepare_cached(
                "INSERT INTO delivery_failures(reply_id,attempts) VALUES(?1,1)
             ON CONFLICT(reply_id) DO UPDATE SET attempts=attempts+1",
            )?
            .execute([reply_id])?;
        let attempts: i64 = transaction
            .prepare_cached("SELECT attempts FROM delivery_failures WHERE reply_id=?1")?
            .query_row([reply_id], |row| row.get(0))?;
        let retry = attempts <= 2;
        transaction.prepare_cached(REJECT_UPDATE)?.execute(params![
            if retry { "retry_wait" } else { "rejected" },
            reply_id
        ])?;
        transaction.commit()?;
        Ok(retry.then_some(frame))
    }

    fn prepare_reply_send(&mut self, reply_id: &str) -> Result<bool> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction
            .prepare_cached(PREPARE_UPDATE)?
            .execute([reply_id])?;
        let ready = transaction
            .prepare_cached(PREPARE_SELECT)?
            .query_row([reply_id], |row| row.get(0))?;
        transaction.commit()?;
        Ok(ready)
    }
}

fn real_chat_source(id: &str, payload: &Value) -> Option<(String, String)> {
    if payload["type"] != "message.send" {
        return None;
    }
    let message_id = payload["message_id"].as_str()?;
    let conversation_id = payload["conversation_id"].as_str()?;
    if id != format!("chat:{message_id}") || message_id.len() > 160 || conversation_id.len() > 160 {
        return None;
    }
    let mut checked = payload.clone();
    crate::wire::validate(&mut checked).ok()?;
    Some((message_id.into(), conversation_id.into()))
}

#[cfg(test)]
#[path = "journal_tests.rs"]
mod tests;
