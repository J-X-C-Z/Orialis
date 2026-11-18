use hermes_rust_core::{Provider, domain_tools, private_db};
#[path = "../src/conversation_updates.rs"]
mod conversation_updates;
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Request, State},
    http::Response,
    routing::any,
};
use conversation_updates::*;
use domain_tools::DomainClient;
use serde_json::{Value, json};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{sync::Notify, task::JoinHandle};
#[derive(Default)]
struct MockState {
    requests: Mutex<Vec<(String, Value)>>,
    row: Mutex<Option<Value>>,
    override_model: Mutex<Option<Value>>,
    block_model: AtomicBool,
    release: Notify,
    model_calls: AtomicUsize,
    rename_during_model: AtomicBool,
    real_rename: Mutex<Option<(DomainClient, String)>>,
}
async fn handler(State(state): State<Arc<MockState>>, request: Request) -> Response<Body> {
    let path = request.uri().path().to_owned();
    let method = request.method().to_string();
    let body = to_bytes(request.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    let body: Value = if body.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&body).unwrap()
    };
    state
        .requests
        .lock()
        .unwrap()
        .push((format!("{method} {path}"), body.clone()));
    let (status, result) = if path == "/v1/chat/completions" {
        state.model_calls.fetch_add(1, Ordering::SeqCst);
        if state.block_model.load(Ordering::SeqCst) {
            state.release.notified().await;
        }
        if state.rename_during_model.load(Ordering::SeqCst)
            && let Some(row) = state.row.lock().unwrap().as_mut()
        {
            row["title"] = json!("Manual rename");
            row["version"] = json!(2);
        }
        let real_rename = state.real_rename.lock().unwrap().take();
        if let Some((domain, id)) = real_rename {
            assert_eq!(
                domain
                    .execute(
                        "update_conversation",
                        json!({"id":id,"baseVersion":1,"title":"User chosen title"})
                    )
                    .await["ok"],
                true
            );
        }
        let content = match body["max_tokens"].as_u64().unwrap() {
            80 => "电路复习安排",
            160 => "我先核对这份资料，再给你完整结论。",
            _ => "入口逻辑已经确认，接着核对相邻模块的行为。",
        };
        let response=state.override_model.lock().unwrap().clone().unwrap_or_else(||json!({"choices":[{"message":{"role":"assistant","content":content}}],"usage":{"completion_tokens_details":{"reasoning_tokens":0}}}));
        (200, response)
    } else if path == "/api/v1/conversations" {
        (200,json!([state.row.lock().unwrap().clone().unwrap_or_else(||json!({"id":"chat","title":"新会话","version":1,"isDefault":false,"type":"normal"}))]))
    } else if method == "PATCH" && path.starts_with("/api/v1/conversations/") {
        let mut row = state.row.lock().unwrap();
        let current = row.get_or_insert_with(|| json!({"id":"chat","title":"新会话","version":1}));
        if current["version"] != body["baseVersion"] {
            (409, json!({"error":"version conflict"}))
        } else {
            current["title"] = body["title"].clone();
            current["version"] = json!(2);
            (200, current.clone())
        }
    } else {
        (404, json!({"error":"not found"}))
    };
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(result.to_string()))
        .unwrap()
}
struct Mock {
    state: Arc<MockState>,
    base: String,
    task: JoinHandle<()>,
    dir: tempfile::TempDir,
}
impl Drop for Mock {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Mock {
    async fn new() -> Self {
        let state = Arc::new(MockState::default());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let app = Router::new()
            .fallback(any(handler))
            .with_state(state.clone());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            state,
            base,
            task,
            dir: tempfile::tempdir().unwrap(),
        }
    }
    fn cache(&self) -> UpdateCache {
        UpdateCache::open(
            &self.dir.path().join("updates.sqlite"),
            "local-test-account",
        )
        .unwrap()
    }
    fn aux(&self) -> AuxiliaryClient {
        AuxiliaryClient::new(
            &format!("{}/v1/chat/completions", self.base),
            "fake-aux",
            Some("synthetic-key"),
            self.cache(),
        )
        .unwrap()
    }
    fn domain(&self) -> DomainClient {
        DomainClient::new(
            &self.base,
            "User_Test_Hermes",
            "synthetic-device-token",
            None,
        )
        .unwrap()
    }
    fn models(&self) -> Vec<Value> {
        self.state
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(p, _)| p == "POST /v1/chat/completions")
            .map(|(_, v)| v.clone())
            .collect()
    }
    async fn calls(&self, n: usize) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while self.state.model_calls.load(Ordering::SeqCst) < n {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
    }
}
fn input() -> TurnInput {
    TurnInput::new("chat", "user-message", "帮我安排电路复习")
}
fn facts() -> PublicFacts {
    PublicFacts {
        phase: Phase::Tool,
        activity: "查看文件和资料".into(),
        stage_history: vec![Stage {
            phase: Phase::Tool,
            activity: "查看文件和资料".into(),
        }],
        public_notes: vec!["已确认入口位于 adapter.py。".into()],
        previous_updates: vec![],
    }
}
async fn advance(secs: u64) {
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(secs)).await;
    tokio::time::resume();
    tokio::task::yield_now().await;
}

#[tokio::test]
async fn title_is_real_http_get_model_and_versioned_cas_patch() {
    let fake = Mock::new().await;
    let aux = fake.aux();
    assert_eq!(
        aux.name_conversation(&fake.domain(), &input())
            .await
            .unwrap(),
        TitleOutcome::Renamed("电路复习安排".into())
    );
    let requests = fake.state.requests.lock().unwrap();
    assert_eq!(
        requests.iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>(),
        [
            "GET /api/v1/conversations",
            "POST /v1/chat/completions",
            "PATCH /api/v1/conversations/chat"
        ]
    );
    assert_eq!(
        requests[2].1,
        json!({"title":"电路复习安排","baseVersion":1})
    );
    let model = &requests[1].1;
    assert_eq!(model["max_tokens"], 80);
    assert!(model.get("tools").is_none());
    assert_eq!(
        model["chat_template_kwargs"],
        json!({"thinking":false,"enable_thinking":false})
    );
}
#[tokio::test]
async fn manual_custom_default_and_background_titles_are_never_overwritten() {
    for row in [
        json!({"id":"chat","title":"Custom","version":1}),
        json!({"id":"chat","title":"新会话","version":2}),
        json!({"id":"chat","title":"新会话","version":1,"isDefault":true}),
        json!({"id":"chat","title":"新会话","version":1,"type":"main"}),
    ] {
        let fake = Mock::new().await;
        *fake.state.row.lock().unwrap() = Some(row);
        assert_eq!(
            fake.aux()
                .name_conversation(&fake.domain(), &input())
                .await
                .unwrap(),
            TitleOutcome::Skipped
        );
        assert_eq!(fake.models().len(), 0);
    }
    let fake = Mock::new().await;
    for id in ["memory-x", "event-y"] {
        let mut event = input();
        event.conversation_id = id.into();
        assert_eq!(
            fake.aux()
                .name_conversation(&fake.domain(), &event)
                .await
                .unwrap(),
            TitleOutcome::Skipped
        );
    }
    assert!(fake.state.requests.lock().unwrap().is_empty());
}
#[tokio::test]
async fn concurrent_manual_rename_wins_and_cas_is_not_retried() {
    let fake = Mock::new().await;
    *fake.state.row.lock().unwrap() = Some(json!({"id":"chat","title":"新会话","version":1}));
    fake.state.rename_during_model.store(true, Ordering::SeqCst);
    assert_eq!(
        fake.aux()
            .name_conversation(&fake.domain(), &input())
            .await
            .unwrap(),
        TitleOutcome::Conflict
    );
    assert_eq!(
        fake.state
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(p, _)| p.starts_with("PATCH"))
            .count(),
        1
    );
    assert_eq!(
        fake.state.row.lock().unwrap().as_ref().unwrap()["title"],
        "Manual rename"
    );
}
#[tokio::test]
async fn invalid_or_thinking_title_does_not_patch() {
    for message in [
        json!({"content":"标题\n解释"}),
        json!({"content":"<think>secret</think>title"}),
        json!({"content":"Normal","reasoning_content":"private reasoning"}),
        json!({"content":"x".repeat(65)}),
    ] {
        let fake = Mock::new().await;
        *fake.state.override_model.lock().unwrap() = Some(json!({"choices":[{"message":message}]}));
        assert!(matches!(
            fake.aux()
                .name_conversation(&fake.domain(), &input())
                .await
                .unwrap(),
            TitleOutcome::Skipped | TitleOutcome::Unavailable
        ));
        assert!(
            !fake
                .state
                .requests
                .lock()
                .unwrap()
                .iter()
                .any(|(p, _)| p.starts_with("PATCH"))
        );
    }
}
#[tokio::test]
async fn concurrent_initials_and_process_restart_reuse_cache_and_detect_changed_input() {
    let fake = Mock::new().await;
    let a = fake.aux();
    let event = input();
    let (one, two) = tokio::join!(a.initial(&event), a.initial(&event));
    assert_eq!(one.unwrap(), two.unwrap());
    assert_eq!(fake.models().len(), 1);
    assert_eq!(
        fake.aux().initial(&event).await.unwrap(),
        "我先核对这份资料，再给你完整结论。"
    );
    assert_eq!(fake.models().len(), 1);
    let mut changed = event;
    changed.text = "Different input".into();
    assert!(a.initial(&changed).await.is_err());
    assert_eq!(fake.models().len(), 1);
    assert!(UpdateCache::open(&fake.dir.path().join("updates.sqlite"), "other-owner").is_err());
}
#[tokio::test]
async fn evidence_is_bounded_public_only_and_cache_has_no_raw_request() {
    let fake = Mock::new().await;
    let mut event = input();
    event.text = format!("PRIVATE_REQUEST_CANARY{}", "中".repeat(7000));
    event.attachment_names = vec!["附件".repeat(100); 12];
    let a = fake.aux();
    a.initial(&event).await.unwrap();
    let f = facts();
    assert!(a.progress(&event, &f).await.unwrap().is_some());
    let models = fake.models();
    for model in &models {
        assert!(model.get("tools").is_none());
        assert_eq!(model["chat_template_kwargs"]["thinking"], false);
        let evidence: Value =
            serde_json::from_str(model["messages"][1]["content"].as_str().unwrap()).unwrap();
        assert_eq!(evidence["attachment_names"].as_array().unwrap().len(), 10);
        assert!(
            evidence["attachment_names"]
                .as_array()
                .unwrap()
                .iter()
                .all(|n| n.as_str().unwrap().chars().count() == 120)
        );
    }
    let first: Value =
        serde_json::from_str(models[0]["messages"][1]["content"].as_str().unwrap()).unwrap();
    assert_eq!(first["message"].as_str().unwrap().chars().count(), 6000);
    let second: Value =
        serde_json::from_str(models[1]["messages"][1]["content"].as_str().unwrap()).unwrap();
    assert_eq!(second["request"].as_str().unwrap().chars().count(), 4000);
    assert_eq!(second["public_notes"], json!(f.public_notes));
    assert!(
        second.get("args").is_none()
            && second.get("result").is_none()
            && second.get("reasoning").is_none()
    );
    let db = rusqlite::Connection::open(fake.dir.path().join("updates.sqlite")).unwrap();
    let values: Vec<String> = db
        .prepare("SELECT input_digest||COALESCE(content,'') FROM helper_cache")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert!(
        values
            .iter()
            .all(|s| !s.contains("PRIVATE_REQUEST_CANARY") && !s.contains("adapter.py"))
    );
}
#[tokio::test]
async fn progress_requires_new_public_notes_and_same_facts_are_cached() {
    let fake = Mock::new().await;
    let aux = fake.aux();
    let mut f = facts();
    f.public_notes.clear();
    assert!(aux.progress(&input(), &f).await.unwrap().is_none());
    assert_eq!(fake.models().len(), 0);
    let first = aux.progress(&input(), &facts()).await.unwrap();
    let second = aux.progress(&input(), &facts()).await.unwrap();
    assert_eq!(first, second);
    assert_eq!(fake.models().len(), 1);
    let mut changed = facts();
    changed.public_notes.push("另一个事实".into());
    aux.progress(&input(), &changed).await.unwrap();
    assert_eq!(fake.models().len(), 2);
}
#[tokio::test]
async fn reasoning_and_empty_summaries_never_leak_or_create_fake_progress() {
    for response in [
        json!({"choices":[{"message":{"content":"Visible","reasoning":"PRIVATE"}}]}),
        json!({"choices":[{"message":{"content":"Visible"}}],"usage":{"completion_tokens_details":{"reasoning_tokens":1}}}),
        json!({"choices":[{"message":{"content":"<analysis>private</analysis>"}}]}),
        json!({"choices":[{"message":{"content":"\"\""}}]}),
        json!({"choices":[{"message":{"content":"x".repeat(241)}}]}),
    ] {
        let fake = Mock::new().await;
        *fake.state.override_model.lock().unwrap() = Some(response);
        assert!(
            fake.aux()
                .progress(&input(), &facts())
                .await
                .unwrap()
                .is_none()
        );
    }
    let fake = Mock::new().await;
    *fake.state.override_model.lock().unwrap() = Some(json!({"choices":[]}));
    assert_eq!(
        fake.aux().initial(&input()).await.unwrap(),
        "我先看看你发来的内容，接着给你完整回复。"
    );
}
#[tokio::test]
async fn only_negotiated_user_messages_start_followups_and_ids_are_stable() {
    let fake = Mock::new().await;
    for (cap, mut event) in [
        (false, input()),
        (true, TurnInput::new("chat", "m", "/stop")),
        (true, input()),
    ] {
        if cap && !event.is_command {
            event.is_user_message = false;
        }
        let (updates, mut receiver) = TurnUpdates::start(fake.aux(), event, cap);
        tokio::task::yield_now().await;
        assert!(receiver.try_recv().is_err());
        updates.close();
    }
    assert!(fake.models().is_empty());
    assert_eq!(input().initial_id(), "initial_fa55cdeb652befd364c24627");
    assert_eq!(input().initial_id(), input().clone().initial_id());
    assert_ne!(
        input().initial_id(),
        TurnInput::new("chat", "other", "x").initial_id()
    );
    assert!(input().progress_id("text").starts_with("progress_"));
    assert_eq!(AUXILIARY_TIMEOUT, Duration::from_secs(12));
    assert_eq!(PROGRESS_INTERVAL, Duration::from_secs(30));
}
#[tokio::test]
async fn blocked_initial_cannot_block_primary_or_emit_after_actual_output_close_or_disconnect() {
    let fake = Mock::new().await;
    fake.state.block_model.store(true, Ordering::SeqCst);
    let (updates, mut receiver) = TurnUpdates::start(fake.aux(), input(), true);
    fake.calls(1).await;
    let main = tokio::time::timeout(Duration::from_millis(50), async { "complete answer" })
        .await
        .unwrap();
    assert_eq!(main, "complete answer");
    updates.public_output(Some("Real primary output"));
    fake.state.release.notify_waiters();
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(receiver.try_recv().is_err());
    updates.close();
    assert!(receiver.try_recv().is_err());
}
#[tokio::test]
async fn queued_initial_lease_is_invalidated_on_final_and_provider_clone_is_independent() {
    let fake = Mock::new().await;
    let provider = Provider::new(
        format!("{}/v1/chat/completions", fake.base),
        "fake-aux".into(),
        None,
        false,
    )
    .unwrap();
    let aux = AuxiliaryClient::from_provider(&provider, fake.cache()).unwrap();
    assert!(!format!("{aux:?}").contains("synthetic"));
    let (updates, mut receiver) = TurnUpdates::start(aux, input(), true);
    let pending = tokio::time::timeout(Duration::from_secs(2), receiver.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(pending.kind, UpdateKind::Initial);
    assert!(pending.is_current());
    let frame = pending.frame_if_current().unwrap();
    assert_eq!(frame["reply_to"], "user-message");
    assert!(
        frame["message_id"]
            .as_str()
            .unwrap()
            .starts_with("initial_")
    );
    pending.confirmed();
    updates.close();
    assert!(!pending.is_current());
    assert!(pending.frame_if_current().is_none());
}
#[tokio::test]
async fn progress_is_throttled_uses_generic_phases_and_stale_generation_is_suppressed() {
    let fake = Mock::new().await;
    let (updates, mut receiver) = TurnUpdates::start(fake.aux(), input(), true);
    let initial = receiver.recv().await.unwrap();
    initial.confirmed();
    updates.observe(Phase::Tool, Some("web_search PRIVATE_RAW_ARGS"));
    advance(31).await;
    assert_eq!(fake.models().len(), 1);
    updates.public_output(Some("已确认入口位于 adapter.py。"));
    updates.observe(Phase::Tool, Some("read_file PRIVATE_RAW_TOOL"));
    advance(29).await;
    assert_eq!(fake.models().len(), 1);
    advance(2).await;
    fake.calls(2).await;
    let pending = tokio::time::timeout(Duration::from_secs(2), receiver.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(pending.kind, UpdateKind::Progress);
    assert!(pending.is_current());
    assert!(
        pending.frame_if_current().unwrap()["message_id"]
            .as_str()
            .unwrap()
            .starts_with("progress_")
    );
    let evidence = fake.models()[1]["messages"][1]["content"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(evidence.contains("查看文件和资料"));
    assert!(!evidence.contains("PRIVATE_RAW"));
    pending.confirmed();
    updates.observe(Phase::Returned, None);
    assert!(!pending.is_current());
    advance(61).await;
    assert_eq!(fake.models().len(), 2);
    assert_eq!(tool_phase("terminal"), "执行任务步骤");
    assert_eq!(tool_phase("other"), "调用工具处理请求");
    updates.close();
}
#[tokio::test]
async fn phase_change_and_stop_cancel_inflight_progress_without_late_emission() {
    let fake = Mock::new().await;
    let (updates, mut receiver) = TurnUpdates::start(fake.aux(), input(), true);
    receiver.recv().await.unwrap().confirmed();
    updates.public_output(Some("Confirmed fact"));
    updates.observe(Phase::Tool, Some("read_file"));
    fake.state.block_model.store(true, Ordering::SeqCst);
    advance(31).await;
    fake.calls(2).await;
    updates.observe(Phase::Returned, None);
    fake.state.release.notify_waiters();
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert!(receiver.try_recv().is_err());
    updates.close();
    advance(61).await;
    assert_eq!(fake.models().len(), 2);
    assert!(receiver.try_recv().is_err());
}

#[tokio::test]
async fn auxiliary_deadline_discards_late_model_and_preserves_fallback_cache() {
    let fake = Mock::new().await;
    fake.state.block_model.store(true, Ordering::SeqCst);
    let aux = fake.aux();
    let initial = tokio::spawn(async move { aux.initial(&input()).await });
    fake.calls(1).await;
    advance(13).await;
    let content = tokio::time::timeout(Duration::from_secs(1), initial)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(content, "我先看看你发来的内容，接着给你完整回复。");
    fake.state.release.notify_waiters();
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert_eq!(fake.aux().initial(&input()).await.unwrap(), content);
    assert_eq!(fake.models().len(), 1);
}

struct ServerChild(std::process::Child);
impl Drop for ServerChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[tokio::test]
#[ignore = "requires ORIALIS_REAL_SERVER_BIN pointing to pinned local Orialis server"]
async fn actual_orialis_title_naming_and_racing_manual_rename_are_cas_safe() {
    let model = Mock::new().await;
    let directory = tempfile::tempdir().unwrap();
    let database = directory.path().join("title.sqlite");
    let reserve = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = reserve.local_addr().unwrap().port();
    drop(reserve);
    let origin = format!("http://127.0.0.1:{port}");
    let child = std::process::Command::new(
        std::env::var("ORIALIS_REAL_SERVER_BIN").expect("set ORIALIS_REAL_SERVER_BIN"),
    )
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
    .env("ORIALIS_UPLOAD_DIR", directory.path().join("uploads"))
    .env("ORIALIS_AGENT_DEVICE_TOKEN", "local-test-token")
    .env("ORIALIS_AGENT_USER_ID", "title-owner")
    .env("RUST_LOG", "error")
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::inherit())
    .spawn()
    .unwrap();
    let _server = ServerChild(child);
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(200))
        .build()
        .unwrap();
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
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(ready);
    let db = rusqlite::Connection::open(&database).unwrap();
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('title-owner','title-owner','local-test-no-login')",[]).unwrap();
    let domain = DomainClient::new(&origin, "User_Test_Hermes", "local-test-token", None).unwrap();
    let auxiliary = model.aux();
    for id in ["untouched", "race"] {
        assert_eq!(
            domain
                .execute("create_conversation", json!({"id":id,"title":"新会话"}))
                .await["ok"],
            true
        );
    }
    let event = TurnInput::new("untouched", "message-1", "安排电路复习");
    assert_eq!(
        auxiliary.name_conversation(&domain, &event).await.unwrap(),
        TitleOutcome::Renamed("电路复习安排".into())
    );
    let (title, version): (String, i64) = db
        .query_row(
            "SELECT title,version FROM conversations WHERE id='untouched'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((title, version), ("电路复习安排".into(), 2));
    assert_eq!(
        auxiliary.name_conversation(&domain, &event).await.unwrap(),
        TitleOutcome::Skipped
    );
    assert_eq!(model.models().len(), 1);
    *model.state.real_rename.lock().unwrap() = Some((domain.clone(), "race".into()));
    let event = TurnInput::new("race", "message-2", "安排电路复习");
    assert_eq!(
        auxiliary.name_conversation(&domain, &event).await.unwrap(),
        TitleOutcome::Conflict
    );
    let title: String = db
        .query_row("SELECT title FROM conversations WHERE id='race'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(title, "User chosen title");
    assert_eq!(model.models().len(), 2);
    let wrong = DomainClient::new(&origin, "User_Test_Hermes", "wrong-token", None).unwrap();
    assert_eq!(
        auxiliary.name_conversation(&wrong, &event).await.unwrap(),
        TitleOutcome::Unavailable
    );
    assert_eq!(model.models().len(), 2);
    println!(
        "REAL TITLE: local Orialis HTTP + local HTTP model named untouched chat and preserved concurrent manual rename via 409 CAS, without retries."
    );
}
