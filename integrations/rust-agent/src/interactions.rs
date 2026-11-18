//! Turn-scoped clarification and one-use approval, with fail-closed crash recovery.
//! Durable rows contain only routing metadata and terminal status, never actions,
//! answers, credentials or a reusable grant. Restore cancellation, never approval.
use crate::tool_runtime::{ToolExecutor, TurnContext};
use anyhow::{Context, Result, bail, ensure};
use futures_util::future::BoxFuture;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, oneshot};

pub trait FeatureEmitter: Send + Sync {
    /// Must enqueue durably and preserve call order. A receipt is not consent.
    fn emit<'a>(&'a self, frame: Value) -> BoxFuture<'a, Result<()>>;
}
impl FeatureEmitter for crate::gateway_events::GatewayEvents {
    fn emit<'a>(&'a self, frame: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move { self.enqueue_feature(frame).await })
    }
}
#[derive(Clone)]
pub struct InteractionHub {
    inner: Arc<Inner>,
}
struct Inner {
    pending: Mutex<HashMap<String, Pending>>,
    leases: Mutex<Vec<(String, Weak<AtomicBool>)>>,
    emitter: Arc<dyn FeatureEmitter>,
    emit_lock: tokio::sync::Mutex<()>,
    journal: Journal,
    timeout: Duration,
    capacity: usize,
    closed: AtomicBool,
    flushing: AtomicBool,
}
struct Pending {
    record: Record,
    expires: Instant,
    multi: bool,
    live: Arc<AtomicBool>,
    sender: oneshot::Sender<Resolution>,
}
#[derive(Clone)]
struct Record {
    id: String,
    kind: String,
    conversation: String,
    input: String,
    session: String,
    expires_ms: i64,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Resolution {
    Answer(Value),
    Once,
    Denied,
    Cancelled,
    Disconnected,
    Expired,
}
struct WaitGuard {
    hub: InteractionHub,
    id: String,
}
impl Drop for WaitGuard {
    fn drop(&mut self) {
        self.hub.cancel_id(&self.id, Resolution::Cancelled);
    }
}
/// No Clone/Serialize; consumes one exact, unexpired grant from this live hub.
/// Cancellation/disconnection invalidates even a grant not yet consumed by host.
pub struct ApprovalPermit {
    digest: String,
    owner: Weak<Inner>,
    live: Arc<AtomicBool>,
    expires: Instant,
}
impl ApprovalPermit {
    pub fn verify(self, context: &TurnContext, action: &Value) -> Result<()> {
        ensure!(
            self.owner.strong_count() > 0
                && self.live.swap(false, Ordering::SeqCst)
                && Instant::now() < self.expires,
            "approval is expired or revoked"
        );
        ensure!(
            self.digest == binding(context, action)?,
            "approved action does not match execution"
        );
        Ok(())
    }
}
fn binding(c: &TurnContext, action: &Value) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&json!([
            c.conversation_id,
            c.input_id,
            c.session_id,
            action
        ]))?)
    ))
}
fn context_valid(c: &TurnContext) -> Result<()> {
    ensure!(
        [&c.conversation_id, &c.input_id, &c.session_id]
            .iter()
            .all(|s| !s.trim().is_empty() && s.len() <= 160 && !s.chars().any(char::is_control)),
        "interaction lacks trusted turn identity"
    );
    Ok(())
}
fn validate_scope(record: &Record, frame: &Value) -> Result<()> {
    let conversation = frame["conversation_id"]
        .as_str()
        .or_else(|| frame["session_id"].as_str())
        .context("interaction conversation missing")?;
    ensure!(
        record.conversation == conversation,
        "INTERACTION_SCOPE_MISMATCH"
    );
    for (key, expected) in [
        ("session_key", &record.session),
        ("reply_to", &record.input),
        ("run_id", &record.input),
    ] {
        if let Some(value) = frame.get(key) {
            ensure!(
                value.as_str() == Some(expected),
                "INTERACTION_SCOPE_MISMATCH"
            );
        }
    }
    Ok(())
}
fn response_fingerprint(record: &Record, frame: &Value) -> Result<String> {
    validate_scope(record, frame)?;
    ensure!(
        serde_json::to_vec(frame)?.len() <= 128 * 1024,
        "interaction reply too large"
    );
    let (kind, answer) = match frame["type"].as_str() {
        Some("clarify.resolve" | "clarify.response") if record.kind == "clarify" => {
            if let (Some(a), Some(b)) = (frame.get("answer"), frame.get("response")) {
                ensure!(a == b, "ambiguous clarification answer");
            }
            (
                "clarify.resolve",
                frame
                    .get("answer")
                    .or_else(|| frame.get("response"))
                    .context("clarification answer missing")?
                    .clone(),
            )
        }
        Some("clarify.cancel") if record.kind == "clarify" => ("clarify.cancel", Value::Null),
        Some("approval.resolve" | "approval.response") if record.kind == "approval" => {
            if let (Some(a), Some(b)) = (frame.get("decision"), frame.get("choice")) {
                ensure!(a == b, "ambiguous approval choice");
            }
            (
                "approval.resolve",
                frame
                    .get("decision")
                    .or_else(|| frame.get("choice"))
                    .context("approval choice missing")?
                    .clone(),
            )
        }
        _ => bail!("INTERACTION_TYPE_MISMATCH"),
    };
    // Transport event IDs/sequences may change during replay. Only the exact
    // semantic answer/decision and original trusted scope bind the receipt.
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&json!([
            record.id,
            record.conversation,
            record.input,
            record.session,
            kind,
            answer,
            frame.get("reason")
        ]))?)
    ))
}
fn wall_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

// All SQLite work belongs to this one blocking actor. Admission is synchronous,
// so cancellation immediately after sending a command cannot reorder its cleanup.
type DbJob = Box<dyn FnOnce(&mut Connection) + Send>;
enum DbCommand {
    Run(DbJob),
    Stop(oneshot::Sender<()>),
}
#[derive(Clone)]
struct Journal {
    commands: mpsc::UnboundedSender<DbCommand>,
}
fn lock_journal(path: &Path) -> Result<Option<std::fs::File>> {
    if path == Path::new(":memory:") {
        return Ok(None);
    }
    #[cfg(unix)]
    {
        use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "interaction journal already has a live owner"
        );
        Ok(Some(file))
    }
    #[cfg(not(unix))]
    {
        bail!("durable interaction journal requires Unix private-file locking")
    }
}
impl Journal {
    fn start(path: &Path, identity: &str) -> Result<(Self, oneshot::Receiver<Result<()>>)> {
        ensure!(
            !identity.trim().is_empty() && identity.len() <= 4096,
            "invalid interaction journal identity"
        );
        let identity = format!("{:x}", Sha256::digest(identity.as_bytes()));
        let path = path.to_owned();
        let (commands, mut rx) = mpsc::unbounded_channel::<DbCommand>();
        let (tx, ready) = oneshot::channel();
        std::thread::Builder::new().name("orialis-interactions".into()).spawn(move || {
            let opened = (|| -> Result<(Connection, Option<std::fs::File>)> {
                let db = crate::private_db::open_private(&path)?;
                let lock = lock_journal(&path)?;
                db.busy_timeout(Duration::from_secs(5))?;
                db.execute_batch("PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS interaction_identity(id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL); CREATE TABLE IF NOT EXISTS interactions(id TEXT PRIMARY KEY, kind TEXT NOT NULL, conversation TEXT NOT NULL, input TEXT NOT NULL, session TEXT NOT NULL, expires_ms INTEGER NOT NULL, state TEXT NOT NULL, updated_ms INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS interaction_receipts(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, ack TEXT NOT NULL);")?;
                let old: Option<String> = db.query_row("SELECT identity FROM interaction_identity WHERE id=1", [], |r| r.get(0)).optional()?;
                if let Some(old) = old { ensure!(old == identity, "interaction journal belongs to another account/device"); }
                else { db.execute("INSERT INTO interaction_identity VALUES(1,?1)", [identity])?; }
                // A process crash cannot resurrect a waiter or an authority.
                db.execute("UPDATE interactions SET state=CASE WHEN expires_ms<=?1 THEN 'timeout' ELSE 'cancelled' END,updated_ms=?1 WHERE state='pending'", [wall_ms()])?;
                Ok((db, lock))
            })();
            match opened {
                Ok((mut db, lock)) => { let _ = tx.send(Ok(())); while let Some(command) = rx.blocking_recv() { match command { DbCommand::Run(job) => job(&mut db), DbCommand::Stop(done) => { drop(db); drop(lock); let _ = done.send(()); return; } } } }
                Err(error) => { let _ = tx.send(Err(error)); }
            }
        })?;
        Ok((Self { commands }, ready))
    }
    fn submit<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<oneshot::Receiver<Result<T>>> {
        let (tx, rx) = oneshot::channel();
        self.commands
            .send(DbCommand::Run(Box::new(move |db| {
                let _ = tx.send(operation(db));
            })))
            .map_err(|_| anyhow::anyhow!("interaction journal stopped"))?;
        Ok(rx)
    }
    async fn call<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        self.submit(operation)?
            .await
            .context("interaction journal stopped")?
    }
    fn finish(&self, id: String, state: &'static str) -> Result<oneshot::Receiver<Result<()>>> {
        self.submit(move |db| {
            db.execute(
                "UPDATE interactions SET state=?2,updated_ms=?3 WHERE id=?1 AND state='pending'",
                params![id, state, wall_ms()],
            )?;
            Ok(())
        })
    }
}
impl InteractionHub {
    /// Ephemeral compatibility constructor, still using a nonblocking DB actor.
    /// Production callers must use `open` with an account/device-scoped private path.
    pub fn new(emitter: Arc<dyn FeatureEmitter>, timeout: Duration) -> Result<Self> {
        Self::construct(Path::new(":memory:"), "ephemeral", emitter, timeout).map(|(hub, _)| hub)
    }
    fn construct(
        path: &Path,
        identity: &str,
        emitter: Arc<dyn FeatureEmitter>,
        timeout: Duration,
    ) -> Result<(Self, oneshot::Receiver<Result<()>>)> {
        ensure!(
            timeout >= Duration::from_millis(1) && timeout <= Duration::from_secs(300),
            "interaction timeout must be 1ms..300s"
        );
        let (journal, ready) = Journal::start(path, identity)?;
        Ok((
            Self {
                inner: Arc::new(Inner {
                    pending: Mutex::new(HashMap::new()),
                    leases: Mutex::new(Vec::new()),
                    emitter,
                    emit_lock: tokio::sync::Mutex::new(()),
                    journal,
                    timeout,
                    capacity: 64,
                    closed: AtomicBool::new(false),
                    flushing: AtomicBool::new(false),
                }),
            },
            ready,
        ))
    }
    pub async fn open(
        path: &Path,
        identity: &str,
        emitter: Arc<dyn FeatureEmitter>,
        timeout: Duration,
    ) -> Result<Self> {
        let (hub, ready) = Self::construct(path, identity, emitter, timeout)?;
        ready
            .await
            .context("interaction journal failed to initialize")??;
        Ok(hub)
    }
    /// Stop new waits, revoke grants, durably enqueue cleanup, then close the DB.
    /// On cleanup failure leave the journal open so callers can reconnect/flush.
    pub async fn shutdown(&self) -> Result<()> {
        self.inner.closed.store(true, Ordering::SeqCst);
        self.disconnect();
        self.flush().await?;
        let (tx, rx) = oneshot::channel();
        self.inner
            .journal
            .commands
            .send(DbCommand::Stop(tx))
            .map_err(|_| anyhow::anyhow!("interaction journal stopped"))?;
        rx.await.context("interaction journal shutdown failed")
    }
    pub fn pending_count(&self) -> usize {
        self.inner.pending.lock().map_or(0, |p| p.len())
    }
    /// Call after capability negotiation and before transport outbox replay.
    /// Enqueues persisted terminal notifications in order; an interrupted enqueue
    /// may duplicate only cancellation, never an action or approval.
    pub async fn flush(&self) -> Result<()> {
        let _serial = self.inner.emit_lock.lock().await;
        let rows = self.inner.journal.call(|db| {
            let mut q = db.prepare("SELECT id,kind,conversation,input,session,expires_ms,state FROM interactions WHERE state IN ('cancelled','disconnected','timeout') ORDER BY updated_ms,id LIMIT 4096")?;
            Ok(q.query_map([], |r| Ok((Record { id:r.get(0)?,kind:r.get(1)?,conversation:r.get(2)?,input:r.get(3)?,session:r.get(4)?,expires_ms:r.get(5)? },r.get::<_,String>(6)?)))?.collect::<rusqlite::Result<Vec<_>>>()?)
        }).await?;
        for (r, state) in rows {
            let frame = if r.kind == "approval" {
                json!({"type":"approval.resolve","request_id":r.id,"conversation_id":r.conversation,"run_id":r.input,"reply_to":r.input,"decision":if state=="timeout" {"timeout"} else {"cancelled"},"reason":state})
            } else {
                json!({"type":"clarify.cancel","request_id":r.id,"conversation_id":r.conversation,"run_id":r.input,"reply_to":r.input,"reason":state})
            };
            tokio::time::timeout(Duration::from_secs(5), self.inner.emitter.emit(frame))
                .await
                .context("interaction cleanup enqueue timed out")??;
            self.inner
                .journal
                .call(move |db| {
                    db.execute(
                        "UPDATE interactions SET state='done',updated_ms=?2 WHERE id=?1",
                        params![r.id, wall_ms()],
                    )?;
                    Ok(())
                })
                .await?;
        }
        self.inner.journal.call(|db| { db.execute("DELETE FROM interactions WHERE state='done' AND id NOT IN (SELECT id FROM interactions WHERE state='done' ORDER BY updated_ms DESC LIMIT 512)", [])?; db.execute("DELETE FROM interaction_receipts WHERE id NOT IN (SELECT id FROM interactions)",[])?; Ok(()) }).await
    }
    fn schedule_flush(&self) {
        if let Ok(runtime) = tokio::runtime::Handle::try_current()
            && self
                .inner
                .flushing
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
        {
            let hub = self.clone();
            runtime.spawn(async move {
                let _ = hub.flush().await;
                hub.inner.flushing.store(false, Ordering::SeqCst);
            });
        }
    }
    fn cancel_id(&self, id: &str, resolution: Resolution) {
        let pending = self
            .inner
            .pending
            .lock()
            .ok()
            .and_then(|mut p| p.remove(id));
        if let Some(p) = pending {
            p.live.store(false, Ordering::SeqCst);
            let state = match resolution {
                Resolution::Expired => "timeout",
                Resolution::Disconnected => "disconnected",
                _ => "cancelled",
            };
            let _ = self.inner.journal.finish(id.to_owned(), state);
            let _ = p.sender.send(resolution);
            self.schedule_flush();
        }
    }
    async fn wait(
        &self,
        kind: &'static str,
        context: &TurnContext,
        mut frame: Value,
        multi: bool,
    ) -> Result<(Resolution, Arc<AtomicBool>, Instant)> {
        context_valid(context)?;
        ensure!(
            !self.inner.closed.load(Ordering::SeqCst),
            "interaction hub is closed"
        );
        let id = format!("{kind}_{}", uuid::Uuid::new_v4());
        let (sender, receiver) = oneshot::channel();
        let expires = Instant::now() + self.inner.timeout;
        let live = Arc::new(AtomicBool::new(true));
        let record = Record {
            id: id.clone(),
            kind: kind.into(),
            conversation: context.conversation_id.clone(),
            input: context.input_id.clone(),
            session: context.session_id.clone(),
            expires_ms: wall_ms().saturating_add(self.inner.timeout.as_millis() as i64),
        };
        {
            let mut pending = self
                .inner
                .pending
                .lock()
                .map_err(|_| anyhow::anyhow!("interaction state unavailable"))?;
            ensure!(
                !self.inner.closed.load(Ordering::SeqCst),
                "interaction hub is closed"
            );
            ensure!(
                pending.len() < self.inner.capacity,
                "too many pending interactions"
            );
            let mut leases = self
                .inner
                .leases
                .lock()
                .map_err(|_| anyhow::anyhow!("interaction state unavailable"))?;
            leases.retain(|(_, weak)| weak.strong_count() > 0);
            ensure!(
                leases.len() < self.inner.capacity * 2,
                "too many unconsumed interaction grants"
            );
            leases.push((context.conversation_id.clone(), Arc::downgrade(&live)));
            pending.insert(
                id.clone(),
                Pending {
                    record: record.clone(),
                    expires,
                    multi,
                    live: live.clone(),
                    sender,
                },
            );
        }
        let _guard = WaitGuard {
            hub: self.clone(),
            id: id.clone(),
        };
        let admission_live = live.clone();
        self.inner
            .journal
            .call(move |db| {
                ensure!(
                    admission_live.load(Ordering::SeqCst),
                    "interaction cancelled before durable admission"
                );
                let count: i64 = db.query_row(
                    "SELECT COUNT(*) FROM interactions WHERE state!='done'",
                    [],
                    |r| r.get(0),
                )?;
                ensure!(count < 4096, "interaction cleanup backlog full");
                db.execute(
                    "INSERT INTO interactions VALUES(?1,?2,?3,?4,?5,?6,'pending',?7)",
                    params![
                        record.id,
                        record.kind,
                        record.conversation,
                        record.input,
                        record.session,
                        record.expires_ms,
                        wall_ms()
                    ],
                )?;
                Ok(())
            })
            .await?;
        frame["type"] = json!(format!("{kind}.request"));
        frame["request_id"] = json!(id);
        frame["conversation_id"] = json!(context.conversation_id);
        frame["run_id"] = json!(context.input_id);
        frame["reply_to"] = json!(context.input_id);
        let deadline = tokio::time::Instant::from_std(expires);
        let emit = async {
            let _serial = self.inner.emit_lock.lock().await;
            ensure!(live.load(Ordering::SeqCst), "interaction already cancelled");
            self.inner.emitter.emit(frame).await
        };
        match tokio::time::timeout_at(deadline, emit).await {
            Ok(result) => result?,
            Err(_) => {
                self.cancel_id(&id, Resolution::Expired);
                return Ok((Resolution::Expired, live, expires));
            }
        }
        let result = match tokio::time::timeout_at(deadline, receiver).await {
            Ok(Ok(response)) => response,
            Ok(Err(_)) => Resolution::Cancelled,
            Err(_) => {
                self.cancel_id(&id, Resolution::Expired);
                Resolution::Expired
            }
        };
        Ok((result, live, expires))
    }
    pub async fn clarify(
        &self,
        context: &TurnContext,
        question: &str,
        choices: Option<&[String]>,
        multi: bool,
    ) -> Result<Resolution> {
        ensure!(
            !question.trim().is_empty() && question.len() <= 64 * 1024,
            "invalid clarification question"
        );
        if let Some(c) = choices {
            ensure!(
                c.len() <= 4
                    && c.iter()
                        .all(|s| !s.trim().is_empty() && s.chars().count() <= 8000),
                "invalid clarification choices"
            );
        }
        let multi = multi && choices.is_some_and(|c| !c.is_empty());
        let mut frame = json!({"question":question,"multi_select":multi});
        if let Some(c) = choices.filter(|c| !c.is_empty()) {
            frame["choices"] = json!(c);
        }
        Ok(self.wait("clarify", context, frame, multi).await?.0)
    }
    /// Only once/deny are supported. Do not pass raw secrets as display text.
    /// Known credential assignments/tokens are defensively redacted before wire.
    pub async fn approve(
        &self,
        context: &TurnContext,
        action: &Value,
        display: &str,
        description: &str,
    ) -> Result<ApprovalPermit> {
        ensure!(
            action.is_object()
                && serde_json::to_vec(action)?.len() <= 256 * 1024
                && !display.trim().is_empty()
                && display.len() <= 32 * 1024
                && description.len() <= 32 * 1024,
            "invalid approval action"
        );
        let digest = binding(context, action)?;
        let display = redact_display(display);
        let description = redact_display(description);
        let visible = format!(
            "{display}\n{description}\nOnly approve once or deny; session/always grants are unsupported."
        );
        let frame = json!({"action":visible,"details":{"description":description,"choices":["once","deny"]},"timeout_ms":self.inner.timeout.as_millis() as u64});
        let (response, live, expires) = self.wait("approval", context, frame, false).await?;
        match response {
            Resolution::Once => Ok(ApprovalPermit {
                owner: Arc::downgrade(&self.inner),
                digest,
                live,
                expires,
            }),
            other => bail!(
                "action was not approved: {}",
                match other {
                    Resolution::Denied => "denied",
                    Resolution::Expired => "expired",
                    Resolution::Disconnected => "disconnected",
                    _ => "cancelled",
                }
            ),
        }
    }
    /// Only call for authenticated server frames after transport deduplication.
    /// Durable consumption precedes waiter delivery, so a crash never re-grants.
    pub async fn resolve(&self, frame: &Value) -> Result<Value> {
        let id = frame["request_id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 160)
            .context("invalid interaction request_id")?;
        let kind = frame["type"].as_str().context("interaction type missing")?;
        let exists = self
            .inner
            .pending
            .lock()
            .map_err(|_| anyhow::anyhow!("interaction state unavailable"))?
            .contains_key(id);
        if !exists {
            return self.replay_receipt(id, frame).await;
        }

        let response;
        let entry;
        let fingerprint;
        {
            let mut pending = self
                .inner
                .pending
                .lock()
                .map_err(|_| anyhow::anyhow!("interaction state unavailable"))?;
            let p = pending.get(id).context("INTERACTION_NOT_PENDING")?;
            validate_scope(&p.record, frame)?;
            // Validate kind before expiry: an unrelated frame cannot consume it.
            if p.record.kind == "clarify" {
                ensure!(
                    ["clarify.response", "clarify.resolve", "clarify.cancel"].contains(&kind),
                    "INTERACTION_TYPE_MISMATCH"
                );
                response = if Instant::now() >= p.expires {
                    Resolution::Expired
                } else if kind == "clarify.cancel" {
                    Resolution::Cancelled
                } else {
                    let answer = frame
                        .get("answer")
                        .or_else(|| frame.get("response"))
                        .context("clarification answer missing")?;
                    if let (Some(a), Some(b)) = (frame.get("answer"), frame.get("response")) {
                        ensure!(a == b, "ambiguous clarification answer");
                    }
                    ensure!(
                        answer.is_string()
                            || (p.multi
                                && answer
                                    .as_array()
                                    .is_some_and(|a| a.iter().all(Value::is_string))),
                        "invalid clarification answer"
                    );
                    ensure!(
                        answer.to_string().len() <= 65536,
                        "clarification answer too large"
                    );
                    Resolution::Answer(answer.clone())
                };
            } else {
                ensure!(
                    ["approval.response", "approval.resolve"].contains(&kind),
                    "INTERACTION_TYPE_MISMATCH"
                );
                let choice = frame["decision"]
                    .as_str()
                    .or_else(|| frame["choice"].as_str())
                    .context("approval choice missing")?;
                if let (Some(a), Some(b)) = (frame.get("decision"), frame.get("choice")) {
                    ensure!(a == b, "ambiguous approval choice");
                }
                let proposed = match choice {
                    "once" => Resolution::Once,
                    "deny" => Resolution::Denied,
                    "timeout" => Resolution::Expired,
                    "cancelled" => Resolution::Cancelled,
                    _ => bail!("approval choice was not offered"),
                };
                response = if Instant::now() >= p.expires {
                    Resolution::Expired
                } else {
                    proposed
                };
            }
            fingerprint = response_fingerprint(&p.record, frame)?;
            entry = pending.remove(id).context("INTERACTION_NOT_PENDING")?;
        }
        let state = if response == Resolution::Expired {
            "timeout"
        } else {
            "done"
        };
        let ack = if response == Resolution::Expired {
            json!({"version":1,"type":"error","reply_to":id,"code":"INTERACTION_EXPIRED","message":"Interaction expired; no action was authorized"})
        } else {
            json!({"version":1,"type":"message.ack","message_id":id,"status":"resolved"})
        };
        let saved_ack = ack.to_string();
        let owned_id = id.to_owned();
        let committed = self.inner.journal.call(move |db| {
            let tx = db.transaction()?;
            ensure!(tx.execute("UPDATE interactions SET state=?2,updated_ms=?3 WHERE id=?1 AND state='pending'",params![owned_id,state,wall_ms()])? == 1,"interaction no longer pending durably");
            tx.execute("INSERT INTO interaction_receipts VALUES(?1,?2,?3)",params![owned_id,fingerprint,saved_ack])?;
            tx.commit()?; Ok(())
        }).await;
        if let Err(error) = committed {
            entry.live.store(false, Ordering::SeqCst);
            let _ = self.inner.journal.finish(id.to_owned(), "cancelled");
            self.schedule_flush();
            return Err(error);
        }
        if response != Resolution::Once {
            entry.live.store(false, Ordering::SeqCst);
        }
        ensure!(
            entry.sender.send(response).is_ok(),
            "INTERACTION_NOT_PENDING"
        );
        self.schedule_flush();
        Ok(ack)
    }
    async fn replay_receipt(&self, id: &str, frame: &Value) -> Result<Value> {
        let id = id.to_owned();
        let frame = frame.clone();
        self.inner.journal.call(move |db| {
            let row = db.query_row("SELECT i.kind,i.conversation,i.input,i.session,i.expires_ms,r.fingerprint,r.ack FROM interactions i JOIN interaction_receipts r ON r.id=i.id WHERE i.id=?1",[&id],|r|Ok((Record {id:id.clone(),kind:r.get(0)?,conversation:r.get(1)?,input:r.get(2)?,session:r.get(3)?,expires_ms:r.get(4)?},r.get::<_,String>(5)?,r.get::<_,String>(6)?))).optional()?.context("INTERACTION_NOT_PENDING")?;
            ensure!(response_fingerprint(&row.0,&frame)? == row.1,"INTERACTION_RESPONSE_MISMATCH");
            Ok(serde_json::from_str(&row.2)?)
        }).await
    }
    pub fn disconnect(&self) {
        self.cancel_matching(None, Resolution::Disconnected);
    }
    pub fn cancel_conversation(&self, conversation: &str) {
        self.cancel_matching(Some(conversation), Resolution::Cancelled);
    }
    fn cancel_matching(&self, conversation: Option<&str>, resolution: Resolution) {
        if let Ok(mut leases) = self.inner.leases.lock() {
            leases.retain(|(c, weak)| {
                if let Some(live) = weak.upgrade() {
                    if conversation.is_none_or(|target| target == c) {
                        live.store(false, Ordering::SeqCst);
                    }
                    true
                } else {
                    false
                }
            });
        }
        let ids = self
            .inner
            .pending
            .lock()
            .map(|p| {
                p.iter()
                    .filter(|(_, p)| conversation.is_none_or(|c| c == p.record.conversation))
                    .map(|(id, _)| id.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        for id in ids {
            self.cancel_id(&id, resolution.clone());
        }
    }
}
/// A defensive baseline, not a secret detector. Hosts should pass a safe summary
/// and never render raw command environments, HTTP headers or credential values.
pub fn redact_display(text: &str) -> String {
    static PATTERNS: std::sync::OnceLock<Vec<regex::Regex>> = std::sync::OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| [
        r#"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
        r#"(?i)\b[A-Za-z0-9_-]*(?:api[_-]?key|token|password|passwd|secret|authorization|cookie)["']?\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s;,]+)"#,
        r#"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|AKIA[A-Z0-9]{16})\b"#,
        r#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#,
        r#"https?://[^\s/@]+:[^\s/@]+@"#,
    ].into_iter().map(|p| regex::Regex::new(p).expect("static redaction regex")).collect());
    patterns.iter().fold(text.to_owned(), |s, p| {
        p.replace_all(&s, "[REDACTED]").into_owned()
    })
}
fn strip_recommended(value: &str) -> String {
    let value = value.trim();
    let label = "(Recommended)";
    if value
        .to_ascii_lowercase()
        .ends_with(&label.to_ascii_lowercase())
    {
        value[..value.len() - label.len()].trim().into()
    } else {
        value.into()
    }
}
pub struct ClarifyTool(pub InteractionHub);
impl ToolExecutor for ClarifyTool {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"clarify","description":"Ask 1–5 specific questions and wait for answers. Offer up to four choices; recommended choice first. Users may answer Other/free text. Cancellation is not an answer.","parameters":{"type":"object","properties":{"questions":{"type":"array","minItems":1,"maxItems":5,"items":{"type":"object","properties":{"question":{"type":"string","minLength":1},"choices":{"type":"array","maxItems":4,"items":{"type":"string","minLength":1}},"multi_select":{"type":"boolean"}},"required":["question"],"additionalProperties":false}}},"required":["questions"],"additionalProperties":false}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        args: Value,
        context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            ensure!(name == "clarify", "unknown interaction tool");
            let object = args
                .as_object()
                .context("clarify arguments must be object")?;
            ensure!(object.len() == 1, "unexpected clarify argument");
            let questions = args["questions"]
                .as_array()
                .context("questions must be array")?;
            ensure!(
                (1..=5).contains(&questions.len()),
                "questions must contain 1..5 items"
            );
            let mut normalized = Vec::new();
            // Validate the whole batch before exposing any user-facing question.
            for item in questions {
                let item = item.as_object().context("question must be object")?;
                ensure!(
                    item.keys()
                        .all(|k| ["question", "choices", "multi_select"].contains(&k.as_str())),
                    "unexpected question field"
                );
                let question = item
                    .get("question")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty() && s.len() <= 64 * 1024)
                    .context("invalid question text")?
                    .trim()
                    .to_owned();
                let choices = match item.get("choices") {
                    None | Some(Value::Null) => None,
                    Some(value) => {
                        let raw = value.as_array().context("choices must be array")?;
                        ensure!(raw.len() <= 4, "at most four choices");
                        let mut clean = Vec::new();
                        for c in raw {
                            let c = c.as_str().context("choice must be text")?.trim();
                            ensure!(!c.is_empty() && c.chars().count() <= 8000, "invalid choice");
                            ensure!(!clean.contains(&c.to_owned()), "duplicate choice");
                            clean.push(c.to_owned());
                        }
                        if clean.is_empty() { None } else { Some(clean) }
                    }
                };
                let multi = match item.get("multi_select") {
                    None => false,
                    Some(v) => v.as_bool().context("multi_select must be boolean")?,
                } && choices.is_some();
                normalized.push((question, choices, multi));
            }
            let mut responses = Vec::new();
            let mut outcome = "answered";
            for (question, choices, multi) in normalized {
                if outcome != "answered" {
                    responses.push(json!({"question":question,"choices_offered":choices,"status":"unanswered","user_response":null}));
                    continue;
                }
                let mut shown = choices.clone();
                if let Some(shown) = &mut shown
                    && shown.len() > 1
                    && strip_recommended(&shown[0]) == shown[0]
                {
                    shown[0].push_str(" (Recommended)");
                }
                let answer = self
                    .0
                    .clarify(context, &question, shown.as_deref(), multi)
                    .await;
                let (status, response) = match answer {
                    Ok(Resolution::Answer(value)) => {
                        let value = if multi {
                            let list = if let Some(a) = value.as_array() {
                                a.clone()
                            } else {
                                serde_json::from_str::<Vec<String>>(value.as_str().unwrap_or(""))
                                    .map(|a| a.into_iter().map(Value::String).collect())
                                    .unwrap_or(vec![value])
                            };
                            let mut clean = Vec::new();
                            for v in list {
                                if let Some(s) = v.as_str() {
                                    let s = strip_recommended(s);
                                    if !s.is_empty() && !clean.contains(&s) {
                                        clean.push(s);
                                    }
                                }
                            }
                            json!(clean)
                        } else {
                            json!(strip_recommended(value.as_str().unwrap_or("")))
                        };
                        if value == "" || value == json!([]) {
                            ("skipped", Value::Null)
                        } else {
                            ("answered", value)
                        }
                    }
                    other => {
                        outcome = match other {
                            Ok(Resolution::Expired) => "timeout",
                            Ok(Resolution::Disconnected) => "disconnected",
                            Err(_) => "unavailable",
                            _ => "cancelled",
                        };
                        ("unanswered", Value::Null)
                    }
                };
                responses.push(json!({"question":question,"choices_offered":choices,"status":status,"user_response":response}));
            }
            Ok(json!({"responses":responses,"outcome":outcome}))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;
    struct Emitter(mpsc::Sender<Value>);
    impl FeatureEmitter for Emitter {
        fn emit<'a>(&'a self, v: Value) -> BoxFuture<'a, Result<()>> {
            Box::pin(async move {
                self.0.send(v).await?;
                Ok(())
            })
        }
    }
    fn setup(ms: u64) -> (InteractionHub, mpsc::Receiver<Value>, TurnContext) {
        let (tx, rx) = mpsc::channel(8);
        let h = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_millis(ms)).unwrap();
        (
            h,
            rx,
            TurnContext {
                conversation_id: "conv".into(),
                input_id: "input".into(),
                session_id: "session".into(),
            },
        )
    }
    #[tokio::test]
    async fn wrong_scope_and_type_cannot_consume_waiter() -> Result<()> {
        let (h, mut rx, c) = setup(500);
        let h2 = h.clone();
        let job = tokio::spawn(async move { h2.clarify(&c, "Question?", None, false).await });
        let f = rx.recv().await.unwrap();
        let mut reply = json!({"type":"clarify.resolve","request_id":f["request_id"],"conversation_id":"other","response":"wrong"});
        assert!(h.resolve(&reply).await.is_err());
        assert_eq!(h.pending_count(), 1);
        reply["conversation_id"] = json!("conv");
        reply["type"] = json!("approval.resolve");
        reply["decision"] = json!("once");
        assert!(h.resolve(&reply).await.is_err());
        reply["type"] = json!("clarify.resolve");
        reply["response"] = json!("answer");
        assert_eq!(h.resolve(&reply).await?["status"], "resolved");
        assert_eq!(job.await??, Resolution::Answer(json!("answer")));
        assert_eq!(h.resolve(&reply).await?["status"], "resolved");
        assert_eq!(h.pending_count(), 0);
        Ok(())
    }
    #[tokio::test]
    async fn permission_is_one_exact_action_not_receipt() -> Result<()> {
        let (h, mut rx, c) = setup(500);
        let action = json!({"command":"printf hello","cwd":"allowed"});
        let h2 = h.clone();
        let c2 = c.clone();
        let a2 = action.clone();
        let job = tokio::spawn(async move {
            h2.approve(&c2, &a2, "printf hello", "Run in allowed workspace")
                .await
        });
        let f = rx.recv().await.unwrap();
        assert_eq!(f["details"]["choices"], json!(["once", "deny"]));
        assert!(h.resolve(&json!({"type":"message.ack","request_id":f["request_id"],"conversation_id":"conv","status":"received"})).await.is_err());
        assert!(h.resolve(&json!({"type":"approval.resolve","request_id":f["request_id"],"conversation_id":"conv","decision":"always"})).await.is_err());
        h.resolve(&json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"conv","decision":"once"})).await?;
        let permit = job.await??;
        assert!(permit.verify(&c, &json!({"command":"different"})).is_err());
        Ok(())
    }
    #[tokio::test]
    async fn cancellation_timeout_disconnect_all_fail_closed() -> Result<()> {
        let (h, mut rx, c) = setup(30);
        let h2 = h.clone();
        let c2 = c.clone();
        let job =
            tokio::spawn(
                async move { h2.approve(&c2, &json!({"command":"x"}), "x", "test").await },
            );
        rx.recv().await.unwrap();
        assert!(job.await?.is_err());
        assert_eq!(h.pending_count(), 0);
        h.flush().await?;
        while rx.try_recv().is_ok() {}
        let h2 = h.clone();
        let c2 = c.clone();
        let job = tokio::spawn(async move { h2.clarify(&c2, "q", None, false).await });
        rx.recv().await.unwrap();
        h.disconnect();
        assert_eq!(job.await??, Resolution::Disconnected);
        assert_eq!(h.pending_count(), 0);
        h.flush().await?;
        while rx.try_recv().is_ok() {}
        let h2 = h.clone();
        let job = tokio::spawn(async move { h2.clarify(&c, "q", None, false).await });
        rx.recv().await.unwrap();
        job.abort();
        let _ = job.await;
        assert_eq!(h.pending_count(), 0);
        Ok(())
    }
    #[tokio::test]
    async fn clarify_multi_and_skipped_remaining_shape() -> Result<()> {
        let (h, mut rx, c) = setup(500);
        let tool = ClarifyTool(h.clone());
        let job = tokio::spawn(async move {
            tool.execute("clarify",json!({"questions":[{"question":"Pick","choices":["A","B"],"multi_select":true},{"question":"Later"},{"question":"Never"}]}),&c).await
        });
        let f = rx.recv().await.unwrap();
        assert_eq!(f["choices"], json!(["A (Recommended)", "B"]));
        h.resolve(&json!({"type":"clarify.resolve","request_id":f["request_id"],"conversation_id":"conv","response":"[\"A (Recommended)\",\"B\"]"})).await?;
        let f = rx.recv().await.unwrap();
        h.resolve(
            &json!({"type":"clarify.cancel","request_id":f["request_id"],"conversation_id":"conv"}),
        )
        .await?;
        let out = job.await??;
        assert_eq!(out["outcome"], "cancelled");
        assert_eq!(out["responses"].as_array().unwrap().len(), 3);
        assert_eq!(out["responses"][0]["user_response"], json!(["A", "B"]));
        assert_eq!(out["responses"][2]["status"], "unanswered");
        Ok(())
    }
    #[tokio::test]
    async fn actual_event_outbox_request_is_sequenced() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let events = crate::gateway_events::GatewayEvents::open(
            &dir.path().join("event.sqlite"),
            "synthetic-owner",
        )
        .await?;
        events
            .enable_features(&[
                "clarify.request".into(),
                "clarify.resolve".into(),
                "clarify.cancel".into(),
            ])
            .await?;
        events.negotiate(&json!({"version":1,"type":"capabilities.ack","capabilities":["clarify.request","clarify.resolve","clarify.cancel"]})).await?;
        let h = InteractionHub::new(Arc::new(events.clone()), Duration::from_secs(1))?;
        let c = TurnContext {
            conversation_id: "conv".into(),
            input_id: "input".into(),
            session_id: "session".into(),
        };
        let h2 = h.clone();
        let job = tokio::spawn(async move { h2.clarify(&c, "Question", None, false).await });
        let frames = loop {
            let p = events.pending_after(0, 10).await?;
            if !p.is_empty() {
                break p;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        };
        assert_eq!(frames[0]["seq"], 1);
        assert_eq!(frames[0]["conversation_id"], "conv");
        assert_ne!(frames[0]["session_id"], "session");
        h.resolve(&json!({"type":"clarify.resolve","request_id":frames[0]["request_id"],"conversation_id":"conv","response":"yes"})).await?;
        assert_eq!(job.await??, Resolution::Answer(json!("yes")));
        events.shutdown().await?;
        Ok(())
    }
}

#[cfg(test)]
mod reliability_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    struct Capture {
        frames: Mutex<Vec<Value>>,
        fail: AtomicBool,
        calls: AtomicUsize,
    }
    impl Capture {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                frames: Mutex::new(Vec::new()),
                fail: AtomicBool::new(false),
                calls: AtomicUsize::new(0),
            })
        }
    }
    impl FeatureEmitter for Capture {
        fn emit<'a>(&'a self, frame: Value) -> BoxFuture<'a, Result<()>> {
            Box::pin(async move {
                self.calls.fetch_add(1, Ordering::SeqCst);
                ensure!(
                    !self.fail.load(Ordering::SeqCst),
                    "synthetic disconnected transport"
                );
                self.frames.lock().unwrap().push(frame);
                Ok(())
            })
        }
    }
    fn context() -> TurnContext {
        TurnContext {
            conversation_id: "chat".into(),
            input_id: "input".into(),
            session_id: "trusted-session".into(),
        }
    }
    async fn request(capture: &Capture) -> Value {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let Some(value) = capture
                    .frames
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|f| f["type"].as_str().unwrap().ends_with(".request"))
                    .cloned()
                {
                    return value;
                }
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn startup_recovers_only_cancellation_and_identity_is_exclusive() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("interactions.sqlite");
        let capture = Capture::new();
        let hub = InteractionHub::open(
            &path,
            "owner/device",
            capture.clone(),
            Duration::from_secs(1),
        )
        .await?;
        assert!(
            InteractionHub::open(
                &path,
                "owner/device",
                capture.clone(),
                Duration::from_secs(1)
            )
            .await
            .is_err()
        );
        hub.shutdown().await?;
        let db = Connection::open(&path)?;
        db.execute("INSERT INTO interactions VALUES('approval_crash','approval','chat','input','trusted-session',?1,'pending',0)",[wall_ms()+10000])?;
        db.execute("INSERT INTO interactions VALUES('clarify_crash','clarify','chat','input','trusted-session',0,'pending',0)",[])?;
        drop(db);
        let hub = InteractionHub::open(
            &path,
            "owner/device",
            capture.clone(),
            Duration::from_secs(1),
        )
        .await?;
        assert_eq!(hub.pending_count(), 0);
        assert!(capture.frames.lock().unwrap().is_empty());
        assert!(hub.resolve(&json!({"type":"approval.resolve","request_id":"approval_crash","session_id":"chat","decision":"once"})).await.is_err());
        hub.flush().await?;
        let frames = capture.frames.lock().unwrap().clone();
        assert_eq!(frames.len(), 2);
        assert!(
            frames
                .iter()
                .any(|f| f["type"] == "approval.resolve" && f["decision"] == "cancelled")
        );
        assert!(
            frames
                .iter()
                .any(|f| f["type"] == "clarify.cancel" && f["reason"] == "timeout")
        );
        hub.flush().await?;
        assert_eq!(capture.frames.lock().unwrap().len(), 2);
        hub.shutdown().await?;
        assert!(
            InteractionHub::open(
                &path,
                "another-owner/device",
                capture,
                Duration::from_secs(1)
            )
            .await
            .is_err()
        );
        Ok(())
    }
    #[tokio::test]
    async fn abort_and_disconnect_durable_cleanup_retries_without_authority() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("waits.sqlite");
        let capture = Capture::new();
        let hub =
            InteractionHub::open(&path, "owner", capture.clone(), Duration::from_secs(1)).await?;
        let h = hub.clone();
        let job = tokio::spawn(async move {
            h.clarify(&context(), "Private question not stored", None, false)
                .await
        });
        let frame = request(&capture).await;
        capture.fail.store(true, Ordering::SeqCst);
        job.abort();
        let _ = job.await;
        assert_eq!(hub.pending_count(), 0);
        assert!(hub.flush().await.is_err());
        let state = hub
            .inner
            .journal
            .call(|db| {
                Ok(db.query_row("SELECT state FROM interactions", [], |r| {
                    r.get::<_, String>(0)
                })?)
            })
            .await?;
        assert_eq!(state, "cancelled");
        assert!(hub.resolve(&json!({"type":"clarify.resolve","request_id":frame["request_id"],"session_id":"chat","answer":"late"})).await.is_err());
        capture.fail.store(false, Ordering::SeqCst);
        hub.flush().await?;
        assert_eq!(
            capture.frames.lock().unwrap().last().unwrap()["type"],
            "clarify.cancel"
        );
        let sql = std::fs::read(&path)?;
        assert!(!String::from_utf8_lossy(&sql).contains("Private question"));
        hub.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn granted_permit_revoked_on_cancel_and_bound_to_exact_turn() -> Result<()> {
        for mode in [
            "valid",
            "input",
            "session",
            "action",
            "disconnect",
            "cancel",
        ] {
            let capture = Capture::new();
            let hub = InteractionHub::new(capture.clone(), Duration::from_secs(1))?;
            let action = json!({"verb":"write","target":"exact-file"});
            let h = hub.clone();
            let a = action.clone();
            let job = tokio::spawn(async move {
                h.approve(&context(), &a, "write exact file", "Only this file")
                    .await
            });
            let f = request(&capture).await;
            hub.resolve(&json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"chat","decision":"once"})).await?;
            let permit = job.await??;
            let mut c = context();
            let mut a = action;
            match mode {
                "input" => c.input_id = "different-input".into(),
                "session" => c.session_id = "different-session".into(),
                "action" => a["target"] = json!("other-file"),
                "disconnect" => hub.disconnect(),
                "cancel" => hub.cancel_conversation("chat"),
                _ => {}
            }
            assert_eq!(permit.verify(&c, &a).is_ok(), mode == "valid", "{mode}");
            hub.shutdown().await?;
        }
        Ok(())
    }
    #[tokio::test]
    async fn malformed_ambiguous_and_wrong_turn_answers_leave_waiter_alive() -> Result<()> {
        let capture = Capture::new();
        let hub = InteractionHub::new(capture.clone(), Duration::from_secs(1))?;
        let h = hub.clone();
        let job = tokio::spawn(async move { h.clarify(&context(), "q", None, false).await });
        let f = request(&capture).await;
        for patch in [
            json!({"answer":["array-not-allowed"]}),
            json!({"answer":"x","response":"y"}),
            json!({"reply_to":"other","answer":"x"}),
            json!({"session_key":"other","answer":"x"}),
            json!({"run_id":"other","answer":"x"}),
        ] {
            let mut frame =
                json!({"type":"clarify.resolve","request_id":f["request_id"],"session_id":"chat"});
            frame
                .as_object_mut()
                .unwrap()
                .extend(patch.as_object().unwrap().clone());
            assert!(hub.resolve(&frame).await.is_err());
            assert_eq!(hub.pending_count(), 1);
        }
        hub.resolve(&json!({"type":"clarify.resolve","request_id":f["request_id"],"session_id":"chat","answer":"Other: custom text"})).await?;
        assert_eq!(job.await??, Resolution::Answer(json!("Other: custom text")));
        hub.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn whole_batch_validation_and_failed_transport_preserve_all_question_statuses()
    -> Result<()> {
        let capture = Capture::new();
        let hub = InteractionHub::new(capture.clone(), Duration::from_secs(1))?;
        let tool = ClarifyTool(hub.clone());
        assert!(tool.execute("clarify",json!({"questions":[{"question":"valid"},{"question":"later","choices":["a","b","c","d","e"]}]}),&context()).await.is_err());
        assert_eq!(capture.calls.load(Ordering::SeqCst), 0);
        capture.fail.store(true, Ordering::SeqCst);
        let result=tool.execute("clarify",json!({"questions":[{"question":"q1"},{"question":"q2"},{"question":"q3"},{"question":"q4"},{"question":"q5"}]}),&context()).await?;
        assert_eq!(result["outcome"], "unavailable");
        assert_eq!(result["responses"].as_array().unwrap().len(), 5);
        assert!(
            result["responses"]
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r["status"] == "unanswered")
        );
        capture.fail.store(false, Ordering::SeqCst);
        hub.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn credential_display_is_redacted_but_action_binding_is_original() -> Result<()> {
        let capture = Capture::new();
        let hub = InteractionHub::new(capture.clone(), Duration::from_secs(1))?;
        let h = hub.clone();
        let action =
            json!({"operation":"fetch","environment":{"OPENAI_API_KEY":"top-secret-value"}});
        let a = action.clone();
        let job = tokio::spawn(async move {
            h.approve(
                &context(),
                &a,
                "OPENAI_API_KEY=top-secret-value curl -H 'Authorization: Bearer testsecret123'",
                "password=secretpass https://u:pass@example.org",
            )
            .await
        });
        let f = request(&capture).await;
        let text = f.to_string();
        for secret in ["top-secret-value", "testsecret123", "secretpass", "u:pass"] {
            assert!(!text.contains(secret), "leaked {secret}");
        }
        assert_eq!(f["details"]["choices"], json!(["once", "deny"]));
        hub.resolve(&json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"chat","decision":"once"})).await?;
        job.await??.verify(&context(), &action)?;
        hub.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn durable_exact_receipt_replay_never_recreates_a_grant() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("receipts.sqlite");
        let capture = Capture::new();
        let hub = InteractionHub::open(
            &path,
            "owner/device",
            capture.clone(),
            Duration::from_secs(1),
        )
        .await?;
        let h = hub.clone();
        let job = tokio::spawn(async move {
            h.approve(
                &context(),
                &json!({"target":"one-file"}),
                "Write one file",
                "Exact action",
            )
            .await
        });
        let f = request(&capture).await;
        let frame = json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"chat","decision":"once","event_id":"original-event","seq":1});
        let ack = hub.resolve(&frame).await?;
        job.await??
            .verify(&context(), &json!({"target":"one-file"}))?;
        let mut replay = frame.clone();
        replay["event_id"] = json!("replayed-event");
        replay["seq"] = json!(99);
        assert_eq!(hub.resolve(&replay).await?, ack);
        assert_eq!(hub.pending_count(), 0);
        hub.shutdown().await?;
        let reopened =
            InteractionHub::open(&path, "owner/device", capture, Duration::from_secs(1)).await?;
        assert_eq!(reopened.resolve(&replay).await?, ack);
        assert_eq!(reopened.pending_count(), 0);
        for patch in [
            json!({"decision":"deny"}),
            json!({"session_id":"other-chat"}),
            json!({"session_key":"different-session"}),
            json!({"type":"clarify.resolve","answer":"no"}),
        ] {
            let mut bad = replay.clone();
            bad.as_object_mut()
                .unwrap()
                .extend(patch.as_object().unwrap().clone());
            assert!(reopened.resolve(&bad).await.is_err());
        }
        reopened.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn approval_expiry_blocks_late_permit_use_and_returns_correlated_error() -> Result<()> {
        let capture = Capture::new();
        let hub = InteractionHub::new(capture.clone(), Duration::from_millis(80))?;
        let h = hub.clone();
        let job = tokio::spawn(async move {
            h.approve(&context(), &json!({"target":"x"}), "x", "test")
                .await
        });
        let f = request(&capture).await;
        let response = json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"chat","decision":"once"});
        hub.resolve(&response).await?;
        let permit = job.await??;
        tokio::time::sleep(Duration::from_millis(85)).await;
        assert!(permit.verify(&context(), &json!({"target":"x"})).is_err());
        hub.shutdown().await?;
        let capture = Capture::new();
        let hub = InteractionHub::new(capture.clone(), Duration::from_secs(1))?;
        let h = hub.clone();
        let job = tokio::spawn(async move {
            h.approve(&context(), &json!({"target":"x"}), "x", "test")
                .await
        });
        let f = request(&capture).await;
        hub.inner
            .pending
            .lock()
            .unwrap()
            .get_mut(f["request_id"].as_str().unwrap())
            .unwrap()
            .expires = Instant::now() - Duration::from_secs(1);
        let response = json!({"type":"approval.resolve","request_id":f["request_id"],"session_id":"chat","decision":"once"});
        let ack = hub.resolve(&response).await?;
        assert_eq!(ack["type"], "error");
        assert_eq!(ack["code"], "INTERACTION_EXPIRED");
        assert!(job.await?.is_err());
        assert_eq!(hub.resolve(&response).await?, ack);
        hub.shutdown().await?;
        Ok(())
    }
}
