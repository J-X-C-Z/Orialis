//! Durable, opt-in parent continuations. This queue never calls a provider or a
//! tool. Only a started claim exposes the trusted seed accepted by Core.
use crate::{
    Core,
    delegation::{BackgroundCompletion, CompletionSendPermit, DelegationRuntime},
    delivery::OwnedDatabase,
    journal::Journal,
    session_context::TurnLookup,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, RwLock, Semaphore};

pub(crate) const PARENT_CONTINUATION_MARKER: &str = "_orialis_parent_continuation";
const FUNCTION: &str = "delegate_task_completion";
const INPUT_PREFIX: &str = "parent-continuation-";

#[derive(Clone, Debug)]
pub struct ContinuationConfig {
    pub enabled: bool,
    /// Retained identities are never evicted to permit a duplicate execution.
    pub max_records: usize,
    pub max_input_bytes: usize,
    pub max_final_bytes: usize,
    pub max_depth: usize,
    pub max_runs_per_root: usize,
    pub max_active_runs: usize,
    pub run_timeout: Duration,
}
impl Default for ContinuationConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            max_records: 8192,
            max_input_bytes: 64 * 1024,
            max_final_bytes: 256 * 1024,
            max_depth: 2,
            max_runs_per_root: 8,
            max_active_runs: 4,
            run_timeout: Duration::from_secs(600),
        }
    }
}
impl ContinuationConfig {
    fn validate(&self) -> Result<()> {
        ensure!(
            (1..=100_000).contains(&self.max_records),
            "invalid continuation retention limit"
        );
        ensure!(
            (4096..=128 * 1024).contains(&self.max_input_bytes)
                && (1024..=1024 * 1024).contains(&self.max_final_bytes),
            "invalid continuation byte limits"
        );
        ensure!(
            (1..=8).contains(&self.max_depth) && (1..=128).contains(&self.max_runs_per_root),
            "invalid continuation lineage limits"
        );
        ensure!(
            (1..=32).contains(&self.max_active_runs),
            "invalid continuation active run limit"
        );
        ensure!(
            !self.run_timeout.is_zero() && self.run_timeout <= Duration::from_secs(3600),
            "invalid continuation timeout"
        );
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContinuationState {
    Queued,
    Claimed,
    Running,
    Interrupted,
    FinalCommitted,
    Enqueued,
    Suppressed,
    Uncertain,
    Unavailable,
}
impl ContinuationState {
    fn parse(s: &str) -> Result<Self> {
        Ok(serde_json::from_value(json!(s))?)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContinuationRecord {
    pub notification_id: String,
    pub input_id: String,
    pub parent_input_id: String,
    pub session_id: String,
    pub conversation_id: String,
    pub generation: i64,
    pub root_input_id: String,
    pub depth: usize,
    pub state: ContinuationState,
    pub final_assistant: Option<Value>,
    pub reason: Option<String>,
    source_digest: String,
    messages: Vec<Value>,
}
impl ContinuationRecord {
    pub fn durable_input(&self) -> Value {
        durable_input(self)
    }
}
struct Inner {
    db: Arc<OwnedDatabase>,
    owner_fingerprint: String,
    runtime: DelegationRuntime,
    cfg: ContinuationConfig,
    // Bound spawn_blocking admission, including calls whose futures are dropped.
    operations: Arc<Semaphore>,
    gate: Arc<RwLock<()>>,
    blocked: Mutex<BTreeSet<String>>,
    changed: Notify,
    closed: AtomicBool,
}
#[derive(Clone)]
pub struct ParentContinuation {
    inner: Arc<Inner>,
}
/// Not constructible from JSON or provider-supplied role objects. A durable
/// claimed->running transition is required before this capability is exposed.
#[derive(Clone)]
pub struct ContinuationInput {
    queue: ParentContinuation,
    record: ContinuationRecord,
    verifier: Option<crate::inbound_delivery::ConversationVerifier>,
}
impl ContinuationInput {
    pub fn with_verifier(
        mut self,
        verifier: crate::inbound_delivery::ConversationVerifier,
    ) -> Self {
        self.verifier = Some(verifier);
        self
    }
    /// Trusted host transport authority, rechecked at effect/provider boundaries.
    /// This is deliberately not part of the local cancellation polling path.
    pub async fn verify_authority(&self) -> Result<()> {
        if let Some(verifier) = &self.verifier {
            verifier.verify(self.conversation_id()).await?;
        }
        self.ensure_current().await
    }
    pub(crate) fn owner_fingerprint(&self) -> &str {
        &self.queue.inner.owner_fingerprint
    }
    pub fn notification_id(&self) -> &str {
        &self.record.notification_id
    }
    pub fn input_id(&self) -> &str {
        &self.record.input_id
    }
    pub fn parent_input_id(&self) -> &str {
        &self.record.parent_input_id
    }
    pub fn session_id(&self) -> &str {
        &self.record.session_id
    }
    pub fn conversation_id(&self) -> &str {
        &self.record.conversation_id
    }
    pub fn generation(&self) -> i64 {
        self.record.generation
    }
    pub fn depth(&self) -> usize {
        self.record.depth
    }
    pub fn messages(&self) -> &[Value] {
        &self.record.messages
    }
    pub fn durable_input(&self) -> Value {
        durable_input(&self.record)
    }
    pub fn run_timeout(&self) -> Duration {
        self.queue.inner.cfg.run_timeout
    }
    pub fn allows_redelegation(&self) -> bool {
        self.depth() < self.queue.inner.cfg.max_depth
    }
    /// Core calls this under its route lock and at every provider/tool/final
    /// boundary, in addition to its own durable generation and cancellation token.
    pub async fn ensure_current(&self) -> Result<()> {
        ensure!(
            !self.queue.is_blocked(self.conversation_id()),
            "continuation conversation stopped"
        );
        let id = self.record.notification_id.clone();
        let input = self.record.input_id.clone();
        let source = self.record.source_digest.clone();
        let running=self.queue.db(move|db| Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM parent_continuations WHERE id=?1 AND input=?2 AND source_digest=?3 AND state='running')", params![id,input,source], |r|r.get::<_,bool>(0))?)).await?;
        ensure!(running, "continuation is not running or identity changed");
        ensure!(
            self.queue
                .inner
                .runtime
                .completion_is_current(self.notification_id())
                .await?,
            "continuation completion was stopped or reset"
        );
        ensure!(
            !self.queue.is_blocked(self.conversation_id()),
            "continuation conversation stopped"
        );
        Ok(())
    }
    /// Select against the Core future. Invalidation wakes immediately; a bounded
    /// fallback also covers a lost wake and asynchronous database failures.
    pub async fn cancelled(&self) {
        loop {
            let changed = self.queue.inner.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if self.ensure_current().await.is_err() {
                return;
            }
            tokio::select! {
                _=&mut changed=>{},
                _=self.queue.inner.runtime.completion_fence_changed()=>{},
                _=tokio::time::sleep(Duration::from_millis(100))=>{},
            }
        }
    }
}
pub struct ContinuationClaim {
    queue: ParentContinuation,
    record: ContinuationRecord,
    nonce: String,
    armed: bool,
}
impl Drop for ContinuationClaim {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let queue = self.queue.clone();
        let id = self.record.notification_id.clone();
        let nonce = self.nonce.clone();
        // There are at most max_active_runs claimed/running rows. Cleanup never
        // executes a model; a possibly committed start is conservatively marked
        // interrupted, while a known-unstarted claim can return to the queue.
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                let _=queue.db(move|db| {
                    db.execute("UPDATE parent_continuations SET state=CASE WHEN state='claimed' THEN 'queued' ELSE 'interrupted' END,claim=NULL,reason=CASE WHEN state='running' THEN 'claim abandoned after execution admission; no automatic replay' ELSE reason END WHERE id=?1 AND claim=?2 AND state IN ('claimed','running')",params![id,nonce])?;
                    Ok(())
                }).await;
            });
        }
    }
}
impl ContinuationClaim {
    pub fn record(&self) -> &ContinuationRecord {
        &self.record
    }
    pub async fn release(mut self) -> Result<()> {
        let id = self.record.notification_id.clone();
        let nonce = self.nonce.clone();
        self.queue.db(move |db| { db.execute("UPDATE parent_continuations SET state='queued',claim=NULL WHERE id=?1 AND state='claimed' AND claim=?2", params![id,nonce])?; Ok(()) }).await?;
        self.armed = false;
        Ok(())
    }
    /// Parent final commit and (where present) terminal transport receipt precede
    /// model admission. A ready but unsent parent final is not sufficient.
    pub async fn start(
        mut self,
        core: &Core,
        parent_journal: Option<&Journal>,
    ) -> Result<Option<ContinuationInput>> {
        self.queue.check_core(core)?;
        let r = &self.record;
        ensure!(
            core.supports_session_context(),
            "continuation requires durable Core session context"
        );
        let parent = core
            .lookup_turn(r.session_id.clone(), r.parent_input_id.clone())
            .await?;
        let terminal_reason = match &parent {
            TurnLookup::Missing => Some((false, "original authenticated parent turn is missing")),
            TurnLookup::Cancelled { .. } | TurnLookup::CancelledBeforeStart => {
                Some((true, "original parent turn was cancelled"))
            }
            TurnLookup::CommandCompleted { .. } => Some((
                false,
                "source input belongs to a command, not a parent model turn",
            )),
            TurnLookup::Completed { token, .. } if token.generation != r.generation => {
                Some((true, "original parent generation differs"))
            }
            TurnLookup::Pending {
                state,
                uncertain_effects,
                ..
            } if state == "interrupted" => Some((
                false,
                if *uncertain_effects {
                    "original parent was interrupted with uncertain tool effects; no automatic continuation"
                } else {
                    "original parent was interrupted before its final; no automatic continuation"
                },
            )),
            _ => None,
        };
        if let Some((suppress, reason)) = terminal_reason {
            if suppress {
                self.queue.suppress_id(&r.notification_id, reason).await?;
            } else {
                self.queue.unavailable(&r.notification_id, reason).await?;
            }
            return Ok(None);
        }
        let parent_done = matches!(parent, TurnLookup::Completed { ref token, .. } if token.generation == r.generation);
        let mut transport_done = true;
        if let Some(journal) = parent_journal
            && let Some(entry) = journal
                .inspect(&format!("chat:{}", r.parent_input_id))
                .await?
        {
            if let Some(frame) = entry.frame {
                ensure!(
                    frame["conversation_id"]
                        .as_str()
                        .is_none_or(|id| id == r.conversation_id),
                    "parent final conversation differs"
                );
            }
            transport_done = matches!(entry.state.as_str(), "delivered" | "rejected" | "uncertain");
        }
        if !parent_done || !transport_done {
            self.release().await?;
            return Ok(None);
        }
        let current = core.session_generation(r.session_id.clone()).await? == r.generation
            && !self.queue.is_blocked(&r.conversation_id)
            && self
                .queue
                .inner
                .runtime
                .completion_is_current(&r.notification_id)
                .await?;
        if !current {
            self.queue
                .suppress_id(&r.notification_id, "parent stopped or generation changed")
                .await?;
            return Ok(None);
        }
        let id = r.notification_id.clone();
        let nonce = self.nonce.clone();
        let changed=self.queue.db(move|db| Ok(db.execute("UPDATE parent_continuations SET state='running' WHERE id=?1 AND state='claimed' AND claim=?2",params![id,nonce])? == 1)).await?;
        if !changed {
            return Ok(None);
        }
        let input = ContinuationInput {
            queue: self.queue.clone(),
            record: self.record.clone(),
            verifier: None,
        };
        input.ensure_current().await?;
        self.armed = false;
        Ok(Some(input))
    }
}
/// Retain across only a bounded outbound send, never a provider/tool run.
pub struct ContinuationSendPermit {
    record: ContinuationRecord,
    _queue_gate: tokio::sync::OwnedRwLockReadGuard<()>,
    _completion_gate: CompletionSendPermit,
}
impl ContinuationSendPermit {
    pub fn record(&self) -> &ContinuationRecord {
        &self.record
    }
}

impl ParentContinuation {
    pub async fn open(
        path: impl AsRef<Path>,
        owner: &str,
        runtime: DelegationRuntime,
        cfg: ContinuationConfig,
    ) -> Result<Self> {
        cfg.validate()?;
        ensure!(
            !owner.is_empty() && runtime.owner_matches(owner),
            "continuation/delegation owner mismatch"
        );
        let path = path.as_ref().to_owned();
        let owner_fingerprint = hash(owner.as_bytes());
        let identity = format!("parent-continuation:{owner_fingerprint}");
        let db = Arc::new(
            tokio::task::spawn_blocking(move || OwnedDatabase::open(&path, &identity)).await??,
        );
        db.call(|db| { db.execute_batch("CREATE TABLE IF NOT EXISTS parent_continuations(id TEXT PRIMARY KEY,input TEXT NOT NULL UNIQUE,parent TEXT NOT NULL,session TEXT NOT NULL,conversation TEXT NOT NULL,generation INTEGER NOT NULL,root TEXT NOT NULL,depth INTEGER NOT NULL,source_digest TEXT NOT NULL,seed TEXT NOT NULL,state TEXT NOT NULL,claim TEXT,final_json TEXT,reason TEXT);
            CREATE INDEX IF NOT EXISTS parent_continuations_queue ON parent_continuations(state,id);
            CREATE INDEX IF NOT EXISTS parent_continuations_route ON parent_continuations(session,state);
            CREATE INDEX IF NOT EXISTS parent_continuations_root ON parent_continuations(root);
            UPDATE parent_continuations SET state='queued',claim=NULL WHERE state='claimed';
            UPDATE parent_continuations SET state='interrupted',claim=NULL,reason='process stopped after execution admission; never replay automatically' WHERE state='running';")?; Ok(()) }).await?;
        Ok(Self {
            inner: Arc::new(Inner {
                db,
                owner_fingerprint,
                runtime,
                cfg,
                operations: Arc::new(Semaphore::new(32)),
                gate: Arc::new(RwLock::new(())),
                blocked: Mutex::new(BTreeSet::new()),
                changed: Notify::new(),
                closed: AtomicBool::new(false),
            }),
        })
    }
    async fn db<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let permit = self.inner.operations.clone().acquire_owned().await?;
        self.inner
            .db
            .call(move |db| {
                let _permit = permit;
                f(db)
            })
            .await
    }
    fn is_blocked(&self, conversation: &str) -> bool {
        self.inner.blocked.lock().unwrap().contains(conversation)
    }
    fn check_core(&self, core: &Core) -> Result<()> {
        ensure!(
            core.session_owner_fingerprint() == Some(self.inner.owner_fingerprint.as_str()),
            "continuation Core owner differs or durable session context is disabled"
        );
        Ok(())
    }
    pub fn run_timeout(&self) -> Duration {
        self.inner.cfg.run_timeout
    }
    /// Close only new admission. The host cancels/drains its bounded active
    /// jobs; committed outputs and never-started queue rows survive shutdown.
    pub fn close_admission(&self) {
        self.inner.closed.store(true, Ordering::Release);
    }
    /// Only immutable identity is accepted. Caller-owned completion JSON cannot
    /// provide routing, authority, roles, lineage, or notification contents.
    pub async fn enqueue(&self, notification_id: &str) -> Result<ContinuationRecord> {
        ensure!(
            self.inner.cfg.enabled && !self.inner.closed.load(Ordering::Acquire),
            "parent continuation is disabled or closed"
        );
        let c = self
            .inner
            .runtime
            .inspect_completion(notification_id)
            .await?
            .context("unknown delegation completion")?;
        ensure!(
            !self.is_blocked(&c.conversation_id),
            "continuation conversation stopped"
        );
        let _permit = self
            .inner
            .runtime
            .prepare_completion_send(notification_id)
            .await?
            .context("stale or suppressed delegation completion")?;
        let source_digest = hash(serde_json::to_string(&c)?.as_bytes());
        let messages = project(&c, self.inner.cfg.max_input_bytes)?;
        let cfg = self.inner.cfg.clone();
        self.db(move|db| {
            let tx=db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(old)=read_record(&tx,&c.notification_id)? {
                ensure!(old.source_digest==source_digest,"continuation identity reused with different completion");
                return Ok(old);
            }
            let count:usize=tx.query_row("SELECT count(*) FROM parent_continuations",[],|r|r.get(0))?;
            ensure!(count<cfg.max_records,"continuation retention capacity reached; no identities were evicted");
            let parent:Option<(String,usize,String,String,i64)>=tx.query_row("SELECT root,depth,session,conversation,generation FROM parent_continuations WHERE input=?1",[&c.input_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
            let (root,depth)=if let Some((root,depth,session,conversation,generation))=parent {
                ensure!(session==c.session_id && conversation==c.conversation_id && generation==c.generation,"continuation lineage scope mismatch");
                (root,depth+1)
            } else {
                ensure!(!c.input_id.starts_with(INPUT_PREFIX),"missing continuation lineage; refusing to reset budget");
                (hash(json!([c.session_id,c.conversation_id,c.generation,c.input_id]).to_string().as_bytes()),1)
            };
            let runs:usize=tx.query_row("SELECT count(*) FROM parent_continuations WHERE root=?1",[&root],|r|r.get(0))?;
            let reason=if depth>cfg.max_depth {Some("parent continuation depth limit reached")} else if runs>=cfg.max_runs_per_root {Some("parent continuation run budget exhausted")} else {None};
            let state=if reason.is_some(){"unavailable"}else{"queued"};
            let input=format!("{INPUT_PREFIX}{}",&hash(c.notification_id.as_bytes())[..40]);
            tx.execute("INSERT INTO parent_continuations(id,input,parent,session,conversation,generation,root,depth,source_digest,seed,state,reason) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",params![c.notification_id,input,c.input_id,c.session_id,c.conversation_id,c.generation,root,depth,source_digest,serde_json::to_string(&messages)?,state,reason])?;
            let record=read_record(&tx,&c.notification_id)?.context("inserted continuation missing")?;
            tx.commit()?; Ok(record)
        }).await
    }
    pub async fn inspect(&self, id: &str) -> Result<Option<ContinuationRecord>> {
        let id = id.to_owned();
        self.db(move |db| read_record(db, &id)).await
    }
    pub async fn inspect_input(&self, input_id: &str) -> Result<Option<ContinuationRecord>> {
        let input_id = input_id.to_owned();
        self.db(move |db| {
            let id: Option<String> = db
                .query_row(
                    "SELECT id FROM parent_continuations WHERE input=?1",
                    [input_id],
                    |r| r.get(0),
                )
                .optional()?;
            id.map(|id| read_record(db, &id))
                .transpose()
                .map(Option::flatten)
        })
        .await
    }
    /// Resolve the original input by durable lineage, not `root_input_id`,
    /// which is a scope hash. This is routing evidence, not proof of a human
    /// message: callers still need Journal's opaque real-chat provenance.
    pub async fn root_parent_input(&self, notification_id: &str) -> Result<String> {
        let notification_id = notification_id.to_owned();
        let (root, evidence) = self
            .db(move |db| {
                let first =
                    read_record(db, &notification_id)?.context("unknown continuation source")?;
                let mut row = first.clone();
                let mut evidence = Vec::new();
                // Eight executable levels, plus one terminal depth-limit notice.
                for _ in 0..=8 {
                    evidence.push((
                        row.notification_id.clone(),
                        row.source_digest.clone(),
                        row.parent_input_id.clone(),
                        row.session_id.clone(),
                        row.conversation_id.clone(),
                        row.generation,
                    ));
                    ensure!(
                        (1..=9).contains(&row.depth),
                        "invalid continuation lineage depth"
                    );
                    let parent: Option<String> = db
                        .query_row(
                            "SELECT id FROM parent_continuations WHERE input=?1",
                            [&row.parent_input_id],
                            |r| r.get(0),
                        )
                        .optional()?;
                    if let Some(parent) = parent {
                        let previous = read_record(db, &parent)?
                            .context("continuation ancestor disappeared")?;
                        ensure!(
                            previous.session_id == first.session_id
                                && previous.conversation_id == first.conversation_id
                                && previous.generation == first.generation
                                && previous.root_input_id == first.root_input_id
                                && previous.depth.checked_add(1) == Some(row.depth),
                            "continuation lineage identity mismatch"
                        );
                        row = previous;
                    } else {
                        ensure!(
                            row.depth == 1 && !row.parent_input_id.starts_with(INPUT_PREFIX),
                            "missing continuation ancestor"
                        );
                        let expected = hash(
                            json!([
                                row.session_id,
                                row.conversation_id,
                                row.generation,
                                row.parent_input_id
                            ])
                            .to_string()
                            .as_bytes(),
                        );
                        ensure!(
                            expected == first.root_input_id
                                && row.root_input_id == first.root_input_id,
                            "continuation root digest mismatch"
                        );
                        return Ok((row.parent_input_id, evidence));
                    }
                }
                anyhow::bail!("continuation lineage exceeds bounded depth")
            })
            .await?;
        // The queue's private root checksum is not independent source evidence.
        // Cross-check immutable delegation records before using the route. This
        // does not claim protection against an actor rewriting all private DBs.
        for (notification, digest, parent, session, conversation, generation) in evidence {
            let source = self
                .inner
                .runtime
                .inspect_completion(&notification)
                .await?
                .context("continuation ancestor source disappeared")?;
            ensure!(
                source.input_id == parent
                    && source.session_id == session
                    && source.conversation_id == conversation
                    && source.generation == generation
                    && hash(serde_json::to_string(&source)?.as_bytes()) == digest,
                "continuation ancestor differs from immutable delegation source"
            );
        }
        Ok(root)
    }
    pub async fn queued(&self, limit: usize) -> Result<Vec<ContinuationRecord>> {
        self.queued_after(None, limit).await
    }
    pub async fn queued_after(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ContinuationRecord>> {
        self.records("queued", after, limit).await
    }
    async fn records(
        &self,
        state: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ContinuationRecord>> {
        ensure!((1..=128).contains(&limit), "invalid continuation page size");
        let state = state.to_owned();
        let after = after.unwrap_or("").to_owned();
        self.db(move |db| {
            let mut query = db.prepare(
                "SELECT id FROM parent_continuations WHERE (state=?1 OR (?1='output_ready' AND state IN ('final_committed','uncertain','unavailable'))) AND id>?2 ORDER BY id LIMIT ?3",
            )?;
            let ids = query
                .query_map(params![state, after, limit], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            ids.into_iter()
                .map(|id| read_record(db, &id)?.context("continuation disappeared"))
                .collect()
        })
        .await
    }
    /// At most one claimed/running/interrupted continuation per session route.
    /// Actual user-turn serialization is still Core's existing route lock.
    pub async fn claim(&self, id: &str) -> Result<Option<ContinuationClaim>> {
        ensure!(
            self.inner.cfg.enabled && !self.inner.closed.load(Ordering::Acquire),
            "parent continuation is disabled or closed"
        );
        let id = id.to_owned();
        let nonce = uuid::Uuid::new_v4().to_string();
        let claim = nonce.clone();
        let max_active = self.inner.cfg.max_active_runs;
        let cfg = self.inner.cfg.clone();
        let queue = self.clone();
        self.db(move|db| {
            let tx=db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let Some(record)=read_record(&tx,&id)? else {return Ok(None)};
            if record.state!=ContinuationState::Queued {return Ok(None)};
            let ordinal:usize=tx.query_row("SELECT count(*) FROM parent_continuations WHERE root=?1 AND rowid<=(SELECT rowid FROM parent_continuations WHERE id=?2)",params![record.root_input_id,id],|r|r.get(0))?;
            if record.depth>cfg.max_depth || ordinal>cfg.max_runs_per_root || serde_json::to_vec(&record.messages)?.len()>cfg.max_input_bytes {
                tx.execute("UPDATE parent_continuations SET state='unavailable',reason='current host continuation budget no longer admits this queued turn' WHERE id=?1",[&id])?;
                tx.commit()?;return Ok(None)
            }
            let active:usize=tx.query_row("SELECT count(*) FROM parent_continuations WHERE state IN ('claimed','running','interrupted')",[],|r|r.get(0))?;
            if active>=max_active {return Ok(None)};
            let busy:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM parent_continuations WHERE session=?1 AND state IN ('claimed','running','interrupted'))",[&record.session_id],|r|r.get(0))?;
            if busy {return Ok(None)};
            tx.execute("UPDATE parent_continuations SET state='claimed',claim=?1 WHERE id=?2 AND state='queued'",params![claim,id])?;
            tx.commit()?; Ok(Some(ContinuationClaim{queue,record,nonce,armed:true}))
        }).await
    }
    /// Adopt only a finalized Core receipt with exactly the trusted seed digest.
    /// There is never an independent "final" supplied by a model or transport.
    pub async fn finish(&self, core: &Core, input_id: &str) -> Result<ContinuationRecord> {
        self.check_core(core)?;
        let input = input_id.to_owned();
        let r = self
            .db(move |db| read_by_input(db, &input)?.context("unknown continuation input"))
            .await?;
        let lookup = core
            .lookup_turn(r.session_id.clone(), r.input_id.clone())
            .await?;
        let TurnLookup::Completed {
            token,
            final_assistant,
            input_digest,
        } = lookup
        else {
            anyhow::bail!("continuation has no finalized Core receipt")
        };
        ensure!(
            token.generation == r.generation
                && input_digest == hash(r.durable_input().to_string().as_bytes()),
            "continuation Core receipt identity differs"
        );
        ensure!(
            final_assistant["role"] == "assistant"
                && final_assistant["content"]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty())
                && final_assistant["tool_calls"]
                    .as_array()
                    .is_none_or(Vec::is_empty),
            "invalid continuation final receipt"
        );
        let final_json = serde_json::to_string(&final_assistant)?;
        if final_json.len() > self.inner.cfg.max_final_bytes {
            self.unavailable(
                &r.notification_id,
                "committed Core final exceeds continuation output bound",
            )
            .await?;
            anyhow::bail!(
                "continuation final exceeds bound; exact final retained in Core without replay"
            );
        }
        let id = r.notification_id;
        self.db(move|db| {
            let old=read_record(db,&id)?.context("continuation disappeared")?;
            if let Some(existing)=old.final_assistant {ensure!(existing==final_assistant,"continuation final changed");}
            else {ensure!(!matches!(old.state,ContinuationState::Uncertain|ContinuationState::Unavailable|ContinuationState::Enqueued),"continuation diagnostic is already immutable");}
            db.execute("UPDATE parent_continuations SET final_json=?1,state=CASE WHEN state='suppressed' THEN 'suppressed' WHEN state='enqueued' THEN 'enqueued' ELSE 'final_committed' END WHERE id=?2 AND state IN ('running','interrupted','uncertain','final_committed','enqueued','suppressed')",params![final_json,id])?;
            read_record(db,&id)?.context("continuation disappeared")
        }).await
    }
    /// Startup repair reads receipts only. Started work without a final is
    /// cancelled in Core so future real user turns do not inherit its lock.
    pub async fn recover(&self, core: &Core, limit: usize) -> Result<usize> {
        self.check_core(core)?;
        let rows = self.records("interrupted", None, limit).await?;
        let mut count = 0;
        for row in rows {
            let repair = async {
                // Verifies the immutable seed even for a pending receipt. A
                // conflicting real input must never be cancelled as our work.
                let completed = core.lookup_completed(row.session_id.clone(), row.input_id.clone(), row.durable_input()).await?;
                if completed.is_some() { self.finish(core, &row.input_id).await?; }
                else {
                    core.cancel_input(row.session_id.clone(), row.input_id.clone()).await?;
                    let id = row.notification_id.clone();
                    self.db(move|db| { db.execute("UPDATE parent_continuations SET state='uncertain',reason='execution interrupted; Core input cancelled; no automatic model or tool replay' WHERE id=?1 AND state='interrupted'",[id])?; Ok(()) }).await?;
                }
                Ok::<(),anyhow::Error>(())
            }.await;
            if repair.is_err() {
                // Terminal, bounded, non-authoritative notice. A bad row cannot
                // keep the first page or active-route slot occupied forever.
                self.unavailable(&row.notification_id, "continuation recovery could not verify the durable Core outcome; no work was replayed").await?;
            }
            count += 1;
        }
        Ok(count)
    }
    /// Host calls after a timed-out/failed started run. Preserve a concurrently
    /// committed final; otherwise stop the durable Core input and never retry it.
    pub async fn interrupt(&self, core: &Core, input_id: &str) -> Result<ContinuationRecord> {
        self.check_core(core)?;
        let input = input_id.to_owned();
        let row = self
            .db(move |db| read_by_input(db, &input)?.context("unknown continuation input"))
            .await?;
        if let Err(error) = core
            .lookup_completed(
                row.session_id.clone(),
                row.input_id.clone(),
                row.durable_input(),
            )
            .await
        {
            self.unavailable(
                &row.notification_id,
                "continuation input identity could not be verified; no work was replayed",
            )
            .await?;
            return Err(error);
        }
        core.cancel_input(row.session_id.clone(), row.input_id.clone())
            .await?;
        if matches!(
            core.lookup_turn(row.session_id.clone(), row.input_id.clone())
                .await?,
            TurnLookup::Completed { .. }
        ) {
            return self.finish(core, input_id).await;
        }
        let id = row.notification_id;
        self.db(move|db| { db.execute("UPDATE parent_continuations SET state='uncertain',reason='started continuation interrupted; no automatic replay' WHERE id=?1 AND state IN ('running','interrupted')",[&id])?; read_record(db,&id)?.context("continuation disappeared") }).await
    }
    pub async fn pending_outputs(&self, limit: usize) -> Result<Vec<ContinuationRecord>> {
        self.pending_outputs_after(None, limit).await
    }
    pub async fn pending_outputs_after(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ContinuationRecord>> {
        self.records("output_ready", after, limit).await
    }
    /// Receipt for local durable outbox insertion, never a remote/read ACK.
    pub async fn mark_enqueued(&self, id: &str) -> Result<bool> {
        let id = id.to_owned();
        self.db(move|db| {db.execute("UPDATE parent_continuations SET state='enqueued' WHERE id=?1 AND state IN ('final_committed','uncertain','unavailable')",[&id])?; Ok(read_record(db,&id)?.is_some_and(|r|r.state==ContinuationState::Enqueued))}).await
    }
    async fn unavailable(&self, id: &str, reason: &str) -> Result<()> {
        let id = id.to_owned();
        let reason = reason.to_owned();
        self.db(move|db|{db.execute("UPDATE parent_continuations SET state='unavailable',claim=NULL,reason=?2 WHERE id=?1 AND state NOT IN ('suppressed','enqueued','final_committed','uncertain','unavailable')",params![id,reason])?;Ok(())}).await
    }
    /// Host-only stale/cancelled disposition, not an enqueue or remote receipt.
    pub async fn suppress_output(&self, id: &str, reason: &str) -> Result<()> {
        ensure!(
            !reason.is_empty() && reason.len() <= 512,
            "invalid continuation suppression reason"
        );
        self.suppress_id(id, reason).await
    }
    async fn suppress_id(&self, id: &str, reason: &str) -> Result<()> {
        let id = id.to_owned();
        let reason = reason.to_owned();
        self.db(move |db| {
            db.execute(
                "UPDATE parent_continuations SET state='suppressed',reason=?2 WHERE id=?1",
                params![id, reason],
            )?;
            Ok(())
        })
        .await
    }
    pub async fn suppress_conversation(&self, core: &Core, conversation: &str) -> Result<usize> {
        self.check_core(core)?;
        ensure!(!conversation.is_empty(), "verified conversation required");
        self.inner
            .blocked
            .lock()
            .unwrap()
            .insert(conversation.to_owned());
        self.inner.changed.notify_waiters();
        let conv = conversation.to_owned();
        let routes = self
            .db(move |db| {
                let mut q = db.prepare(
                    "SELECT DISTINCT session FROM parent_continuations WHERE conversation=?1",
                )?;
                Ok(q.query_map([conv], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?)
            })
            .await?;
        for route in routes {
            core.cancel(route).await?;
        }
        self.inner.runtime.cancel_conversation(conversation).await?;
        let _gate = self.inner.gate.write().await;
        let conv = conversation.to_owned();
        let count=self.db(move|db|Ok(db.execute("UPDATE parent_continuations SET state='suppressed',claim=NULL,reason='conversation explicitly stopped' WHERE conversation=?1 AND state<>'suppressed'",[conv])?)).await?;
        self.inner.blocked.lock().unwrap().remove(conversation);
        Ok(count)
    }
    /// Currentness is checked again after local outbox insertion and immediately
    /// before sending. The caller additionally verifies current remote ownership.
    pub async fn prepare_send(&self, id: &str) -> Result<Option<ContinuationSendPermit>> {
        let gate = self.inner.gate.clone().read_owned().await;
        let Some(row) = self.inspect(id).await? else {
            return Ok(None);
        };
        if !matches!(
            row.state,
            ContinuationState::FinalCommitted
                | ContinuationState::Enqueued
                | ContinuationState::Uncertain
                | ContinuationState::Unavailable
        ) || self.is_blocked(&row.conversation_id)
        {
            return Ok(None);
        };
        let Some(completion) = self.inner.runtime.prepare_completion_send(id).await? else {
            return Ok(None);
        };
        ensure!(
            hash(serde_json::to_string(completion.completion())?.as_bytes()) == row.source_digest,
            "continuation source changed"
        );
        Ok(Some(ContinuationSendPermit {
            record: row,
            _queue_gate: gate,
            _completion_gate: completion,
        }))
    }
}

fn hash(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}
fn durable_input(r: &ContinuationRecord) -> Value {
    json!({"kind":"native_parent_continuation","notification_id":r.notification_id,"input_id":r.input_id,
        "parent_input_id":r.parent_input_id,"session_id":r.session_id,"conversation_id":r.conversation_id,
        "generation":r.generation,"source_digest":r.source_digest,"messages":r.messages})
}
fn read_by_input(db: &Connection, input: &str) -> Result<Option<ContinuationRecord>> {
    let id: Option<String> = db
        .query_row(
            "SELECT id FROM parent_continuations WHERE input=?1",
            [input],
            |r| r.get(0),
        )
        .optional()?;
    id.map(|id| read_record(db, &id)?.context("continuation disappeared"))
        .transpose()
}
fn read_record(db: &Connection, id: &str) -> Result<Option<ContinuationRecord>> {
    type Raw = (
        String,
        String,
        String,
        String,
        i64,
        String,
        usize,
        String,
        String,
        String,
        Option<String>,
        Option<String>,
    );
    let raw:Option<Raw>=db.query_row("SELECT input,parent,session,conversation,generation,root,depth,state,source_digest,seed,final_json,reason FROM parent_continuations WHERE id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?,r.get(9)?,r.get(10)?,r.get(11)?))).optional()?;
    raw.map(
        |(
            input_id,
            parent_input_id,
            session_id,
            conversation_id,
            generation,
            root_input_id,
            depth,
            state,
            source_digest,
            seed,
            final_json,
            reason,
        )| {
            Ok(ContinuationRecord {
                notification_id: id.into(),
                input_id,
                parent_input_id,
                session_id,
                conversation_id,
                generation,
                root_input_id,
                depth,
                state: ContinuationState::parse(&state)?,
                source_digest,
                messages: serde_json::from_str(&seed)?,
                final_assistant: final_json.map(|s| serde_json::from_str(&s)).transpose()?,
                reason,
            })
        },
    )
    .transpose()
}
fn prefix(value: &str, bytes: usize) -> &str {
    let mut n = value.len().min(bytes);
    while !value.is_char_boundary(n) {
        n -= 1;
    }
    &value[..n]
}
fn project(c: &BackgroundCompletion, maximum: usize) -> Result<Vec<Value>> {
    let rows = c.result["results"]
        .as_array()
        .context("background result rows missing")?;
    ensure!(rows.len() <= 64, "too many completion results");
    // Budget is checked against actual encoded JSON. Escapes can expand a byte
    // sixfold, so use a bounded shrink loop, preserving the same source digest.
    let mut budget = (maximum / rows.len().max(1))
        .saturating_sub(1024)
        .clamp(64, 16 * 1024);
    let mut row_limit = rows.len();
    loop {
        let summaries:Vec<_>=rows.iter().take(row_limit).map(|r| {
            let summary=r["summary"].as_str().unwrap_or(""); let shown=prefix(summary,budget);
            json!({"subagent_id":prefix(r["subagent_id"].as_str().unwrap_or(""),128),
                "status":prefix(r["status"].as_str().unwrap_or("unknown"),64),"summary":shown,"truncated":shown.len()!=summary.len()})
        }).collect();
        let content=json!({"source":"background_delegation","untrusted":true,"grants_permissions":false,
            "delegation_id":c.delegation_id,"partial":c.result["partial"].as_bool().unwrap_or(true),"results":summaries,"omitted_results":rows.len()-row_limit}).to_string();
        let call_id = format!("completion_{}", &hash(c.notification_id.as_bytes())[..32]);
        let marker = json!({"version":1,"notification_id":c.notification_id});
        let messages = vec![
            json!({"role":"assistant",PARENT_CONTINUATION_MARKER:marker,"tool_calls":[{"id":call_id,"type":"function","function":{"name":FUNCTION,"arguments":"{}"}}]}),
            json!({"role":"tool","tool_call_id":call_id,"content":content}),
        ];
        if serde_json::to_vec(&messages)?.len() <= maximum {
            validate_seed(&messages)?;
            return Ok(messages);
        }
        if budget > 0 {
            budget /= 2;
        } else {
            ensure!(row_limit > 0, "completion metadata exceeds input bound");
            row_limit -= 1;
        }
    }
}
pub(crate) fn validate_seed(messages: &[Value]) -> Result<()> {
    ensure!(
        messages.len() == 2,
        "continuation requires one host tool-call/result pair"
    );
    let head = &messages[0];
    let result = &messages[1];
    ensure!(
        head["role"] == "assistant" && result["role"] == "tool",
        "continuation cannot contain system, developer or human input"
    );
    let marker = &head[PARENT_CONTINUATION_MARKER];
    ensure!(
        marker["version"] == 1
            && marker["notification_id"]
                .as_str()
                .is_some_and(|s| s.starts_with("delegation-completion-") && s.len() <= 200),
        "invalid continuation marker"
    );
    ensure!(
        head.as_object().is_some_and(|o| o.keys().all(|k| [
            "role",
            "tool_calls",
            PARENT_CONTINUATION_MARKER
        ]
        .contains(&k.as_str())))
            && result.as_object().is_some_and(|o| o.keys().all(|k| [
                "role",
                "tool_call_id",
                "content"
            ]
            .contains(&k.as_str()))),
        "unrecognized continuation message fields"
    );
    let calls = head["tool_calls"]
        .as_array()
        .context("continuation call missing")?;
    ensure!(
        calls.len() == 1
            && calls[0]["type"] == "function"
            && calls[0]["function"]["name"] == FUNCTION
            && calls[0]["function"]["arguments"] == "{}",
        "invalid host completion function"
    );
    ensure!(
        calls[0]["id"]
            .as_str()
            .is_some_and(|s| s.starts_with("completion_") && s.len() <= 64)
            && calls[0]["id"] == result["tool_call_id"]
            && result["content"].is_string(),
        "continuation result does not match call"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn projection_bounds_escaped_text_and_many_metadata_rows() -> Result<()> {
        let c = BackgroundCompletion {
            notification_id: "delegation-completion-fixture".into(),
            delegation_id: "batch-fixture".into(),
            session_id: "parent".into(),
            conversation_id: "conversation".into(),
            generation: 0,
            input_id: "original".into(),
            result: json!({"partial":false,"results":(0..64).map(|_|json!({"subagent_id":"\u{0001}".repeat(128),"status":"\u{0001}".repeat(64),"summary":"长文\u{0001}".repeat(1000)})).collect::<Vec<_>>()}),
        };
        let messages = project(&c, 4096)?;
        assert!(serde_json::to_vec(&messages)?.len() <= 4096);
        let body: Value = serde_json::from_str(messages[1]["content"].as_str().unwrap())?;
        assert!(body["omitted_results"].as_u64().unwrap() > 0);
        assert_eq!(body["untrusted"], true);
        assert_eq!(body["grants_permissions"], false);
        validate_seed(&messages)?;
        Ok(())
    }
}
