//! Model -> Core -> actual Orialis HTTP -> durable history integration.
//! Synthetic loopback service only; no production credentials or model calls.
use anyhow::{Context, Result, ensure};
use axum::{Json, Router, extract::State, routing::post};
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    attachments::{AttachmentConfig, AttachmentTransport, ModelInputLimits},
    domain_tools::DomainClient,
    host_tools::OrialisDomainTools,
    media_runtime::{MEDIA_FIELD, OrialisMediaResolver, user_reference},
    tool_runtime::TurnContext,
};
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
struct Child(std::process::Child);
impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[derive(Clone, Default)]
struct Observed(Arc<Mutex<Vec<Value>>>);
async fn model(State(observed): State<Observed>, Json(payload): Json<Value>) -> Json<Value> {
    let mut seen = observed.0.lock().unwrap();
    let n = seen.len();
    seen.push(payload);
    let message = if n == 0 {
        json!({"role":"assistant","content":null,"tool_calls":[
            {"id":"task-call","type":"function","function":{"name":"create_task","arguments":json!({"id":"created-by-core","title":"验证真实主链"}).to_string()}},
            {"id":"memory-call","type":"function","function":{"name":"memory","arguments":json!({"target":"user","operations":[{"action":"add","content":"User prefers Rust performance reports"}]}).to_string()}}
        ]})
    } else {
        json!({"role":"assistant","content":if n==1{"Created task from actual document and saved preference."}else{"Remembered the earlier turn and document."}})
    };
    Json(json!({"choices":[{"message":message,"finish_reason":"stop"}]}))
}
#[tokio::test]
#[ignore = "requires local pinned ORIALIS_REAL_SERVER_BIN"]
async fn real_server_provider_domain_memory_attachment_restart() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let reserve = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = reserve.local_addr()?.port();
    drop(reserve);
    let origin = format!("http://127.0.0.1:{port}");
    let database = dir.path().join("server.sqlite");
    let child = std::process::Command::new(std::env::var("ORIALIS_REAL_SERVER_BIN")?)
        .env_clear()
        .env("ORIALIS_HOST", "127.0.0.1")
        .env("ORIALIS_PORT", port.to_string())
        .env("ORIALIS_ENV", "development")
        .env("ORIALIS_DEV_DEVICE_AUTH", "false")
        .env("ORIALIS_PUBLIC_URL", &origin)
        .env(
            "ORIALIS_DATABASE_URL",
            format!("sqlite://{}?mode=rwc", database.display()),
        )
        .env("ORIALIS_UPLOAD_DIR", dir.path().join("uploads"))
        .env("ORIALIS_AGENT_DEVICE_TOKEN", "synthetic-core-token")
        .env("ORIALIS_AGENT_USER_ID", "core-owner")
        .env("RUST_LOG", "error")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .spawn()?;
    let _server = Child(child);
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(1))
        .build()?;
    let mut ready = false;
    for _ in 0..100 {
        if http
            .get(format!("{origin}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    ensure!(ready, "real server startup failed");
    let db = rusqlite::Connection::open(&database)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('core-owner','core-owner','synthetic-no-login'),('other-owner','other-owner','synthetic-no-login')",[])?;
    let domain = DomainClient::new(&origin, "User_Core_Hermes", "synthetic-core-token", None)?;
    let create = domain
        .execute(
            "create_conversation",
            json!({"id":"core-conversation","title":"Integration fixture"}),
        )
        .await;
    ensure!(
        create["ok"] == true,
        "conversation creation failed: {create}"
    );
    let transport = AttachmentTransport::new(AttachmentConfig::new(
        origin.clone(),
        "User_Core_Hermes".into(),
        "synthetic-core-token".into(),
        dir.path().join("cache"),
    ))?;
    let source = dir.path().join("requirements.txt");
    std::fs::write(
        &source,
        "Concrete attachment payload: Rust performance report, owner-scoped real API.",
    )?;
    let metadata = transport
        .upload_file(
            "core-conversation",
            &source,
            Some("requirements.txt"),
            "text/plain",
            "core-contract-upload",
        )
        .await?;
    let model_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!(
        "http://{}/v1/chat/completions",
        model_listener.local_addr()?
    );
    let seen = Observed::default();
    let app = Router::new()
        .route("/v1/chat/completions", post(model))
        .with_state(seen.clone());
    let model_task = tokio::spawn(async move { axum::serve(model_listener, app).await.unwrap() });
    let path = dir.path().join("agent.sqlite");
    let make_core = || -> Result<Core> {
        Ok(Core::new(
            Store::open(&path)?,
            Provider::new(
                endpoint.clone(),
                "controlled-integration-model".into(),
                None,
                false,
            )?,
        )
        .with_tool_executors(vec![Arc::new(OrialisDomainTools(domain.clone()))])?
        .with_media_resolver(Arc::new(OrialisMediaResolver {
            transport: transport.clone(),
            limits: ModelInputLimits::default(),
        })))
    };
    let core = make_core()?;
    let session = hermes_rust_core::wire::digest("core-conversation");
    let context = TurnContext {
        conversation_id: "core-conversation".into(),
        input_id: "core-input".into(),
        session_id: session.clone(),
    };
    let user = user_reference(
        "Read this file and create the task; remember my preference.",
        &[metadata],
        &context,
    )?;
    let answer = core
        .chat_with_user_message(
            ChatRequest {
                session_id: session.clone(),
                message: user["content"].as_str().unwrap().into(),
            },
            context,
            user,
            None,
        )
        .await?;
    assert_eq!(answer.provider_calls, 2);
    assert!(answer.answer.starts_with("Created task"));
    let owner: String = db.query_row(
        "SELECT user_id FROM tasks WHERE id='created-by-core'",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(owner, "core-owner");
    let history = core.history(session.clone()).await?;
    assert_eq!(history.len(), 5);
    assert!(history[0].get(MEDIA_FIELD).is_some());
    assert!(
        !history[0]
            .to_string()
            .contains("Concrete attachment payload")
    );
    assert_eq!(
        Store::open(&path)?.memory("user")?,
        vec!["User prefers Rust performance reports"]
    );
    drop(core);
    let core = make_core()?;
    let followup = core
        .chat(ChatRequest {
            session_id: session.clone(),
            message: "Continue from the saved document.".into(),
        })
        .await?;
    assert!(followup.answer.starts_with("Remembered"));
    let observed = seen.0.lock().unwrap();
    assert_eq!(observed.len(), 3);
    let first = &observed[0];
    assert_eq!(first["tools"].as_array().unwrap().len(), 40);
    let names = first["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["function"]["name"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(names.contains(&"create_calendar_event"));
    assert!(names.contains(&"news_dot_publish"));
    assert!(
        first["messages"]
            .to_string()
            .contains("Concrete attachment payload")
    );
    assert!(!first["messages"].to_string().contains(MEDIA_FIELD));
    let results = observed[1]["messages"]
        .as_array()
        .context("second request missing messages")?;
    let tools = results
        .iter()
        .filter(|v| v["role"] == "tool")
        .collect::<Vec<_>>();
    assert_eq!(tools.len(), 2);
    let task: Value = serde_json::from_str(tools[0]["content"].as_str().unwrap())?;
    assert_eq!(task["ok"], true);
    let memory: Value = serde_json::from_str(tools[1]["content"].as_str().unwrap())?;
    assert_eq!(memory["done"], true);
    assert!(memory.get("entries").is_none());
    assert!(
        observed[2]["messages"]
            .to_string()
            .contains("Concrete attachment payload")
    );
    assert_eq!(observed[2]["messages"][0], first["messages"][0]);
    model_task.abort();
    Ok(())
}
