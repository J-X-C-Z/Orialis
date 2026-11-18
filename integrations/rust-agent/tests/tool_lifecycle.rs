use anyhow::{Result, bail, ensure};
use axum::{Json, Router, routing::post};
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    session_context::CompressionPolicy,
    tool_runtime::{ToolExecutor, ToolRouter, TurnContext},
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

#[derive(Default)]
struct Probe {
    generation: Mutex<Option<i64>>,
    seen: Mutex<Vec<i64>>,
    updates: Mutex<Vec<i64>>,
    fail_cleanup: bool,
    pause: bool,
    entered: Notify,
    resume: Notify,
}
impl ToolExecutor for Probe {
    fn schemas(&self) -> Vec<Value> {
        ["generation_probe", "generation_other"]
            .map(|name| {
                json!({
                    "type":"function", "function":{"name":name,
                        "parameters":{"type":"object","properties":{}}}
                })
            })
            .to_vec()
    }
    fn set_session_generation<'a>(
        &'a self,
        _: &'a str,
        generation: i64,
    ) -> BoxFuture<'a, Result<()>> {
        // Invalidation occurs before constructing any asynchronous cleanup.
        let mut current = self.generation.lock().unwrap();
        if current.is_none_or(|old| generation > old) {
            *current = Some(generation);
            self.updates.lock().unwrap().push(generation);
        }
        Box::pin(async move {
            if self.fail_cleanup {
                bail!("controlled cleanup failure");
            }
            Ok(())
        })
    }
    fn execute<'a>(
        &'a self,
        _: &'a str,
        _: Value,
        _: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async { bail!("Core must use immutable generation dispatch") })
    }
    fn execute_at_generation<'a>(
        &'a self,
        _: &'a str,
        _: Value,
        _: &'a TurnContext,
        generation: i64,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            if self.pause {
                self.entered.notify_one();
                self.resume.notified().await;
            }
            ensure!(
                *self.generation.lock().unwrap() == Some(generation),
                "stale generation"
            );
            self.seen.lock().unwrap().push(generation);
            Ok(json!({"generation":generation}))
        })
    }
}
fn context(input: &str) -> TurnContext {
    TurnContext {
        conversation_id: "conversation".into(),
        input_id: input.into(),
        session_id: "route".into(),
    }
}
async fn call(core: &Core, input: &str) -> Result<()> {
    let answer = core
        .chat_with_context(
            ChatRequest {
                session_id: "route".into(),
                message: input.into(),
            },
            context(input),
            None,
        )
        .await?;
    assert_eq!(answer.answer, "done");
    Ok(())
}
async fn core(
    probe: Arc<Probe>,
    durable: bool,
) -> Result<(tempfile::TempDir, Core, tokio::task::JoinHandle<()>)> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr()?);
    let app=Router::new().route("/v1/chat/completions",post(|Json(body):Json<Value>| async move {
        let message=if body["messages"].as_array().unwrap().last().unwrap()["role"]=="tool" {
            json!({"role":"assistant","content":"done"})
        } else {
            // A model argument cannot choose the trusted generation.
            json!({"role":"assistant","content":null,"tool_calls":[{
                "id":"probe-call","type":"function","function":{"name":"generation_probe","arguments":"{\"generation\":999}"}
            }]})
        };
        Json(json!({"choices":[{"message":message,"finish_reason":"stop"}]}))
    }));
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let dir = tempfile::tempdir()?;
    let mut core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(endpoint, "controlled".into(), None, false)?,
    )
    .with_tool_executors(vec![probe])?;
    if durable {
        core = core.with_session_context("owner".into(), CompressionPolicy::default())?;
    }
    Ok((dir, core, server))
}

#[tokio::test]
async fn core_binds_generation_in_both_context_modes() -> Result<()> {
    for durable in [false, true] {
        let probe = Arc::new(Probe::default());
        let (_dir, core, server) = core(probe.clone(), durable).await?;
        call(&core, "first").await?;
        assert_eq!(core.reset("route".into()).await?["generation"], 1);
        call(&core, "second").await?;
        assert_eq!(*probe.seen.lock().unwrap(), vec![0, 1]);
        // Two registered tool names must not mean two independent state owners.
        assert_eq!(*probe.updates.lock().unwrap(), vec![0, 1]);
        server.abort();
    }
    Ok(())
}

#[tokio::test]
async fn stale_reset_receipt_does_not_rollback_new_kernel_generation() -> Result<()> {
    let probe = Arc::new(Probe::default());
    let (_dir, core, server) = core(probe.clone(), true).await?;
    call(&core, "zero").await?;
    core.reset_for_input("route".into(), "reset-one".into())
        .await?;
    call(&core, "one").await?;
    core.reset_for_input("route".into(), "reset-two".into())
        .await?;
    call(&core, "two").await?;
    assert_eq!(
        core.reset_for_input("route".into(), "reset-one".into())
            .await?["generation"],
        1
    );
    call(&core, "still-two").await?;
    assert_eq!(*probe.updates.lock().unwrap(), vec![0, 1, 2]);
    assert_eq!(*probe.seen.lock().unwrap(), vec![0, 1, 2, 2]);
    server.abort();
    Ok(())
}

#[tokio::test]
async fn reset_fences_a_dispatched_old_generation_before_effect() -> Result<()> {
    let probe = Arc::new(Probe {
        pause: true,
        ..Probe::default()
    });
    let (_dir, core, server) = core(probe.clone(), true).await?;
    let task = tokio::spawn({
        let core = core.clone();
        async move { call(&core, "old").await }
    });
    tokio::time::timeout(std::time::Duration::from_secs(2), probe.entered.notified()).await?;
    core.reset("route".into()).await?;
    probe.resume.notify_one();
    assert!(task.await?.is_err());
    assert!(probe.seen.lock().unwrap().is_empty());
    server.abort();
    Ok(())
}

#[tokio::test]
async fn cleanup_failure_is_reported_without_undoing_committed_reset() -> Result<()> {
    let probe = Arc::new(Probe {
        fail_cleanup: true,
        ..Probe::default()
    });
    let (_dir, core, server) = core(probe.clone(), true).await?;
    let error = core
        .reset_for_input("route".into(), "reset".into())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("reset committed"));
    assert_eq!(*probe.generation.lock().unwrap(), Some(1));
    let error = core
        .reset_for_input("route".into(), "reset".into())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("reset committed"));
    assert_eq!(*probe.updates.lock().unwrap(), vec![1]);
    server.abort();
    Ok(())
}

#[tokio::test]
async fn direct_router_rejects_old_immutable_generation() -> Result<()> {
    let probe = Arc::new(Probe::default());
    let router = ToolRouter::new(vec![probe.clone()])?;
    router.set_session_generation("route", 2).await?;
    assert!(
        router
            .execute_at_generation("generation_probe", json!({}), &context("x"), 1)
            .await
            .is_err()
    );
    assert_eq!(
        router
            .execute_at_generation("generation_probe", json!({}), &context("x"), 2)
            .await?["generation"],
        2
    );
    Ok(())
}

#[tokio::test]
async fn generation_bound_admission_rejects_stale_and_completed_input_after_reset() -> Result<()> {
    for durable in [false, true] {
        let probe = Arc::new(Probe::default());
        let (_dir, core, server) = core(probe.clone(), durable).await?;
        assert_eq!(core.session_generation("route".into()).await?, 0);
        let request = || ChatRequest {
            session_id: "route".into(),
            message: "queued".into(),
        };
        core.chat_with_context_at_generation(request(), context("queued"), None, 0)
            .await?;
        core.reset("route".into()).await?;
        assert_eq!(core.session_generation("route".into()).await?, 1);
        let error = core
            .chat_with_context_at_generation(request(), context("queued"), None, 0)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("generation changed"));
        let error = core
            .chat_with_context_at_generation(request(), context("new-id"), None, 0)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("generation changed"));
        assert_eq!(*probe.seen.lock().unwrap(), vec![0]);
        assert!(core.history("route".into()).await?.is_empty());
        core.chat_with_context_at_generation(request(), context("new-id"), None, 1)
            .await?;
        assert_eq!(*probe.seen.lock().unwrap(), vec![0, 1]);
        server.abort();
    }
    Ok(())
}
