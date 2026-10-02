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
    let AgentCommand::Send(GatewayMessage::MessageSend {
        message_id,
        conversation_id,
        ..
    }) = command
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
