//! Host-selected tools and trusted turn context. Models choose registered names
//! and arguments only; they cannot supply the transport identity or destination.
use anyhow::{Context, Result, ensure};
use futures_util::future::BoxFuture;
use serde_json::Value;
use std::{collections::HashMap, sync::Arc};

/// Names reserved for trusted host lifecycle/media state, never provider output.
pub(crate) fn reserved_host_namespace(key: &str) -> bool {
    key.starts_with("_core_") || key.starts_with("_orialis_") || key.starts_with("_context_")
}
/// Do not whitelist vendor fields: reasoning and other provider metadata may be
/// required for replay. Only remove our host namespace and imported API override.
pub(crate) fn sanitize_provider_assistant(mut message: Value) -> Value {
    if let Some(fields) = message.as_object_mut() {
        fields.retain(|key, _| !reserved_host_namespace(key) && key != "api_content");
    }
    message
}
/// Old versions persisted arbitrary assistant fields. Project away host fields
/// on read without changing the archive or rejecting otherwise valid sessions.
/// Imported Hermes api_content is legitimate historical data and stays intact.
pub(crate) fn historical_assistant_projection(message: &Value) -> Option<Value> {
    let fields = message.as_object()?;
    if message["role"] != "assistant" || !fields.keys().any(|key| reserved_host_namespace(key)) {
        return None;
    }
    Some(Value::Object(
        fields
            .iter()
            .filter(|(key, _)| !reserved_host_namespace(key))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    ))
}

#[derive(Clone, Debug, Default)]
pub struct TurnContext {
    pub conversation_id: String,
    pub input_id: String,
    pub session_id: String,
}
#[derive(Clone, Debug)]
pub enum TurnEvent {
    Started,
    Delta(String),
    ToolStarted {
        id: String,
        name: String,
    },
    ToolCompleted {
        id: String,
        name: String,
        failed: bool,
    },
    Completed,
}
#[derive(Clone)]
pub struct TurnObserver(pub tokio::sync::mpsc::Sender<TurnEvent>);
impl TurnObserver {
    pub async fn emit(&self, event: TurnEvent) -> Result<()> {
        self.0
            .try_send(event)
            .context("turn observer unavailable or congested")
    }
}
pub trait ToolExecutor: Send + Sync {
    fn schemas(&self) -> Vec<Value>;
    /// Host lifecycle, never a model-callable operation. Stateful executors must
    /// advance monotonically and invalidate older state BEFORE awaiting cleanup.
    /// An older generation may be ignored during reset-receipt replay, but must
    /// never resurrect or close a newer generation. A prepared old turn is also
    /// fenced by Core before effects. Implementations must not block a runtime
    /// thread: the host deadline is cooperative, not preemption of Rust code.
    /// Blocking process reaping belongs on a separately bounded worker.
    /// Stateless executors need no extra work.
    fn set_session_generation<'a>(
        &'a self,
        _session_id: &'a str,
        _generation: i64,
    ) -> BoxFuture<'a, Result<()>> {
        Box::pin(async { Ok(()) })
    }
    /// Bind turn-local resources from the validated host message. The owned
    /// lease lives across provider/tool work and drops on completion or cancel.
    fn prepare_turn<'a>(
        &'a self,
        _context: &'a TurnContext,
        _user_message: &'a Value,
    ) -> BoxFuture<'a, Result<Box<dyn Send + Sync>>> {
        Box::pin(async { Ok(Box::new(()) as Box<dyn Send + Sync>) })
    }
    /// Immutable host generation accompanies execution without letting model
    /// arguments select it. Stateful executors reject stale prepared calls.
    fn execute_at_generation<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
        _generation: i64,
    ) -> BoxFuture<'a, Result<Value>> {
        self.execute(name, arguments, context)
    }
    /// Core-validated identity within the trusted input, not an authority field
    /// from tool arguments. Distinct equal-argument calls remain distinguishable.
    fn execute_call_at_generation<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
        generation: i64,
        _call_id: &'a str,
    ) -> BoxFuture<'a, Result<Value>> {
        self.execute_at_generation(name, arguments, context, generation)
    }
    /// Host capability marker. Native outputs require durable Core receipts and
    /// an explicitly capable main provider, not an auxiliary vision endpoint.
    fn emits_native_images(&self) -> bool {
        false
    }
    /// Typed output lane. Legacy JSON results are NEVER promoted by inspecting
    /// their keys. The default preserves identity-aware dispatch hooks.
    fn execute_output_at_generation<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
        generation: i64,
        call_id: &'a str,
    ) -> BoxFuture<'a, Result<crate::tool_images::ToolOutput>> {
        Box::pin(async move {
            self.execute_call_at_generation(name, arguments, context, generation, call_id)
                .await
                .map(crate::tool_images::ToolOutput::Json)
        })
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>>;
}
struct Registered {
    name: String,
    executor: Arc<dyn ToolExecutor>,
}
#[derive(Default)]
pub struct ToolRouter {
    schemas: Vec<Value>,
    by_model_name: HashMap<String, Registered>,
    executors: Vec<Arc<dyn ToolExecutor>>,
}
impl ToolRouter {
    pub fn new(executors: Vec<Arc<dyn ToolExecutor>>) -> Result<Self> {
        let mut router = Self::default();
        for executor in executors {
            let schemas = executor.schemas();
            if !schemas.is_empty() {
                router.executors.push(executor.clone());
            }
            for mut schema in schemas {
                ensure!(schema["type"] == "function", "tool schema must be function");
                let name = schema["function"]["name"]
                    .as_str()
                    .context("tool schema missing name")?
                    .to_owned();
                ensure!(
                    !name.is_empty()
                        && name.len() <= 64
                        && name
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)),
                    "invalid tool name"
                );
                // Some OpenAI-compatible providers reject dots. The mapping is
                // deterministic, reverse-looked-up, and collision checked.
                let model_name = name.replace('.', "_dot_");
                ensure!(
                    model_name.len() <= 64
                        && model_name != "memory"
                        && !router.by_model_name.contains_key(&model_name),
                    "duplicate or reserved model tool name"
                );
                schema["function"]["name"] = Value::String(model_name.clone());
                router.by_model_name.insert(
                    model_name,
                    Registered {
                        name,
                        executor: executor.clone(),
                    },
                );
                router.schemas.push(schema);
            }
        }
        Ok(router)
    }
    pub async fn set_session_generation(&self, session_id: &str, generation: i64) -> Result<()> {
        ensure!(
            !session_id.is_empty() && generation >= 0,
            "invalid session generation"
        );
        let mut failed = false;
        for executor in &self.executors {
            if !matches!(
                tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    executor.set_session_generation(session_id, generation),
                )
                .await,
                Ok(Ok(()))
            ) {
                failed = true;
            }
        }
        ensure!(!failed, "one or more tool session cleanups did not finish");
        Ok(())
    }
    pub async fn execute_at_generation(
        &self,
        name: &str,
        arguments: Value,
        context: &TurnContext,
        generation: i64,
    ) -> Result<Value> {
        ensure!(
            arguments.is_object() && generation >= 0,
            "invalid tool arguments or generation"
        );
        let registered = self
            .by_model_name
            .get(name)
            .context("unknown or disabled tool")?;
        registered
            .executor
            .execute_at_generation(&registered.name, arguments, context, generation)
            .await
    }
    pub async fn execute_call_at_generation(
        &self,
        name: &str,
        arguments: Value,
        context: &TurnContext,
        generation: i64,
        call_id: &str,
    ) -> Result<Value> {
        ensure!(
            arguments.is_object()
                && generation >= 0
                && !call_id.is_empty()
                && call_id.len() <= 1024,
            "invalid tool call context"
        );
        let registered = self
            .by_model_name
            .get(name)
            .context("unknown or disabled tool")?;
        registered
            .executor
            .execute_call_at_generation(&registered.name, arguments, context, generation, call_id)
            .await
    }
    pub fn emits_native_images(&self) -> bool {
        self.executors
            .iter()
            .any(|executor| executor.emits_native_images())
    }
    pub async fn execute_output_at_generation(
        &self,
        name: &str,
        arguments: Value,
        context: &TurnContext,
        generation: i64,
        call_id: &str,
    ) -> Result<crate::tool_images::ToolOutput> {
        ensure!(
            arguments.is_object()
                && generation >= 0
                && !call_id.is_empty()
                && call_id.len() <= 1024,
            "invalid tool call context"
        );
        let registered = self
            .by_model_name
            .get(name)
            .context("unknown or disabled tool")?;
        let output = registered
            .executor
            .execute_output_at_generation(&registered.name, arguments, context, generation, call_id)
            .await?;
        ensure!(
            !output.has_image() || registered.executor.emits_native_images(),
            "executor did not declare native image capability"
        );
        Ok(output)
    }
    pub async fn prepare_turn(
        &self,
        context: &TurnContext,
        user_message: &Value,
    ) -> Result<Vec<Box<dyn Send + Sync>>> {
        let mut leases = Vec::with_capacity(self.executors.len());
        for executor in &self.executors {
            leases.push(executor.prepare_turn(context, user_message).await?);
        }
        Ok(leases)
    }
    pub fn schemas(&self) -> &[Value] {
        &self.schemas
    }
    pub fn contains(&self, name: &str) -> bool {
        self.by_model_name.contains_key(name)
    }
    pub async fn execute(
        &self,
        name: &str,
        arguments: Value,
        context: &TurnContext,
    ) -> Result<Value> {
        ensure!(arguments.is_object(), "tool arguments must be object");
        let registered = self
            .by_model_name
            .get(name)
            .context("unknown or disabled tool")?;
        registered
            .executor
            .execute(&registered.name, arguments, context)
            .await
    }
}

/// Preview is optional. Once delivery fails, disable the remainder of this
/// turn's preview rather than drop a delta then append an incorrect suffix.
/// The authoritative full final answer still follows the normal durable path.
pub fn emit_preview(observer: &mut Option<TurnObserver>, event: TurnEvent) {
    if observer
        .as_ref()
        .is_some_and(|o| o.0.try_send(event).is_err())
    {
        *observer = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    struct Fake(&'static str);
    impl ToolExecutor for Fake {
        fn schemas(&self) -> Vec<Value> {
            vec![
                json!({"type":"function","function":{"name":self.0,"parameters":{"type":"object"}}}),
            ]
        }
        fn execute<'a>(
            &'a self,
            name: &'a str,
            args: Value,
            ctx: &'a TurnContext,
        ) -> BoxFuture<'a, Result<Value>> {
            Box::pin(async move { Ok(json!({"name":name,"input":ctx.input_id,"args":args})) })
        }
    }
    #[tokio::test]
    async fn names_are_mapped_without_losing_host_context() {
        let r = ToolRouter::new(vec![Arc::new(Fake("news.publish"))]).unwrap();
        assert_eq!(r.schemas()[0]["function"]["name"], "news_dot_publish");
        let c = TurnContext {
            input_id: "trusted-id".into(),
            ..Default::default()
        };
        let v = r
            .execute("news_dot_publish", json!({"input_id":"untrusted"}), &c)
            .await
            .unwrap();
        assert_eq!(v["name"], "news.publish");
        assert_eq!(v["input"], "trusted-id");
        assert!(r.execute("not_registered", json!({}), &c).await.is_err());
    }
    #[test]
    fn collisions_fail_closed() {
        assert!(
            ToolRouter::new(vec![
                Arc::new(Fake("news.publish")),
                Arc::new(Fake("news_dot_publish"))
            ])
            .is_err()
        );
        assert!(ToolRouter::new(vec![Arc::new(Fake("memory"))]).is_err());
    }
}
