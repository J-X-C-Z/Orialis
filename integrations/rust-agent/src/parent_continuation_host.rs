//! Bounded main-host scheduling and immutable delivery for parent continuations.
//!
//! A delivery ACK acknowledges the pinned server's notification path, not chat
//! persistence. Accordingly this host never invents a chat anchor or final ACK.
use crate::{
    Core,
    continuation_reply::{
        ContinuationReplyOutbox, ReplyLimits, ReplyRecord, ReplyRequest, ReplySource, ReplyStatus,
    },
    delegation::DelegationRuntime,
    delivery::{
        DeliveryBody, DeliveryKind, DeliveryOutbox, DeliveryRequest, DeliveryStatus,
        DeliveryTarget, digest,
    },
    inbound_delivery::ConversationVerifier,
    journal::{Journal, ProvenChatAnchor},
    output_files::{OutputFiles, OutputScope},
    parent_continuation::{ContinuationRecord, ContinuationSendPermit, ParentContinuation},
};
use anyhow::{Context, Result, ensure};
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::Notify;

const PAGE: usize = 32;
const JOBS: usize = 4;
const PREFIX: &str = "parent-final:";
const MAX_TEXT: usize = 256 * 1024;

#[derive(Clone)]
pub struct ParentContinuationHost {
    queue: ParentContinuation,
    runtime: DelegationRuntime,
    core: Core,
    outbox: DeliveryOutbox,
    verifier: ConversationVerifier,
    journal: Journal,
    outputs: Option<OutputFiles>,
    replies: ContinuationReplyOutbox,
    reply_followups: Arc<AtomicBool>,
    wake: Arc<Notify>,
    output_ready: Arc<Notify>,
    shutdown: Arc<Notify>,
    stopping: Arc<AtomicBool>,
}
pub struct ParentFinalSendPermit {
    frame: Value,
    _lease: ContinuationSendPermit,
}
impl ParentFinalSendPermit {
    pub fn frame(&self) -> &Value {
        &self.frame
    }
}
impl ParentContinuationHost {
    /// All services must be constructed from the same verified owner/server/device.
    pub async fn new(
        queue: ParentContinuation,
        runtime: DelegationRuntime,
        core: Core,
        outbox: DeliveryOutbox,
        verifier: ConversationVerifier,
        journal: Journal,
    ) -> Result<Self> {
        ensure!(
            runtime.owner_matches(&outbox.identity.owner)
                && core.session_owner_fingerprint()
                    == Some(digest(outbox.identity.owner.as_bytes()).as_str()),
            "parent continuation host owner binding differs"
        );
        outbox.db.call(|db| {
            db.execute_batch("CREATE TABLE IF NOT EXISTS parent_final_projections(source TEXT PRIMARY KEY,request TEXT NOT NULL); CREATE TABLE IF NOT EXISTS parent_reply_projections(source TEXT PRIMARY KEY,request TEXT NOT NULL);")?;
            Ok(())
        }).await?;
        let replies =
            ContinuationReplyOutbox::from_delivery(&outbox, ReplyLimits::default()).await?;
        Ok(Self {
            queue,
            runtime,
            core,
            outbox,
            verifier,
            journal,
            outputs: None,
            replies,
            reply_followups: Arc::new(AtomicBool::new(false)),
            wake: Arc::new(Notify::new()),
            output_ready: Arc::new(Notify::new()),
            shutdown: Arc::new(Notify::new()),
            stopping: Arc::new(AtomicBool::new(false)),
        })
    }
    pub fn with_outputs(mut self, outputs: Option<OutputFiles>) -> Self {
        self.outputs = outputs;
        self
    }
    pub fn set_reply_followups(&self, enabled: bool) {
        self.reply_followups.store(enabled, Ordering::Release);
        if enabled {
            self.wake.notify_one();
            self.output_ready.notify_one();
        }
    }
    pub fn parent_terminal(&self) {
        self.wake.notify_one();
    }
    pub async fn output_notified(&self) {
        self.output_ready.notified().await;
    }
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        self.queue.close_admission();
        self.shutdown.notify_waiters();
    }
    async fn stopped(&self) {
        loop {
            let notify = self.shutdown.notified();
            tokio::pin!(notify);
            notify.as_mut().enable();
            if self.stopping.load(Ordering::Acquire) {
                return;
            }
            notify.await;
        }
    }
    pub async fn suppress_conversation(&self, conversation: &str) -> Result<usize> {
        let count = self
            .queue
            .suppress_conversation(&self.core, conversation)
            .await?;
        self.replies
            .suppress_conversation(conversation, "conversation explicitly stopped or reset")
            .await?;
        Ok(count)
    }
    /// Reserve the entire namespace even for a missing row: never let a queued
    /// final bypass its continuation fence after a configuration toggle.
    pub fn is_output_id(id: &str) -> bool {
        id.starts_with(PREFIX)
    }
    pub fn output_id(source: &str) -> String {
        format!("{PREFIX}{source}")
    }
    fn source_id(id: &str) -> Result<&str> {
        let source = id.strip_prefix(PREFIX).context("not a parent final ID")?;
        ensure!(
            !source.is_empty() && Self::output_id(source) == id,
            "invalid parent final ID"
        );
        Ok(source)
    }
    pub async fn verify_output(&self, id: &str) -> Result<()> {
        if !Self::is_output_id(id) {
            return Ok(());
        }
        let row = self
            .queue
            .inspect(Self::source_id(id)?)
            .await?
            .context("parent final source missing")?;
        self.verifier.verify(&row.conversation_id).await
    }
    /// Old raw completions already in the outbox must not race the resumed final.
    pub async fn suppress_legacy_output(&self, id: &str) -> Result<bool> {
        if self.runtime.inspect_completion(id).await?.is_some() {
            if !self.runtime.completion_is_current(id).await? {
                self.outbox.cancel(id).await?;
            } else if self.queue.enqueue(id).await.is_ok() {
                self.runtime.mark_completion_enqueued(id).await?;
                self.outbox.cancel(id).await?;
                self.wake.notify_one();
            }
            // A capacity-blocked migration stays durable and unsent. It must not
            // disconnect the writer or starve unrelated final rows in this page.
            return Ok(true);
        }
        Ok(false)
    }
    fn metadata(row: &ContinuationRecord) -> Value {
        json!({"source":"native_parent_continuation", "notification_id":row.notification_id,
            "input_id":row.input_id, "parent_input_id":row.parent_input_id,
            "generation":row.generation,
            "outcome_digest":digest(json!([row.final_assistant,row.reason]).to_string().as_bytes())})
    }
    fn validate_request(&self, row: &ContinuationRecord, request: &DeliveryRequest) -> Result<()> {
        request.target.validate(&self.outbox.identity)?;
        let mut identity = request.body.metadata.clone();
        let projection = identity
            .as_object_mut()
            .context("parent final metadata missing")?
            .remove("projection");
        let payload_digest = identity.as_object_mut().unwrap().remove("payload_digest");
        ensure!(
            matches!(
                projection.as_ref().and_then(Value::as_str),
                Some("text-v1" | "artifacts-v1")
            ) && payload_digest
                == Some(json!(digest(
                    json!([request.body.content, request.body.attachments])
                        .to_string()
                        .as_bytes()
                ))),
            "parent final transport projection changed"
        );
        ensure!(
            request.delivery_id == Self::output_id(&row.notification_id)
                && request.target.conversation_id == row.conversation_id
                && request.kind == DeliveryKind::Proactive
                && identity == Self::metadata(row),
            "parent final delivery identity changed"
        );
        request.frame()?;
        ensure!(
            request.body.attachments.is_empty(),
            "legacy notification cannot deliver attachments; preserve the old immutable receipt"
        );
        // For plain text the exact immutable projection is independently checked.
        // Artifact projections are themselves durable immutable outbox receipts.
        if projection.as_ref().and_then(Value::as_str) == Some("text-v1") {
            ensure!(
                request.body.content == outcome_text(row)? && request.body.attachments.is_empty(),
                "parent final delivery payload changed"
            );
        }
        Ok(())
    }
    async fn projection(&self, source: &str) -> Result<Option<DeliveryRequest>> {
        let source = source.to_owned();
        self.outbox
            .db
            .call(move |db| {
                let saved: Option<String> = db
                    .query_row(
                        "SELECT request FROM parent_final_projections WHERE source=?1",
                        [source],
                        |r| r.get(0),
                    )
                    .optional()?;
                saved.map(|s| Ok(serde_json::from_str(&s)?)).transpose()
            })
            .await
    }
    async fn commit_projection(&self, source: &str, request: &DeliveryRequest) -> Result<()> {
        let source = source.to_owned();
        let serialized = serde_json::to_string(request)?;
        self.outbox
            .db
            .call(move |db| {
                let old: Option<String> = db
                    .query_row(
                        "SELECT request FROM parent_final_projections WHERE source=?1",
                        [&source],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(old) = old {
                    ensure!(old == serialized, "parent final projection changed");
                } else {
                    db.execute(
                        "INSERT INTO parent_final_projections(source,request) VALUES(?1,?2)",
                        params![source, serialized],
                    )?;
                }
                Ok(())
            })
            .await
    }
    async fn ensure_current_output(&self, row: &ContinuationRecord) -> Result<()> {
        ensure!(
            !self.stopping.load(Ordering::Acquire)
                && self.core.session_generation(row.session_id.clone()).await? == row.generation
                && self
                    .runtime
                    .completion_is_current(&row.notification_id)
                    .await?,
            "parent final stopped before artifact preparation"
        );
        ensure!(
            self.queue
                .inspect(&row.notification_id)
                .await?
                .is_some_and(|r| matches!(
                    r.state,
                    crate::parent_continuation::ContinuationState::FinalCommitted
                        | crate::parent_continuation::ContinuationState::Enqueued
                        | crate::parent_continuation::ContinuationState::Uncertain
                        | crate::parent_continuation::ContinuationState::Unavailable
                )),
            "parent final suppressed before artifact preparation"
        );
        Ok(())
    }
    async fn output_cancelled(&self, row: &ContinuationRecord) {
        loop {
            let changed = self.runtime.completion_fence_changed();
            tokio::pin!(changed);
            if self.ensure_current_output(row).await.is_err() {
                return;
            }
            tokio::select! {_=changed=>{},_=self.stopped()=>return,_=tokio::time::sleep(Duration::from_millis(250))=>{}}
        }
    }
    async fn request(&self, row: &ContinuationRecord) -> Result<DeliveryRequest> {
        let mut content = outcome_text(row)?;
        // The pinned original Server drops delivery attachments when mapping
        // notifications to mobile. Never advertise an invisible attachment.
        let attachments = Vec::new();
        let artifact_projection = self.outputs.is_some()
            && !crate::output_files::parse_media_markers(&content).is_empty();
        if artifact_projection && let Some(outputs) = &self.outputs {
            self.verifier.verify(&row.conversation_id).await?;
            let scope = OutputScope {
                conversation_id: row.conversation_id.clone(),
                input_id: row.input_id.clone(),
            };
            // Recheck after potentially slow remote verification. Cancellation
            // drops preparation promptly; a started upload's durable uploading
            // receipt remains uncertain rather than authorizing another attempt.
            self.ensure_current_output(row).await?;
            let media = tokio::select! {biased;
                _=self.output_cancelled(row)=>anyhow::bail!("parent stopped during artifact preparation"),
                result=tokio::time::timeout(Duration::from_secs(30),outputs.finalize_media(&scope,&content))=>result.context("artifact preparation timed out").and_then(|v|v),
            };
            match media {
                Ok(media) => {
                    content = if media.attachments.is_empty() {
                        media.text
                    } else {
                        legacy_artifact_notice(&media.text)
                    };
                    // Uploaded bytes and exact metadata remain in OutputFiles.
                    // Do not expose download URLs, invent a message anchor, or
                    // mistake a notification ACK for attachment delivery.
                }
                Err(_) => {
                    content = output_notice(
                        &content,
                        "附件尚未完成上传，原始结果已保留；未确认的上传不会自动重复执行。",
                    );
                }
            }
        }
        let mut metadata = Self::metadata(row);
        metadata["projection"] = json!(if artifact_projection {
            "artifacts-v1"
        } else {
            "text-v1"
        });
        metadata["payload_digest"] =
            json!(digest(json!([content, attachments]).to_string().as_bytes()));
        let request = DeliveryRequest {
            delivery_id: Self::output_id(&row.notification_id),
            target: DeliveryTarget {
                owner: self.outbox.identity.owner.clone(),
                device_id: self.outbox.identity.device_id.clone(),
                conversation_id: row.conversation_id.clone(),
            },
            kind: DeliveryKind::Proactive,
            body: DeliveryBody {
                content,
                attachments,
                metadata,
            },
        };
        self.validate_request(row, &request)?;
        Ok(request)
    }
    pub async fn prepare_send(&self, id: &str) -> Result<Option<ParentFinalSendPermit>> {
        let source = Self::source_id(id)?;
        let Some(lease) = self.queue.prepare_send(source).await? else {
            self.outbox.cancel(id).await?;
            return Ok(None);
        };
        let row = lease.record();
        if self.core.session_generation(row.session_id.clone()).await? != row.generation {
            // Never acquire queue's write gate while retaining the read permit.
            drop(lease);
            self.outbox.cancel(id).await?;
            self.queue
                .suppress_output(source, "session generation changed before final send")
                .await?;
            return Ok(None);
        }
        let Some(saved) = self
            .outbox
            .inspect(id)
            .await?
            .filter(|r| r.status == DeliveryStatus::Pending)
        else {
            return Ok(None);
        };
        // Pre-release artifacts-v1 rows may contain attachments that the pinned
        // Server silently drops. Keep their immutable receipt, but never send
        // them or mislabel them delivered. Do not disconnect unrelated output.
        if !saved.request.body.attachments.is_empty() {
            return Ok(None);
        }
        self.validate_request(row, &saved.request)?;
        ensure!(
            self.projection(source).await?.as_ref() == Some(&saved.request),
            "parent final does not match its host projection receipt"
        );
        Ok(Some(ParentFinalSendPermit {
            frame: saved.request.frame()?,
            _lease: lease,
        }))
    }
    async fn ingest(&self, cursor: &mut Option<String>) -> Result<()> {
        let rows = self
            .runtime
            .pending_completions_after(cursor.as_deref(), PAGE)
            .await?;
        *cursor = next_cursor(rows.len(), rows.last().map(|r| r.notification_id.clone()));
        for row in rows {
            // An unavailable/stale record cannot poison the remaining page.
            if self.queue.enqueue(&row.notification_id).await.is_ok() {
                self.runtime
                    .mark_completion_enqueued(&row.notification_id)
                    .await?;
            }
        }
        Ok(())
    }
    async fn chat_anchor(&self, row: &ContinuationRecord) -> Result<Option<ProvenChatAnchor>> {
        let root = self.queue.root_parent_input(&row.notification_id).await?;
        let anchor = self
            .journal
            .proven_chat_anchor(&root, &row.conversation_id)
            .await?;
        // A known chat journal entry without authentic inbound proof is not a
        // non-chat source and must not silently switch transports.
        ensure!(
            anchor.is_some()
                || self
                    .journal
                    .inspect(&format!("chat:{root}"))
                    .await?
                    .is_none(),
            "original chat anchor has no durable inbound provenance; result retained"
        );
        Ok(anchor)
    }
    fn reply_source(row: &ContinuationRecord, anchor: &ProvenChatAnchor) -> ReplySource {
        ReplySource {
            notification_id: row.notification_id.clone(),
            input_id: row.input_id.clone(),
            parent_input_id: row.parent_input_id.clone(),
            root_input_id: anchor.message_id().to_owned(),
            session_id: row.session_id.clone(),
            conversation_id: row.conversation_id.clone(),
            generation: row.generation,
            outcome_digest: digest(
                json!([row.final_assistant, row.reason])
                    .to_string()
                    .as_bytes(),
            ),
        }
    }
    async fn reply_projection(&self, source: &str) -> Result<Option<ReplyRequest>> {
        let source = source.to_owned();
        self.outbox
            .db
            .call(move |db| {
                let saved: Option<String> = db
                    .query_row(
                        "SELECT request FROM parent_reply_projections WHERE source=?1",
                        [source],
                        |r| r.get(0),
                    )
                    .optional()?;
                saved.map(|s| Ok(serde_json::from_str(&s)?)).transpose()
            })
            .await
    }
    async fn commit_reply_projection(&self, request: &ReplyRequest) -> Result<()> {
        let source = request.source.notification_id.clone();
        let serialized = serde_json::to_string(request)?;
        self.outbox
            .db
            .call(move |db| {
                let old: Option<String> = db
                    .query_row(
                        "SELECT request FROM parent_reply_projections WHERE source=?1",
                        [&source],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(old) = old {
                    ensure!(old == serialized, "parent reply projection changed");
                } else {
                    db.execute(
                        "INSERT INTO parent_reply_projections(source,request) VALUES(?1,?2)",
                        params![source, serialized],
                    )?;
                }
                Ok(())
            })
            .await
    }
    async fn bind_reply_artifacts(&self, request: &ReplyRequest) -> Result<()> {
        if request.artifact_ids.is_empty() {
            return Ok(());
        }
        let outputs = self
            .outputs
            .as_ref()
            .context("persisted reply artifacts require the configured output service")?;
        outputs
            .bind_final(
                &request.message_id(),
                &OutputScope {
                    conversation_id: request.source.conversation_id.clone(),
                    input_id: request.source.input_id.clone(),
                },
                &request.artifact_ids,
            )
            .await
    }
    async fn new_reply(
        &self,
        row: &ContinuationRecord,
        anchor: &ProvenChatAnchor,
    ) -> Result<ReplyRequest> {
        let mut content = outcome_text(row)?;
        let mut attachments = Vec::new();
        let mut artifact_ids = Vec::new();
        if let Some(outputs) = &self.outputs
            && !crate::output_files::parse_media_markers(&content).is_empty()
        {
            self.verifier.verify(&row.conversation_id).await?;
            self.ensure_current_output(row).await?;
            let scope = OutputScope {
                conversation_id: row.conversation_id.clone(),
                input_id: row.input_id.clone(),
            };
            let prepared = tokio::select! {biased;
                _=self.output_cancelled(row)=>anyhow::bail!("parent stopped during reply artifact preparation"),
                result=tokio::time::timeout(Duration::from_secs(30),outputs.finalize_media(&scope,&content))=>result.context("reply artifact preparation timed out").and_then(|v|v),
            };
            match prepared {
                Ok(media) => {
                    content = media.text;
                    attachments = media.attachments;
                    artifact_ids = media.artifacts.into_iter().map(|a| a.artifact_id).collect();
                }
                Err(_) => {
                    content = output_notice(
                        &content,
                        "附件尚未完成上传，原始结果已保留；未确认的上传不会自动重复执行。",
                    )
                }
            }
        }
        let source = Self::reply_source(row, anchor);
        let mut frame = json!({"version":1,"type":"message.reply","message_id":self.replies.message_id(&row.notification_id),
            "reply_to":anchor.message_id(),"conversation_id":row.conversation_id,"content":content});
        if !attachments.is_empty() {
            frame["attachments"] = serde_json::to_value(attachments)?;
        }
        Ok(ReplyRequest {
            source,
            frame,
            artifact_ids,
        })
    }
    async fn flush_reply(&self, row: &ContinuationRecord, anchor: ProvenChatAnchor) -> Result<()> {
        ensure!(
            self.reply_followups.load(Ordering::Acquire),
            "reply_followups unavailable; original chat final retained without changing channel"
        );
        let id = self.replies.message_id(&row.notification_id);
        let request = if let Some(saved) = self.reply_projection(&row.notification_id).await? {
            ensure!(
                saved.source == Self::reply_source(row, &anchor),
                "parent reply source changed"
            );
            saved
        } else {
            ensure!(
                self.replies.inspect(&id).await?.is_none(),
                "unbound parent reply outbox row"
            );
            let request = self.new_reply(row, &anchor).await?;
            self.commit_reply_projection(&request).await?;
            request
        };
        self.replies.enqueue(request.clone(), &anchor).await?;
        self.bind_reply_artifacts(&request).await?;
        self.queue.mark_enqueued(&row.notification_id).await?;
        self.output_ready.notify_one();
        Ok(())
    }
    pub async fn pending_replies_after(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ReplyRecord>> {
        if !self.reply_followups.load(Ordering::Acquire) {
            return Ok(Vec::new());
        }
        self.replies.pending_after(after, limit, now_ms()).await
    }
    pub async fn verify_reply(&self, id: &str) -> Result<()> {
        let row = self
            .replies
            .inspect(id)
            .await?
            .context("parent reply disappeared")?;
        self.verifier
            .verify(&row.request.source.conversation_id)
            .await
    }
    pub async fn prepare_reply_send(&self, id: &str) -> Result<Option<ParentFinalSendPermit>> {
        if !self.reply_followups.load(Ordering::Acquire) {
            return Ok(None);
        }
        let Some(saved) = self.replies.inspect(id).await? else {
            return Ok(None);
        };
        if saved.status != ReplyStatus::Pending {
            return Ok(None);
        }
        let source = &saved.request.source.notification_id;
        let Some(row) = self.queue.inspect(source).await? else {
            return Ok(None);
        };
        if !matches!(
            row.state,
            crate::parent_continuation::ContinuationState::FinalCommitted
                | crate::parent_continuation::ContinuationState::Enqueued
                | crate::parent_continuation::ContinuationState::Uncertain
                | crate::parent_continuation::ContinuationState::Unavailable
        ) {
            self.replies
                .suppress(id, "parent continuation is no longer output-ready")
                .await?;
            return Ok(None);
        }
        let anchor = self
            .chat_anchor(&row)
            .await?
            .context("parent reply lost proven original anchor")?;
        ensure!(
            saved.request.source == Self::reply_source(&row, &anchor),
            "parent reply source changed"
        );
        ensure!(
            self.reply_projection(source).await?.as_ref() == Some(&saved.request),
            "parent reply does not match its host projection receipt"
        );
        // Repair an enqueue-before-binding crash using the stored artifact IDs,
        // before a socket attempt can produce a commit ACK.
        self.bind_reply_artifacts(&saved.request).await?;
        let Some(lease) = self.queue.prepare_send(source).await? else {
            self.replies
                .suppress(id, "parent stopped or generation changed before reply send")
                .await?;
            return Ok(None);
        };
        if self.core.session_generation(row.session_id.clone()).await? != row.generation {
            drop(lease);
            self.replies
                .suppress(id, "parent generation changed before reply send")
                .await?;
            self.queue
                .suppress_output(source, "parent generation changed before reply send")
                .await?;
            return Ok(None);
        }
        if !self.reply_followups.load(Ordering::Acquire) {
            return Ok(None);
        }
        let Some(frame) = self.replies.prepare_send(id, now_ms()).await? else {
            return Ok(None);
        };
        ensure!(
            frame == saved.request.frame,
            "immutable parent reply frame changed"
        );
        Ok(Some(ParentFinalSendPermit {
            frame,
            _lease: lease,
        }))
    }
    pub async fn acknowledge_reply(&self, frame: Value) -> Result<bool> {
        let id = frame["message_id"]
            .as_str()
            .context("parent reply ACK ID missing")?
            .to_owned();
        let accepted = self.replies.acknowledge(frame).await?;
        if accepted {
            if let Some(outputs) = &self.outputs {
                outputs.ack_final(&id).await?;
            }
            self.wake.notify_one();
        }
        Ok(accepted)
    }
    pub async fn reject_reply(&self, frame: Value) -> Result<bool> {
        self.replies.reject(frame, now_ms()).await
    }
    pub async fn reply_delivered(&self, id: &str) -> Result<bool> {
        Ok(self
            .replies
            .inspect(id)
            .await?
            .is_some_and(|r| r.status == ReplyStatus::Delivered))
    }
    async fn parent_reply_terminal(&self, row: &ContinuationRecord) -> Result<bool> {
        let Some(parent) = self.queue.inspect_input(&row.parent_input_id).await? else {
            return Ok(true);
        };
        if self.chat_anchor(&parent).await?.is_none() {
            return Ok(true);
        }
        Ok(self
            .replies
            .inspect(&self.replies.message_id(&parent.notification_id))
            .await?
            .is_some_and(|r| {
                matches!(
                    r.status,
                    ReplyStatus::Delivered | ReplyStatus::Rejected | ReplyStatus::Uncertain
                )
            }))
    }
    async fn flush_one(&self, row: &ContinuationRecord) -> Result<()> {
        let id = Self::output_id(&row.notification_id);
        if self.core.session_generation(row.session_id.clone()).await? != row.generation
            || !self
                .runtime
                .completion_is_current(&row.notification_id)
                .await?
        {
            self.outbox.cancel(&id).await?;
            self.queue
                .suppress_output(
                    &row.notification_id,
                    "parent stopped or generation changed before output",
                )
                .await?;
            return Ok(());
        }
        if self.projection(&row.notification_id).await?.is_none()
            && self.outbox.inspect(&id).await?.is_none()
            && let Some(anchor) = self.chat_anchor(row).await?
        {
            return self.flush_reply(row, anchor).await;
        }
        // A crash after durable enqueue never reruns artifact preparation or
        // changes the retained transport payload, even if host options changed.
        let projection = if let Some(saved) = self.projection(&row.notification_id).await? {
            self.validate_request(row, &saved)?;
            saved
        } else {
            // Public outbox enqueue cannot impersonate artifact projection. Only
            // this host's earlier durable receipt authorizes the exact payload.
            ensure!(
                self.outbox.inspect(&id).await?.is_none(),
                "unbound parent final outbox row"
            );
            let request = self.request(row).await?;
            self.commit_projection(&row.notification_id, &request)
                .await?;
            request
        };
        self.outbox.enqueue(projection).await?;
        self.queue.mark_enqueued(&row.notification_id).await?;
        self.output_ready.notify_one();
        Ok(())
    }
    async fn execute(&self, id: String) {
        let result = async {
            let Some(claim) = self.queue.claim(&id).await? else {
                return Ok::<_, anyhow::Error>(());
            };
            if !self.parent_reply_terminal(claim.record()).await? {
                claim.release().await?;
                return Ok(());
            }
            tokio::select! { biased;
                _=self.stopped()=>{claim.release().await?; return Ok(());},
                result=self.verifier.verify(&claim.record().conversation_id)=>result?,
            }
            if self.stopping.load(Ordering::Acquire) {
                claim.release().await?;
                return Ok(());
            }
            let Some(input) = claim.start(&self.core, Some(&self.journal)).await? else {
                return Ok(());
            };
            let input = input.with_verifier(self.verifier.clone());
            let result = tokio::select! { biased;
                _=self.stopped()=>Err(anyhow::anyhow!("host shutdown")),
                result=tokio::time::timeout(input.run_timeout(),self.core.continue_parent(&input,None))=>{
                    result.context("continuation run timed out").and_then(|v|v)
                }
            };
            if result.is_ok() {
                if self
                    .queue
                    .finish(&self.core, input.input_id())
                    .await
                    .is_err()
                {
                    self.queue.interrupt(&self.core, input.input_id()).await?;
                }
            } else {
                self.queue.interrupt(&self.core, input.input_id()).await?;
            }
            self.wake.notify_one();
            Ok(())
        };
        // Verification is cancellable before a started claim. Once started, its
        // own select performs durable interruption rather than aborting the job.
        let _ = result.await;
    }
    /// One host pump: bounded scanning, four verification/model jobs, no retries
    /// of started model/tool work, and a rotating cursor for every pending lane.
    pub async fn run(&self) {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut tasks = tokio::task::JoinSet::new();
        let mut active = std::collections::BTreeSet::new();
        let mut output_tasks = tokio::task::JoinSet::<(String, bool)>::new();
        let mut output_active = std::collections::BTreeSet::new();
        let (mut completion_cursor, mut ready_cursor, mut output_cursor) = (None, None, None);
        let mut last_error: Option<Instant> = None;
        loop {
            tokio::select! { biased;
                _=self.stopped()=>break,
                done=tasks.join_next(),if !tasks.is_empty()=>{
                    if let Some(Ok(id))=done {active.remove(&id);}
                },
                done=output_tasks.join_next(),if !output_tasks.is_empty()=>{
                    if let Some(Ok((id,failed)))=done {
                        output_active.remove(&id);
                        if !failed {self.wake.notify_one();}
                        if failed && last_error.is_none_or(|t:Instant|t.elapsed()>=Duration::from_secs(60)) {
                            eprintln!("Parent continuation output deferred; committed receipts remain durable.");last_error=Some(Instant::now());
                        }
                    }
                },
                _=async {tokio::select!{_=tick.tick()=>{},_=self.runtime.completion_notified()=>{},_=self.wake.notified()=>{}}}=>{
                    let pump=async {
                        self.queue.recover(&self.core,PAGE).await?;
                        self.ingest(&mut completion_cursor).await?;
                        // Artifact verification/uploads use a separate bounded
                        // lane. They never hold up completion admission/model jobs.
                        if output_active.len()<2 {
                            let rows=self.queue.pending_outputs_after(output_cursor.as_deref(),PAGE).await?;
                            let full=rows.len()==PAGE;let mut examined=None;let mut exhausted=true;
                            for row in rows {
                                if output_active.len()>=2 {exhausted=false;break;}
                                examined=Some(row.notification_id.clone());
                                if output_active.insert(row.notification_id.clone()) {
                                    let host=self.clone();
                                    output_tasks.spawn(async move {
                                        let failed=tokio::select!{biased;
                                            _=host.stopped()=>false,
                                            result=host.flush_one(&row)=>result.is_err(),
                                        };
                                        (row.notification_id,failed)
                                    });
                                }
                            }
                            output_cursor=if exhausted && !full {None}else{examined.or(output_cursor.take())};
                        }
                        if active.len()<JOBS {
                            let rows=self.queue.queued_after(ready_cursor.as_deref(),PAGE).await?;
                            // Advance only through examined candidates. Do not skip
                            // a tail when all four slots fill mid-page.
                            let full=rows.len()==PAGE; let mut examined=None; let mut exhausted=true;
                            for row in rows {
                                if active.len()>=JOBS {exhausted=false;break;}
                                examined=Some(row.notification_id.clone());
                                if active.insert(row.notification_id.clone()) {
                                    let host=self.clone();let id=row.notification_id;
                                    tasks.spawn(async move {host.execute(id.clone()).await;id});
                                }
                            }
                            ready_cursor=if exhausted && !full {None}else{examined.or(ready_cursor.take())};
                        }
                        Ok::<_,anyhow::Error>(())
                    };
                    let result=tokio::select!{_=self.stopped()=>break,result=pump=>result};
                    if result.is_err() && last_error.is_none_or(|t|t.elapsed()>=Duration::from_secs(60)) {
                        eprintln!("Parent continuation handoff deferred; committed receipts remain durable.");last_error=Some(Instant::now());
                    }
                }
            }
        }
        self.queue.close_admission();
        // Started jobs select shutdown themselves, release the route, and retain
        // final or uncertain receipts. Do not abandon these by aborting JoinSet.
        while tasks.join_next().await.is_some() {}
        while output_tasks.join_next().await.is_some() {}
    }
}
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
fn next_cursor(count: usize, last: Option<String>) -> Option<String> {
    if count == PAGE { last } else { None }
}
fn bounded_text(text: &str) -> String {
    if text.len() <= MAX_TEXT {
        return text.to_owned();
    }
    let note = "\n\n[结果过长，通知已截断；完整结果保留在会话执行记录中。]";
    let mut end = MAX_TEXT - note.len();
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{note}", &text[..end])
}
const LEGACY_ARTIFACT_NOTICE: &str = "附件已上传，上传记录已保留；当前通知通道不展示或交付附件。";
fn legacy_artifact_notice(text: &str) -> String {
    output_notice(text, LEGACY_ARTIFACT_NOTICE)
}
fn output_notice(text: &str, notice: &str) -> String {
    let text = text.trim();
    if text.is_empty() {
        return notice.to_owned();
    }
    let separator = "\n\n";
    let limit = MAX_TEXT - notice.len() - separator.len();
    if text.len() <= limit {
        return format!("{text}{separator}{notice}");
    }
    let truncation = "\n[正文已截断；完整结果保留在执行记录中。]";
    let mut end = limit - truncation.len();
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{truncation}{separator}{notice}", &text[..end])
}
fn outcome_text(row: &ContinuationRecord) -> Result<String> {
    if let Some(final_message) = &row.final_assistant {
        let body = final_message["content"]
            .as_str()
            .context("committed parent final text missing")?;
        ensure!(!body.trim().is_empty(), "empty committed parent final");
        return Ok(bounded_text(body));
    }
    let reason = row
        .reason
        .as_deref()
        .context("parent outcome has no final or diagnostic")?;
    Ok(bounded_text(&format!(
        "后台任务结果已保存，但后续处理未完成。已开始的模型或工具操作不会自动重试。\n{reason}"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_attachment_only_and_text_projection_are_nonempty_and_honest() {
        assert_eq!(legacy_artifact_notice(""), LEGACY_ARTIFACT_NOTICE);
        assert_eq!(
            legacy_artifact_notice("Useful summary"),
            format!("Useful summary\n\n{LEGACY_ARTIFACT_NOTICE}")
        );
        let large = legacy_artifact_notice(&"结果".repeat(MAX_TEXT));
        assert!(large.len() <= MAX_TEXT);
        assert!(large.ends_with(LEGACY_ARTIFACT_NOTICE));
        assert!(!large.contains("http"));
        let failure = "附件尚未完成上传；未确认的上传不会自动重复执行。";
        let failed = output_notice(&"结果".repeat(MAX_TEXT), failure);
        assert!(failed.len() <= MAX_TEXT);
        assert!(failed.ends_with(failure));
    }
    #[test]
    fn output_namespace_is_reversible_and_distinct() {
        let source = "delegation-completion-0123456789";
        let id = ParentContinuationHost::output_id(source);
        assert_ne!(id, source);
        assert_eq!(ParentContinuationHost::source_id(&id).unwrap(), source);
        assert!(ParentContinuationHost::source_id("parent-final:").is_err());
    }
    #[test]
    fn large_multibyte_final_is_bounded_without_losing_original() {
        let original = "结果".repeat(MAX_TEXT);
        let value = bounded_text(&original);
        assert!(value.len() <= MAX_TEXT);
        assert!(value.ends_with("完整结果保留在会话执行记录中。]"));
        assert_eq!(original.len(), MAX_TEXT * 6);
        assert_eq!(bounded_text("exact final"), "exact final");
    }
}
