//! Durable completion handoff. This is not an external-effect retry queue.
use super::*;
use rusqlite::{OptionalExtension, params};

type CompletionRow = (String, String, String, i64, String, String);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BackgroundCompletion {
    pub notification_id: String,
    pub delegation_id: String,
    pub session_id: String,
    pub conversation_id: String,
    pub generation: i64,
    pub input_id: String,
    pub result: Value,
}

/// Hold across a bounded socket send. Reset/cancellation invalidates admission
/// before waiting for existing permits; already-started sends cannot be recalled.
pub struct CompletionSendPermit {
    completion: BackgroundCompletion,
    _gate: tokio::sync::OwnedRwLockReadGuard<()>,
}
impl CompletionSendPermit {
    pub fn completion(&self) -> &BackgroundCompletion {
        &self.completion
    }
}

pub(super) struct DetachedGuard {
    runtime: DelegationRuntime,
    id: String,
}
impl Drop for DetachedGuard {
    fn drop(&mut self) {
        self.runtime
            .inner
            .background
            .lock()
            .unwrap()
            .remove(&self.id);
        self.runtime.inner.background_done.notify_waiters();
    }
}

pub(super) fn admission_handle(id: &str, children: &[store::Child]) -> Value {
    json!({"delegation_id":id,"mode":"background","status":"dispatched",
        "count":children.len(),"goals":children.iter().map(|c|&c.task.goal).collect::<Vec<_>>(),
        "subagent_ids":children.iter().map(|c|&c.id).collect::<Vec<_>>(),
        "note":"The batch is running independently. End this turn when your other work is done; its bounded result will be delivered separately. Do not poll to wait. Restart reports interrupted or uncertain work without replaying external effects."})
}

pub(super) fn insert_record(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    a: &Authority,
    children: &[store::Child],
) -> Result<()> {
    if a.detached {
        let notification_id = format!("delegation-completion-{}", &digest(id)[..40]);
        tx.execute("INSERT INTO delegation_background(batch,notification_id,root,conversation,generation,input,handle,state) VALUES(?1,?2,?3,?4,?5,?6,?7,'pending')",
            params![id,notification_id,a.context.session_id,a.context.conversation_id,a.generation,a.context.input_id,admission_handle(id,children).to_string()])?;
    }
    Ok(())
}

impl DelegationRuntime {
    pub(super) fn detach_authority(
        &self,
        id: &str,
        mut a: Authority,
    ) -> (Authority, Option<DetachedGuard>) {
        if !a.detached {
            return (a, None);
        }
        // Only root dispatch may detach. Ancestor cancellation never gets lost
        // for nested work; dispatch_inner always keeps nested execution inline.
        a.cancel = Arc::new(Cancel::default());
        a.ancestors.clear();
        self.inner.background.lock().unwrap().insert(
            id.into(),
            LiveChild {
                token: a.cancel.clone(),
                root: a.context.session_id.clone(),
                conversation: a.context.conversation_id.clone(),
                generation: a.generation,
            },
        );
        (
            a,
            Some(DetachedGuard {
                runtime: self.clone(),
                id: id.into(),
            }),
        )
    }

    /// Wake a single host delivery pump after durable normal completion. Notify
    /// retains one permit; a bounded fallback scan still covers startup recovery
    /// and abandoned-future DB cleanup, which cannot execute Tokio callbacks.
    pub async fn completion_notified(&self) {
        self.inner.completion_ready.notified().await;
    }
    pub(crate) async fn completion_fence_changed(&self) {
        self.inner.completion_fence_changed.notified().await;
    }

    /// Trusted host-only outbox. Results are owner-bound, scoped, immutable and
    /// bounded by max_batches/max_retained_children. This does not call a model.
    pub async fn pending_completions(&self, limit: usize) -> Result<Vec<BackgroundCompletion>> {
        self.pending_completions_after(None, limit).await
    }
    /// Stable lexicographic keyset pagination, not OFFSET. A cursor need not
    /// still be pending or exist in this database. Wrap to None after a complete
    /// scan to discover newly completed lower IDs and revisit deferred parents.
    pub async fn pending_completions_after(
        &self,
        after_notification_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<BackgroundCompletion>> {
        ensure!((1..=128).contains(&limit), "invalid completion page size");
        ensure!(
            after_notification_id.is_none_or(|id| !id.is_empty()
                && id.len() <= 200
                && !id.chars().any(char::is_control)),
            "invalid completion cursor"
        );
        self.inner
            .db
            .pending_completions_after(after_notification_id, limit)
            .await
    }
    /// Includes enqueued and suppressed records so a host never needs to trust
    /// a delivery frame's untrusted metadata to determine its original owner.
    pub async fn inspect_completion(
        &self,
        notification_id: &str,
    ) -> Result<Option<BackgroundCompletion>> {
        self.inner.db.inspect_completion(notification_id).await
    }
    /// Call only AFTER an idempotent durable outbox enqueue succeeds. This is a
    /// local handoff receipt, not remote delivery, persistence, display or read.
    pub async fn mark_completion_enqueued(&self, notification_id: &str) -> Result<bool> {
        self.inner
            .db
            .mark_completion_enqueued(notification_id)
            .await
    }
    pub async fn completion_is_current(&self, notification_id: &str) -> Result<bool> {
        let _gate = self.inner.notification_gate.read().await;
        let Some((session, conversation, generation)) = self
            .inner
            .db
            .current_completion_identity(notification_id)
            .await?
        else {
            return Ok(false);
        };
        Ok(!self.inner.closed.load(Ordering::Acquire)
            && !self
                .inner
                .blocked_notifications
                .lock()
                .unwrap()
                .contains(&conversation)
            && !self
                .inner
                .generations
                .lock()
                .unwrap()
                .get(&session)
                .is_some_and(|current| *current != generation))
    }
    pub async fn prepare_completion_send(
        &self,
        notification_id: &str,
    ) -> Result<Option<CompletionSendPermit>> {
        let gate = self.inner.notification_gate.clone().read_owned().await;
        let Some(completion) = self.inner.db.current_completion(notification_id).await? else {
            return Ok(None);
        };
        if self.inner.closed.load(Ordering::Acquire)
            || self
                .inner
                .blocked_notifications
                .lock()
                .unwrap()
                .contains(&completion.conversation_id)
            || self
                .inner
                .generations
                .lock()
                .unwrap()
                .get(&completion.session_id)
                .is_some_and(|generation| *generation != completion.generation)
        {
            return Ok(None);
        }
        Ok(Some(CompletionSendPermit {
            completion,
            _gate: gate,
        }))
    }
    /// Explicit host /stop, not ordinary turn interruption or socket disconnect.
    /// Cancels every delegated descendant in this verified conversation and
    /// suppresses late completion delivery. Records remain available for audit.
    pub async fn cancel_conversation(&self, conversation_id: &str) -> Result<usize> {
        ensure!(!conversation_id.is_empty(), "trusted conversation required");
        self.inner
            .blocked_notifications
            .lock()
            .unwrap()
            .insert(conversation_id.into());
        self.inner.completion_fence_changed.notify_waiters();
        for map in [&self.inner.background, &self.inner.live] {
            for job in map.lock().unwrap().values() {
                if job.conversation == conversation_id {
                    job.token.stop();
                }
            }
        }
        let _gate = self.inner.notification_gate.write().await;
        let count = self.inner.db.cancel_conversation(conversation_id).await?;
        // A concurrent admission checks this fence before every provider/tool
        // boundary and its durable row is stopped by the ordered DB command.
        self.inner
            .blocked_notifications
            .lock()
            .unwrap()
            .remove(conversation_id);
        Ok(count)
    }
}

impl store::Store {
    pub(super) fn current_completion_identity(
        &self,
        id: &str,
    ) -> Result<Option<(String, String, i64)>> {
        Ok(self.db.query_row("SELECT b.root,b.conversation,b.generation FROM delegation_background b JOIN delegation_generations g ON b.root=g.session AND b.generation=g.generation WHERE b.notification_id=?1 AND b.state<>'suppressed' AND b.result IS NOT NULL", [id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?)
    }
    pub(super) fn inspect_completion(&self, id: &str) -> Result<Option<BackgroundCompletion>> {
        let row: Option<CompletionRow> = self.db.query_row(
            "SELECT batch,root,conversation,generation,input,result FROM delegation_background WHERE notification_id=?1 AND result IS NOT NULL",
            [id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional()?;
        row.map(
            |(delegation_id, session_id, conversation_id, generation, input_id, result)| {
                Ok(BackgroundCompletion {
                    notification_id: id.into(),
                    delegation_id,
                    session_id,
                    conversation_id,
                    generation,
                    input_id,
                    result: serde_json::from_str(&result)?,
                })
            },
        )
        .transpose()
    }
    pub(super) fn current_completion(&self, id: &str) -> Result<Option<BackgroundCompletion>> {
        let current: bool = self.db.query_row("SELECT EXISTS(SELECT 1 FROM delegation_background b JOIN delegation_generations g ON b.root=g.session AND b.generation=g.generation WHERE b.notification_id=?1 AND b.state<>'suppressed' AND b.result IS NOT NULL)", [id], |r|r.get(0))?;
        if current {
            self.inspect_completion(id)
        } else {
            Ok(None)
        }
    }
    pub(super) fn pending_completions_after(
        &self,
        after_notification_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<BackgroundCompletion>> {
        let ids = {
            // Empty is below every generated notification ID and keeps the
            // indexed key range simple for both the first and later pages.
            let after = after_notification_id.unwrap_or("");
            let mut q=self.db.prepare("SELECT b.notification_id FROM delegation_background b JOIN delegation_generations g ON b.root=g.session AND b.generation=g.generation WHERE b.state='pending' AND b.notification_id>?1 AND b.result IS NOT NULL ORDER BY b.notification_id LIMIT ?2")?;
            q.query_map(params![after, limit], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        ids.iter()
            .map(|id| {
                self.inspect_completion(id)?
                    .context("completion disappeared")
            })
            .collect()
    }
    pub(super) fn mark_completion_enqueued(&mut self, id: &str) -> Result<bool> {
        self.db.execute("UPDATE delegation_background SET state='enqueued' WHERE notification_id=?1 AND state='pending' AND result IS NOT NULL AND EXISTS(SELECT 1 FROM delegation_generations g WHERE g.session=delegation_background.root AND g.generation=delegation_background.generation)",[id])?;
        Ok(self.db.query_row("SELECT EXISTS(SELECT 1 FROM delegation_background WHERE notification_id=?1 AND state='enqueued')",[id],|r|r.get(0))?)
    }
    pub(super) fn cancel_conversation(&mut self, conversation: &str) -> Result<usize> {
        let tx = self.db.transaction()?;
        let count=tx.execute("UPDATE delegation_children SET status='stopping' WHERE conversation=?1 AND status IN ('pending','running')",[conversation])?;
        tx.execute(
            "UPDATE delegation_background SET state='suppressed' WHERE conversation=?1",
            [conversation],
        )?;
        tx.commit()?;
        Ok(count)
    }
}
