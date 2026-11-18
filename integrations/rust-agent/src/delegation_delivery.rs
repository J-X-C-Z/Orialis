//! Immutable background-child result handoff to the existing Orialis outbox.
//! The legacy server acknowledges notifications, not durable mobile messages.
use crate::{
    Core,
    delegation::{BackgroundCompletion, CompletionSendPermit, DelegationRuntime},
    delivery::{
        DeliveryBody, DeliveryKind, DeliveryOutbox, DeliveryRequest, DeliveryStatus, DeliveryTarget,
    },
    inbound_delivery::ConversationVerifier,
};
use anyhow::{Result, ensure};
use serde_json::{Value, json};

#[derive(Clone)]
pub struct DelegationDelivery {
    runtime: DelegationRuntime,
    core: Core,
    outbox: DeliveryOutbox,
    verifier: ConversationVerifier,
    output_ready: std::sync::Arc<tokio::sync::Notify>,
    parent_ready: std::sync::Arc<tokio::sync::Notify>,
    parent_journal: Option<crate::journal::Journal>,
    scan_cursor: std::sync::Arc<tokio::sync::Mutex<Option<String>>>,
}

pub struct DelegationSendPermit {
    frame: Value,
    _lease: CompletionSendPermit,
}
impl DelegationSendPermit {
    pub fn frame(&self) -> &Value {
        &self.frame
    }
}

impl DelegationDelivery {
    /// Every argument is selected by the trusted host, never a model field.
    pub fn new(
        runtime: DelegationRuntime,
        core: Core,
        outbox: DeliveryOutbox,
        verifier: ConversationVerifier,
    ) -> Self {
        Self {
            runtime,
            core,
            outbox,
            verifier,
            output_ready: std::sync::Arc::new(tokio::sync::Notify::new()),
            parent_ready: std::sync::Arc::new(tokio::sync::Notify::new()),
            parent_journal: None,
            scan_cursor: std::sync::Arc::new(tokio::sync::Mutex::new(None)),
        }
    }

    /// Main gateway supplies its final-reply journal. Component-only users that
    /// omit this builder explicitly own parent-turn ordering themselves.
    pub fn with_parent_journal(mut self, journal: crate::journal::Journal) -> Self {
        self.parent_journal = Some(journal);
        self
    }
    pub fn parent_terminal(&self) {
        self.parent_ready.notify_one();
    }
    pub async fn completion_notified(&self) {
        tokio::select! {_=self.runtime.completion_notified()=>{},_=self.parent_ready.notified()=>{}}
    }
    async fn parent_finished(&self, completion: &BackgroundCompletion) -> Result<bool> {
        let Some(journal) = &self.parent_journal else {
            return Ok(true);
        };
        if let Some(parent) = journal
            .inspect(&format!("chat:{}", completion.input_id))
            .await?
        {
            if let Some(frame) = &parent.frame {
                ensure!(
                    frame["conversation_id"]
                        .as_str()
                        .is_none_or(|conv| conv == completion.conversation_id),
                    "parent reply conversation differs"
                );
            }
            // A ready but unsent final must not be overtaken. Interrupted/rejected
            // parents are terminal for ordering, not claims of successful delivery.
            return Ok(matches!(
                parent.state.as_str(),
                "delivered" | "rejected" | "uncertain"
            ));
        }
        // Non-chat ingress (scheduled/inbound work) has Core receipts but no
        // chat journal row. Do not invent a message ACK for that transport.
        use crate::session_context::TurnLookup;
        Ok(
            match self
                .core
                .lookup_turn(completion.session_id.clone(), completion.input_id.clone())
                .await?
            {
                TurnLookup::Completed { .. }
                | TurnLookup::Cancelled { .. }
                | TurnLookup::CancelledBeforeStart
                | TurnLookup::CommandCompleted { .. } => true,
                TurnLookup::Pending { state, .. } => state == "interrupted",
                TurnLookup::Missing => false,
            },
        )
    }
    pub async fn output_notified(&self) {
        self.output_ready.notified().await;
    }

    fn request(&self, completion: &BackgroundCompletion) -> Result<DeliveryRequest> {
        let request = DeliveryRequest {
            delivery_id: completion.notification_id.clone(),
            target: DeliveryTarget {
                owner: self.outbox.identity.owner.clone(),
                device_id: self.outbox.identity.device_id.clone(),
                conversation_id: completion.conversation_id.clone(),
            },
            kind: DeliveryKind::Proactive,
            body: DeliveryBody {
                content: completion_text(&completion.result)?,
                attachments: Vec::new(),
                metadata: json!({"source":"native_delegation", "delegation_id":completion.delegation_id, "input_id":completion.input_id}),
            },
        };
        request.target.validate(&self.outbox.identity)?;
        request.body.validate()?;
        Ok(request)
    }

    /// Two durable journals use one stable ID and immutable payload. A crash
    /// after enqueue but before marking transferred only repeats that enqueue.
    pub async fn flush(&self, limit: usize) -> Result<usize> {
        ensure!((1..=128).contains(&limit), "invalid completion page size");
        let mut count = 0;
        // Keep bounded progress even when a whole page has unfinished parents.
        // A new scan begins after the last page; there is no busy loop repeatedly
        // rereading one blocked prefix. Concurrent flush callers share the cursor.
        let mut cursor = self.scan_cursor.lock().await;
        let page = self
            .runtime
            .pending_completions_after(cursor.as_deref(), limit)
            .await?;
        let full = page.len() == limit;
        *cursor = if full {
            page.last().map(|row| row.notification_id.clone())
        } else {
            None
        };
        for completion in page {
            if self
                .core
                .session_generation(completion.session_id.clone())
                .await?
                != completion.generation
                || !self
                    .runtime
                    .completion_is_current(&completion.notification_id)
                    .await?
            {
                self.outbox.cancel(&completion.notification_id).await?;
                self.runtime
                    .mark_completion_enqueued(&completion.notification_id)
                    .await?;
                continue;
            }
            if !self.parent_finished(&completion).await? {
                continue;
            }
            self.outbox.enqueue(self.request(&completion)?).await?;
            self.runtime
                .mark_completion_enqueued(&completion.notification_id)
                .await?;
            count += 1;
            self.output_ready.notify_one();
        }
        Ok(count)
    }

    pub async fn owns(&self, id: &str) -> Result<bool> {
        Ok(self.runtime.inspect_completion(id).await?.is_some())
    }

    /// Network ownership checks run on a bounded producer, not the WS reader.
    pub async fn verify_output(&self, id: &str) -> Result<()> {
        if let Some(completion) = self.runtime.inspect_completion(id).await? {
            self.verifier.verify(&completion.conversation_id).await?;
        }
        Ok(())
    }

    /// Retain this lease through the bounded socket send. Cancellation/reset
    /// serializes against this attempted send, not against remote persistence.
    pub async fn prepare_send(&self, id: &str) -> Result<Option<DelegationSendPermit>> {
        let Some(lease) = self.runtime.prepare_completion_send(id).await? else {
            self.outbox.cancel(id).await?;
            return Ok(None);
        };
        let completion = lease.completion();
        if !self.parent_finished(completion).await? {
            return Ok(None);
        }
        if self
            .core
            .session_generation(completion.session_id.clone())
            .await?
            != completion.generation
        {
            self.outbox.cancel(id).await?;
            return Ok(None);
        }
        let Some(row) = self
            .outbox
            .inspect(id)
            .await?
            .filter(|row| row.status == DeliveryStatus::Pending)
        else {
            return Ok(None);
        };
        ensure!(
            row.request == self.request(completion)?,
            "background notification receipt changed"
        );
        Ok(Some(DelegationSendPermit {
            frame: row.request.frame()?,
            _lease: lease,
        }))
    }
}

fn completion_text(result: &Value) -> Result<String> {
    let rows = result["results"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("delegation result rows missing"))?;
    ensure!(rows.len() <= 64, "too many completion summaries");
    let mut text = if result["partial"] == true {
        "后台任务已结束，部分工作未完成或结果不确定。已执行的操作不会自动撤销。\n".to_owned()
    } else {
        "后台任务已完成。\n".to_owned()
    };
    // The runtime may validly retain 16 x 256 KiB summaries. Notification
    // projection is deliberately bounded independently; a large valid result
    // must not poison the first outbox page and starve later completions.
    let per_row = (60 * 1024 / rows.len().max(1)).min(16 * 1024);
    for (index, row) in rows.iter().enumerate() {
        let status = row["status"].as_str().unwrap_or("unknown");
        let summary = row["summary"].as_str().unwrap_or("");
        let status = bounded_prefix(status, 128);
        let shown = bounded_prefix(summary, per_row);
        text.push_str(&format!("\n{}. [{}]\n{}\n", index + 1, status, shown));
        if shown.len() < summary.len() {
            text.push_str("[通知摘要已截断；完整结果保留在任务记录中。]\n");
        }
    }
    Ok(text)
}

fn bounded_prefix(value: &str, maximum: usize) -> &str {
    let mut end = value.len().min(maximum);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn notification_projection_has_no_prompt_or_hidden_tool_payload() -> Result<()> {
        let text = completion_text(
            &json!({"partial":true,"secret_prompt":"not for notification", "results":[{"status":"uncertain","summary":"Visible result", "tool_args":{"private":"hidden"}}]}),
        )?;
        assert!(text.contains("Visible result") && text.contains("不确定"));
        assert!(!text.contains("private") && !text.contains("not for notification"));
        let large = completion_text(
            &json!({"results":vec![json!({"status":"completed","summary":"文".repeat(90_000)});16]}),
        )?;
        assert!(large.len() < 70 * 1024 && large.contains("摘要已截断"));
        assert!(completion_text(&json!({})).is_err());
        Ok(())
    }
}
