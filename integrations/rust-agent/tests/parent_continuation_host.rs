//! Slow output transport must not own the parent-model scheduling pump.
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::State,
    routing::{get, post},
};
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    account_scope::OwnerVerifier,
    attachments::{AttachmentConfig, AttachmentTransport},
    delegation::{DelegationConfig, DelegationModel, DelegationRuntime},
    delivery::{DeliveryIdentity, DeliveryLimits, DeliveryOutbox},
    inbound_delivery::ConversationVerifier,
    journal::Journal,
    output_files::{OutputConfig, OutputFiles},
    parent_continuation::{ContinuationConfig, ContinuationState, ParentContinuation},
    parent_continuation_host::ParentContinuationHost,
    session_context::CompressionPolicy,
    tool_runtime::{ToolRouter, TurnContext},
};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, Semaphore};
#[rustfmt::skip]
#[allow(dead_code, clippy::collapsible_if)]
#[path = "fixtures/orialis_delivery_mapper.rs"]
mod original_mapper;
struct Child;
impl DelegationModel for Child {
    fn route_identity(&self) -> String {
        "controlled-host-child".into()
    }
    fn complete<'a>(
        &'a self,
        _messages: &'a [Value],
        _tools: &'a [Value],
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async { Ok(json!({"role":"assistant","content":"child complete"})) })
    }
}
#[derive(Clone)]
struct StateData {
    file: String,
    uploads: Arc<AtomicUsize>,
    started: Arc<Notify>,
    release: Arc<Semaphore>,
    origin: String,
    success_upload: bool,
    model_calls: Arc<AtomicUsize>,
}
async fn model(State(state): State<StateData>, Json(payload): Json<Value>) -> Json<Value> {
    state.model_calls.fetch_add(1, Ordering::SeqCst);
    let messages = payload["messages"].as_array().unwrap();
    let continuation = messages
        .iter()
        .any(|m| m["role"] == "tool" && m["name"] == "delegate_task_completion");
    // Tool results omit the optional name; identify the authoritative synthetic call.
    let continuation = continuation
        || messages.iter().any(|m| {
            m["tool_calls"].as_array().is_some_and(|calls| {
                calls
                    .iter()
                    .any(|c| c["function"]["name"] == "delegate_task_completion")
            })
        });
    let slow = messages
        .iter()
        .any(|m| m["role"] == "user" && m["content"] == "slow");
    let has_user = |label: &str| {
        messages
            .iter()
            .any(|m| m["role"] == "user" && m["content"] == label)
    };
    let answer = if continuation && has_user("attachmentonly") {
        format!("MEDIA:{}", state.file)
    } else if continuation && has_user("attachmenttext") {
        format!("Useful attachment summary\nMEDIA:{}", state.file)
    } else if continuation && slow {
        format!("Slow final\nMEDIA:{}", state.file)
    } else if continuation {
        "Fast exact final".into()
    } else {
        "Original parent returned".into()
    };
    Json(
        json!({"choices":[{"message":{"role":"assistant","content":answer},"finish_reason":"stop"}]}),
    )
}
async fn upload(State(state): State<StateData>, _body: axum::body::Bytes) -> Json<Value> {
    let index = state.uploads.fetch_add(1, Ordering::SeqCst) + 1;
    state.started.notify_one();
    if state.success_upload {
        let id = format!("fixture-upload-{index}");
        Json(
            json!({"items":[{"id":id,"name":"fixture.txt","mimeType":"text/plain",
            "size":std::fs::metadata(&state.file).unwrap().len(),
            "downloadUrl":format!("{}/api/v1/attachments/{id}/download",state.origin)}]}),
        )
    } else {
        state.release.acquire().await.unwrap().forget();
        Json(json!({"items":[]}))
    }
}
fn context(label: &str) -> TurnContext {
    TurnContext {
        session_id: format!("route-{label}"),
        conversation_id: format!("conv-{label}"),
        input_id: format!("original-{label}"),
    }
}
async fn background(core: &Core, rt: &DelegationRuntime, label: &str) -> Result<String> {
    let ctx = context(label);
    core.chat_with_context(
        ChatRequest {
            session_id: ctx.session_id.clone(),
            message: label.into(),
        },
        ctx.clone(),
        None,
    )
    .await?;
    let handle = rt
        .dispatch(
            json!({"background":true,"tasks":[{"goal":"finish fixture task"}]}),
            &ctx,
            0,
            &format!("call-{label}"),
        )
        .await?;
    let notification = format!(
        "delegation-completion-{}",
        &hermes_rust_core::wire::digest(
            handle["delegation_id"]
                .as_str()
                .context("missing delegation ID")?
        )[..40]
    );
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if rt.inspect_completion(&notification).await?.is_some() {
                return Ok(notification);
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await?
}
#[tokio::test]
async fn slow_artifact_lane_does_not_block_other_parent_or_stop() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let artifact = dir.path().join("fixture.txt");
    std::fs::write(&artifact, b"synthetic attachment")?;
    let state = StateData {
        file: artifact.to_string_lossy().into_owned(),
        uploads: Arc::new(AtomicUsize::new(0)),
        started: Arc::new(Notify::new()),
        release: Arc::new(Semaphore::new(0)),
        origin: String::new(),
        success_upload: false,
        model_calls: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route(
            "/api/v1/auth/session",
            get(|| async { Json(json!({"userId":"host-fixture-owner"})) }),
        )
        .route(
            "/api/v1/conversations/{id}/messages",
            get(|| async { Json(json!({"items":[]})) }),
        )
        .route("/api/v1/conversations/{id}/attachments", post(upload))
        .route("/v1/chat/completions", post(model))
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let server = format!("http://{}", listener.local_addr()?);
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let device = "TE_ST_Host";
    let token = "fixture-token";
    let owner = OwnerVerifier::new(&server, device, token, None)?
        .verify()
        .await?
        .scope();
    let runtime = DelegationRuntime::open(
        &dir.path().join("child.sqlite"),
        &owner,
        Arc::new(Child),
        Arc::new(ToolRouter::new(vec![])?),
        DelegationConfig {
            background_enabled: true,
            ..Default::default()
        },
    )?;
    let core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(
            format!("{server}/v1/chat/completions"),
            "synthetic".into(),
            None,
            false,
        )?,
    )
    .with_tool_executors(vec![Arc::new(runtime.clone())])?
    .with_session_context(owner.clone(), CompressionPolicy::default())?;
    let queue = ParentContinuation::open(
        dir.path().join("queue.sqlite"),
        &owner,
        runtime.clone(),
        ContinuationConfig {
            enabled: true,
            ..Default::default()
        },
    )
    .await?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("outbox.sqlite"),
        DeliveryIdentity::new(&owner, &server.replacen("http", "ws", 1), device, token)?,
        DeliveryLimits::default(),
    )
    .await?;
    let mut output_config =
        OutputConfig::new(dir.path().join("outputs.sqlite"), dir.path().join("spool"));
    output_config.artifact_roots = vec![dir.path().to_owned()];
    let outputs = OutputFiles::open(
        output_config,
        AttachmentTransport::new(AttachmentConfig::new(
            server.clone(),
            device.into(),
            token.into(),
            dir.path().join("cache"),
        ))?,
    )
    .await?;
    let journal = Journal::open(&dir.path().join("journal.sqlite"), "host-fixture").await?;
    let host = ParentContinuationHost::new(
        queue.clone(),
        runtime.clone(),
        core.clone(),
        outbox.clone(),
        ConversationVerifier::new(&server.replacen("http", "ws", 1), device, token, owner)?,
        journal.clone(),
    )
    .await?
    .with_outputs(Some(outputs));
    let slow = background(&core, &runtime, "slow").await?;
    let running = host.clone();
    let host_task = tokio::spawn(async move { running.run().await });
    tokio::time::timeout(Duration::from_secs(5), state.started.notified())
        .await
        .context("artifact upload never started")?;
    let fast = background(&core, &runtime, "fast").await?;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if queue
                .inspect(&fast)
                .await?
                .is_some_and(|r| r.state == ContinuationState::Enqueued)
            {
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .context("slow artifact blocked another model/output")??;
    assert_eq!(
        outbox
            .inspect(&ParentContinuationHost::output_id(&fast))
            .await?
            .unwrap()
            .request
            .body
            .content,
        "Fast exact final"
    );
    assert!(
        outbox
            .inspect(&ParentContinuationHost::output_id(&slow))
            .await?
            .is_none()
    );
    assert_eq!(state.uploads.load(Ordering::SeqCst), 1);
    tokio::time::timeout(
        Duration::from_secs(1),
        host.suppress_conversation("conv-slow"),
    )
    .await??;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        queue.inspect(&slow).await?.unwrap().state,
        ContinuationState::Suppressed
    );
    assert_eq!(
        state.uploads.load(Ordering::SeqCst),
        1,
        "no repeated uncertain upload"
    );
    host.stop();
    tokio::time::timeout(Duration::from_secs(2), host_task).await??;
    state.release.add_permits(1);
    runtime.drain().await?;
    journal.shutdown().await?;
    task.abort();
    Ok(())
}

struct RestartStack {
    host: ParentContinuationHost,
    core: Core,
    runtime: DelegationRuntime,
    queue: ParentContinuation,
    outbox: DeliveryOutbox,
    journal: Journal,
}
async fn restart_stack(dir: &std::path::Path, server: &str) -> Result<RestartStack> {
    let device = "TE_ST_Host";
    let token = "fixture-token";
    let gateway = server.replacen("http", "ws", 1);
    let owner = OwnerVerifier::new(&gateway, device, token, None)?
        .verify()
        .await?
        .scope();
    let runtime = DelegationRuntime::open(
        &dir.join("child.sqlite"),
        &owner,
        Arc::new(Child),
        Arc::new(ToolRouter::new(vec![])?),
        DelegationConfig {
            background_enabled: true,
            ..Default::default()
        },
    )?;
    let core = Core::new(
        Store::open(&dir.join("core.sqlite"))?,
        Provider::new(
            format!("{server}/v1/chat/completions"),
            "synthetic".into(),
            None,
            false,
        )?,
    )
    .with_tool_executors(vec![Arc::new(runtime.clone())])?
    .with_session_context(owner.clone(), CompressionPolicy::default())?;
    let queue = ParentContinuation::open(
        dir.join("queue.sqlite"),
        &owner,
        runtime.clone(),
        ContinuationConfig {
            enabled: true,
            ..Default::default()
        },
    )
    .await?;
    let outbox = DeliveryOutbox::open(
        dir.join("outbox.sqlite"),
        DeliveryIdentity::new(&owner, &gateway, device, token)?,
        DeliveryLimits::default(),
    )
    .await?;
    let mut cfg = OutputConfig::new(dir.join("outputs.sqlite"), dir.join("spool"));
    cfg.artifact_roots = vec![dir.to_owned()];
    let outputs = OutputFiles::open(
        cfg,
        AttachmentTransport::new(AttachmentConfig::new(
            gateway.clone(),
            device.into(),
            token.into(),
            dir.join("cache"),
        ))?,
    )
    .await?;
    let journal = Journal::open(&dir.join("journal.sqlite"), "host-fixture").await?;
    let host = ParentContinuationHost::new(
        queue.clone(),
        runtime.clone(),
        core.clone(),
        outbox.clone(),
        ConversationVerifier::new(&gateway, device, token, owner)?,
        journal.clone(),
    )
    .await?
    .with_outputs(Some(outputs));
    Ok(RestartStack {
        host,
        core,
        runtime,
        queue,
        outbox,
        journal,
    })
}
#[tokio::test]
async fn uploaded_attachments_become_honest_text_in_original_mapper_and_survive_restart()
-> Result<()> {
    let dir = tempfile::tempdir()?;
    let artifact = dir.path().join("fixture.txt");
    std::fs::write(&artifact, b"synthetic attachment")?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let server = format!("http://{}", listener.local_addr()?);
    let state = StateData {
        file: artifact.to_string_lossy().into_owned(),
        uploads: Arc::new(AtomicUsize::new(0)),
        started: Arc::new(Notify::new()),
        release: Arc::new(Semaphore::new(0)),
        origin: server.clone(),
        success_upload: true,
        model_calls: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route(
            "/api/v1/auth/session",
            get(|| async { Json(json!({"userId":"host-fixture-owner"})) }),
        )
        .route(
            "/api/v1/conversations/{id}/messages",
            get(|| async { Json(json!({"items":[]})) }),
        )
        .route("/api/v1/conversations/{id}/attachments", post(upload))
        .route("/v1/chat/completions", post(model))
        .with_state(state.clone());
    let server_task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let stack = restart_stack(dir.path(), &server).await?;
    let mut sources = Vec::new();
    for label in ["attachmentonly", "attachmenttext"] {
        sources.push(background(&stack.core, &stack.runtime, label).await?);
    }
    let running = stack.host.clone();
    let host_task = tokio::spawn(async move { running.run().await });
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let mut done = true;
            for source in &sources {
                done &= stack
                    .queue
                    .inspect(source)
                    .await?
                    .is_some_and(|r| r.state == ContinuationState::Enqueued);
            }
            if done {
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await??;
    let notice = "附件已上传，上传记录已保留；当前通知通道不展示或交付附件。";
    let mut saved = Vec::new();
    for (index, source) in sources.iter().enumerate() {
        let record = stack.queue.inspect(source).await?.unwrap();
        assert!(
            record.final_assistant.as_ref().unwrap()["content"]
                .as_str()
                .unwrap()
                .contains("MEDIA:"),
            "exact Core final must remain unchanged"
        );
        match stack
            .core
            .lookup_turn(record.session_id.clone(), record.input_id.clone())
            .await?
        {
            hermes_rust_core::session_context::TurnLookup::Completed {
                final_assistant, ..
            } => assert_eq!(Some(final_assistant), record.final_assistant),
            other => anyhow::bail!("Core final missing after upload: {other:?}"),
        }
        let id = ParentContinuationHost::output_id(source);
        let request = stack.outbox.inspect(&id).await?.unwrap().request;
        let expected = if index == 0 {
            notice.to_owned()
        } else {
            format!("Useful attachment summary\n\n{notice}")
        };
        assert_eq!(request.body.content, expected);
        assert!(request.body.attachments.is_empty());
        let raw = request.frame()?;
        assert!(!raw.to_string().contains("/attachments/"));
        assert!(!raw.to_string().contains("MEDIA:"));
        let parsed = original_mapper::parse_extension(&raw.to_string())?;
        let events = original_mapper::extension_mobile_events(&parsed);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["message"], expected);
        assert!(events[0]["message"].as_str().is_some_and(|s| !s.is_empty()));
        assert!(events[0].get("attachments").is_none());
        let permit = stack
            .host
            .prepare_send(&id)
            .await?
            .context("missing final send permit")?;
        assert_eq!(permit.frame(), &raw);
        drop(permit);
        saved.push(request);
    }
    assert_eq!(state.uploads.load(Ordering::SeqCst), 2);
    let db = rusqlite::Connection::open(dir.path().join("outputs.sqlite"))?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM output_files WHERE state='uploaded' AND metadata IS NOT NULL",
            [],
            |r| r.get::<_, usize>(0)
        )?,
        2
    );
    assert_eq!(
        db.query_row("SELECT count(*) FROM output_final_messages", [], |r| r
            .get::<_, usize>(0))?,
        0,
        "notification must not invent a persisted chat binding"
    );
    drop(db);
    let model_calls = state.model_calls.load(Ordering::SeqCst);
    stack.host.stop();
    tokio::time::timeout(Duration::from_secs(2), host_task).await??;
    stack.runtime.drain().await?;
    stack.journal.shutdown().await?;
    drop(stack);
    let reopened = restart_stack(dir.path(), &server).await?;
    let running = reopened.host.clone();
    let resumed = tokio::spawn(async move { running.run().await });
    tokio::time::sleep(Duration::from_millis(1100)).await;
    for (source, request) in sources.iter().zip(saved) {
        let id = ParentContinuationHost::output_id(source);
        assert_eq!(
            reopened.outbox.inspect(&id).await?.unwrap().request,
            request
        );
        let permit = reopened
            .host
            .prepare_send(&id)
            .await?
            .context("lost immutable retry payload")?;
        assert_eq!(permit.frame(), &request.frame()?);
    }
    assert_eq!(
        state.model_calls.load(Ordering::SeqCst),
        model_calls,
        "restart repeated a model call"
    );
    assert_eq!(
        state.uploads.load(Ordering::SeqCst),
        2,
        "restart repeated an upload"
    );
    for source in &sources {
        let id = ParentContinuationHost::output_id(source);
        let request = reopened.outbox.inspect(&id).await?.unwrap().request;
        assert!(reopened.outbox.acknowledge(json!({"version":1,"type":"delivery.ack","delivery_id":id,"conversation_id":request.target.conversation_id,"status":"received"})).await?);
    }
    let db = rusqlite::Connection::open(dir.path().join("outputs.sqlite"))?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM output_files WHERE state='uploaded' AND delivered_at IS NULL",
            [],
            |r| r.get::<_, usize>(0)
        )?,
        2,
        "notification ACK must not mark artifacts delivered"
    );
    drop(db);
    reopened.host.stop();
    tokio::time::timeout(Duration::from_secs(2), resumed).await??;
    reopened.runtime.drain().await?;
    reopened.journal.shutdown().await?;
    server_task.abort();
    Ok(())
}
#[test]
fn pinned_original_delivery_mapper_drops_attachments_even_when_parser_accepts_them() -> Result<()> {
    use sha2::{Digest, Sha256};
    let provenance: Value = serde_json::from_str(include_str!(
        "fixtures/orialis_delivery_mapper_provenance.json"
    ))?;
    assert_eq!(
        provenance["fixture_sha256"],
        format!(
            "{:x}",
            Sha256::digest(include_bytes!("fixtures/orialis_delivery_mapper.rs"))
        )
    );
    let original = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../orialis/orialis-server/src/agent_gateway/protocol.rs");
    if original.exists() {
        assert_eq!(
            provenance["source_sha256"],
            format!("{:x}", Sha256::digest(std::fs::read(original)?))
        );
    }
    for content in ["", "Original text"] {
        let frame = json!({"version":1,"type":"proactive.delivery","delivery_id":"fixture-output","conversation_id":"fixture-conversation","content":content,
            "attachments":[{"id":"file","name":"file.txt","mime_type":"text/plain","download_url":"https://not-published.invalid/file"}]});
        let parsed = original_mapper::parse_extension(&frame.to_string())?;
        let events = original_mapper::extension_mobile_events(&parsed);
        assert_eq!(events[0]["message"], content);
        assert!(events[0].get("attachments").is_none());
        assert!(!events[0].to_string().contains("not-published"));
    }
    Ok(())
}
