use super::*;
use crate::tool_images::{self, NativeToolImageMode, ToolOutput};
use futures_util::{StreamExt, stream::FuturesUnordered};
use store::Child;

struct RunGuard {
    runtime: DelegationRuntime,
    id: String,
    run: i64,
    token: Arc<Cancel>,
    finished: bool,
}
impl Drop for RunGuard {
    fn drop(&mut self) {
        if !self.finished {
            self.runtime
                .inner
                .db
                .abandoned_child(self.id.clone(), self.run);
        }
        let mut live = self.runtime.inner.live.lock().unwrap();
        if live
            .get(&self.id)
            .is_some_and(|token| Arc::ptr_eq(&token.token, &self.token))
        {
            live.remove(&self.id);
        }
        drop(live);
        // Stateful child tools are fenced on every exit, including dropped futures.
        // Cleanup is bounded by ToolRouter and never performs a child model call.
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let tools = self.runtime.inner.tools.clone();
            let id = self.id.clone();
            let generation = self.run * 2 + 1;
            handle.spawn(async move {
                let _ = tools.set_session_generation(&id, generation).await;
            });
        }
    }
}
struct BatchGuard {
    runtime: DelegationRuntime,
    id: String,
    children: Vec<(String, i64)>,
    permits: Option<tokio::sync::OwnedSemaphorePermit>,
    finished: bool,
}
impl Drop for BatchGuard {
    fn drop(&mut self) {
        if !self.finished {
            self.runtime.inner.db.abandoned_batch(
                self.id.clone(),
                self.children.clone(),
                self.permits.take(),
            );
        }
    }
}
impl DelegationRuntime {
    fn batch_identity(&self, a: &Authority, call_id: &str) -> String {
        format!(
            "delegation-{}",
            &digest(
                &json!([
                    a.context.session_id,
                    a.context.conversation_id,
                    a.generation,
                    a.context.input_id,
                    a.parent,
                    call_id
                ])
                .to_string()
            )[..40]
        )
    }
    fn batch_lock(&self, key: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self.inner.batches.lock().unwrap();
        locks.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = locks.get(key).and_then(std::sync::Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        locks.insert(key.into(), Arc::downgrade(&lock));
        lock
    }
    pub(super) async fn spawn_batch(
        &self,
        raw: Value,
        tasks: Vec<Task>,
        a: Authority,
        call_id: String,
        iterations: usize,
    ) -> Result<Value> {
        let id = self.batch_identity(&a, &call_id);
        let lock = self.batch_lock(&id);
        let _guard = lock.lock().await;
        let _admission_gate = if a.detached {
            Some(self.inner.notification_gate.clone().read_owned().await)
        } else {
            None
        };
        self.check(&a)?;
        if let Some(cached) = self.inner.db.batch_existing(&id, &raw).await? {
            return Ok(cached);
        }
        // Reject over-capacity rather than queue indefinitely, including nested fanout.
        let _permits = self
            .inner
            .slots
            .clone()
            .try_acquire_many_owned(tasks.len() as u32)
            .context("delegation concurrency capacity reached")?;
        for task in &tasks {
            if let Some(schema) = &task.output_schema {
                output_schema::validate_schema(schema.clone()).await?;
            }
        }
        self.check(&a)?;
        let (a, detached_guard) = self.detach_authority(&id, a);
        let admission = BatchGuard {
            runtime: self.clone(),
            id: id.clone(),
            children: vec![],
            permits: Some(_permits),
            finished: false,
        };
        let children = self
            .inner
            .db
            .reserve(
                &id,
                &raw,
                &tasks,
                &a,
                &self.inner.scope,
                iterations,
                &self.inner.cfg,
            )
            .await?;
        self.start_admitted_batch(id, children, a, admission, detached_guard)
            .await
    }
    pub(super) async fn continue_child(
        &self,
        raw: Value,
        args: Arguments,
        a: Authority,
        call_id: String,
    ) -> Result<Value> {
        let id = self.batch_identity(&a, &call_id);
        let lock = self.batch_lock(&id);
        let _guard = lock.lock().await;
        let _admission_gate = if a.detached {
            Some(self.inner.notification_gate.clone().read_owned().await)
        } else {
            None
        };
        self.check(&a)?;
        if let Some(cached) = self.inner.db.batch_existing(&id, &raw).await? {
            return Ok(cached);
        }
        let child_id = args
            .subagent_id
            .as_deref()
            .context("continue requires subagent_id")?;
        let message = args
            .message
            .as_deref()
            .filter(|s| !s.trim().is_empty() && s.len() <= 64 * 1024)
            .context("continue requires bounded nonempty message")?;
        let _permit = self
            .inner
            .slots
            .clone()
            .try_acquire_owned()
            .context("delegation concurrency capacity reached")?;
        let (a, detached_guard) = self.detach_authority(&id, a);
        let admission = BatchGuard {
            runtime: self.clone(),
            id: id.clone(),
            children: vec![],
            permits: Some(_permit),
            finished: false,
        };
        let child = self
            .inner
            .db
            .continue_child(
                child_id,
                &id,
                &raw,
                message,
                &a,
                &self.inner.scope,
                &self.inner.cfg,
            )
            .await?;
        self.start_admitted_batch(id, vec![child], a, admission, detached_guard)
            .await
    }
    async fn start_admitted_batch(
        &self,
        id: String,
        children: Vec<Child>,
        a: Authority,
        mut admission: BatchGuard,
        detached_guard: Option<background::DetachedGuard>,
    ) -> Result<Value> {
        if let Some(detached_guard) = detached_guard {
            let handle = background::admission_handle(&id, &children);
            let runtime = self.clone();
            tokio::spawn(async move {
                let _job = detached_guard;
                // Retain live admission slots until terminal state has been published.
                let result = runtime.run_batch(id, children, a).await;
                if result.is_ok() {
                    admission.finished = true;
                }
                drop(admission);
            });
            Ok(handle)
        } else {
            let result = self.run_batch(id, children, a).await;
            if result.is_ok() {
                admission.finished = true;
            }
            result
        }
    }
    pub(super) async fn run_batch(
        &self,
        id: String,
        children: Vec<Child>,
        a: Authority,
    ) -> Result<Value> {
        let mut guard = BatchGuard {
            runtime: self.clone(),
            id: id.clone(),
            children: children.iter().map(|c| (c.id.clone(), c.run)).collect(),
            permits: None,
            finished: false,
        };
        let mut running = FuturesUnordered::new();
        for child in children {
            running.push(self.run_child(child, a.clone()));
        }
        while let Some(result) = running.next().await {
            result?;
        }
        let result = self.inner.db.finish_batch(&id).await?;
        if a.detached {
            self.inner.completion_ready.notify_one();
        }
        guard.finished = true;
        Ok(result)
    }
    async fn run_child(&self, child: Child, a: Authority) -> Result<()> {
        let local = Arc::new(Cancel::default());
        self.inner.live.lock().unwrap().insert(
            child.id.clone(),
            LiveChild {
                token: local.clone(),
                root: a.context.session_id.clone(),
                conversation: a.context.conversation_id.clone(),
                generation: a.generation,
            },
        );
        let mut guard = RunGuard {
            runtime: self.clone(),
            id: child.id.clone(),
            run: child.run,
            token: local.clone(),
            finished: false,
        };
        let outcome = tokio::time::timeout(
            self.inner.cfg.child_timeout,
            self.run_loop(&child, &a, &local),
        )
        .await;
        // Do not publish a resumable child until its stateful tools are fenced.
        // If cleanup fails, retain the result but refuse continuation explicitly.
        let cleanup = self
            .inner
            .tools
            .set_session_generation(&child.id, child.run * 2 + 1)
            .await;
        match outcome {
            Ok(Ok((mut result, messages))) => {
                if cleanup.is_err() {
                    result["status"] = json!("cleanup_pending");
                    result["partial"] = json!(true);
                    result["cleanup_pending"] = json!(true);
                }
                self.inner.db.finish(&child, result, &messages).await?;
            }
            Ok(Err(_)) => {
                self.inner.db.interrupt(&child.id,child.run,"child stopped or provider/tool failed; inspect partial result before continuing").await?;
            }
            Err(_) => {
                self.inner.db.interrupt(&child.id,child.run,"child total runtime budget exhausted; inspect partial result before continuing").await?;
            }
        }
        if cleanup.is_err() {
            self.inner.db.cleanup_failed(&child).await?;
        }
        guard.finished = true;
        Ok(())
    }
    async fn run_loop(
        &self,
        child: &Child,
        a: &Authority,
        local: &Arc<Cancel>,
    ) -> Result<(Value, Vec<Value>)> {
        let cfg = &self.inner.cfg;
        self.check_child(a, local)?;
        let mut messages = if child.messages.is_empty() {
            self.initial_messages(&child.task, a, local).await?
        } else {
            child.messages.clone()
        };
        for message in &mut messages {
            if message.get(tool_images::FIELD).is_some() {
                *message = tool_images::hydrate(message)?;
            }
        }
        let mut schemas = self.inner.schemas.clone();
        if child.depth < cfg.max_depth {
            schemas.push(self.schema());
        }
        let tool_names: BTreeSet<_> = schemas
            .iter()
            .filter_map(|v| v["function"]["name"].as_str().map(str::to_owned))
            .collect();
        let child_context = TurnContext {
            session_id: child.id.clone(),
            conversation_id: a.context.conversation_id.clone(),
            input_id: format!("{}.{}", child.id, child.run),
        };
        self.inner.db.start(child, &messages).await?;
        self.guarded(
            a,
            local,
            self.inner
                .tools
                .set_session_generation(&child.id, child.run * 2),
        )
        .await?;
        let current_input = messages
            .iter()
            .rev()
            .find(|m| m["role"] == "user")
            .cloned()
            .context("child transcript missing user input")?;
        let _leases = self
            .guarded(
                a,
                local,
                self.inner
                    .tools
                    .prepare_turn(&child_context, &current_input),
            )
            .await?;
        let mut schema_retry = 0usize;
        let mut provider_calls = 0usize;
        let mut tool_calls = 0usize;
        let mut summary = String::new();
        let mut ids = BTreeSet::new();
        for m in &messages {
            if let Some(calls) = m["tool_calls"].as_array() {
                for c in calls {
                    if let Some(id) = c["id"].as_str() {
                        ids.insert(id.to_owned());
                    }
                }
            }
        }
        while provider_calls < child.iterations {
            self.check_child(a, local)?;
            self.inner.db.drain_steer(child, &mut messages).await?;
            ensure!(
                serde_json::to_vec(&messages)?.len() <= cfg.max_context_bytes,
                "child context byte budget exhausted"
            );
            let response = crate::tool_runtime::sanitize_provider_assistant(
                self.guarded(a, local, self.inner.model.complete(&messages, &schemas))
                    .await?,
            );
            provider_calls += 1;
            ensure!(
                response["role"] == "assistant"
                    && serde_json::to_vec(&response)?.len() <= cfg.max_tool_output_bytes,
                "invalid or oversized child model response"
            );
            output_schema::bounded_value(&response, 64, 20_000)?;
            if let Some(text) = response["content"].as_str()
                && !text.is_empty()
            {
                summary = truncate(text, cfg.max_output_bytes);
            }
            let calls = response["tool_calls"]
                .as_array()
                .filter(|c| !c.is_empty())
                .cloned();
            if let Some(calls) = calls {
                ensure!(
                    calls.len() <= cfg.max_tool_calls_per_round,
                    "child per-round tool budget exhausted"
                );
                for call in &calls {
                    let id = call["id"].as_str().context("child tool call lacks id")?;
                    ensure!(
                        !id.is_empty() && id.len() <= 256 && ids.insert(id.to_owned()),
                        "duplicate/invalid child tool-call id"
                    );
                    ensure!(
                        call["type"] == "function"
                            && call["function"]["name"].is_string()
                            && call["function"]["arguments"]
                                .as_str()
                                .is_some_and(|s| s.len() <= 64 * 1024),
                        "invalid child tool-call shape"
                    );
                }
                // Persist the assistant's exact call before executing any effect.
                messages.push(response);
                self.inner.db.save(child, &messages).await?;
                for call in calls {
                    self.check_child(a, local)?;
                    let id = call["id"].as_str().unwrap();
                    let name = call["function"]["name"].as_str().unwrap();
                    let arguments = serde_json::from_str::<Value>(
                        call["function"]["arguments"].as_str().unwrap(),
                    );
                    // Unknown/forbidden tools are never dispatched, even if hallucinated.
                    let rejection = if !tool_names.contains(name) {
                        Some(json!({"error":"tool not permitted in this child"}))
                    } else if !arguments.as_ref().is_ok_and(Value::is_object) {
                        Some(json!({"error":"tool arguments must be a JSON object"}))
                    } else {
                        None
                    };
                    let tool_message = if let Some(rejected) = rejection {
                        ToolOutput::Json(rejected).message(id)?
                    } else {
                        let existing = self.inner.db.begin_tool(child, id, &call).await?;
                        if let Some(receipt) = existing {
                            let message = receipt
                                .get("message")
                                .cloned()
                                .context("child receipt message missing")?;
                            if message.get(tool_images::FIELD).is_some() {
                                tool_images::hydrate(&message)?
                            } else {
                                message
                            }
                        } else {
                            let arguments = arguments.unwrap();
                            output_schema::bounded_value(&arguments, 48, 16_000)?;
                            let result = if name == "delegate_task" {
                                let mut ancestors = a.ancestors.clone();
                                ancestors.push(a.cancel.clone());
                                let nested = Authority {
                                    context: a.context.clone(),
                                    generation: a.generation,
                                    parent: Some(child.id.clone()),
                                    depth: child.depth,
                                    cancel: local.clone(),
                                    ancestors,
                                    detached: false,
                                };
                                let result = self
                                    .guarded(
                                        a,
                                        local,
                                        self.dispatch_inner(
                                            arguments,
                                            nested,
                                            format!("{}:{id}", child.run),
                                        ),
                                    )
                                    .await;
                                match result {
                                    Ok(value) => ToolOutput::Json(value),
                                    Err(_) => ToolOutput::Json(
                                        json!({"error":"nested delegation refused or interrupted; inspect child state"}),
                                    ),
                                }
                            } else {
                                // An executor error is ambiguous: leave the STARTED receipt,
                                // stop this child, and never claim the effect was not performed.
                                self.guarded(
                                    a,
                                    local,
                                    self.inner.tools.execute_output_at_generation(
                                        name,
                                        arguments,
                                        &child_context,
                                        child.run * 2,
                                        id,
                                    ),
                                )
                                .await?
                            };
                            ensure!(
                                serde_json::to_vec(result.metadata())?.len()
                                    <= cfg.max_tool_output_bytes,
                                "child tool result exceeds budget; effect may have completed"
                            );
                            output_schema::bounded_value(result.metadata(), 64, 20_000)?;
                            let result = match self.check_image_budget(&result, &messages) {
                                Ok(()) => result,
                                Err(_) => ToolOutput::Json(
                                    json!({"error":"child native tool-image capability or cumulative image budget unavailable; image pixels were not sent", "tool_result_metadata":result.metadata()}),
                                ),
                            };
                            result.message(id)?
                        }
                    };
                    tool_calls += 1;
                    messages.push(tool_message.clone());
                    let receipt = json!({"version":1,"message":tool_message});
                    self.inner
                        .db
                        .finish_tool(child, id, &receipt, &messages)
                        .await?;
                }
                continue;
            }
            let text = response["content"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .context("empty child final response")?;
            messages.push(response.clone());
            self.inner.db.save(child, &messages).await?;
            let (valid, errors) = if let Some(schema) = &child.task.output_schema {
                let errors =
                    output_schema::validate_output(schema.clone(), text.to_owned()).await?;
                (Some(errors.is_empty()), errors)
            } else {
                (None, vec![])
            };
            if valid == Some(false) && schema_retry == 0 && provider_calls < child.iterations {
                schema_retry += 1;
                messages.push(json!({"role":"user","content":format!("Your final response failed the OUTPUT CONTRACT. Reply with only corrected JSON. Validation errors: {}\nOUTPUT CONTRACT: {}",errors.join("\n"),child.task.output_schema.as_ref().unwrap())}));
                self.inner.db.save(child, &messages).await?;
                continue;
            }
            let mut output = json!({"subagent_id":child.id,"task_index":child.ordinal,"status":"completed","summary":truncate(text,cfg.max_output_bytes),"summary_truncated":text.len()>cfg.max_output_bytes,"partial":false,"provider_calls":provider_calls,"tool_calls":tool_calls,"schema_retries":schema_retry});
            if let Some(valid) = valid {
                output["schema_valid"] = json!(valid);
                if !valid {
                    output["schema_errors"] = json!(errors);
                }
            }
            return Ok((output, messages));
        }
        Ok((
            json!({"subagent_id":child.id,"task_index":child.ordinal,"status":"budget_exhausted","summary":summary,"partial":true,"provider_calls":provider_calls,"tool_calls":tool_calls,"schema_retries":schema_retry}),
            messages,
        ))
    }
    async fn initial_messages(
        &self,
        task: &Task,
        a: &Authority,
        local: &Arc<Cancel>,
    ) -> Result<Vec<Value>> {
        let mut text = task.goal.clone();
        if let Some(context) = &task.context {
            text.push_str("\n\nTask context:\n");
            text.push_str(context);
        }
        if let Some(schema) = &task.output_schema {
            text.push_str("\n\nOUTPUT CONTRACT: Your final response must be only a JSON value satisfying this JSON Schema:\n");
            text.push_str(&schema.to_string());
        }
        let content = if task.images.is_empty() {
            json!(text)
        } else {
            let mut blocks = vec![json!({"type":"text","text":text})];
            let resolver = self
                .inner
                .images
                .as_ref()
                .context("image resolver not configured")?;
            for reference in &task.images {
                let block = self.guarded(a, local, resolver.resolve(reference)).await?;
                let url = block["image_url"]["url"]
                    .as_str()
                    .context("invalid resolved child image")?;
                ensure!(
                    block["type"] == "image_url"
                        && url.starts_with("data:image/")
                        && url.len() <= 512 * 1024,
                    "child image resolver must return bounded inline pixels"
                );
                blocks.push(block);
            }
            json!(blocks)
        };
        Ok(vec![
            json!({"role":"system","content":self.inner.cfg.system_prompt}),
            json!({"role":"user","content":content}),
        ])
    }
    fn check_image_budget(&self, result: &ToolOutput, messages: &[Value]) -> Result<()> {
        let ToolOutput::Native(image) = result else {
            return Ok(());
        };
        ensure!(
            self.inner.model.native_tool_image_mode() == NativeToolImageMode::OpenAiChatUserBridge,
            "child model does not accept native tool images"
        );
        let (source, bytes, max_repeats, max_images, max_bytes) = image.usage();
        let mut count = 1;
        let mut total = bytes;
        let mut repeats = 1;
        for message in messages {
            if let Some(value) = message.get(tool_images::FIELD) {
                let previous = crate::tool_images::NativeToolImage::from_stored(value.clone())?;
                let (old_source, old_bytes, _, _, _) = previous.usage();
                count += 1;
                total += old_bytes;
                if old_source == source {
                    repeats += 1;
                }
            }
        }
        ensure!(
            count <= max_images.min(8)
                && total
                    <= max_bytes
                        .min(1024 * 1024)
                        .min(self.inner.cfg.max_context_bytes / 2)
                && repeats <= max_repeats,
            "child native image history budget exhausted"
        );
        Ok(())
    }
    fn check_child(&self, a: &Authority, local: &Cancel) -> Result<()> {
        ensure!(!local.is_stopped(), "child stopped");
        self.check(a)
    }
    async fn guarded<T>(
        &self,
        a: &Authority,
        local: &Arc<Cancel>,
        future: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        self.check_child(a, local)?;
        let mut tokens = a.ancestors.clone();
        tokens.push(a.cancel.clone());
        tokens.push(local.clone());
        let cancel = async move {
            let mut futures = FuturesUnordered::new();
            for token in &tokens {
                futures.push(token.cancelled());
            }
            futures.next().await;
        };
        let value = tokio::select! {
            biased;
            _=cancel=>bail!("delegation cancelled"),
            result=tokio::time::timeout(self.inner.cfg.operation_timeout,future)=>result.context("delegation operation timed out")??,
        };
        self.check_child(a, local)?;
        Ok(value)
    }
}

#[cfg(test)]
mod native_tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::STANDARD};
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct NativeTool;
    impl ToolExecutor for NativeTool {
        fn emits_native_images(&self) -> bool {
            true
        }
        fn schemas(&self) -> Vec<Value> {
            vec![
                json!({"type":"function","function":{"name":"vision_analyze","parameters":{"type":"object"}}}),
            ]
        }
        fn execute<'a>(
            &'a self,
            _name: &'a str,
            _args: Value,
            _ctx: &'a TurnContext,
        ) -> BoxFuture<'a, Result<Value>> {
            Box::pin(async { bail!("typed channel required") })
        }
        fn execute_output_at_generation<'a>(
            &'a self,
            _name: &'a str,
            _args: Value,
            _ctx: &'a TurnContext,
            _generation: i64,
            _call_id: &'a str,
        ) -> BoxFuture<'a, Result<ToolOutput>> {
            Box::pin(async {
                let mut bytes = std::io::Cursor::new(Vec::new());
                image::DynamicImage::new_rgb8(2, 2)
                    .write_to(&mut bytes, image::ImageFormat::Png)?;
                let bytes = bytes.into_inner();
                Ok(ToolOutput::Native(
                    crate::tool_images::NativeToolImage::prepared(
                        json!({"status":"native_image"}),
                        "fixture pixels".into(),
                        format!("data:image/png;base64,{}", STANDARD.encode(&bytes)),
                        digest("fixture-image"),
                        bytes.len(),
                        (2, 2),
                        crate::tool_images::NativeImageBudget {
                            source_repeats: 1,
                            session_images: 8,
                            session_bytes: 1024 * 1024,
                        },
                    )?,
                ))
            })
        }
    }
    struct ImageModel {
        mode: NativeToolImageMode,
        calls: AtomicUsize,
        seen: Mutex<Vec<Vec<Value>>>,
        two_images: bool,
    }
    impl DelegationModel for ImageModel {
        fn route_identity(&self) -> String {
            "native-fixture-v1".into()
        }
        fn native_tool_image_mode(&self) -> NativeToolImageMode {
            self.mode
        }
        fn complete<'a>(
            &'a self,
            messages: &'a [Value],
            _tools: &'a [Value],
        ) -> BoxFuture<'a, Result<Value>> {
            Box::pin(async move {
                let n = self.calls.fetch_add(1, Ordering::SeqCst);
                self.seen.lock().unwrap().push(messages.to_vec());
                if n == 0 || (n == 1 && self.two_images) {
                    Ok(
                        json!({"role":"assistant","content":null,"tool_calls":[{"id":format!("image-{n}"),"type":"function","function":{"name":"vision_analyze","arguments":"{}"}}]}),
                    )
                } else {
                    Ok(json!({"role":"assistant","content":"image answer"}))
                }
            })
        }
    }
    async fn fixture(
        mode: NativeToolImageMode,
        two_images: bool,
    ) -> Result<(DelegationRuntime, Arc<ImageModel>, Value)> {
        let model = Arc::new(ImageModel {
            mode,
            calls: AtomicUsize::new(0),
            seen: Mutex::new(vec![]),
            two_images,
        });
        let cfg = DelegationConfig {
            allowed_tools: BTreeSet::from(["vision_analyze".into()]),
            capability_scope: Some("normalized-image-fixture-v1".into()),
            ..Default::default()
        };
        let runtime = DelegationRuntime::open(
            Path::new(":memory:"),
            "owner",
            model.clone(),
            Arc::new(ToolRouter::new(vec![Arc::new(NativeTool)])?),
            cfg,
        )?;
        let ctx = TurnContext {
            session_id: "parent".into(),
            conversation_id: "conversation".into(),
            input_id: "input".into(),
        };
        let result = runtime
            .dispatch(
                json!({"tasks":[{"goal":"inspect image"}]}),
                &ctx,
                0,
                "spawn",
            )
            .await?;
        Ok((runtime, model, result))
    }
    #[tokio::test]
    async fn child_native_pixels_survive_tool_round_and_continuation() -> Result<()> {
        let (runtime, model, result) =
            fixture(NativeToolImageMode::OpenAiChatUserBridge, false).await?;
        assert_eq!(result["results"][0]["status"], "completed");
        assert!(
            model.seen.lock().unwrap()[1]
                .iter()
                .any(|m| m.get(tool_images::FIELD).is_some())
        );
        let ctx = TurnContext {
            session_id: "parent".into(),
            conversation_id: "conversation".into(),
            input_id: "next-input".into(),
        };
        runtime.dispatch(json!({"action":"continue","subagent_id":result["results"][0]["subagent_id"],"message":"same image follow-up"}),&ctx,0,"continue").await?;
        assert!(
            model.seen.lock().unwrap()[2]
                .iter()
                .any(|m| m.get(tool_images::FIELD).is_some())
        );
        runtime.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn disabled_child_image_mode_returns_explicit_error_without_fake_pixels() -> Result<()> {
        let (runtime, model, _) = fixture(NativeToolImageMode::Disabled, false).await?;
        let messages = model.seen.lock().unwrap()[1].clone();
        assert!(messages.iter().all(|m| m.get(tool_images::FIELD).is_none()));
        assert!(
            messages.last().unwrap()["content"]
                .as_str()
                .unwrap()
                .contains("pixels were not sent")
        );
        runtime.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn child_native_image_repetition_budget_is_enforced() -> Result<()> {
        let (runtime, model, _) = fixture(NativeToolImageMode::OpenAiChatUserBridge, true).await?;
        let messages = model.seen.lock().unwrap()[2].clone();
        assert_eq!(
            messages
                .iter()
                .filter(|m| m.get(tool_images::FIELD).is_some())
                .count(),
            1
        );
        assert!(
            messages.last().unwrap()["content"]
                .as_str()
                .unwrap()
                .contains("budget unavailable")
        );
        runtime.shutdown().await?;
        Ok(())
    }
}
