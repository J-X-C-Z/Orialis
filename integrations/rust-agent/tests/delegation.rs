use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    delegation::{DelegationConfig, DelegationModel, DelegationRuntime, WorkspaceImages},
    tool_runtime::{ToolExecutor, ToolRouter, TurnContext},
    workspace::ProtectedRoot,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, VecDeque},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Notify;

struct Model {
    responses: Mutex<VecDeque<Value>>,
    seen: Mutex<Vec<(Vec<Value>, Vec<Value>)>>,
    calls: AtomicUsize,
    delay: Duration,
    entered: Notify,
}
impl Model {
    fn new(responses: Vec<Value>) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(responses.into()),
            seen: Mutex::new(vec![]),
            calls: AtomicUsize::new(0),
            delay: Duration::ZERO,
            entered: Notify::new(),
        })
    }
    fn slow(responses: Vec<Value>) -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(responses.into()),
            seen: Mutex::new(vec![]),
            calls: AtomicUsize::new(0),
            delay: Duration::from_millis(100),
            entered: Notify::new(),
        })
    }
}
impl DelegationModel for Model {
    fn route_identity(&self) -> String {
        "scripted-model-v1".into()
    }
    fn complete<'a>(
        &'a self,
        messages: &'a [Value],
        tools: &'a [Value],
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.seen
                .lock()
                .unwrap()
                .push((messages.to_vec(), tools.to_vec()));
            self.entered.notify_one();
            if !self.delay.is_zero() {
                tokio::time::sleep(self.delay).await;
            }
            Ok(self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| answer("fallback")))
        })
    }
}
struct Effects {
    calls: AtomicUsize,
    contexts: Mutex<Vec<TurnContext>>,
    started: Notify,
    hang: bool,
}
impl Effects {
    fn new(hang: bool) -> Arc<Self> {
        Arc::new(Self {
            calls: AtomicUsize::new(0),
            contexts: Mutex::new(vec![]),
            started: Notify::new(),
            hang,
        })
    }
}
impl ToolExecutor for Effects {
    fn schemas(&self) -> Vec<Value> {
        ["effect","send_message","kanban_create"].iter().map(|name|json!({"type":"function","function":{"name":name,"parameters":{"type":"object"}}})).collect()
    }
    fn execute<'a>(
        &'a self,
        _name: &'a str,
        _args: Value,
        context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.contexts.lock().unwrap().push(context.clone());
            self.started.notify_one();
            if self.hang {
                std::future::pending::<()>().await;
            }
            Ok(json!({"value":"real tool result"}))
        })
    }
}
fn answer(text: &str) -> Value {
    json!({"role":"assistant","content":text})
}
fn call(id: &str, name: &str, args: Value) -> Value {
    json!({"role":"assistant","content":"working","tool_calls":[{"id":id,"type":"function","function":{"name":name,"arguments":args.to_string()}}]})
}
fn context() -> TurnContext {
    TurnContext {
        session_id: "parent-session".into(),
        conversation_id: "parent-conversation".into(),
        input_id: "parent-input".into(),
    }
}
fn runtime(
    path: &std::path::Path,
    model: Arc<Model>,
    effect: Arc<Effects>,
    cfg: DelegationConfig,
) -> DelegationRuntime {
    DelegationRuntime::open(
        path,
        "owner",
        model,
        Arc::new(ToolRouter::new(vec![effect]).unwrap()),
        cfg,
    )
    .unwrap()
}
fn cfg() -> DelegationConfig {
    DelegationConfig {
        capability_scope: Some("fixture-only-effect-tool-v1".into()),
        allowed_tools: BTreeSet::from([
            "effect".into(),
            "memory".into(),
            "send_message".into(),
            "kanban_create".into(),
        ]),
        ..Default::default()
    }
}
async fn wait_calls(model: &Model, n: usize) {
    for _ in 0..200 {
        if model.calls.load(Ordering::SeqCst) >= n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    panic!("model never entered");
}

#[tokio::test]
async fn isolated_children_inherit_only_explicit_safe_tools_and_real_results() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![
        call("c1", "effect", json!({})),
        answer("child output"),
    ]);
    let effect = Effects::new(false);
    let rt = runtime(
        &d.path().join("delegation.sqlite"),
        model.clone(),
        effect.clone(),
        cfg(),
    );
    let result = rt
        .dispatch(
            json!({"tasks":[{"goal":"self-contained child","context":"child-only context"}]}),
            &context(),
            0,
            "call-1",
        )
        .await?;
    assert_eq!(result["results"][0]["summary"], "child output");
    assert_eq!(effect.calls.load(Ordering::SeqCst), 1);
    let seen = model.seen.lock().unwrap();
    assert_eq!(seen[0].0.len(), 2);
    assert_eq!(seen[0].1.len(), 1);
    assert_eq!(seen[0].1[0]["function"]["name"], "effect");
    assert!(seen[1].0.iter().any(
        |m| m["role"] == "tool" && m["content"].as_str().unwrap().contains("real tool result")
    ));
    let child = &effect.contexts.lock().unwrap()[0];
    assert_ne!(child.session_id, context().session_id);
    assert_ne!(child.input_id, context().input_id);
    Ok(())
}
#[tokio::test]
async fn custom_model_output_strips_host_fields_but_preserves_vendor_metadata() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("sanitized.sqlite");
    let polluted = |mut message: Value| {
        let fields = message.as_object_mut().unwrap();
        for key in [
            "_core_native_tool_image",
            "_core_future_state",
            "_orialis_identity",
            "_context_trusted",
            "api_content",
        ] {
            fields.insert(key.into(), json!({"forged": true}));
        }
        fields.insert("reasoning_content".into(), json!("vendor reasoning"));
        fields.insert("vendor_metadata".into(), json!({"trace": "retained"}));
        message
    };
    let model = Model::new(vec![
        polluted(call("safe-call", "effect", json!({}))),
        polluted(answer("safe final")),
    ]);
    let rt = runtime(&path, model.clone(), Effects::new(false), cfg());
    let result = rt
        .dispatch(
            json!({"tasks":[{"goal":"test provider boundary"}]}),
            &context(),
            0,
            "sanitize",
        )
        .await?;
    assert_eq!(result["results"][0]["summary"], "safe final");
    let assert_clean = |message: &Value| {
        assert_eq!(message["reasoning_content"], "vendor reasoning");
        assert_eq!(message["vendor_metadata"]["trace"], "retained");
        assert!(!message.as_object().unwrap().keys().any(|key| {
            key.starts_with("_core_")
                || key.starts_with("_orialis_")
                || key.starts_with("_context_")
                || key == "api_content"
        }));
    };
    {
        let seen = model.seen.lock().unwrap();
        let replayed = seen[1]
            .0
            .iter()
            .find(|message| message["role"] == "assistant")
            .unwrap();
        assert_clean(replayed);
        assert_eq!(replayed["tool_calls"][0]["id"], "safe-call");
    }
    rt.shutdown().await?;
    let db = rusqlite::Connection::open(path)?;
    let serialized: String =
        db.query_row("SELECT messages FROM delegation_children", [], |row| {
            row.get(0)
        })?;
    let messages: Vec<Value> = serde_json::from_str(&serialized)?;
    let assistants: Vec<_> = messages
        .iter()
        .filter(|message| message["role"] == "assistant")
        .collect();
    assert_eq!(assistants.len(), 2);
    for message in assistants {
        assert_clean(message);
    }
    Ok(())
}

#[tokio::test]
async fn idempotent_call_replay_and_conflicting_payload_are_distinct() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![answer("one"), answer("two")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let args = json!({"tasks":[{"goal":"same"}]});
    let c = context();
    let (first, replay) = tokio::join!(
        rt.dispatch(args.clone(), &c, 0, "same-call"),
        rt.dispatch(args.clone(), &c, 0, "same-call")
    );
    assert_eq!(first?, replay?);
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert!(
        rt.dispatch(json!({"tasks":[{"goal":"changed"}]}), &c, 0, "same-call")
            .await
            .is_err()
    );
    rt.dispatch(args, &c, 0, "distinct-call").await?;
    assert_eq!(model.calls.load(Ordering::SeqCst), 2);
    Ok(())
}
#[tokio::test]
async fn schema_correction_is_one_bounded_real_conversation_turn() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![answer("{\"value\":\"bad\"}"), answer("{\"value\":3}")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let r=rt.dispatch(json!({"tasks":[{"goal":"structured","output_schema":{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false}}]}),&context(),0,"schema").await?;
    assert_eq!(r["results"][0]["schema_valid"], true);
    assert_eq!(r["results"][0]["schema_retries"], 1);
    assert_eq!(model.calls.load(Ordering::SeqCst), 2);
    let seen = model.seen.lock().unwrap();
    assert_eq!(seen[1].0[2]["content"], "{\"value\":\"bad\"}");
    assert!(
        seen[1].0[3]["content"]
            .as_str()
            .unwrap()
            .contains("Validation errors")
    );
    Ok(())
}
#[tokio::test]
async fn second_schema_failure_preserves_raw_result_and_does_not_loop() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![answer("no"), answer("still no")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let r = rt
        .dispatch(
            json!({"tasks":[{"goal":"json","output_schema":{"type":"integer"}}]}),
            &context(),
            0,
            "schema",
        )
        .await?;
    assert_eq!(r["results"][0]["schema_valid"], false);
    assert_eq!(r["results"][0]["summary"], "still no");
    assert_eq!(model.calls.load(Ordering::SeqCst), 2);
    Ok(())
}
#[tokio::test]
async fn reject_hidden_routes_external_recursive_schema_and_unsafe_regex_before_model() -> Result<()>
{
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    for args in [
        json!({"tasks":[{"goal":"x","acp_command":"evil"}]}),
        json!({"tasks":[{"goal":"x","output_schema":{"$ref":"https://host/private"}}]}),
        json!({"tasks":[{"goal":"x","output_schema":{"$defs":{"x":{"$ref":"#/$defs/x"}},"$ref":"#/$defs/x"}}]}),
        json!({"tasks":[{"goal":"x","output_schema":{"pattern":"(a)\\1"}}]}),
    ] {
        assert!(rt.dispatch(args, &context(), 0, "invalid").await.is_err());
    }
    assert_eq!(model.calls.load(Ordering::SeqCst), 0);
    Ok(())
}
#[tokio::test]
async fn child_forbidden_tool_never_dispatches_and_depth_is_bounded() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![
        call("bad", "memory", json!({})),
        call(
            "nested",
            "delegate_task",
            json!({"tasks":[{"goal":"grandchild"}]}),
        ),
        answer("done"),
    ]);
    let effects = Effects::new(false);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        effects.clone(),
        cfg(),
    );
    rt.dispatch(
        json!({"tasks":[{"goal":"root child"}]}),
        &context(),
        0,
        "root",
    )
    .await?;
    assert_eq!(effects.calls.load(Ordering::SeqCst), 0);
    assert_eq!(model.calls.load(Ordering::SeqCst), 3);
    assert!(
        model.seen.lock().unwrap()[2].0.last().unwrap()["content"]
            .as_str()
            .unwrap()
            .contains("not permitted")
    );
    Ok(())
}
#[tokio::test]
async fn bounded_nested_children_execute_with_durable_lineage() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![
        call(
            "nested",
            "delegate_task",
            json!({"tasks":[{"goal":"grandchild"}]}),
        ),
        answer("grandchild answer"),
        answer("parent child answer"),
    ]);
    let mut config = cfg();
    config.max_depth = 2;
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        config,
    );
    let r = rt
        .dispatch(
            json!({"tasks":[{"goal":"orchestrator"}]}),
            &context(),
            0,
            "root",
        )
        .await?;
    assert_eq!(r["results"][0]["summary"], "parent child answer");
    let list = rt
        .dispatch(json!({"action":"list"}), &context(), 0, "list")
        .await?;
    assert_eq!(list["count"], 2);
    let entries = list["subagents"].as_array().unwrap();
    assert!(
        entries
            .iter()
            .any(|e| e["depth"] == 2 && e["parent_id"] == r["results"][0]["subagent_id"])
    );
    assert!(
        model.seen.lock().unwrap()[1]
            .1
            .iter()
            .all(|s| s["function"]["name"] != "delegate_task")
    );
    Ok(())
}
#[tokio::test]
async fn iteration_and_output_budgets_return_partial_and_truncation() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![
        call("c", "effect", json!({})),
        answer(&"x".repeat(1000)),
    ]);
    let effects = Effects::new(false);
    let mut config = cfg();
    config.max_iterations = 1;
    config.max_output_bytes = 256;
    let rt = runtime(&d.path().join("s.sqlite"), model, effects.clone(), config);
    let r = rt
        .dispatch(json!({"tasks":[{"goal":"loop"}]}), &context(), 0, "first")
        .await?;
    assert_eq!(r["results"][0]["status"], "budget_exhausted");
    assert_eq!(effects.calls.load(Ordering::SeqCst), 1);
    let r = rt
        .dispatch(json!({"tasks":[{"goal":"long"}]}), &context(), 0, "second")
        .await?;
    assert_eq!(r["results"][0]["summary"].as_str().unwrap().len(), 256);
    assert_eq!(r["results"][0]["summary_truncated"], true);
    Ok(())
}
#[tokio::test]
async fn cancellation_and_restart_never_repeat_an_uncertain_tool_effect() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("s.sqlite");
    let model = Model::new(vec![call("effect-id", "effect", json!({}))]);
    let effect = Effects::new(true);
    let rt = runtime(&path, model.clone(), effect.clone(), cfg());
    let args = json!({"tasks":[{"goal":"effect"}]});
    let other = rt.clone();
    let input = args.clone();
    let running =
        tokio::spawn(async move { other.dispatch(input, &context(), 0, "uncertain-call").await });
    effect.started.notified().await;
    running.abort();
    let _ = running.await;
    rt.shutdown().await?;
    let new_model = Model::new(vec![answer("must not execute")]);
    let reopened = runtime(&path, new_model.clone(), effect.clone(), cfg());
    let replay = reopened
        .dispatch(args, &context(), 0, "uncertain-call")
        .await?;
    assert_eq!(replay["results"][0]["status"], "uncertain");
    assert_eq!(effect.calls.load(Ordering::SeqCst), 1);
    assert_eq!(new_model.calls.load(Ordering::SeqCst), 0);
    assert!(reopened.dispatch(json!({"action":"continue","subagent_id":replay["results"][0]["subagent_id"],"message":"retry"}),&context(),0,"retry").await.is_err());
    Ok(())
}
#[tokio::test]
async fn continue_reuses_only_child_transcript_and_rejects_wrong_parent() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("s.sqlite");
    let model = Model::new(vec![answer("first child answer")]);
    let rt = runtime(&path, model, Effects::new(false), cfg());
    let first = rt
        .dispatch(
            json!({"tasks":[{"goal":"original task","context":"private child context"}]}),
            &context(),
            0,
            "spawn",
        )
        .await?;
    let id = first["results"][0]["subagent_id"].clone();
    rt.shutdown().await?;
    let model = Model::new(vec![answer("continued answer")]);
    let rt = runtime(&path, model.clone(), Effects::new(false), cfg());
    let mut other = context();
    other.conversation_id = "stranger".into();
    assert!(
        rt.dispatch(
            json!({"action":"continue","subagent_id":id,"message":"follow-up"}),
            &other,
            0,
            "other"
        )
        .await
        .is_err()
    );
    let mut next = context();
    next.input_id = "next-input".into();
    let result = rt
        .dispatch(
            json!({"action":"continue","subagent_id":id,"message":"follow-up"}),
            &next,
            0,
            "continue",
        )
        .await?;
    assert_eq!(result["results"][0]["subagent_id"], id);
    let seen = model.seen.lock().unwrap();
    assert_eq!(seen[0].0.len(), 4);
    assert_eq!(seen[0].0[2]["content"], "first child answer");
    assert_eq!(seen[0].0[3]["content"], "follow-up");
    Ok(())
}
#[tokio::test]
async fn parent_generation_reset_stops_old_child_and_fences_new_calls() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![call("effect", "effect", json!({}))]);
    let effects = Effects::new(false);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        effects.clone(),
        cfg(),
    );
    let other = rt.clone();
    let run = tokio::spawn(async move {
        other
            .dispatch(json!({"tasks":[{"goal":"slow"}]}), &context(), 0, "spawn")
            .await
    });
    wait_calls(&model, 1).await;
    rt.set_session_generation(&context().session_id, 1).await?;
    let result = run.await??;
    assert_eq!(result["partial"], true);
    assert_eq!(effects.calls.load(Ordering::SeqCst), 0);
    assert!(
        rt.dispatch(json!({"tasks":[{"goal":"old"}]}), &context(), 0, "old")
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn live_steer_is_reported_if_final_boundary_was_already_passed_and_stop_is_scoped()
-> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![answer("finished")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let other = rt.clone();
    let run = tokio::spawn(async move {
        other
            .dispatch(json!({"tasks":[{"goal":"slow"}]}), &context(), 0, "spawn")
            .await
    });
    wait_calls(&model, 1).await;
    let list = rt
        .dispatch(json!({"action":"list"}), &context(), 0, "list")
        .await?;
    let id = list["subagents"][0]["subagent_id"].clone();
    rt.dispatch(
        json!({"action":"steer","subagent_id":id,"message":"exact extra requirement"}),
        &context(),
        0,
        "steer",
    )
    .await?;
    let mut other_context = context();
    other_context.conversation_id = "wrong".into();
    assert!(
        rt.dispatch(
            json!({"action":"stop","subagent_id":id}),
            &other_context,
            0,
            "stop"
        )
        .await
        .is_err()
    );
    let result = run.await??;
    assert_eq!(
        result["results"][0]["missed_steer"][0],
        "exact extra requirement"
    );
    Ok(())
}
#[tokio::test]
async fn parent_lease_drop_cancels_inline_children() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![answer("never")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let context = context();
    let lease = rt
        .prepare_turn(&context, &json!({"role":"user","content":"parent"}))
        .await?;
    let other = rt.clone();
    let c = context.clone();
    let run = tokio::spawn(async move {
        other
            .dispatch(json!({"tasks":[{"goal":"slow"}]}), &c, 0, "spawn")
            .await
    });
    wait_calls(&model, 1).await;
    drop(lease);
    let r = run.await??;
    assert_eq!(r["results"][0]["status"], "interrupted");
    Ok(())
}
#[tokio::test]
async fn concurrency_rejection_does_not_reserve_or_execute_extra_children() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![answer("one")]);
    let mut config = cfg();
    config.max_batch = 1;
    config.max_concurrent_children = 1;
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        config,
    );
    let other = rt.clone();
    let run = tokio::spawn(async move {
        other
            .dispatch(json!({"tasks":[{"goal":"slow"}]}), &context(), 0, "spawn")
            .await
    });
    wait_calls(&model, 1).await;
    assert!(
        rt.dispatch(json!({"tasks":[{"goal":"extra"}]}), &context(), 0, "extra")
            .await
            .is_err()
    );
    run.await??;
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    Ok(())
}
#[tokio::test]
async fn workspace_images_send_actual_pixels_and_reject_traversal() -> Result<()> {
    let d = tempfile::tempdir()?;
    let workspace = d.path().join("files");
    std::fs::create_dir(&workspace)?;
    image::RgbImage::new(8, 8).save(workspace.join("input.png"))?;
    let model = Model::new(vec![answer("pixels seen")]);
    let rt = runtime(
        &d.path().join("s.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    )
    .with_image_resolver(Arc::new(WorkspaceImages::new(
        ProtectedRoot::new(&workspace)?,
        "fixture-workspace",
    )?))?;
    rt.dispatch(
        json!({"tasks":[{"goal":"look","images":["input.png"]}]}),
        &context(),
        0,
        "image",
    )
    .await?;
    assert!(
        model.seen.lock().unwrap()[0].0[1]["content"][1]["image_url"]["url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/jpeg;base64,")
    );
    let result = rt
        .dispatch(
            json!({"tasks":[{"goal":"escape","images":["../s.sqlite"]}]}),
            &context(),
            0,
            "escape",
        )
        .await?;
    assert_eq!(result["partial"], true);
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    Ok(())
}

#[tokio::test]
async fn stopped_child_returns_partial_without_inheriting_another_owner() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![call("late", "effect", json!({}))]);
    let effect = Effects::new(false);
    let rt = runtime(
        &d.path().join("stop.sqlite"),
        model.clone(),
        effect.clone(),
        cfg(),
    );
    let child = rt.clone();
    let running = tokio::spawn(async move {
        child
            .dispatch(
                json!({"tasks":[{"goal":"stop me"}]}),
                &context(),
                0,
                "spawn",
            )
            .await
    });
    wait_calls(&model, 1).await;
    let list = rt
        .dispatch(json!({"action":"list"}), &context(), 0, "list")
        .await?;
    rt.dispatch(
        json!({"action":"stop","subagent_id":list["subagents"][0]["subagent_id"]}),
        &context(),
        0,
        "stop",
    )
    .await?;
    let output = running.await??;
    assert_eq!(output["results"][0]["status"], "interrupted");
    assert_eq!(effect.calls.load(Ordering::SeqCst), 0);
    Ok(())
}
#[tokio::test]
async fn local_schema_reference_and_fenced_array_are_validated() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(vec![answer("```json\n[{\"n\":1}]\n```")]);
    let rt = runtime(
        &d.path().join("refs.sqlite"),
        model,
        Effects::new(false),
        cfg(),
    );
    let r=rt.dispatch(json!({"tasks":[{"goal":"json","output_schema":{"$defs":{"item":{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}},"type":"array","items":{"$ref":"#/$defs/item"}}}]}),&context(),0,"schema").await?;
    assert_eq!(r["results"][0]["schema_valid"], true);
    assert_eq!(r["results"][0]["schema_retries"], 0);
    Ok(())
}
#[tokio::test]
async fn continuation_refuses_changed_capability_scope_and_second_runtime_owner() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("scope.sqlite");
    let rt = runtime(
        &path,
        Model::new(vec![answer("first")]),
        Effects::new(false),
        cfg(),
    );
    let result = rt
        .dispatch(json!({"tasks":[{"goal":"first"}]}), &context(), 0, "spawn")
        .await?;
    assert!(
        DelegationRuntime::open(
            &path,
            "owner",
            Model::new(vec![]),
            Arc::new(ToolRouter::default()),
            DelegationConfig::default()
        )
        .is_err()
    );
    rt.shutdown().await?;
    let mut changed = cfg();
    changed.capability_scope = Some("different workspace or grants".into());
    let model = Model::new(vec![]);
    let rt = runtime(&path, model.clone(), Effects::new(false), changed);
    assert!(rt.dispatch(json!({"action":"continue","subagent_id":result["results"][0]["subagent_id"],"message":"followup"}),&context(),0,"continue").await.is_err());
    assert_eq!(model.calls.load(Ordering::SeqCst), 0);
    Ok(())
}

#[tokio::test]
#[ignore = "Microbenchmark: run alone after compilation, not during saturation tests"]
async fn measure_delegation_overhead() -> Result<()> {
    let d = tempfile::tempdir()?;
    let count = 100;
    let model = Model::new(vec![answer("completed"); count]);
    let rt = runtime(
        &d.path().join("bench.sqlite"),
        model,
        Effects::new(false),
        DelegationConfig::default(),
    );
    let mut samples = Vec::new();
    for n in 0..count {
        let start = std::time::Instant::now();
        rt.dispatch(
            json!({"tasks":[{"goal":"bounded no-tool result"}]}),
            &context(),
            0,
            &format!("benchmark-{n}"),
        )
        .await?;
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(f64::total_cmp);
    println!(
        "delegation_private_sqlite_no_tools_samples={} p50_ms={:.4} p95_ms={:.4} max_ms={:.4}",
        count,
        samples[count / 2],
        samples[count * 95 / 100],
        samples[count - 1]
    );
    rt.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn shared_drain_is_idempotent_and_closes_admission_for_every_clone() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::slow(vec![answer("too late")]);
    let rt = runtime(
        &d.path().join("drain.sqlite"),
        model.clone(),
        Effects::new(false),
        cfg(),
    );
    let other = rt.clone();
    let running = tokio::spawn(async move {
        other
            .dispatch(json!({"tasks":[{"goal":"slow"}]}), &context(), 0, "spawn")
            .await
    });
    wait_calls(&model, 1).await;
    let retained = rt.clone();
    rt.drain().await?;
    rt.drain().await?;
    let _ = running.await?;
    assert!(
        retained
            .dispatch(json!({"tasks":[{"goal":"new"}]}), &context(), 0, "new")
            .await
            .is_err()
    );
    drop(retained);
    rt.shutdown().await?;
    Ok(())
}

struct CleanupGate {
    entered: Notify,
    released: std::sync::atomic::AtomicBool,
    release: Notify,
}
impl ToolExecutor for CleanupGate {
    fn schemas(&self) -> Vec<Value> {
        vec![json!({"type":"function","function":{"name":"effect","parameters":{"type":"object"}}})]
    }
    fn execute<'a>(
        &'a self,
        _: &'a str,
        _: Value,
        _: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async { Ok(json!({})) })
    }
    fn set_session_generation<'a>(
        &'a self,
        _: &'a str,
        generation: i64,
    ) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            if generation % 2 == 1 && !self.released.load(Ordering::SeqCst) {
                self.entered.notify_one();
                self.release.notified().await;
            }
            Ok(())
        })
    }
}
#[tokio::test]
async fn drain_during_cleanup_cannot_be_overwritten_by_late_success() -> Result<()> {
    let d = tempfile::tempdir()?;
    let gate = Arc::new(CleanupGate {
        entered: Notify::new(),
        released: std::sync::atomic::AtomicBool::new(false),
        release: Notify::new(),
    });
    let rt = DelegationRuntime::open(
        &d.path().join("cleanup.sqlite"),
        "owner",
        Model::new(vec![answer("finished before cleanup")]),
        Arc::new(ToolRouter::new(vec![gate.clone()])?),
        cfg(),
    )?;
    let child = rt.clone();
    let running = tokio::spawn(async move {
        child
            .dispatch(
                json!({"tasks":[{"goal":"quick task"}]}),
                &context(),
                0,
                "spawn",
            )
            .await
    });
    gate.entered.notified().await;
    rt.drain().await?;
    gate.released.store(true, Ordering::SeqCst);
    gate.release.notify_waiters();
    let result = running.await??;
    assert_eq!(result["results"][0]["status"], "interrupted");
    assert_eq!(result["partial"], true);
    rt.shutdown().await?;
    Ok(())
}
