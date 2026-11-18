//! Explicit Core opt-in for lossless context and durable turn receipts.
use crate::{
    ChatResponse, Core, MemoryRequest, Provider, memory_runtime,
    session_context::{
        self as sc, CompressionPolicy, ContextView, OwnerScope, TurnLookup, TurnToken,
    },
    tool_runtime::TurnContext,
};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use std::time::Duration;

#[derive(Clone)]
pub(crate) struct SessionRuntime {
    pub(crate) scope: OwnerScope,
    policy: CompressionPolicy,
    summary_timeout: Duration,
}
pub(crate) enum PreparedTurn {
    Completed(ChatResponse),
    Ready {
        view: ContextView,
        token: TurnToken,
        checkpoint: Vec<Value>,
    },
}
impl sc::SummaryModel for Provider {
    fn summarize(&self, messages: Vec<Value>) -> sc::SummaryFuture<'_> {
        Box::pin(async move {
            // Keep finish_reason here: a length-stopped partial summary must not
            // replace the active view, even if it happens to fit our byte limit.
            let reply = if self.mock {
                self.complete_with_tools(&messages, &[], None).await?
            } else {
                let payload = json!({"model":self.model,"messages":messages,"tools":[],"temperature":0,"stream":false});
                let mut request = self.client.post(&self.endpoint).json(&payload);
                if let Some(key) = &self.api_key {
                    request = request.bearer_auth(key);
                }
                let mut response = request.send().await?;
                ensure!(
                    response.status().is_success(),
                    "summary provider returned unsuccessful status"
                );
                ensure!(
                    response.content_length().unwrap_or(0) <= 1_048_576,
                    "summary response too large"
                );
                let mut bytes = Vec::new();
                while let Some(chunk) = response.chunk().await? {
                    ensure!(
                        bytes.len() + chunk.len() <= 1_048_576,
                        "summary response too large"
                    );
                    bytes.extend_from_slice(&chunk);
                }
                let body: Value = serde_json::from_slice(&bytes)?;
                let choice = &body["choices"][0];
                ensure!(
                    choice["finish_reason"] == "stop",
                    "summary is partial or completion reason is unverified"
                );
                let reply = choice["message"].clone();
                ensure!(
                    reply["role"] == "assistant"
                        && reply["refusal"].as_str().is_none_or(str::is_empty),
                    "summary model did not return a completed assistant summary"
                );
                reply
            };
            ensure!(
                reply["tool_calls"].as_array().is_none_or(Vec::is_empty),
                "summary model requested unavailable tools"
            );
            Ok(reply["content"]
                .as_str()
                .context("summary model returned no text")?
                .to_owned())
        })
    }
}
impl Core {
    /// Explicit deployment opt-in. The owner comes from trusted configuration,
    /// never the model or request payload. Existing databases cannot change owner.
    pub fn with_session_context(
        mut self,
        owner_scope: String,
        policy: CompressionPolicy,
    ) -> Result<Self> {
        ensure!(
            policy.retain_turns > 0
                && policy.max_summary_bytes > 0
                && policy.max_input_bytes > 0
                && policy.minimum_reduction_percent < 100,
            "invalid compaction policy"
        );
        ensure!(
            !self.tools.contains("session_search"),
            "session_search is reserved by session context"
        );
        let scope = OwnerScope::new(&owner_scope)?;
        {
            let mut store = self
                .store
                .lock()
                .map_err(|_| anyhow::anyhow!("database lock poisoned"))?;
            sc::initialize(&mut store.db, &scope)?;
        }
        self.session = Some(SessionRuntime {
            scope,
            policy,
            summary_timeout: Duration::from_secs(30),
        });
        Ok(self)
    }
    pub fn with_summary_timeout(mut self, timeout: Duration) -> Result<Self> {
        ensure!(
            !timeout.is_zero() && timeout <= Duration::from_secs(300),
            "invalid summary timeout"
        );
        self.session
            .as_mut()
            .context("session context is not enabled")?
            .summary_timeout = timeout;
        Ok(self)
    }
    /// Replay-safe /new. Caller must validate the command body with its Journal.
    pub async fn reset_for_input(&self, route: String, input_id: String) -> Result<Value> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        let original = route.clone();
        let generation = self
            .db(move |s| sc::reset_for_input(&mut s.db, &runtime.scope, &route, &input_id))
            .await?;
        self.tools
            .set_session_generation(&original, generation)
            .await
            .context("session reset committed; tool cleanup is incomplete")?;
        Ok(json!({"session_id":original,"generation":generation}))
    }
    pub fn supports_session_context(&self) -> bool {
        self.session.is_some()
    }
    pub(crate) fn session_owner_fingerprint(&self) -> Option<&str> {
        self.session
            .as_ref()
            .map(|runtime| runtime.scope.fingerprint())
    }
    /// Does not wait for the route mutex or any model/tool request.
    pub async fn cancel_input(&self, route: String, input_id: String) -> Result<TurnLookup> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        self.db(move |s| sc::cancel_input(&mut s.db, &runtime.scope, &route, &input_id))
            .await
    }
    pub async fn cancel(&self, route: String) -> Result<usize> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        self.db(move |s| sc::cancel_route(&mut s.db, &runtime.scope, &route))
            .await
    }
    pub async fn lookup_turn(&self, route: String, input_id: String) -> Result<TurnLookup> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        self.db(move |s| sc::lookup_turn(&s.db, &runtime.scope, &route, &input_id))
            .await
    }
    /// Rebuild the same final reply after a Core commit / outbound journal crash.
    /// The incoming durable user object must match, including attachment references.
    pub async fn lookup_completed(
        &self,
        route: String,
        input_id: String,
        user: Value,
    ) -> Result<Option<ChatResponse>> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        self.db(move |s| {
            sc::verify_input(&s.db, &runtime.scope, &route, &input_id, &user)?;
            match sc::lookup_turn(&s.db, &runtime.scope, &route, &input_id)? {
                TurnLookup::Completed {
                    final_assistant, ..
                } => Ok(Some(completed_response(route, final_assistant)?)),
                _ => Ok(None),
            }
        })
        .await
    }
    pub async fn session_search(&self, args: Value) -> Result<Value> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        self.db(move |s| sc::search_tool(&s.db, &runtime.scope, &args))
            .await
    }
    pub(crate) async fn prepare_context_turn(
        &self,
        route: String,
        input_id: String,
        user: Value,
        expected_generation: Option<i64>,
    ) -> Result<PreparedTurn> {
        self.prepare_context_seed(
            route,
            input_id,
            user.clone(),
            vec![user],
            expected_generation,
            false,
        )
        .await
    }
    pub(crate) async fn prepare_context_seed(
        &self,
        route: String,
        input_id: String,
        user: Value,
        seed: Vec<Value>,
        expected_generation: Option<i64>,
        continuation: bool,
    ) -> Result<PreparedTurn> {
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        let scope = runtime.scope.clone();
        let id = route.clone();
        let input = input_id.clone();
        let inbound = user.clone();
        let (lookup, initial_session) = self
            .db(move |s| {
                let generation: i64 =
                    s.db.query_row("SELECT generation FROM routes WHERE id=?1", [&id], |r| {
                        r.get(0)
                    })
                    .optional()?
                    .unwrap_or(0);
                ensure!(
                    expected_generation.is_none_or(|expected| expected == generation),
                    "session generation changed before turn admission"
                );
                sc::verify_input(&s.db, &scope, &id, &input, &inbound)?;
                let lookup = sc::lookup_turn(&s.db, &scope, &id, &input)?;
                let active = s.active_session(&id)?;
                // Avoid loading the entire raw archive on every compacted turn.
                let exists: bool = s.db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM sessions WHERE id=?1)",
                    [&active],
                    |r| r.get(0),
                )?;
                if !exists && matches!(lookup, TurnLookup::Missing | TurnLookup::Pending { .. }) {
                    s.load_session(&active)?;
                }
                Ok((lookup, active))
            })
            .await?;
        match lookup {
            TurnLookup::Completed {
                final_assistant, ..
            } => {
                return Ok(PreparedTurn::Completed(completed_response(
                    route,
                    final_assistant,
                )?));
            }
            TurnLookup::CommandCompleted { .. } => {
                bail!("trusted input belongs to a completed command, not a chat turn")
            }
            TurnLookup::Cancelled { .. } | TurnLookup::CancelledBeforeStart => {
                bail!("trusted input was cancelled; use a new input identity for new work")
            }
            TurnLookup::Pending {
                token,
                uncertain_effects,
                ..
            } => {
                ensure!(
                    !continuation,
                    "a parent continuation already started; refusing automatic replay"
                );
                ensure!(
                    !uncertain_effects,
                    "tool effects have uncertain outcomes; refusing automatic replay"
                );
                let scope = runtime.scope.clone();
                return self
                    .db(move |s| {
                        let (token, checkpoint) = sc::resume_turn(&mut s.db, &scope, &token)?;
                        let view = sc::load_context(&s.db, &scope, &route)?;
                        ensure!(
                            view.session_id == token.session_id
                                && view.total_messages == token.base_count,
                            "recovery context changed"
                        );
                        Ok(PreparedTurn::Ready {
                            view,
                            token,
                            checkpoint,
                        })
                    })
                    .await;
            }
            TurnLookup::Missing => {}
        }
        let scope = runtime.scope.clone();
        let id = route.clone();
        let policy = runtime.policy.clone();
        let plan = self
            .db(move |s| sc::prepare_compaction(&s.db, &scope, &id, &policy))
            .await?;
        if let Some(plan) = plan {
            // Model timeout/failure or a non-reducing summary preserves the old
            // model view. A failed CAS/DB commit is NOT swallowed.
            if let Ok(Ok(summary)) = tokio::time::timeout(
                runtime.summary_timeout,
                sc::summarize_plan(&self.provider, plan),
            )
            .await
            {
                let scope = runtime.scope.clone();
                self.db(move |s| sc::commit_compaction(&mut s.db, &scope, summary))
                    .await?;
            }
        }
        self.db(move |s| {
            let view = sc::load_context(&s.db, &runtime.scope, &route)?;
            ensure!(
                view.session_id == initial_session,
                "session reset before turn start"
            );
            let token = if continuation {
                sc::begin_continuation_for_view(
                    &mut s.db,
                    &runtime.scope,
                    &route,
                    &input_id,
                    &user,
                    &seed,
                    &view,
                )?
            } else {
                sc::begin_turn_for_view(&mut s.db, &runtime.scope, &route, &input_id, &user, &view)?
            };
            Ok(PreparedTurn::Ready {
                view,
                token,
                checkpoint: seed,
            })
        })
        .await
    }
    pub(crate) async fn assert_turn(&self, token: &TurnToken) -> Result<()> {
        let scope = self
            .session
            .as_ref()
            .context("session context is not enabled")?
            .scope
            .clone();
        let token = token.clone();
        self.db(move |s| sc::assert_turn_live(&s.db, &scope, &token))
            .await
    }
    /// Detached once dispatched: dropping the outer chat future must not discard
    /// a known result from an effect that continues (notably spawn_blocking).
    pub(crate) async fn execute_durable_call_with_policy(
        &self,
        token: TurnToken,
        call: Value,
        context: TurnContext,
        failures: usize,
        allow_delegation: bool,
    ) -> Result<(crate::tool_images::ToolOutput, usize)> {
        let core = self.clone();
        tokio::spawn(async move {
            let scope = core
                .session
                .as_ref()
                .context("session context is not enabled")?
                .scope
                .clone();
            let scope_reserve = scope.clone();
            let t = token.clone();
            let c = call.clone();
            let reserved = core
                .db(move |s| {
                    sc::assert_turn_live(&s.db, &scope_reserve, &t)?;
                    sc::reserve_tool(&mut s.db, &scope_reserve, &t, &c)
                })
                .await?;
            let (content, failures) = match reserved {
                sc::ToolReservation::ExecuteOnce => {
                    if !allow_delegation && call["function"]["name"] == "delegate_task" {
                        (crate::tool_images::ToolOutput::Json(json!({"error":"Automatic parent continuation depth limit reached; no new child was dispatched"})), failures)
                    } else {
                        core.execute_model_call(&call, &context, failures, token.generation).await
                    }
                }
                sc::ToolReservation::Completed {
                    result,
                    native_image_json,
                } => (
                    crate::tool_images::ToolOutput::from_receipt(result, native_image_json)?,
                    failures,
                ),
                sc::ToolReservation::Uncertain => {
                    bail!("tool effect is uncertain; refusing duplicate execution")
                }
            };
            let t = token;
            let result = content;
            let call_id = call["id"]
                .as_str()
                .context("tool identity missing")?
                .to_owned();
            let (receipt, content) = core
                .db(move |s| {
                    sc::record_tool_output_with_memory_failures(
                        &mut s.db, &scope, &t, &call_id, result, failures,
                    )
                })
                .await?;
            ensure!(
                receipt != sc::ReceiptWrite::RetainedAfterFence,
                "tool result retained after turn was fenced; live history unchanged"
            );
            Ok((content, failures))
        })
        .await
        .context("durable tool worker failed; inspect receipt before retrying")?
    }
    pub(crate) async fn execute_model_call(
        &self,
        call: &Value,
        context: &TurnContext,
        mut memory_failures: usize,
        generation: i64,
    ) -> (crate::tool_images::ToolOutput, usize) {
        use crate::tool_images::ToolOutput;
        let name = call["function"]["name"].as_str().unwrap_or("");
        let args = call["function"]["arguments"].as_str().unwrap_or("");
        if self.tools.contains(name) {
            let output = match serde_json::from_str::<Value>(args) {
                Ok(arg) => {
                    self.tools
                        .execute_output_at_generation(
                            name,
                            arg,
                            context,
                            generation,
                            call["id"].as_str().unwrap_or(""),
                        )
                        .await
                }
                Err(_) => Err(anyhow::anyhow!("invalid tool arguments")),
            };
            let output = match output {
                Ok(v)
                    if v.has_image()
                        && (self.session.is_none()
                            || self.provider.native_tool_image_mode
                                == crate::tool_images::NativeToolImageMode::Disabled) =>
                {
                    ToolOutput::Json(
                        json!({"error":"native image output is not enabled for this durable provider route"}),
                    )
                }
                Ok(v) => v,
                Err(e) => ToolOutput::Json(json!({"error":e.to_string()})),
            };
            return (output, memory_failures);
        }
        let mut result = if name == "memory" {
            match serde_json::from_str::<MemoryRequest>(args) {
                Ok(_) if memory_failures >= 4 => Ok(
                    json!({"success":false,"done":true,"error":"Memory write retry limit reached for this turn. Do not repeat the write."}),
                ),
                Ok(arg) if memory_runtime::has_legacy_replace(&arg) => Err(anyhow::anyhow!(
                    "The replace action is not available in the model tool. Use patch to change a literal span, or an atomic remove/add batch."
                )),
                Ok(arg) => self.memory(arg).await,
                Err(_) => Err(anyhow::anyhow!("invalid memory arguments")),
            }
        } else if name == "session_search" && self.session.is_some() {
            match serde_json::from_str::<Value>(args) {
                Ok(arg) => self.session_search(arg).await,
                Err(_) => Err(anyhow::anyhow!("invalid session search arguments")),
            }
        } else {
            Err(anyhow::anyhow!("unknown or disabled tool"))
        };
        if name == "memory" {
            if result.as_ref().is_ok_and(|v| v["success"] == true) {
                memory_failures = 0;
            } else if result
                .as_ref()
                .err()
                .and_then(|e| e.downcast_ref::<memory_runtime::MemoryFailure>())
                .is_some_and(|e| e.consolidation)
            {
                memory_failures += 1;
                if memory_failures >= 4 {
                    result = Ok(
                        json!({"success":false,"done":true,"error":"Memory consolidation failed four times this turn. Leave memory unchanged and continue the answer."}),
                    );
                }
            }
        }
        (
            match result {
                Ok(v) => ToolOutput::Json(v),
                Err(e) => ToolOutput::Json(json!({"error":e.to_string()})),
            },
            memory_failures,
        )
    }
}
fn completed_response(route: String, final_assistant: Value) -> Result<ChatResponse> {
    Ok(ChatResponse {
        session_id: route,
        answer: final_assistant["content"]
            .as_str()
            .context("completed assistant answer has no text")?
            .to_owned(),
        provider_calls: 0,
    })
}
