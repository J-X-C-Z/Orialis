use super::*;
use crate::{
    agent_gateway::AgentCommand, metadata, AgentRegistry, AppState, SqlitePoolOptions, VERSION,
};
use axum::{extract::DefaultBodyLimit, routing::get, Router};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
};

struct Server {
    state: Arc<AppState>,
    address: std::net::SocketAddr,
    task: tokio::task::JoinHandle<()>,
}
impl Server {
    async fn new() -> Self {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        for user in ["alice", "bob"] {
            sqlx::query("INSERT INTO users (id,username,password_hash) VALUES (?,?,'unused')")
                .bind(user)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO user_sessions (id,user_id,token_hash,expires_at) VALUES (?,?,?,'2099-01-01T00:00:00Z')")
                .bind(user).bind(user).bind(crate::hash_token(user)).execute(&pool).await.unwrap();
        }
        let state = Arc::new(AppState {
            metadata: metadata(VERSION, "test", "http://localhost"),
            pool,
            agent: AgentRegistry::default(),
            mobile: crate::mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".into(),
            upload_dir: std::env::temp_dir().join("unused-memory-test"),
        });
        let app = Router::new()
            .route(
                "/api/v1/memory/analyses/{id}",
                get(get_analysis).post(start_analysis),
            )
            .layer(DefaultBodyLimit::max(1_500_000))
            .with_state(state.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            state,
            address,
            task,
        }
    }
    async fn agent(
        &self,
        user: &str,
        device: &str,
        capability: bool,
    ) -> mpsc::Receiver<AgentCommand> {
        let (tx, rx) = mpsc::channel(8);
        self.state
            .agent
            .register_connection(
                format!("{user}-{device}"),
                user.into(),
                device.into(),
                "linux".into(),
                tx,
            )
            .await;
        if capability {
            self.state
                .agent
                .set_peer_capabilities(device, vec!["memory.analyze".into()])
                .await;
        }
        rx
    }
    async fn request(
        &self,
        method: &str,
        user: Option<&str>,
        id: &str,
        body: Value,
    ) -> (u16, Value) {
        let body = body.to_string();
        let mut stream = TcpStream::connect(self.address).await.unwrap();
        let auth = user
            .map(|user| format!("Authorization: Session {user}\r\n"))
            .unwrap_or_default();
        let request = format!("{method} /api/v1/memory/analyses/{id} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len());
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).await.unwrap();
        let split = bytes
            .windows(4)
            .position(|part| part == b"\r\n\r\n")
            .unwrap();
        let status = std::str::from_utf8(&bytes[..split])
            .unwrap()
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes[split + 4..]).unwrap_or(Value::Null),
        )
    }
    async fn wait_status(&self, status: &str) -> Value {
        for _ in 0..100 {
            let (_, result) = self
                .request("GET", Some("alice"), "capture-1", Value::Null)
                .await;
            if result["status"] == status {
                return result;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        panic!("background job did not reach {status}");
    }
    async fn no_chat(&self) {
        for table in ["conversations", "messages", "attachments", "sync_events"] {
            let count: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
                .fetch_one(&self.state.pool)
                .await
                .unwrap();
            assert_eq!(count, 0, "unexpected {table} row");
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn next_request(rx: &mut mpsc::Receiver<AgentCommand>) -> String {
    match tokio::time::timeout(Duration::from_secs(1), rx.recv())
        .await
        .unwrap()
        .unwrap()
    {
        AgentCommand::Send(message) => match *message {
            GatewayMessage::MemoryAnalyze {
                request_id,
                content,
                image_base64,
                source_urls,
                ..
            } => {
                assert_eq!(content, "original evidence");
                assert!(image_base64.is_none());
                assert!(source_urls.is_empty());
                request_id
            }
            other => panic!("unexpected frame: {other:?}"),
        },
        _ => panic!("unexpected close"),
    }
}
fn evidence() -> Value {
    json!({"content":"original evidence"})
}

#[tokio::test]
async fn background_result_is_scoped_idempotent_and_never_creates_chat() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    let (code, first) = server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    assert_eq!(code, 200);
    assert_eq!(first["status"], "analyzing");
    let request_id = next_request(&mut rx).await;
    assert_eq!(
        server
            .request("POST", Some("alice"), "capture-1", evidence())
            .await
            .1["status"],
        "analyzing"
    );
    assert!(rx.try_recv().is_err());
    assert_eq!(
        server
            .request("GET", Some("bob"), "capture-1", Value::Null)
            .await
            .0,
        404
    );
    assert_eq!(
        server
            .request("GET", None, "capture-1", Value::Null)
            .await
            .0,
        401
    );
    assert!(
        !server
            .state
            .agent
            .resolve_reply_for_device(
                "another-device",
                GatewayMessage::MemoryResult {
                    version: 1,
                    request_id: request_id.clone(),
                    content: Some("wrong owner".into()),
                    error: None,
                    category: None,
                    source_url: None,
                    video_status: None,
                    video_summary: None,
                    video_error: None,
                }
            )
            .await
    );
    assert!(
        server
            .state
            .agent
            .resolve_reply_for_device(
                TARGET_DEVICE,
                GatewayMessage::MemoryResult {
                    version: 1,
                    request_id,
                    content: Some("# A title\n\nA summary".into()),
                    error: None,
                    category: None,
                    source_url: None,
                    video_status: None,
                    video_summary: None,
                    video_error: None,
                }
            )
            .await
    );
    assert_eq!(
        server.wait_status("completed").await["content"],
        "# A title\n\nA summary"
    );
    assert_eq!(
        server
            .request("POST", Some("alice"), "capture-1", evidence())
            .await
            .1["status"],
        "completed"
    );
    assert!(rx.try_recv().is_err());
    assert_eq!(
        server
            .request(
                "POST",
                Some("alice"),
                "capture-1",
                json!({"content":"different"})
            )
            .await
            .0,
        409
    );
    server.no_chat().await;
}

#[tokio::test]
async fn offline_wrong_device_and_missing_capability_never_fall_back() {
    let server = Server::new().await;
    let mut other = server.agent("alice", "JXCZ_HAKARI_Hermes", true).await;
    assert_eq!(
        server
            .request("POST", Some("alice"), "capture-1", evidence())
            .await
            .0,
        503
    );
    let mut azure = server.agent("alice", TARGET_DEVICE, false).await;
    assert_eq!(
        server
            .request("POST", Some("alice"), "capture-1", evidence())
            .await
            .0,
        503
    );
    assert!(azure.try_recv().is_err());
    assert!(other.try_recv().is_err());
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM memory_analyses")
        .fetch_one(&server.state.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
    server.no_chat().await;
}

#[tokio::test]
async fn failed_and_interrupted_analysis_can_retry_without_old_attempt_overwrite() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    let first = next_request(&mut rx).await;
    server
        .state
        .agent
        .resolve_reply_for_device(
            TARGET_DEVICE,
            GatewayMessage::MemoryResult {
                version: 1,
                request_id: first.clone(),
                content: None,
                error: Some("SECRET_PROVIDER_DETAIL".into()),
                category: None,
                source_url: None,
                video_status: None,
                video_summary: None,
                video_error: None,
            },
        )
        .await;
    let failed = server.wait_status("failed").await;
    assert_eq!(failed["error"], FAILED);
    assert!(!failed.to_string().contains("SECRET"));
    server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    let second = next_request(&mut rx).await;
    assert_ne!(first, second);
    // Simulate a server interruption: reads expire stale work, rather than hanging forever.
    sqlx::query("UPDATE memory_analyses SET started_at=0 WHERE id='capture-1'")
        .execute(&server.state.pool)
        .await
        .unwrap();
    assert_eq!(server.wait_status("failed").await["error"], TIMED_OUT);
    server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    let third = next_request(&mut rx).await;
    assert_ne!(second, third);
    server
        .state
        .agent
        .resolve_reply_for_device(
            TARGET_DEVICE,
            GatewayMessage::MemoryResult {
                version: 1,
                request_id: second,
                content: Some("stale result".into()),
                error: None,
                category: None,
                source_url: None,
                video_status: None,
                video_summary: None,
                video_error: None,
            },
        )
        .await;
    server
        .state
        .agent
        .resolve_reply_for_device(
            TARGET_DEVICE,
            GatewayMessage::MemoryResult {
                version: 1,
                request_id: third,
                content: Some("# Current result\n\nValid body".into()),
                error: None,
                category: None,
                source_url: None,
                video_status: None,
                video_summary: None,
                video_error: None,
            },
        )
        .await;
    assert_eq!(
        server.wait_status("completed").await["content"],
        "# Current result\n\nValid body"
    );
    server.no_chat().await;
}

#[tokio::test]
async fn analysis_evidence_limits_are_checked_before_dispatch() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    for body in [
        json!({"content":" "}),
        json!({"content":"a".repeat(100001)}),
        json!({"content":"valid", "imageBase64":"bad"}),
        json!({"content":"valid", "imageBase64": STANDARD.encode(b"not JPEG")}),
    ] {
        assert_eq!(
            server
                .request("POST", Some("alice"), "capture-1", body)
                .await
                .0,
            400
        );
    }
    assert!(rx.try_recv().is_err());
    server.no_chat().await;
}

#[test]
fn memory_protocol_validates_limits_and_correlation() {
    let frame = GatewayMessage::MemoryAnalyze {
        version: 1,
        request_id: "attempt-1".into(),
        content: "evidence".into(),
        image_base64: None,
        source_urls: Vec::new(),
    };
    let raw = serde_json::to_string(&frame).unwrap();
    assert_eq!(
        crate::agent_gateway::protocol::parse_message(&raw)
            .unwrap()
            .message_id(),
        Some("attempt-1")
    );
    let result =
        r#"{"version":1,"type":"memory.result","request_id":"attempt-1","content":"summary"}"#;
    assert_eq!(
        crate::agent_gateway::protocol::parse_message(result)
            .unwrap()
            .reply_to(),
        Some("attempt-1")
    );
    for invalid in [
        r#"{"version":1,"type":"memory.result","request_id":"a","content":"summary","error":"error"}"#,
        r#"{"version":1,"type":"memory.result","request_id":"a"}"#,
    ] {
        assert!(crate::agent_gateway::protocol::parse_message(invalid).is_err());
    }
}

#[tokio::test]
async fn malformed_summary_is_failed_and_can_be_reanalyzed() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    let first = next_request(&mut rx).await;
    server
        .state
        .agent
        .resolve_reply_for_device(
            TARGET_DEVICE,
            GatewayMessage::MemoryResult {
                version: 1,
                request_id: first,
                content: Some("# Title only\n\n".into()),
                error: None,
                category: None,
                source_url: None,
                video_status: None,
                video_summary: None,
                video_error: None,
            },
        )
        .await;
    server.wait_status("failed").await;
    server
        .request("POST", Some("alice"), "capture-1", evidence())
        .await;
    let next = next_request(&mut rx).await;
    server
        .state
        .agent
        .resolve_reply_for_device(
            TARGET_DEVICE,
            GatewayMessage::MemoryResult {
                version: 1,
                request_id: next,
                content: Some("# Fixed\n\nSummary body".into()),
                error: None,
                category: None,
                source_url: None,
                video_status: None,
                video_summary: None,
                video_error: None,
            },
        )
        .await;
    server.wait_status("completed").await;
}

#[tokio::test]
async fn classification_video_and_original_url_round_trip_without_chat() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    let url = "https://www.bilibili.com/video/BV1test?share_source=copy_web&token=abc%2Bdef";
    let body = json!({"content":"original evidence", "sourceUrls":[url]});
    let (code, _) = server
        .request("POST", Some("alice"), "capture-1", body.clone())
        .await;
    assert_eq!(code, 200);
    let request_id = match rx.recv().await.unwrap() {
        AgentCommand::Send(frame) => match *frame {
            GatewayMessage::MemoryAnalyze {
                request_id,
                source_urls,
                ..
            } => {
                assert_eq!(source_urls, [url]);
                request_id
            }
            _ => panic!("expected memory analysis"),
        },
        _ => panic!("unexpected close"),
    };
    assert_eq!(
        server
            .request(
                "POST",
                Some("alice"),
                "capture-1",
                json!({"content":"original evidence", "sourceUrls":["https://b23.tv/different"]})
            )
            .await
            .0,
        409
    );
    assert!(
        server
            .state
            .agent
            .resolve_reply_for_device(
                TARGET_DEVICE,
                GatewayMessage::MemoryResult {
                    version: 1,
                    request_id,
                    content: Some("# AI video\n\nEvidence-based summary".into()),
                    error: None,
                    category: Some("ai".into()),
                    source_url: Some(url.into()),
                    video_status: Some("analyzed".into()),
                    video_summary: Some(
                        "Video captions and frames explain a model training method.".into()
                    ),
                    video_error: None,
                }
            )
            .await
    );
    let result = server.wait_status("completed").await;
    assert_eq!(result["category"], "ai");
    assert_eq!(result["sourceUrl"], url);
    assert_eq!(result["videoStatus"], "analyzed");
    assert!(result["videoSummary"]
        .as_str()
        .unwrap()
        .contains("captions and frames"));
    assert!(result.get("source_url").is_none());
    assert_eq!(
        server
            .request("GET", Some("alice"), "capture-1", Value::Null)
            .await
            .1,
        result
    );
    server.no_chat().await;
}

#[tokio::test]
async fn invalid_source_urls_are_rejected_before_dispatch() {
    let server = Server::new().await;
    let mut rx = server.agent("alice", TARGET_DEVICE, true).await;
    for urls in [
        json!(["file:///private/video"]),
        json!(["https://user:password@example.com/video"]),
        json!(["https://example.com\nprivate"]),
        json!(vec!["https://example.com"; 33]),
    ] {
        assert_eq!(
            server
                .request(
                    "POST",
                    Some("alice"),
                    "capture-1",
                    json!({"content":"original evidence", "sourceUrls":urls})
                )
                .await
                .0,
            400
        );
    }
    assert!(rx.try_recv().is_err());
}

#[test]
fn memory_video_metadata_limits_preserve_old_protocol_compatibility() {
    use crate::agent_gateway::protocol::parse_message;
    let legacy =
        json!({"version":1,"type":"memory.analyze","request_id":"attempt","content":"evidence"});
    assert!(
        matches!(parse_message(&legacy.to_string()).unwrap(), GatewayMessage::MemoryAnalyze { source_urls, .. } if source_urls.is_empty())
    );
    let base = json!({"version":1,"type":"memory.result","request_id":"attempt","content":"# Video\n\nSummary", "category":"other", "source_url":"https://b23.tv/Original", "video_status":"unavailable", "video_error":"Platform did not supply accessible media"});
    assert!(parse_message(&base.to_string()).is_ok());
    for (key, bad) in [
        ("category", json!("unknown")),
        ("source_url", json!("javascript:alert(1)")),
        ("video_status", json!("guessed")),
        ("video_summary", json!("a".repeat(100001))),
        ("video_error", json!("a".repeat(4001))),
    ] {
        let mut invalid = base.clone();
        invalid[key] = bad;
        assert!(
            parse_message(&invalid.to_string()).is_err(),
            "invalid {key} should fail"
        );
    }
    let mut missing_evidence = base;
    missing_evidence["video_status"] = json!("analyzed");
    assert!(parse_message(&missing_evidence.to_string()).is_err());
}
