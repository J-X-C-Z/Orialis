//! Negotiated Orialis event-v1 lifecycle and durable device-wide sequencing.
//!
//! One actor owns SQLite; WAL/FULL commits never block the Tokio network workers.
//! Keep one instance per server/device, replay in sequence order through one WS
//! writer, and acknowledge only exact `event_id`/`seq` pairs. Event session IDs
//! identify the device's durable epoch, NOT individual chat sessions. Orialis
//! retires an earlier epoch when it sees a different one.
use crate::tool_runtime::{TurnContext, TurnEvent};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    path::Path,
    sync::Arc,
    time::Duration,
};
use tokio::sync::{Notify, mpsc, oneshot, watch};

/// Implemented output capabilities only. Parser support does not imply a host
/// approval, clarification, artifact or session-control workflow exists.
pub const CAPABILITIES: &[&str] = &[
    "agent.typing",
    "agent.start",
    "agent.delta",
    "agent.complete",
    "agent.error",
    "tool.started",
    "tool.completed",
    "tool.failed",
];
/// Optional host-owned interaction workflows. These are never enabled or
/// advertised by this module until the host explicitly registers them.
pub const FEATURE_CAPABILITIES: &[&str] = &[
    "clarify.request",
    "clarify.resolve",
    "clarify.cancel",
    "approval.request",
    "approval.resolve",
    "artifact.started",
    "artifact.progress",
    "artifact.completed",
    "artifact.failed",
];
pub const MAX_EVENT_TEXT: usize = 256 * 1024;
const MAX_ID: usize = 1024;
const MAX_FEATURE_RECEIPTS: usize = 100_000;

#[derive(Clone, Copy, Debug)]
pub struct EventLimits {
    pub max_events: usize,
    pub max_bytes: usize,
    pub actor_capacity: usize,
}
impl Default for EventLimits {
    fn default() -> Self {
        Self {
            max_events: 4096,
            max_bytes: 16 * 1024 * 1024,
            actor_capacity: 128,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AckOutcome {
    Accepted,
    /// An already removed or unrelated receipt. No state was changed.
    Ignored,
    /// Reset the connection's send cursor to `expected_seq - 1` and replay.
    ReplayFrom(u64),
}
#[derive(Clone, Debug)]
pub struct EventSnapshot {
    pub session_id: String,
    pub last_seq: u64,
    pub acknowledged_seq: u64,
    pub inbound_seq: u64,
    pub pending_events: usize,
    pub pending_completions: usize,
    pub retained_bytes: usize,
}

type Operation = Box<dyn FnOnce(&mut Database) + Send + 'static>;
enum Command {
    Run(Operation),
    Shutdown,
}

/// Cloneable durable event service. Cancellation after admission does not cancel
/// a transaction. Use `shutdown` to drain before process exit.
#[derive(Clone)]
pub struct GatewayEvents {
    commands: mpsc::Sender<Command>,
    stopped: watch::Receiver<bool>,
    changed: Arc<Notify>,
}
impl GatewayEvents {
    pub async fn open(path: &Path, identity: &str) -> Result<Self> {
        Self::open_with_limits(path, identity, EventLimits::default()).await
    }
    pub async fn open_with_limits(
        path: &Path,
        identity: &str,
        limits: EventLimits,
    ) -> Result<Self> {
        ensure!(
            limits.actor_capacity > 0 && limits.max_events > 0 && limits.max_bytes > 0,
            "event limits must be positive"
        );
        ensure!(
            limits.max_events <= i64::MAX as usize && limits.max_bytes <= i64::MAX as usize,
            "event limits exceed SQLite integer range"
        );
        text_field(identity, "event journal identity")?;
        let path = path.to_owned();
        let identity = identity.to_owned();
        let (commands, mut receiver) = mpsc::channel(limits.actor_capacity);
        let (ready_tx, ready_rx) = oneshot::channel();
        let (stopped_tx, stopped) = watch::channel(false);
        let changed = Arc::new(Notify::new());
        let notify = changed.clone();
        std::thread::Builder::new()
            .name("orialis-events".into())
            .spawn(move || {
                let mut database = match Database::open(&path, &identity, limits, notify) {
                    Ok(db) => db,
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                if ready_tx.send(Ok(())).is_err() {
                    return;
                }
                while let Some(command) = receiver.blocking_recv() {
                    match command {
                        Command::Run(operation) => operation(&mut database),
                        Command::Shutdown => receiver.close(),
                    }
                }
                drop(database);
                let _ = stopped_tx.send(true);
            })
            .context("start event journal actor")?;
        ready_rx
            .await
            .context("event journal actor stopped during open")??;
        Ok(Self {
            commands,
            stopped,
            changed,
        })
    }
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
            .context("event journal actor closed")?;
        let operation = build();
        let (tx, rx) = oneshot::channel();
        permit.send(Command::Run(Box::new(move |db| {
            let result = operation(db);
            let _ = tx.send(result);
        })));
        rx.await
            .context("event journal actor stopped during operation")?
    }
    /// Wake a single transport writer. Always drain `pending_after` before
    /// waiting. Notify retains a permit if an enqueue raced with that wait.
    pub async fn notified(&self) {
        self.changed.notified().await;
    }
    pub async fn shutdown(&self) -> Result<()> {
        if !*self.stopped.borrow() {
            let _ = self.commands.send(Command::Shutdown).await;
        }
        let mut stopped = self.stopped.clone();
        while !*stopped.borrow() {
            stopped.changed().await.context("event actor shutdown")?;
        }
        Ok(())
    }
    pub async fn snapshot(&self) -> Result<EventSnapshot> {
        self.call(|| |db: &mut Database| db.snapshot()).await
    }
    /// The resume cursor is for SERVER -> client events, not our outgoing seq.
    /// This implementation advertises no incoming interactive workflows, so it
    /// stays zero unless a host explicitly commits a supported inbound event.
    pub async fn capabilities_hello(&self, extra_capabilities: &[String]) -> Result<Value> {
        self.call(|| { let extra = extra_capabilities.to_vec(); move |db: &mut Database| {
            let mut caps: Vec<String> = CAPABILITIES.iter().map(|s| (*s).into()).collect();
            let mut features: Vec<_> = db.features.iter().cloned().collect(); features.sort(); caps.extend(features);
            for cap in extra { if !caps.contains(&cap) { caps.push(cap); } }
            ensure!(caps.len() <= 64, "too many capabilities");
            let cursor: u64 = db.connection.query_row("SELECT inbound_seq FROM gateway_event_state WHERE id=1", [], |r| r.get(0))?;
            Ok(json!({"version":1,"type":"capabilities.hello","capabilities":caps,"resume_from":cursor}))
        }}).await
    }
    /// Call for each fresh hello_ack, then capabilities.ack. An omitted/empty
    /// capability list disables events. Exact event names are required: broad
    /// `streaming`/`tool_state` hints cannot authorize unsupported event types.
    pub async fn negotiate(&self, ack: &Value) -> Result<()> {
        self.call(|| {
            let ack = ack.clone();
            move |db: &mut Database| {
                ensure!(
                    ack["version"] == 1
                        && matches!(ack["type"].as_str(), Some("hello_ack" | "capabilities.ack")),
                    "invalid capability acknowledgement"
                );
                let values = ack.get("capabilities").or_else(|| ack.get("features"));
                let mut capabilities = HashSet::new();
                if let Some(values) = values {
                    let values = values.as_array().context("capabilities must be array")?;
                    ensure!(values.len() <= 128, "too many server capabilities");
                    for value in values {
                        let name = value.as_str().context("capability must be string")?;
                        ensure!(
                            !name.trim().is_empty() && name.len() <= 120,
                            "invalid capability name"
                        );
                        capabilities.insert(name.to_owned());
                    }
                }
                // next_seq and resume_from refer to the SERVER outbound sequence.
                // Never overwrite our persistent device-wide counter with them.
                if let Some(next) = ack.get("next_seq") {
                    ensure!(
                        next.as_u64().is_some_and(|n| n > 0),
                        "invalid server next_seq"
                    );
                }
                if let Some(cursor) = ack.get("resume_from") {
                    ensure!(cursor.as_u64().is_some(), "invalid server resume cursor");
                }
                db.peer_capabilities = capabilities;
                db.refresh_capabilities();
                db.flush_completions()?;
                db.flush_interrupted()?;
                Ok(())
            }
        })
        .await
    }
    /// Register only interaction handlers that the host actually implements.
    /// Call before advertising hello/capabilities.hello. Registration does not
    /// itself negotiate or authorize a user action. The host owns request IDs,
    /// response validation, pending state, deadlines and deny/timeout behavior.
    pub async fn enable_features(&self, capabilities: &[String]) -> Result<()> {
        self.call(|| {
            let capabilities = capabilities.to_vec();
            move |db: &mut Database| {
                ensure!(
                    capabilities
                        .iter()
                        .all(|c| FEATURE_CAPABILITIES.contains(&c.as_str())),
                    "unsupported optional event capability"
                );
                db.features.extend(capabilities);
                db.refresh_capabilities();
                Ok(())
            }
        })
        .await
    }
    /// Enqueue an explicitly enabled, negotiated host feature using the same
    /// durable device-wide sequence as streaming/typing/tools. Sequence metadata
    /// is exclusively actor-owned and must not appear in caller input.
    pub async fn enqueue_feature(&self, frame: Value) -> Result<()> {
        self.call(|| {
            move |db: &mut Database| {
                db.validate_feature_input(&frame)?;
                db.enqueue(&[frame])
            }
        })
        .await
    }
    /// Cross-database handoff: bind a caller's durable source identity to one
    /// immutable payload and sequence transaction. A crash after this commit but
    /// before the source marks its event transferred cannot duplicate publication.
    /// Receipts survive event ACK/pruning. On receipt capacity exhaustion this
    /// fails closed; callers retain their source event and keep final delivery.
    pub async fn enqueue_feature_once(&self, source_key: &str, frame: Value) -> Result<()> {
        let source_key = source_key.to_owned();
        text_field(&source_key, "feature source key")?;
        self.call(|| {
            move |db: &mut Database| {
                db.validate_feature_input(&frame)?;
                let digest = format!("{:x}", Sha256::digest(serde_json::to_vec(&frame)?));
                let tx = db
                    .connection
                    .transaction_with_behavior(TransactionBehavior::Immediate)?;
                let prior: Option<String> = tx
                    .query_row(
                        "SELECT payload_hash FROM gateway_feature_receipts WHERE source_key=?1",
                        [&source_key],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(prior) = prior {
                    ensure!(
                        prior == digest,
                        "feature source identity reused with different payload"
                    );
                    return Ok(());
                }
                let count: usize =
                    tx.query_row("SELECT COUNT(*) FROM gateway_feature_receipts", [], |r| {
                        r.get(0)
                    })?;
                ensure!(
                    count < MAX_FEATURE_RECEIPTS,
                    "feature receipt capacity exhausted; source event retained"
                );
                queue_tx(&tx, &[frame], db.limits)?;
                tx.execute(
                    "INSERT INTO gateway_feature_receipts(source_key,payload_hash) VALUES(?1,?2)",
                    params![source_key, digest],
                )?;
                tx.commit()?;
                db.changed.notify_one();
                Ok(())
            }
        })
        .await
    }
    /// Query the current exact negotiated capability. A host can avoid opening
    /// an SSE provider stream when the legacy peer has no agent.delta support.
    pub async fn supports(&self, capability: &str) -> Result<bool> {
        self.call(|| {
            let capability = capability.to_owned();
            move |db: &mut Database| Ok(db.capabilities.contains(&capability))
        })
        .await
    }
    /// Durable pending completions for reconciliation against the host's reply
    /// journal. After reconnect/startup, confirm those whose chat:<input_id>
    /// journal entry is delivered and has this exact final message ID. This
    /// closes the crash window between journal ACK and event confirmation.
    pub async fn completion_candidates(&self) -> Result<Vec<(String, String)>> {
        self.call(|| |db: &mut Database| {
            let mut query=db.connection.prepare_cached("SELECT json_extract(frame,'$.reply_to'),message_id FROM gateway_event_completions ORDER BY rowid")?;
            Ok(query.query_map([], |row| Ok((row.get(0)?,row.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?)
        }).await
    }
    pub async fn commit_inbound(&self, seq: u64) -> Result<()> {
        self.call(|| {
            move |db: &mut Database| {
                ensure!(
                    seq > 0 && seq <= i64::MAX as u64,
                    "invalid inbound sequence"
                );
                let old: u64 = db.connection.query_row(
                    "SELECT inbound_seq FROM gateway_event_state WHERE id=1",
                    [],
                    |r| r.get(0),
                )?;
                ensure!(
                    seq <= old.saturating_add(1),
                    "gap in applied inbound events"
                );
                db.connection.execute(
                    "UPDATE gateway_event_state SET inbound_seq=MAX(inbound_seq,?1) WHERE id=1",
                    [seq],
                )?;
                Ok(())
            }
        })
        .await
    }
    /// Sequence-ordered, bounded replay. A changed peer that no longer supports
    /// a retained event is an explicit error, never a silently skipped seq.
    pub async fn pending_after(&self, after_seq: u64, limit: usize) -> Result<Vec<Value>> {
        ensure!(
            limit > 0 && limit <= 4096,
            "event replay page must be 1..4096"
        );
        self.call(|| move |db: &mut Database| {
            let mut query = db.connection.prepare_cached("SELECT frame FROM gateway_event_outbox WHERE acknowledged=0 AND seq>?1 ORDER BY seq LIMIT ?2")?;
            let frames = query.query_map(params![after_seq, limit], |row| row.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            frames.into_iter().map(|frame| {
                let value: Value = serde_json::from_str(&frame)?;
                ensure!(db.capabilities.contains(value["type"].as_str().unwrap_or("")), "peer no longer supports retained event; preserve outbox and use final-message fallback");
                Ok(value)
            }).collect()
        }).await
    }
    pub async fn acknowledge(&self, ack: &Value) -> Result<AckOutcome> {
        self.call(|| {
            let ack = ack.clone();
            move |db: &mut Database| db.acknowledge(&ack)
        })
        .await
    }
    /// Call ONLY for message.ack.status=received for the exact sent final reply.
    /// Persist the receipt even if event capacity is exhausted. Publication is
    /// retried as earlier event receipts free space and after renegotiation.
    pub async fn confirm_message(&self, message_id: &str) -> Result<()> {
        self.call(|| {
            let id = message_id.to_owned();
            move |db: &mut Database| {
                text_field(&id, "message_id")?;
                db.connection.execute(
                    "UPDATE gateway_event_completions SET confirmed=1 WHERE message_id=?1",
                    [id],
                )?;
                db.flush_completions()
            }
        })
        .await
    }
    async fn enqueue(&self, templates: &[Value]) -> Result<()> {
        self.call(|| {
            let templates = templates.to_vec();
            move |db: &mut Database| db.enqueue(&templates)
        })
        .await
    }
    async fn defer_completion(&self, frame: &Value) -> Result<()> {
        self.call(|| {
            let frame = frame.clone();
            move |db: &mut Database| db.defer_completion(&frame)
        })
        .await
    }
    /// Starts one isolated run. Its protocol session comes from the durable
    /// device journal; `TurnContext.session_id` is a history identifier only.
    pub async fn begin_run(&self, context: &TurnContext) -> Result<RunEvents> {
        text_field(&context.conversation_id, "conversation_id")?;
        text_field(&context.input_id, "input_id")?;
        let mut run = RunEvents {
            events: self.clone(),
            context: context.clone(),
            run_id: format!("run_{}", uuid::Uuid::new_v4().simple()),
            content: String::new(),
            rewritten: false,
            started: false,
            stopped: false,
            terminal: false,
            tools: HashMap::new(),
        };
        run.observe(TurnEvent::Started).await?;
        Ok(run)
    }
}

/// Own one of these per turn, never behind a shared global current-run variable.
pub struct RunEvents {
    events: GatewayEvents,
    context: TurnContext,
    run_id: String,
    content: String,
    rewritten: bool,
    started: bool,
    stopped: bool,
    terminal: bool,
    tools: HashMap<String, bool>,
}
impl RunEvents {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn content(&self) -> &str {
        &self.content
    }
    fn frame(&self, kind: &str) -> Value {
        json!({"type":kind,"conversation_id":self.context.conversation_id,"reply_to":self.context.input_id,"run_id":self.run_id})
    }
    fn typing(&self, typing: bool) -> Value {
        let mut frame = self.frame("agent.typing");
        frame["typing"] = json!(typing);
        frame
    }
    /// Bridge the actual provider/tool observer. Delta means a new incremental
    /// token fragment. Use `snapshot` explicitly for cumulative upstream text.
    pub async fn observe(&mut self, event: TurnEvent) -> Result<()> {
        ensure!(!self.terminal, "event after terminal run");
        match event {
            TurnEvent::Started => {
                if !self.started {
                    self.events
                        .enqueue(&[self.frame("agent.start"), self.typing(true)])
                        .await?;
                    self.started = true;
                }
            }
            TurnEvent::Delta(delta) => self.append(&delta).await?,
            TurnEvent::ToolStarted { id, name } => {
                text_field(&id, "tool_call_id")?;
                text_field(&name, "tool_name")?;
                if !self.tools.contains_key(&id) {
                    let mut frame = self.frame("tool.started");
                    frame["tool_call_id"] = json!(format!("{}:{id}", self.run_id));
                    frame["tool_name"] = json!(name);
                    self.events.enqueue(&[frame]).await?;
                    self.tools.insert(id, false);
                }
            }
            TurnEvent::ToolCompleted {
                id,
                name: _,
                failed,
            } => {
                ensure!(
                    self.tools.contains_key(&id),
                    "completion for unknown tool call"
                );
                if self.tools[&id] {
                    return Ok(());
                }
                let mut frame = self.frame(if failed {
                    "tool.failed"
                } else {
                    "tool.completed"
                });
                frame["tool_call_id"] = json!(format!("{}:{id}", self.run_id));
                if failed {
                    frame["code"] = json!("TOOL_FAILED");
                    frame["message"] = json!("Tool execution failed");
                }
                self.events.enqueue(&[frame]).await?;
                self.tools.insert(id, true);
            }
            // Generation complete is not persistence complete. The actual
            // message.ack releases the staged agent.complete later.
            TurnEvent::Completed => self.stop_typing().await?,
        }
        Ok(())
    }
    /// Emit negotiated activity while a real run is still executing, including
    /// long provider/tool waits. The host should call every 15 seconds, below
    /// the server's 60-second idle deadline. This does not extend its 15-minute
    /// total limit and stops after generation/completion/error.
    pub async fn heartbeat(&mut self) -> Result<()> {
        if self.started && !self.stopped && !self.terminal {
            self.events.enqueue(&[self.typing(true)]).await?;
        }
        Ok(())
    }
    async fn stop_typing(&mut self) -> Result<()> {
        if !self.stopped {
            self.events.enqueue(&[self.typing(false)]).await?;
            self.stopped = true;
        }
        Ok(())
    }
    pub async fn append(&mut self, delta: &str) -> Result<()> {
        ensure!(
            !self.terminal && !self.stopped,
            "delta after generation ended"
        );
        ensure!(
            self.content.len().saturating_add(delta.len()) <= MAX_EVENT_TEXT,
            "stream text exceeds event bound"
        );
        if delta.is_empty() {
            return Ok(());
        }
        if !self.rewritten {
            let mut frame = self.frame("agent.delta");
            frame["delta"] = json!(delta);
            self.events.enqueue(&[frame]).await?;
        }
        self.content.push_str(delta);
        Ok(())
    }
    /// Cumulative snapshots emit only the new UTF-8 suffix. Once an upstream
    /// rewrite occurs, append previews stop; authoritative completion replaces
    /// the old preview. Repeated snapshots cannot duplicate tokens.
    pub async fn snapshot(&mut self, content: &str) -> Result<()> {
        ensure!(
            !self.terminal && !self.stopped,
            "snapshot after generation ended"
        );
        ensure!(
            content.len() <= MAX_EVENT_TEXT,
            "stream text exceeds event bound"
        );
        let rewritten = self.rewritten || !content.starts_with(&self.content);
        if !rewritten && content.len() > self.content.len() {
            let mut frame = self.frame("agent.delta");
            frame["delta"] = json!(&content[self.content.len()..]);
            self.events.enqueue(&[frame]).await?;
        }
        self.rewritten = rewritten;
        self.content = content.to_owned();
        Ok(())
    }
    /// Stage before sending a durable final message.reply. Pass its exact stored
    /// ID and authoritative content. No agent.complete is emitted until
    /// GatewayEvents::confirm_message observes the server's persistence receipt.
    pub async fn defer_completion(&mut self, message_id: &str, content: &str) -> Result<()> {
        ensure!(!self.terminal, "run already finalized");
        text_field(message_id, "message_id")?;
        ensure!(
            content.len() <= MAX_EVENT_TEXT,
            "final event text exceeds bound"
        );
        self.stop_typing().await?;
        let mut frame = self.frame("agent.complete");
        frame["message_id"] = json!(message_id);
        frame["content"] = json!(content);
        self.events.defer_completion(&frame).await?;
        self.content = content.to_owned();
        self.terminal = true;
        Ok(())
    }
    pub async fn fail(&mut self, code: &str, message: &str) -> Result<()> {
        if self.terminal {
            return Ok(());
        }
        text_field(code, "error code")?;
        text_field(message, "error message")?;
        let mut frame = self.frame("agent.error");
        frame["code"] = json!(code);
        frame["message"] = json!(message);
        let mut frames = Vec::new();
        if !self.stopped {
            frames.push(self.typing(false));
        }
        frames.push(frame);
        self.events.enqueue(&frames).await?;
        self.stopped = true;
        self.terminal = true;
        Ok(())
    }
}

struct Database {
    connection: Connection,
    limits: EventLimits,
    capabilities: HashSet<String>,
    peer_capabilities: HashSet<String>,
    features: HashSet<String>,
    changed: Arc<Notify>,
}
impl Database {
    fn open(
        path: &Path,
        identity: &str,
        limits: EventLimits,
        changed: Arc<Notify>,
    ) -> Result<Self> {
        let connection = crate::private_db::open_private(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS gateway_event_state(id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL, session_id TEXT NOT NULL, last_seq INTEGER NOT NULL DEFAULT 0, acknowledged_seq INTEGER NOT NULL DEFAULT 0, inbound_seq INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS gateway_event_outbox(seq INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE, frame TEXT NOT NULL, bytes INTEGER NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS gateway_event_completions(message_id TEXT PRIMARY KEY, frame TEXT NOT NULL, bytes INTEGER NOT NULL, confirmed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS gateway_event_runs(run_id TEXT PRIMARY KEY, frame TEXT NOT NULL, needs_recovery INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS gateway_feature_receipts(source_key TEXT PRIMARY KEY, payload_hash TEXT NOT NULL);")?;
        connection.execute(
            "INSERT OR IGNORE INTO gateway_event_state(id,identity,session_id) VALUES(1,?1,?2)",
            params![
                identity,
                format!("session_{}", uuid::Uuid::new_v4().simple())
            ],
        )?;
        let existing: String = connection.query_row(
            "SELECT identity FROM gateway_event_state WHERE id=1",
            [],
            |r| r.get(0),
        )?;
        ensure!(
            existing == identity,
            "event journal belongs to a different server/device"
        );
        // A prior process ended without a completion/error. Preserve sequence
        // and epoch and close its preview after fresh capability negotiation.
        connection.execute("UPDATE gateway_event_runs SET needs_recovery=1", [])?;
        Ok(Self {
            connection,
            limits,
            capabilities: HashSet::new(),
            peer_capabilities: HashSet::new(),
            features: HashSet::new(),
            changed,
        })
    }
    fn validate_feature_input(&self, frame: &Value) -> Result<()> {
        ensure!(frame.is_object(), "feature frame must be object");
        for key in ["version", "event_id", "seq", "session_id", "sequence"] {
            ensure!(
                frame.get(key).is_none(),
                "feature caller cannot supply {key}"
            );
        }
        let kind = frame["type"].as_str().context("feature type required")?;
        ensure!(self.features.contains(kind), "feature handler not enabled");
        ensure!(
            self.capabilities.contains(kind),
            "feature not negotiated by peer"
        );
        validate_feature(frame)
    }
    fn refresh_capabilities(&mut self) {
        self.capabilities = self
            .peer_capabilities
            .iter()
            .filter(|c| CAPABILITIES.contains(&c.as_str()) || self.features.contains(c.as_str()))
            .cloned()
            .collect();
    }
    fn snapshot(&self) -> Result<EventSnapshot> {
        let (session_id,last_seq,acknowledged_seq,inbound_seq) = self.connection.query_row("SELECT session_id,last_seq,acknowledged_seq,inbound_seq FROM gateway_event_state WHERE id=1", [], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
        let (count, bytes) = usage(&self.connection)?;
        let completions: usize = self.connection.query_row(
            "SELECT COUNT(*) FROM gateway_event_completions",
            [],
            |r| r.get(0),
        )?;
        Ok(EventSnapshot {
            session_id,
            last_seq,
            acknowledged_seq,
            inbound_seq,
            pending_events: count - completions,
            pending_completions: completions,
            retained_bytes: bytes,
        })
    }
    fn enqueue(&mut self, templates: &[Value]) -> Result<()> {
        let enabled: Vec<_> = templates
            .iter()
            .filter(|value| {
                self.capabilities
                    .contains(value["type"].as_str().unwrap_or(""))
            })
            .cloned()
            .collect();
        let terminals: Vec<_> = templates
            .iter()
            .filter(|f| f["type"] == "agent.error")
            .collect();
        if enabled.is_empty() && terminals.is_empty() {
            return Ok(());
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        queue_tx(&tx, &enabled, self.limits)?;
        for terminal in terminals {
            tx.execute(
                "DELETE FROM gateway_event_runs WHERE run_id=?1",
                [terminal["run_id"].as_str().context("run_id required")?],
            )?;
        }
        tx.commit()?;
        self.changed.notify_one();
        Ok(())
    }
    fn defer_completion(&mut self, frame: &Value) -> Result<()> {
        if !self.capabilities.contains("agent.complete") {
            self.connection.execute(
                "DELETE FROM gateway_event_runs WHERE run_id=?1",
                [frame["run_id"].as_str().context("run_id required")?],
            )?;
            return Ok(());
        }
        validate_template(frame)?;
        let id = frame["message_id"]
            .as_str()
            .context("completion missing message_id")?;
        let serialized = serde_json::to_string(frame)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let prior: Option<String> = tx
            .query_row(
                "SELECT frame FROM gateway_event_completions WHERE message_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(prior) = prior {
            ensure!(prior == serialized, "conflicting final completion identity");
            return Ok(());
        }
        // Reserve space for the sequencing fields added when confirmed.
        let reserved = serialized.len() + 256;
        let (count, bytes) = usage(&tx)?;
        ensure!(
            count < self.limits.max_events
                && bytes.saturating_add(reserved) <= self.limits.max_bytes,
            "event outbox capacity exhausted"
        );
        tx.execute(
            "INSERT INTO gateway_event_completions(message_id,frame,bytes) VALUES(?1,?2,?3)",
            params![id, serialized, reserved],
        )?;
        tx.execute(
            "DELETE FROM gateway_event_runs WHERE run_id=?1",
            [frame["run_id"].as_str().context("run_id required")?],
        )?;
        tx.commit()?;
        Ok(())
    }
    fn flush_completions(&mut self) -> Result<()> {
        if !self.capabilities.contains("agent.complete") {
            return Ok(());
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let rows = {
            let mut q = tx.prepare("SELECT message_id,frame FROM gateway_event_completions WHERE confirmed=1 ORDER BY rowid")?;
            q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for (id, frame) in &rows {
            let frame = serde_json::from_str(frame)?;
            tx.execute(
                "DELETE FROM gateway_event_completions WHERE message_id=?1",
                [id],
            )?;
            queue_tx(&tx, &[frame], self.limits)?;
        }
        tx.commit()?;
        if !rows.is_empty() {
            self.changed.notify_one();
        }
        Ok(())
    }
    fn flush_interrupted(&mut self) -> Result<()> {
        if !self.capabilities.contains("agent.error") {
            return Ok(());
        }
        let pending = {
            let mut q = self.connection.prepare(
                "SELECT frame FROM gateway_event_runs WHERE needs_recovery=1 ORDER BY rowid",
            )?;
            q.query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for serialized in pending {
            let mut error: Value = serde_json::from_str(&serialized)?;
            for key in ["event_id", "seq", "session_id", "version"] {
                error
                    .as_object_mut()
                    .context("invalid interrupted run")?
                    .remove(key);
            }
            error["type"] = json!("agent.error");
            error["code"] = json!("PROCESS_INTERRUPTED");
            error["message"] = json!(
                "Agent process ended before this run completed; tool side effects were not retried"
            );
            let mut frames = Vec::new();
            if self.capabilities.contains("agent.typing") {
                let mut typing = error.clone();
                typing["type"] = json!("agent.typing");
                typing["typing"] = json!(false);
                typing.as_object_mut().unwrap().remove("code");
                typing.as_object_mut().unwrap().remove("message");
                frames.push(typing);
            }
            frames.push(error);
            let (count, bytes) = usage(&self.connection)?;
            let reserve: usize = frames
                .iter()
                .map(|f| serde_json::to_string(f).map(|s| s.len() + 256))
                .collect::<serde_json::Result<Vec<_>>>()?
                .iter()
                .sum();
            // The old outbox drains first. Never drop a preview event or allocate
            // a sequence hole to make room for the recovery terminal event.
            if count.saturating_add(frames.len()) > self.limits.max_events
                || bytes.saturating_add(reserve) > self.limits.max_bytes
            {
                break;
            }
            self.enqueue(&frames)?;
        }
        Ok(())
    }
    fn acknowledge(&mut self, ack: &Value) -> Result<AckOutcome> {
        ensure!(
            ack["version"] == 1 && ack["type"] == "agent.ack",
            "invalid agent acknowledgement"
        );
        let id = ack["event_id"].as_str().context("ack event_id required")?;
        text_field(id, "event_id")?;
        let seq = ack["seq"]
            .as_u64()
            .filter(|n| *n > 0 && *n <= i64::MAX as u64)
            .context("ack seq must be positive")?;
        let status = ack["status"].as_str().context("ack status required")?;
        ensure!(
            matches!(status, "received" | "duplicate" | "gap" | "unknown"),
            "invalid agent acknowledgement status"
        );
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored: Option<String> = tx
            .query_row(
                "SELECT event_id FROM gateway_event_outbox WHERE seq=?1",
                [seq],
                |r| r.get(0),
            )
            .optional()?;
        if stored.as_deref() != Some(id) {
            return Ok(AckOutcome::Ignored);
        }
        if status == "unknown" {
            bail!(
                "server rejected known event; preserve outbox and reconnect or diagnose stale session"
            );
        }
        if status == "gap" {
            let expected = ack["expected_seq"]
                .as_u64()
                .filter(|n| *n > 0 && *n <= seq)
                .context("invalid expected_seq in gap acknowledgement")?;
            let (first,last,count): (Option<u64>,Option<u64>,u64) = tx.query_row("SELECT MIN(seq),MAX(seq),COUNT(*) FROM gateway_event_outbox WHERE seq>=?1 AND seq<=?2", params![expected,seq], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
            ensure!(
                first == Some(expected) && last == Some(seq) && count == seq - expected + 1,
                "unrecoverable event gap: expected sequence already pruned; do not renumber events"
            );
            tx.execute(
                "UPDATE gateway_event_outbox SET acknowledged=0 WHERE seq>=?1",
                [expected],
            )?;
            tx.commit()?;
            self.changed.notify_one();
            return Ok(AckOutcome::ReplayFrom(expected));
        }
        tx.execute(
            "UPDATE gateway_event_outbox SET acknowledged=1 WHERE seq=?1",
            [seq],
        )?;
        let (old, last): (u64, u64) = tx.query_row(
            "SELECT acknowledged_seq,last_seq FROM gateway_event_state WHERE id=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let first: Option<u64> = tx.query_row(
            "SELECT MIN(seq) FROM gateway_event_outbox WHERE acknowledged=0",
            [],
            |r| r.get(0),
        )?;
        let through = first.map_or(last, |n| n - 1).max(old);
        tx.execute(
            "UPDATE gateway_event_state SET acknowledged_seq=?1 WHERE id=1",
            [through],
        )?;
        tx.execute(
            "DELETE FROM gateway_event_outbox WHERE seq<=?1 AND acknowledged=1",
            [through],
        )?;
        tx.commit()?;
        self.flush_completions()?;
        self.flush_interrupted()?;
        Ok(AckOutcome::Accepted)
    }
}
fn usage(db: &Connection) -> Result<(usize, usize)> {
    Ok(db.query_row("SELECT (SELECT COUNT(*) FROM gateway_event_outbox)+(SELECT COUNT(*) FROM gateway_event_completions), (SELECT COALESCE(SUM(bytes),0) FROM gateway_event_outbox)+(SELECT COALESCE(SUM(bytes),0) FROM gateway_event_completions)", [], |r| Ok((r.get(0)?,r.get(1)?)))?)
}
fn queue_tx(tx: &Transaction<'_>, templates: &[Value], limits: EventLimits) -> Result<()> {
    let (mut seq, session): (u64, String) = tx.query_row(
        "SELECT last_seq,session_id FROM gateway_event_state WHERE id=1",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let (mut count, mut bytes) = usage(tx)?;
    for template in templates {
        validate_template(template)?;
        ensure!(seq < i64::MAX as u64, "event sequence exhausted");
        seq += 1;
        let id = format!("evt_{}", uuid::Uuid::new_v4().simple());
        let mut frame = template.clone();
        frame["version"] = json!(1);
        frame["event_id"] = json!(id);
        frame["seq"] = json!(seq);
        frame["session_id"] = json!(session);
        let serialized = serde_json::to_string(&frame)?;
        count += 1;
        bytes = bytes.saturating_add(serialized.len());
        ensure!(
            count <= limits.max_events && bytes <= limits.max_bytes,
            "event outbox capacity exhausted"
        );
        tx.execute(
            "INSERT INTO gateway_event_outbox(seq,event_id,frame,bytes) VALUES(?1,?2,?3,?4)",
            params![seq, id, serialized, serialized.len()],
        )?;
        if template["type"] == "agent.start" {
            let active: usize =
                tx.query_row("SELECT COUNT(*) FROM gateway_event_runs", [], |r| r.get(0))?;
            ensure!(
                active < limits.max_events,
                "active event run capacity exhausted"
            );
            tx.execute(
                "INSERT INTO gateway_event_runs(run_id,frame) VALUES(?1,?2)",
                params![
                    template["run_id"].as_str().context("run_id required")?,
                    serialized
                ],
            )?;
        } else if template["type"] == "agent.error" {
            tx.execute(
                "DELETE FROM gateway_event_runs WHERE run_id=?1",
                [template["run_id"].as_str().context("run_id required")?],
            )?;
        }
    }
    tx.execute(
        "UPDATE gateway_event_state SET last_seq=?1 WHERE id=1",
        [seq],
    )?;
    Ok(())
}
fn text_field(text: &str, field: &str) -> Result<()> {
    ensure!(
        !text.trim().is_empty() && text.len() <= MAX_ID,
        "invalid {field}"
    );
    Ok(())
}
fn validate_template(frame: &Value) -> Result<()> {
    let kind = frame["type"].as_str().context("event type required")?;
    if FEATURE_CAPABILITIES.contains(&kind) {
        return validate_feature(frame);
    }
    ensure!(CAPABILITIES.contains(&kind), "unimplemented event type");
    for field in ["run_id", "conversation_id"] {
        text_field(
            frame[field].as_str().context("event context missing")?,
            field,
        )?;
    }
    for field in ["content", "delta", "message"] {
        if let Some(v) = frame.get(field) {
            ensure!(
                v.as_str().is_some_and(|s| s.len() <= MAX_EVENT_TEXT),
                "event text exceeds bound"
            );
        }
    }
    if kind == "agent.delta" {
        ensure!(
            frame["delta"].as_str().is_some_and(|s| !s.is_empty()),
            "empty delta"
        );
    }
    if kind == "agent.typing" {
        ensure!(frame["typing"].is_boolean(), "invalid typing state");
    }
    if kind.starts_with("tool.") {
        text_field(
            frame["tool_call_id"]
                .as_str()
                .context("tool_call_id required")?,
            "tool_call_id",
        )?;
    }
    if kind == "tool.started" {
        text_field(
            frame["tool_name"].as_str().context("tool_name required")?,
            "tool_name",
        )?;
    }
    if kind.ends_with("error") || kind.ends_with("failed") {
        text_field(
            frame["code"].as_str().context("error code required")?,
            "code",
        )?;
        text_field(
            frame["message"]
                .as_str()
                .context("error message required")?,
            "message",
        )?;
    }
    if kind == "agent.complete" {
        text_field(
            frame["message_id"]
                .as_str()
                .context("final message_id required")?,
            "message_id",
        )?;
        ensure!(frame["content"].is_string(), "completion content required");
    }
    Ok(())
}

fn validate_artifact(frame: &Value, kind: &str) -> Result<()> {
    text_field(
        frame["conversation_id"]
            .as_str()
            .context("artifact conversation required")?,
        "conversation_id",
    )?;
    let fields: &[&str] = match kind {
        "artifact.started" | "artifact.completed" => &["artifact"],
        "artifact.progress" => &["artifact_id", "progress"],
        "artifact.failed" => &["artifact_id", "code", "message", "metadata"],
        _ => bail!("unsupported artifact type"),
    };
    for key in frame
        .as_object()
        .context("artifact frame must be object")?
        .keys()
    {
        ensure!(
            ["type", "conversation_id"].contains(&key.as_str()) || fields.contains(&key.as_str()),
            "unsupported artifact frame field"
        );
    }
    if let Some(artifact) = frame.get("artifact") {
        let object = artifact.as_object().context("artifact must be object")?;
        for key in object.keys() {
            ensure!(
                [
                    "id",
                    "kind",
                    "name",
                    "mime_type",
                    "size",
                    "uri",
                    "download_url",
                    "sha256",
                    "metadata"
                ]
                .contains(&key.as_str()),
                "unsupported artifact metadata field"
            );
        }
        for field in ["id", "kind"] {
            text_field(
                artifact[field]
                    .as_str()
                    .context("artifact identity required")?,
                field,
            )?;
        }
        let kind = artifact["kind"].as_str().unwrap().to_ascii_lowercase();
        ensure!(
            !["audio", "video", "voice"].contains(&kind.as_str()),
            "audio/video artifacts unsupported by server"
        );
        for field in ["name", "mime_type", "uri", "download_url", "sha256"] {
            if let Some(value) = artifact.get(field) {
                text_field(value.as_str().context("invalid artifact text")?, field)?;
            }
        }
        if let Some(mime) = artifact["mime_type"].as_str() {
            let mime = mime.to_ascii_lowercase();
            ensure!(
                !mime.starts_with("audio/") && !mime.starts_with("video/"),
                "audio/video artifact MIME unsupported"
            );
        }
        if let Some(size) = artifact.get("size") {
            ensure!(
                size.as_i64().is_some_and(|n| n >= 0),
                "artifact size must be nonnegative i64"
            );
        }
    } else {
        text_field(
            frame["artifact_id"]
                .as_str()
                .context("artifact_id required")?,
            "artifact_id",
        )?;
        if kind == "artifact.progress" {
            ensure!(
                frame.get("progress").is_some(),
                "artifact progress required"
            );
        }
        if kind == "artifact.failed" {
            text_field(
                frame["code"]
                    .as_str()
                    .context("artifact error code required")?,
                "code",
            )?;
            ensure!(
                frame["message"]
                    .as_str()
                    .is_some_and(|m| !m.trim().is_empty() && m.len() <= MAX_EVENT_TEXT),
                "artifact error message required"
            );
        }
    }
    Ok(())
}

fn validate_feature(frame: &Value) -> Result<()> {
    let kind = frame["type"].as_str().context("feature type required")?;
    ensure!(
        FEATURE_CAPABILITIES.contains(&kind),
        "unimplemented feature type"
    );
    ensure!(
        serde_json::to_vec(frame)?.len() <= MAX_EVENT_TEXT,
        "feature payload exceeds bound"
    );
    if kind.starts_with("artifact.") {
        return validate_artifact(frame, kind);
    }
    for field in ["request_id", "conversation_id"] {
        text_field(
            frame[field].as_str().context("feature context missing")?,
            field,
        )?;
    }
    for field in ["run_id", "reply_to"] {
        if let Some(value) = frame.get(field) {
            text_field(
                value.as_str().context("feature identity must be string")?,
                field,
            )?;
        }
    }
    let allowed: &[&str] = match kind {
        "clarify.request" => &["question", "choices", "multi_select"],
        "clarify.resolve" => &["answer"],
        "clarify.cancel" => &["reason"],
        "approval.request" => &["action", "details", "timeout_ms"],
        "approval.resolve" => &["decision", "reason"],
        _ => unreachable!(),
    };
    for key in frame.as_object().context("feature must be object")?.keys() {
        ensure!(
            [
                "type",
                "conversation_id",
                "request_id",
                "run_id",
                "reply_to"
            ]
            .contains(&key.as_str())
                || allowed.contains(&key.as_str()),
            "unsupported field in feature request"
        );
    }
    if let Some(reason) = frame.get("reason") {
        ensure!(
            reason.as_str().is_some_and(|s| s.len() <= MAX_EVENT_TEXT),
            "invalid feature reason"
        );
    }
    match kind {
        "clarify.request" => {
            ensure!(
                frame["question"]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty() && s.len() <= MAX_EVENT_TEXT),
                "clarification question required"
            );
            if let Some(choices) = frame.get("choices") {
                let choices = choices
                    .as_array()
                    .context("clarify choices must be array")?;
                ensure!(
                    choices.len() <= 32
                        && choices
                            .iter()
                            .all(|v| v.as_str().is_some_and(|s| !s.trim().is_empty())),
                    "invalid clarify choices"
                );
            }
            if let Some(multi) = frame.get("multi_select") {
                ensure!(multi.is_boolean(), "multi_select must be boolean");
            }
        }
        // The release Rust server requires `answer`, whereas the historical
        // Python helper emits `response`. Use the actual server contract.
        "clarify.resolve" => ensure!(
            frame.get("answer").is_some(),
            "clarify.resolve requires answer"
        ),
        "approval.request" => {
            ensure!(
                frame["action"]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty() && s.len() <= MAX_EVENT_TEXT),
                "approval action required"
            );
            if let Some(timeout) = frame.get("timeout_ms") {
                ensure!(
                    timeout
                        .as_u64()
                        .is_some_and(|n| (1..=86_400_000).contains(&n)),
                    "approval timeout out of range"
                );
            }
        }
        "approval.resolve" => ensure!(
            matches!(
                frame["decision"].as_str(),
                Some("once" | "session" | "always" | "deny" | "timeout" | "cancelled")
            ),
            "invalid approval decision"
        ),
        "clarify.cancel" => {}
        _ => unreachable!(),
    }
    Ok(())
}
