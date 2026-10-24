use super::*;
use agent_gateway::{protocol::GatewayMessage, AgentCommand};
use tokio::sync::mpsc;

async fn setup(pool: SqlitePool) -> Arc<AppState> {
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    sqlx::query("INSERT INTO users (id,username,password_hash) VALUES ('u1','u1','test'),('u2','u2','test')")
        .execute(&pool).await.unwrap();
    for (user, id) in [("u1", "mac"), ("u1", "aozora"), ("u2", "foreign")] {
        sqlx::query("INSERT INTO agent_devices (device_id,user_id,client,plugin_version,platform,last_seen_at) VALUES (?,?,'test','1','test',?)")
            .bind(id).bind(user).bind(now()).execute(&pool).await.unwrap();
    }
    for (user, id) in [
        ("u1", "mac-chat"),
        ("u1", "aozora-chat"),
        ("u1", "legacy"),
        ("u2", "mac-chat"),
    ] {
        sqlx::query("INSERT INTO conversations (id,user_id,title,created_at,updated_at) VALUES (?,?,'Chat',?,?)")
            .bind(id).bind(user).bind(now()).bind(now()).execute(&pool).await.unwrap();
    }
    Arc::new(AppState {
        metadata: metadata(VERSION, "test", "http://localhost"),
        pool,
        agent: AgentRegistry::default(),
        mobile: mobile_realtime::MobileRegistry::default(),
        agent_device_token: Some("test-agent".into()),
        agent_user_id: Some("u1".into()),
        public_url: "http://localhost".into(),
        upload_dir: PathBuf::from("/tmp"),
    })
}
fn headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert("authorization", "Bearer test-agent".parse().unwrap());
    headers
}
pub(super) async fn bind(
    state: &Arc<AppState>,
    chat: &str,
    device: &str,
) -> Result<Json<ConversationAgentDeviceResponse>, AppError> {
    set_conversation_agent_device(
        State(state.clone()),
        headers(),
        Path(chat.into()),
        Json(ConversationAgentDeviceInput {
            device_id: device.into(),
        }),
    )
    .await
}
pub(super) async fn memory_state() -> Arc<AppState> {
    setup(
        SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn conversation_binding_persists_and_is_account_scoped() {
    let path = std::env::temp_dir().join(format!("orialis-chat-routing-{}.db", new_id()));
    let url = format!("sqlite://{}?mode=rwc", path.display());
    let state = setup(
        SqlitePoolOptions::new()
            .max_connections(1)
            .connect(&url)
            .await
            .unwrap(),
    )
    .await;
    assert!(matches!(
        bind(&state, "mac-chat", "foreign").await,
        Err(AppError::NotFound)
    ));
    assert!(matches!(
        bind(&state, "missing", "mac").await,
        Err(AppError::NotFound)
    ));
    assert!(matches!(
        bind(&state, "mac-chat", " ").await,
        Err(AppError::BadRequest(_))
    ));
    let Json(response) = bind(&state, "mac-chat", "mac").await.unwrap();
    assert_eq!(
        serde_json::to_value(response).unwrap(),
        serde_json::json!({"conversationId":"mac-chat","deviceId":"mac"})
    );
    assert_eq!(
        conversation_agent_device(&state.pool, "u2", "mac-chat")
            .await
            .unwrap(),
        None
    );
    assert_eq!(
        conversation_agent_device(&state.pool, "u1", "legacy")
            .await
            .unwrap(),
        None
    );
    let version: i64 = sqlx::query_scalar(
        "SELECT version FROM conversations WHERE user_id='u1' AND id='mac-chat'",
    )
    .fetch_one(&state.pool)
    .await
    .unwrap();
    assert_eq!(version, 1);
    state.pool.close().await;
    let reopened = SqlitePoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .unwrap();
    assert_eq!(
        conversation_agent_device(&reopened, "u1", "mac-chat")
            .await
            .unwrap(),
        Some("mac".into())
    );
    reopened.close().await;
    std::fs::remove_file(path).unwrap();
}

async fn queue(state: &AppState, id: &str, conversation: &str) {
    sqlx::query("INSERT INTO messages (id,user_id,conversation_id,role,content,attachments_json) VALUES (?,'u1',?,'user','hello','[]')")
        .bind(id).bind(conversation).execute(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO agent_delivery_queue (message_id,user_id,conversation_id,next_attempt_at) VALUES (?,'u1',?,?)")
        .bind(id).bind(conversation).bind(now()).execute(&state.pool).await.unwrap();
}
async fn dispatch(state: Arc<AppState>, chat: &str, id: &str) {
    agent_gateway::ws::dispatch_message(
        state,
        "u1".into(),
        chat.into(),
        id.into(),
        "hello".into(),
        vec![],
    )
    .await;
}
async fn reply(state: &AppState, command: AgentCommand, id: &str) {
    let AgentCommand::Send(message) = command else {
        panic!("wrong command")
    };
    let GatewayMessage::MessageSend {
        message_id,
        conversation_id,
        ..
    } = *message
    else {
        panic!("wrong command")
    };
    state
        .agent
        .resolve_reply(GatewayMessage::MessageReply {
            version: 1,
            message_id: id.into(),
            reply_to: message_id,
            conversation_id,
            content: "reply".into(),
            attachments: vec![],
        })
        .await;
}

fn native_reply(id: &str, anchor: &str, chat: &str, text: &str) -> GatewayMessage {
    GatewayMessage::MessageReply {
        version: 1, message_id: id.into(), reply_to: anchor.into(),
        conversation_id: chat.into(), content: text.into(), attachments: vec![],
    }
}

#[tokio::test]
async fn response_ui_reply_preserves_exact_content_in_commits_retries_and_history() {
    let state = memory_state().await;
    let _ = bind(&state, "mac-chat", "mac").await.unwrap();
    queue(&state, "ui-anchor", "mac-chat").await;
    let rich = format!("今天的学习安排。\n\n```orialis-ui\n{}\n```", include_str!("../../docs/contracts/response-ui-v1.example.json"));
    // Malformed/unknown UI remains a valid text reply, never a reason to lose content.
    let malformed = "仍然保留这段文字。\n```orialis-ui\n{not JSON}\n```";
    for (id, text) in [("ui-rich", rich.as_str()), ("ui-malformed", malformed)] {
        let wire = serde_json::to_string(&native_reply(id, "ui-anchor", "mac-chat", text)).unwrap();
        let response = agent_gateway::protocol::parse_message(&wire).unwrap();
        for _ in 0..2 {
            assert!(matches!(agent_gateway::ws::accept_message_reply(&state, "u1", "mac", response.clone()).await.unwrap(), GatewayMessage::MessageAck { status, .. } if status == "received"));
        }
        let stored: String = sqlx::query_scalar("SELECT content FROM messages WHERE id=?")
            .bind(id).fetch_one(&state.pool).await.unwrap();
        assert_eq!(stored, text);
    }
    let Json(history) = list_messages(State(state.clone()), headers(), Path("mac-chat".into()),
        Query(MessageListQuery { after: None, limit: Some(100) })).await.unwrap();
    let messages = history["items"].as_array().unwrap();
    for (id, text) in [("ui-rich", rich.as_str()), ("ui-malformed", malformed)] {
        let rows: Vec<_> = messages.iter().filter(|m| m["id"] == id).collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["content"], text);
    }
}

#[tokio::test]
async fn native_followups_commit_before_ack_and_preserve_multiple_media() {
    let state = memory_state().await;
    let _ = bind(&state, "mac-chat", "mac").await.unwrap();
    queue(&state, "native-anchor", "mac-chat").await;
    let (tx, mut rx) = mpsc::channel(4);
    state.agent.register_connection("native".into(), "u1".into(), "mac".into(), "macos".into(), tx).await;
    let task = tokio::spawn(dispatch(state.clone(), "mac-chat", "native-anchor"));
    rx.recv().await.unwrap();
    let boundary = native_reply("boundary", "native-anchor", "mac-chat", "Before tool");
    let ack = agent_gateway::ws::accept_message_reply(&state, "u1", "mac", boundary.clone()).await.unwrap();
    assert!(matches!(ack, GatewayMessage::MessageAck { message_id, status, .. } if message_id=="boundary" && status=="received"));
    // An ACK is not constructed until the committed row is readable and the
    // durable delivery has been removed, even for the first/native boundary.
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM messages WHERE id='boundary'").fetch_one(&state.pool).await.unwrap(), 1);
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM agent_delivery_queue WHERE message_id='native-anchor'").fetch_one(&state.pool).await.unwrap(), 0);
    task.await.unwrap();
    for id in ["media-one", "media-two"] {
        sqlx::query("INSERT INTO attachments (id,user_id,original_name,mime_type,size_bytes,storage_path,access_token_hash,conversation_id) VALUES (?,'u1','result.txt','text/plain',4,'unused','unused','mac-chat')")
            .bind(id).execute(&state.pool).await.unwrap();
        let mut response = native_reply(id, "native-anchor", "mac-chat", "same caption");
        if let GatewayMessage::MessageReply { attachments, .. } = &mut response {
            attachments.push(agent_gateway::protocol::GatewayAttachment { id:id.into(), name:"result.txt".into(), mime_type:"text/plain".into(),size:4,download_url:"http://localhost/unused".into() });
        }
        agent_gateway::ws::accept_message_reply(&state,"u1","mac",response).await.unwrap();
    }
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",native_reply("final", "native-anchor", "mac-chat", "After tool")).await.unwrap();
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",boundary).await.unwrap();
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM messages WHERE role='assistant' AND reply_to_message_id='native-anchor'").fetch_one(&state.pool).await.unwrap(),4);
}

#[tokio::test]
async fn native_followup_rejects_foreign_device_owner_conversation_and_anchor() {
    let state=memory_state().await;
    let _ = bind(&state,"mac-chat","mac").await.unwrap();
    let _ = bind(&state,"aozora-chat","aozora").await.unwrap();
    queue(&state,"anchor-owned","mac-chat").await;
    for (owner,device,anchor,chat) in [
        ("u1","aozora","anchor-owned","mac-chat"),
        ("u2","mac","anchor-owned","mac-chat"),
        ("u1","mac","anchor-owned","aozora-chat"),
        ("u1","mac","missing","mac-chat"),
    ] {
        assert!(agent_gateway::ws::accept_message_reply(&state,owner,device,native_reply("rejected",anchor,chat,"no")).await.is_err());
    }
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM messages WHERE id='rejected'").fetch_one(&state.pool).await.unwrap(),0);
    let original=native_reply("idempotent","anchor-owned","mac-chat","original");
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",original.clone()).await.unwrap();
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",original).await.unwrap();
    assert!(agent_gateway::ws::accept_message_reply(&state,"u1","mac",native_reply("idempotent","anchor-owned","mac-chat","changed body")).await.is_err());
    assert!(agent_gateway::ws::accept_message_reply(&state,"u1","mac",native_reply("bad-anchor","idempotent","mac-chat","assistant is not a user anchor")).await.is_err());
}

#[tokio::test]
async fn native_reply_database_failure_returns_no_ack_and_can_retry() {
    let state=memory_state().await;
    let _ = bind(&state,"mac-chat","mac").await.unwrap();
    queue(&state,"db-anchor","mac-chat").await;
    sqlx::query("CREATE TRIGGER fail_reply_commit BEFORE DELETE ON agent_delivery_queue BEGIN SELECT RAISE(ABORT,'simulated storage failure'); END").execute(&state.pool).await.unwrap();
    let response=native_reply("db-reply","db-anchor","mac-chat","text");
    assert!(agent_gateway::ws::accept_message_reply(&state,"u1","mac",response.clone()).await.is_err());
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM messages WHERE id='db-reply'").fetch_one(&state.pool).await.unwrap(),0);
    assert_eq!(sqlx::query_scalar::<_,i64>("SELECT count(*) FROM agent_delivery_queue WHERE message_id='db-anchor'").fetch_one(&state.pool).await.unwrap(),1);
    sqlx::query("DROP TRIGGER fail_reply_commit").execute(&state.pool).await.unwrap();
    assert!(matches!(agent_gateway::ws::accept_message_reply(&state,"u1","mac",response).await.unwrap(),GatewayMessage::MessageAck { .. }));
}

#[tokio::test]
async fn native_reply_attachment_owner_and_chat_are_authoritative() {
    let state=memory_state().await;
    let _=bind(&state,"mac-chat","mac").await.unwrap();
    queue(&state,"file-anchor","mac-chat").await;
    for (id,owner,chat) in [("own-file","u1","mac-chat"),("foreign-file","u2","mac-chat"),("other-chat-file","u1","aozora-chat")] {
        sqlx::query("INSERT INTO attachments (id,user_id,original_name,mime_type,size_bytes,storage_path,access_token_hash,conversation_id) VALUES (?,?,'verified.txt','text/plain',4,'unused','unused',?)")
            .bind(id).bind(owner).bind(chat).execute(&state.pool).await.unwrap();
    }
    let file_reply=|id:&str| {
        let mut response=native_reply("same-file-reply","file-anchor","mac-chat","caption");
        if let GatewayMessage::MessageReply { attachments, .. }=&mut response {
            attachments.push(agent_gateway::protocol::GatewayAttachment {id:id.into(),name:"untrusted.txt".into(),mime_type:"text/plain".into(),size:4,download_url:"http://untrusted/unused".into()});
        }
        response
    };
    for id in ["foreign-file","other-chat-file"] {
        assert!(agent_gateway::ws::accept_message_reply(&state,"u1","mac",file_reply(id)).await.is_err());
    }
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",file_reply("own-file")).await.unwrap();
    agent_gateway::ws::accept_message_reply(&state,"u1","mac",file_reply("own-file")).await.unwrap();
    let stored:String=sqlx::query_scalar("SELECT attachments_json FROM messages WHERE id='same-file-reply'").fetch_one(&state.pool).await.unwrap();
    assert!(stored.contains("verified.txt"));
    assert!(!stored.contains("untrusted"));
}

#[tokio::test]
async fn unbound_message_never_chooses_an_arbitrary_online_device() {
    let state=memory_state().await;
    let (tx,mut rx)=mpsc::channel(2);
    state.agent.register_connection("online".into(),"u1".into(),"mac".into(),"test".into(),tx).await;
    queue(&state,"unbound-anchor","legacy").await;
    dispatch(state.clone(),"legacy","unbound-anchor").await;
    assert!(rx.try_recv().is_err());
    assert_eq!(conversation_agent_device(&state.pool,"u1","legacy").await.unwrap(),None);
    let error:String=sqlx::query_scalar("SELECT last_error FROM agent_delivery_queue WHERE message_id='unbound-anchor'").fetch_one(&state.pool).await.unwrap();
    assert!(error.contains("explicit Agent destination"));
}
#[tokio::test]
async fn conversation_message_dispatch_isolated_and_offline_never_falls_back() {
    let state = memory_state().await;
    let _ = bind(&state, "mac-chat", "mac").await.unwrap();
    let _ = bind(&state, "aozora-chat", "aozora").await.unwrap();
    let (mac_tx, mut mac_rx) = mpsc::channel(4);
    let (ao_tx, mut ao_rx) = mpsc::channel(4);
    state
        .agent
        .register_connection(
            "cm".into(),
            "u1".into(),
            "mac".into(),
            "macos".into(),
            mac_tx,
        )
        .await;
    state
        .agent
        .register_connection(
            "ca".into(),
            "u1".into(),
            "aozora".into(),
            "linux".into(),
            ao_tx,
        )
        .await;
    sqlx::query("INSERT INTO agent_preferences (user_id,active_device_id) VALUES ('u1','aozora')")
        .execute(&state.pool)
        .await
        .unwrap();
    queue(&state, "mac-message", "mac-chat").await;
    let task = tokio::spawn(dispatch(state.clone(), "mac-chat", "mac-message"));
    let command = tokio::time::timeout(std::time::Duration::from_secs(2), mac_rx.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(ao_rx.try_recv().is_err());
    reply(&state, command, "mac-reply").await;
    task.await.unwrap();
    queue(&state, "ao-message", "aozora-chat").await;
    let task = tokio::spawn(dispatch(state.clone(), "aozora-chat", "ao-message"));
    reply(&state, ao_rx.recv().await.unwrap(), "ao-reply").await;
    task.await.unwrap();
    assert!(mac_rx.try_recv().is_err());
    state.agent.remove_connection("cm").await;
    queue(&state, "offline-message", "mac-chat").await;
    dispatch(state.clone(), "mac-chat", "offline-message").await;
    assert!(ao_rx.try_recv().is_err());
    let error: Option<String> = sqlx::query_scalar(
        "SELECT last_error FROM agent_delivery_queue WHERE message_id='offline-message'",
    )
    .fetch_one(&state.pool)
    .await
    .unwrap();
    assert!(error.is_some());
    queue(&state, "legacy-message", "legacy").await;
    let task = tokio::spawn(dispatch(state.clone(), "legacy", "legacy-message"));
    reply(&state, ao_rx.recv().await.unwrap(), "legacy-reply").await;
    task.await.unwrap();
}

#[tokio::test]
async fn conversation_binding_cannot_change_but_same_target_is_idempotent() {
    let state = memory_state().await;
    let _ = bind(&state, "mac-chat", "mac").await.unwrap();
    queue(&state, "queued-fixed", "mac-chat").await;
    assert!(matches!(
        bind(&state, "mac-chat", "aozora").await,
        Err(AppError::Conflict(_))
    ));
    let Json(repeated) = bind(&state, "mac-chat", "mac").await.unwrap();
    assert_eq!(repeated.device_id.as_deref(), Some("mac"));
    assert_eq!(
        conversation_agent_device(&state.pool, "u1", "mac-chat")
            .await
            .unwrap()
            .as_deref(),
        Some("mac")
    );
}

#[tokio::test]
async fn conversation_with_legacy_user_messages_cannot_capture_new_target() {
    let state = memory_state().await;
    queue(&state, "queued-legacy", "legacy").await;
    assert!(matches!(
        bind(&state, "legacy", "mac").await,
        Err(AppError::Conflict(_))
    ));
    assert_eq!(
        conversation_agent_device(&state.pool, "u1", "legacy")
            .await
            .unwrap(),
        None
    );
    // Delivered historical user messages also prevent first binding.
    sqlx::query("DELETE FROM agent_delivery_queue WHERE message_id='queued-legacy'")
        .execute(&state.pool)
        .await
        .unwrap();
    assert!(matches!(
        bind(&state, "legacy", "aozora").await,
        Err(AppError::Conflict(_))
    ));
}

#[tokio::test]
async fn mac_request_rejects_aozora_spoofed_reply_and_error() {
    let state = memory_state().await;
    let (mac_tx, mut mac_rx) = mpsc::channel(2);
    let (ao_tx, _ao_rx) = mpsc::channel(2);
    state
        .agent
        .register_connection(
            "cm".into(),
            "u1".into(),
            "mac".into(),
            "macos".into(),
            mac_tx,
        )
        .await;
    state
        .agent
        .register_connection(
            "ca".into(),
            "u1".into(),
            "aozora".into(),
            "linux".into(),
            ao_tx,
        )
        .await;
    let mut receiver = state
        .agent
        .send_request_for_user(
            "u1",
            Some("mac"),
            GatewayMessage::MessageSend {
                version: 1,
                message_id: "mac-pending".into(),
                conversation_id: "mac-chat".into(),
                content: "hello".into(),
                attachments: vec![],
            },
        )
        .await
        .unwrap();
    assert!(mac_rx.recv().await.is_some());
    let response = GatewayMessage::MessageReply {
        version: 1,
        message_id: "mac-response".into(),
        reply_to: "mac-pending".into(),
        conversation_id: "mac-chat".into(),
        content: "from Mac".into(),
        attachments: vec![],
    };
    assert!(
        !state
            .agent
            .resolve_reply_for_device("aozora", response.clone())
            .await
    );
    assert!(matches!(
        receiver.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    assert!(
        !state
            .agent
            .resolve_reply_for_device(
                "aozora",
                GatewayMessage::Error {
                    version: 1,
                    code: "spoofed".into(),
                    message: "interrupt Mac".into(),
                    reply_to: Some("mac-pending".into()),
                }
            )
            .await
    );
    assert!(matches!(
        receiver.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    assert!(state.agent.resolve_reply_for_device("mac", response).await);
    assert!(
        matches!(receiver.await.unwrap(), GatewayMessage::MessageReply { content, .. } if content == "from Mac")
    );
    let receiver = state
        .agent
        .send_request_for_user(
            "u1",
            Some("mac"),
            GatewayMessage::MessageSend {
                version: 1,
                message_id: "mac-error".into(),
                conversation_id: "mac-chat".into(),
                content: "hello".into(),
                attachments: vec![],
            },
        )
        .await
        .unwrap();
    assert!(mac_rx.recv().await.is_some());
    assert!(
        state
            .agent
            .resolve_reply_for_device(
                "mac",
                GatewayMessage::Error {
                    version: 1,
                    code: "legitimate".into(),
                    message: "Mac error".into(),
                    reply_to: Some("mac-error".into()),
                }
            )
            .await
    );
    assert!(
        matches!(receiver.await.unwrap(), GatewayMessage::Error { code, .. } if code == "legitimate")
    );
}
