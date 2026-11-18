//! Authenticated, durable delivery TEXT ingress. Never dispatches slash commands.
//!
//! This is deliberately separate from Scheduler: incoming deliveries continue the
//! original conversation, while local cron occurrences have isolated sessions.
use crate::{
    ChatRequest, Core,
    account_scope::OwnerVerifier,
    delivery::{
        DeliveryBody, DeliveryIdentity, DeliveryKind, DeliveryOutbox, DeliveryRequest,
        DeliveryStatus, DeliveryTarget, MAX_DELIVERY_BYTES, digest, id,
    },
    session_context::{self, OwnerScope, TurnLookup},
    tool_runtime::TurnContext,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
    time::Duration,
};

/// Ownership is checked against the configured bearer, never payload metadata.
/// The pinned Server has no GET-conversation route; list_messages checks both
/// agent authentication and conversation ownership before reading its contents.
#[derive(Clone)]
pub struct ConversationVerifier {
    owner: OwnerVerifier,
    expected_scope: String,
    identity: DeliveryIdentity,
    client: reqwest::Client,
    endpoint: reqwest::Url,
}
impl ConversationVerifier {
    pub fn new(server: &str, device: &str, token: &str, expected_scope: String) -> Result<Self> {
        let owner = OwnerVerifier::new(server, device, token, None)?;
        let identity = DeliveryIdentity::new(&expected_scope, server, device, token)?;
        let mut endpoint = reqwest::Url::parse(server)?;
        ensure!(
            endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none(),
            "invalid delivery server URL"
        );
        let secure = matches!(endpoint.scheme(), "wss" | "https");
        ensure!(
            secure
                || matches!(
                    endpoint.host_str(),
                    Some("127.0.0.1" | "localhost" | "[::1]")
                ),
            "delivery verification requires HTTPS except loopback"
        );
        endpoint
            .set_scheme(if secure { "https" } else { "http" })
            .map_err(|_| anyhow::anyhow!("invalid server URL"))?;
        endpoint.set_path("/");
        let mut headers = reqwest::header::HeaderMap::new();
        let mut bearer = reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))?;
        bearer.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, bearer);
        let client = reqwest::Client::builder()
            .default_headers(headers)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            owner,
            expected_scope,
            identity,
            client,
            endpoint,
        })
    }
    pub async fn verify(&self, conversation: &str) -> Result<()> {
        id(conversation)?;
        ensure!(
            self.owner.verify().await?.scope() == self.expected_scope,
            "delivery bearer owner changed"
        );
        let mut endpoint = self.endpoint.clone();
        endpoint
            .path_segments_mut()
            .map_err(|_| anyhow::anyhow!("invalid server URL"))?
            .clear()
            .extend(["api", "v1", "conversations", conversation, "messages"]);
        endpoint.query_pairs_mut().append_pair("limit", "1");
        let response = self
            .client
            .get(endpoint)
            .send()
            .await
            .context("conversation verification unavailable")?;
        ensure!(
            response.status().as_u16() == 200,
            "delivery conversation is not authorized"
        );
        // A 200 is the contract's authorization decision. Do not consume private
        // message bodies merely to prove access, and never follow a redirect.
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InboundRecord {
    pub delivery_id: String,
    pub conversation_id: String,
    pub route: String,
    pub input_id: String,
    pub output_id: String,
    pub generation: i64,
    pub content: String,
    pub state: String,
    pub attempts: u32,
}
#[derive(Clone, Debug)]
pub struct Admission {
    pub record: InboundRecord,
    /// May be sent only after admit returns: the receipt is now durable.
    pub ack: Value,
}
/// Owns the local send/control ordering through one bounded transport attempt.
/// The host must hold this value until send completes or fails, then drop it.
pub struct SendPermit {
    frame: Value,
    _gate: tokio::sync::OwnedMutexGuard<()>,
}
impl SendPermit {
    pub fn frame(&self) -> &Value {
        &self.frame
    }
}
#[derive(Clone)]
pub struct InboundDeliveries {
    core: Core,
    outbox: DeliveryOutbox,
    verifier: ConversationVerifier,
    gate: Arc<tokio::sync::Mutex<()>>,
    running: Arc<Mutex<HashSet<String>>>,
}
struct Running(Arc<Mutex<HashSet<String>>>, String);
impl Drop for Running {
    fn drop(&mut self) {
        if let Ok(mut values) = self.0.lock() {
            values.remove(&self.1);
        }
    }
}

impl InboundDeliveries {
    pub async fn new(
        core: Core,
        outbox: DeliveryOutbox,
        verifier: ConversationVerifier,
    ) -> Result<Self> {
        ensure!(
            core.supports_session_context(),
            "inbound delivery requires durable Core receipts"
        );
        ensure!(
            outbox.identity == verifier.identity,
            "delivery verifier/outbox identity mismatch"
        );
        let owner = OwnerScope::new(&outbox.identity.owner)?;
        core.db(move |s| session_context::check_owner(&s.db, &owner))
            .await?;
        outbox.db.call(|db| {
            db.execute_batch("CREATE TABLE IF NOT EXISTS incoming_deliveries(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, record TEXT NOT NULL, conversation TEXT NOT NULL, output_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0); CREATE INDEX IF NOT EXISTS incoming_delivery_state ON incoming_deliveries(state); CREATE INDEX IF NOT EXISTS incoming_delivery_conversation ON incoming_deliveries(conversation,state); CREATE TABLE IF NOT EXISTS incoming_delivery_fences(conversation TEXT PRIMARY KEY,epoch INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS incoming_delivery_send_attempts(id TEXT PRIMARY KEY,attempts INTEGER NOT NULL);")?;
            Ok(())
        }).await?;
        Ok(Self {
            core,
            outbox,
            verifier,
            gate: Arc::new(tokio::sync::Mutex::new(())),
            running: Arc::new(Mutex::new(HashSet::new())),
        })
    }
    pub async fn admit(&self, frame: Value) -> Result<Admission> {
        ensure!(
            frame.is_object() && frame["version"] == 1,
            "invalid inbound delivery version"
        );
        ensure!(
            matches!(
                frame["type"].as_str(),
                Some("cron.delivery" | "proactive.delivery" | "delivery.send")
            ),
            "not an inbound delivery"
        );
        let delivery = frame["delivery_id"]
            .as_str()
            .context("delivery ID missing")?
            .to_owned();
        let conversation = frame["conversation_id"]
            .as_str()
            .context("delivery conversation missing")?
            .to_owned();
        id(&delivery)?;
        id(&conversation)?;
        ensure!(
            delivery.len() <= 160 && conversation.len() <= 160,
            "delivery ID too long"
        );
        let content = frame["content"]
            .as_str()
            .context("delivery text missing")?
            .to_owned();
        ensure!(
            !content.trim().is_empty() && content.len() <= 256 * 1024,
            "invalid delivery text"
        );
        ensure!(
            frame
                .get("attachments")
                .is_none_or(|v| v.as_array().is_some_and(Vec::is_empty)),
            "inbound delivery attachments are unsupported; text-only parity"
        );
        ensure!(
            frame
                .get("metadata")
                .is_none_or(|v| v.is_null() || v.is_object()),
            "invalid delivery metadata"
        );
        for (key, expected) in [
            ("owner", &self.outbox.identity.owner),
            ("owner_id", &self.outbox.identity.owner),
            ("device_id", &self.outbox.identity.device_id),
        ] {
            ensure!(
                frame.get(key).is_none_or(|v| v.as_str() == Some(expected)),
                "inbound delivery scope mismatch"
            );
        }
        let bytes = serde_json::to_vec(&frame)?;
        ensure!(
            bytes.len() <= MAX_DELIVERY_BYTES,
            "inbound delivery too large"
        );
        let fingerprint = digest(&bytes);
        // Capture the local control fence before the remote check. A /stop that
        // completes during HTTP verification must also reject this not-yet-stored
        // input, not merely the already-admitted rows.
        let epoch_conversation = conversation.clone();
        let epoch: i64 = self
            .outbox
            .db
            .call(move |db| {
                Ok(db
                    .query_row(
                        "SELECT epoch FROM incoming_delivery_fences WHERE conversation=?1",
                        [epoch_conversation],
                        |r| r.get(0),
                    )
                    .optional()?
                    .unwrap_or(0))
            })
            .await?;
        let generation = self
            .core
            .session_generation(crate::wire::digest(&conversation))
            .await?;
        self.verifier.verify(&conversation).await?;
        let _gate = self.gate.lock().await;
        let route = crate::wire::digest(&conversation);
        ensure!(
            self.core.session_generation(route.clone()).await? == generation,
            "delivery admission crossed reset"
        );
        let identity = digest(&serde_json::to_vec(&(
            &self.outbox.identity,
            &delivery,
            &conversation,
        ))?);
        let record = InboundRecord {
            delivery_id: delivery.clone(),
            conversation_id: conversation.clone(),
            route,
            input_id: format!("delivery_in_{identity}"),
            output_id: format!("delivery_out_{identity}"),
            generation,
            content,
            state: "admitted".into(),
            attempts: 0,
        };
        let result=self.outbox.db.call(move |db| {
            let tx=db.transaction()?;
            let current_epoch:i64=tx.query_row("SELECT epoch FROM incoming_delivery_fences WHERE conversation=?1",[&conversation],|r|r.get(0)).optional()?.unwrap_or(0);
            ensure!(current_epoch==epoch,"delivery admission crossed cancellation");
            if let Some((old, saved))=tx.query_row("SELECT fingerprint,record FROM incoming_deliveries WHERE id=?1",[&delivery],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()? {
                ensure!(old==fingerprint,"inbound delivery ID reused with changed payload or target");
                let mut stored:InboundRecord=serde_json::from_str(&saved)?;
                (stored.state,stored.attempts)=tx.query_row("SELECT state,attempts FROM incoming_deliveries WHERE id=?1",[&delivery],|r|Ok((r.get(0)?,r.get(1)?)))?;
                return Ok((stored,"duplicate"));
            }
            let (count,bytes):(usize,usize)=tx.query_row("SELECT COUNT(*),COALESCE(SUM(LENGTH(record)),0) FROM incoming_deliveries",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
            let serialized=serde_json::to_string(&record)?;
            ensure!(count<8192 && bytes.saturating_add(serialized.len())<=32*1024*1024,"inbound delivery journal capacity exhausted");
            tx.execute("INSERT INTO incoming_deliveries(id,fingerprint,record,conversation,output_id,state) VALUES(?1,?2,?3,?4,?5,'admitted')",params![delivery,fingerprint,serialized,conversation,record.output_id])?;
            tx.commit()?;
            Ok((record,"received"))
        }).await?;
        Ok(Admission {
            ack: json!({"version":1,"type":"delivery.ack","delivery_id":result.0.delivery_id,"conversation_id":result.0.conversation_id,"status":result.1}),
            record: result.0,
        })
    }
    pub async fn inspect(&self, delivery_id: &str) -> Result<Option<InboundRecord>> {
        let key = delivery_id.to_owned();
        self.outbox.db.call(move |db| read_record(db, &key)).await
    }
    /// Called only after the authenticated socket writer sent the ACK. A crash
    /// between send and this commit causes an ACK resend, not premature inference.
    pub async fn received(&self, delivery_id: &str) -> Result<()> {
        let key = delivery_id.to_owned();
        self.outbox.db.call(move |db| {
            ensure!(read_record(db,&key)?.is_some(),"unknown inbound receipt");
            db.execute("UPDATE incoming_deliveries SET state='queued' WHERE id=?1 AND state='admitted'",[key])?;
            Ok(())
        }).await
    }
    pub async fn pending_receipts(&self, limit: usize) -> Result<Vec<Admission>> {
        ensure!((1..=256).contains(&limit), "invalid receipt page size");
        self.outbox.db.call(move |db| {
            let mut q=db.prepare("SELECT id FROM incoming_deliveries WHERE state='admitted' ORDER BY rowid LIMIT ?1")?;
            let keys=q.query_map([limit],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            keys.into_iter().map(|key| {
                let record=read_record(db,&key)?.context("receipt disappeared")?;
                let ack=json!({"version":1,"type":"delivery.ack","delivery_id":record.delivery_id,"conversation_id":record.conversation_id,"status":"received"});
                Ok(Admission{record,ack})
            }).collect()
        }).await
    }
    /// At most one eligible head per conversation, ordered by durable admission.
    /// The SQL selection skips arbitrarily long same-conversation queues without
    /// pulling them into memory. An earlier unACKed/uncertain input blocks only
    /// its own conversation; retries cannot be overtaken by later inputs.
    /// Core receipts still decide whether resumption is safe.
    pub async fn ready(&self, limit: usize) -> Result<Vec<InboundRecord>> {
        ensure!((1..=256).contains(&limit), "invalid inbound page size");
        self.outbox.db.call(move |db| {
            let mut q=db.prepare("SELECT current.id FROM incoming_deliveries current WHERE current.state IN ('queued','running','retry') AND NOT EXISTS (SELECT 1 FROM incoming_deliveries prior WHERE prior.conversation=current.conversation AND prior.rowid<current.rowid AND prior.state IN ('admitted','queued','running','retry','uncertain')) ORDER BY current.rowid LIMIT ?1")?;
            let ids=q.query_map([limit],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            ids.into_iter().map(|id|read_record(db,&id)?.context("inbound record disappeared")).collect()
        }).await
    }
    async fn state(&self, key: &str, state: &str) -> Result<()> {
        let (key, state) = (key.to_owned(), state.to_owned());
        self.outbox.db.call(move |db|{db.execute("UPDATE incoming_deliveries SET state=?2 WHERE id=?1 AND state NOT IN ('cancelled','cancelled_after_send_attempt','completed')",params![key,state])?;Ok(())}).await
    }
    pub async fn execute(&self, key: &str) -> Result<()> {
        {
            let mut running = self
                .running
                .lock()
                .map_err(|_| anyhow::anyhow!("inbound running lock poisoned"))?;
            if !running.insert(key.to_owned()) {
                return Ok(());
            }
        }
        let _running = Running(self.running.clone(), key.to_owned());
        let record = self
            .inspect(key)
            .await?
            .context("unknown inbound delivery")?;
        if matches!(
            record.state.as_str(),
            "admitted"
                | "completed"
                | "cancelled"
                | "cancelled_after_send_attempt"
                | "uncertain"
                | "failed"
        ) {
            return Ok(());
        }
        self.verifier.verify(&record.conversation_id).await?;
        if self.core.session_generation(record.route.clone()).await? != record.generation {
            self.cancel_input(&record).await?;
            return Ok(());
        }
        let receipt = self
            .core
            .lookup_turn(record.route.clone(), record.input_id.clone())
            .await?;
        let completed = match receipt {
            TurnLookup::Completed { .. } => {
                self.core
                    .lookup_completed(
                        record.route.clone(),
                        record.input_id.clone(),
                        json!({"role":"user","content":record.content}),
                    )
                    .await?
            }
            TurnLookup::Cancelled { .. } | TurnLookup::CancelledBeforeStart => {
                self.cancel_input(&record).await?;
                return Ok(());
            }
            TurnLookup::Pending {
                uncertain_effects: true,
                ..
            }
            | TurnLookup::CommandCompleted { .. } => {
                self.state(key, "uncertain").await?;
                return Ok(());
            }
            _ => None,
        };
        let result = if let Some(completed) = completed {
            Ok(completed)
        } else {
            let _gate = self.gate.lock().await;
            let current = self
                .inspect(key)
                .await?
                .context("inbound delivery disappeared")?;
            if current.state.starts_with("cancelled") {
                return Ok(());
            }
            if current.attempts >= 3 {
                // This branch is reached only after ruling out uncertain tool
                // effects. Fence the exhausted receipt before marking terminal,
                // so it cannot monopolize the conversation's active-turn slot.
                self.core
                    .cancel_input(record.route.clone(), record.input_id.clone())
                    .await?;
                self.state(key, "failed").await?;
                return Ok(());
            }
            let id = key.to_owned();
            self.outbox.db.call(move |db|{db.execute("UPDATE incoming_deliveries SET state='running',attempts=attempts+1 WHERE id=?1",[id])?;Ok(())}).await?;
            drop(_gate);
            // The generation is checked inside the Core route lock as well as
            // at admission and send. Payload text is never sent to work_chat.
            self.core
                .chat_with_context_at_generation(
                    ChatRequest {
                        session_id: record.route.clone(),
                        message: record.content.clone(),
                    },
                    TurnContext {
                        session_id: record.route.clone(),
                        conversation_id: record.conversation_id.clone(),
                        input_id: record.input_id.clone(),
                    },
                    None,
                    record.generation,
                )
                .await
        };
        let answer = match result {
            Ok(answer) => answer,
            Err(error) => {
                let receipt = self
                    .core
                    .lookup_turn(record.route.clone(), record.input_id.clone())
                    .await?;
                let status = match receipt {
                    TurnLookup::Cancelled { .. } | TurnLookup::CancelledBeforeStart => "cancelled",
                    TurnLookup::Pending {
                        uncertain_effects: true,
                        ..
                    } => "uncertain",
                    _ => "retry",
                };
                self.state(key, status).await?;
                return Err(error);
            }
        };
        self.verifier.verify(&record.conversation_id).await?;
        let _gate = self.gate.lock().await;
        if self
            .inspect(key)
            .await?
            .is_none_or(|r| r.state.starts_with("cancelled"))
            || self.core.session_generation(record.route.clone()).await? != record.generation
        {
            drop(_gate);
            self.cancel_input(&record).await?;
            return Ok(());
        }
        self.outbox
            .enqueue(DeliveryRequest {
                delivery_id: record.output_id.clone(),
                target: DeliveryTarget {
                    owner: self.outbox.identity.owner.clone(),
                    device_id: self.outbox.identity.device_id.clone(),
                    conversation_id: record.conversation_id.clone(),
                },
                kind: DeliveryKind::Proactive,
                body: DeliveryBody::text(answer.answer),
            })
            .await?;
        // Crash between enqueue and this update is repaired from Core's completed
        // receipt and outbox's exact idempotent payload, never by another model.
        self.state(key, "completed").await?;
        Ok(())
    }
    async fn cancel_input(&self, record: &InboundRecord) -> Result<()> {
        let _gate = self.gate.lock().await;
        let key = record.delivery_id.clone();
        self.outbox
            .db
            .call(move |db| {
                db.execute(
                    "UPDATE incoming_deliveries SET state=CASE WHEN EXISTS(SELECT 1 FROM incoming_delivery_send_attempts a WHERE a.id=incoming_deliveries.id) THEN 'cancelled_after_send_attempt' ELSE 'cancelled' END WHERE id=?1",
                    [key],
                )?;
                Ok(())
            })
            .await?;
        self.core
            .cancel_input(record.route.clone(), record.input_id.clone())
            .await?;
        self.outbox.cancel(&record.output_id).await?;
        Ok(())
    }
    /// Call for an authenticated /stop or /new before cancelling/resetting Core.
    /// This fences admitted-but-not-started work and completed-but-unsent output.
    pub async fn cancel_conversation(&self, conversation: &str) -> Result<usize> {
        let _gate = self.gate.lock().await;
        let conv = conversation.to_owned();
        let records=self.outbox.db.call(move |db| {
            let tx=db.transaction()?;
            let rows={let mut q=tx.prepare("SELECT id FROM incoming_deliveries WHERE conversation=?1 AND state NOT LIKE 'cancelled%'")?;
                q.query_map([&conv],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?};
            let records=rows.into_iter().map(|id|read_record(&tx,&id)?.context("missing inbound record")).collect::<Result<Vec<_>>>()?;
            tx.execute("UPDATE deliveries SET status='cancelled' WHERE status='pending' AND id IN (SELECT output_id FROM incoming_deliveries WHERE conversation=?1)",[&conv])?;
            tx.execute("UPDATE incoming_deliveries SET state=CASE WHEN EXISTS(SELECT 1 FROM incoming_delivery_send_attempts a WHERE a.id=incoming_deliveries.id) THEN 'cancelled_after_send_attempt' ELSE 'cancelled' END WHERE conversation=?1",[&conv])?;
            tx.execute("INSERT INTO incoming_delivery_fences(conversation,epoch) VALUES(?1,1) ON CONFLICT(conversation) DO UPDATE SET epoch=epoch+1",[conv])?;
            tx.commit()?;Ok(records)
        }).await?;
        for record in &records {
            // Only started/suspended execution needs a Core tombstone. Queued
            // admissions are fenced under this same gate before execution, and
            // finalized history is never rewritten merely to suppress output.
            if matches!(record.state.as_str(), "running" | "retry" | "uncertain") {
                self.core
                    .cancel_input(record.route.clone(), record.input_id.clone())
                    .await?;
            }
        }
        Ok(records.len())
    }
    async fn output_record(&self, output_id: &str) -> Result<Option<InboundRecord>> {
        let id = output_id.to_owned();
        self.outbox
            .db
            .call(move |db| {
                let key: Option<String> = db
                    .query_row(
                        "SELECT id FROM incoming_deliveries WHERE output_id=?1",
                        [id],
                        |r| r.get(0),
                    )
                    .optional()?;
                key.map(|key| read_record(db, &key))
                    .transpose()
                    .map(Option::flatten)
            })
            .await
    }
    /// Remote checks run off the single socket reader/writer. Call once for each
    /// send/retry attempt before handing the output to that writer.
    pub async fn verify_output(&self, output_id: &str) -> Result<()> {
        if let Some(record) = self.output_record(output_id).await? {
            self.verifier.verify(&record.conversation_id).await?;
        }
        Ok(())
    }
    /// A durable send attempt and owned control lease, after verify_output.
    /// Keep the permit alive through a bounded socket send. Cancellation either
    /// commits before this lease (no attempt), or afterward (possible delivery).
    /// SQLite and the remote socket are intentionally not claimed atomic.
    pub async fn prepare_send(&self, output_id: &str) -> Result<Option<SendPermit>> {
        let gate = self.gate.clone().lock_owned().await;
        let record = self.output_record(output_id).await?;
        if let Some(record) = record.as_ref()
            && (record.state.starts_with("cancelled")
                || self.core.session_generation(record.route.clone()).await? != record.generation)
        {
            self.outbox.cancel(&record.output_id).await?;
            return Ok(None);
        }
        let Some(row) = self
            .outbox
            .inspect(output_id)
            .await?
            .filter(|r| r.status == DeliveryStatus::Pending)
        else {
            return Ok(None);
        };
        let frame = row.request.frame()?;
        if let Some(record) = record {
            let key = record.delivery_id;
            self.outbox.db.call(move |db| {
                db.execute("INSERT INTO incoming_delivery_send_attempts(id,attempts) VALUES(?1,1) ON CONFLICT(id) DO UPDATE SET attempts=attempts+1",[key])?;
                Ok(())
            }).await?;
        }
        Ok(Some(SendPermit { frame, _gate: gate }))
    }
}
fn read_record(db: &rusqlite::Connection, id: &str) -> Result<Option<InboundRecord>> {
    let row: Option<(String, String, u32)> = db
        .query_row(
            "SELECT record,state,attempts FROM incoming_deliveries WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    row.map(|(value, state, attempts)| {
        let mut record: InboundRecord = serde_json::from_str(&value)?;
        record.state = state;
        record.attempts = attempts;
        Ok(record)
    })
    .transpose()
}
