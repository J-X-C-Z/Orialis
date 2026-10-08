use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

async fn pool() -> SqlitePool {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    pool
}

async fn http(
    address: std::net::SocketAddr,
    method: &str,
    path: &str,
    body: &str,
    headers: &[(&str, &str)],
) -> (u16, Vec<u8>) {
    let mut stream = TcpStream::connect(address).await.unwrap();
    let mut request =
        format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
    if !body.is_empty() {
        request.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    request.push_str(body);
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await.unwrap();
    let split = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap();
    let status = std::str::from_utf8(&response[..split])
        .unwrap()
        .lines()
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    (status, response[split + 4..].to_vec())
}

fn json(body: &[u8]) -> Value {
    serde_json::from_slice(body).unwrap()
}

#[tokio::test]
async fn auth_http_contract_sessions_expiry_gate_and_agent_ownership() {
    let pool = pool().await;
    let state = Arc::new(AppState {
        metadata: metadata(VERSION, "test", "http://localhost"),
        pool: pool.clone(),
        agent: AgentRegistry::default(),
        mobile: mobile_realtime::MobileRegistry::default(),
        agent_device_token: Some("test-agent-token".into()),
        agent_user_id: None,
        public_url: "http://localhost".into(),
        upload_dir: PathBuf::from("/tmp"),
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, auth_router().with_state(state))
            .await
            .unwrap()
    });

    let (status, body) = http(
        address,
        "POST",
        "/api/v1/auth/register",
        r#"{"username":"auth_user_a","password":"Password-123"}"#,
        &[],
    )
    .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&body));
    let first = json(&body);
    let token_a = first["accessToken"].as_str().unwrap();
    assert!(!first["userId"].as_str().unwrap().is_empty());
    assert!(first["expiresAt"].as_str().is_some());

    let (status, body) = http(
        address,
        "GET",
        "/api/v1/auth/session",
        "",
        &[("Authorization", &format!("Session {token_a}"))],
    )
    .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&body));
    assert_eq!(json(&body)["username"], "auth_user_a");

    let (status, body) = http(
        address,
        "POST",
        "/api/v1/auth/login",
        r#"{"username":"auth_user_a","password":"wrong-password"}"#,
        &[],
    )
    .await;
    assert_eq!(status, 401, "{}", String::from_utf8_lossy(&body));
    assert_eq!(json(&body)["error"]["code"], "unauthorized");

    let (status, body) = http(
        address,
        "POST",
        "/api/v1/auth/login",
        r#"{"username":"auth_user_a","password":"Password-123"}"#,
        &[],
    )
    .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&body));
    let token_a2 = json(&body)["accessToken"].as_str().unwrap().to_owned();
    let (status, _) = http(
        address,
        "GET",
        "/api/v1/auth/session",
        "",
        &[
            ("Authorization", "Session invalid-session"),
            ("Cookie", &format!("orialis_session={token_a}")),
        ],
    )
    .await;
    assert_eq!(
        status, 401,
        "an explicit invalid Session must not fall back to a valid cookie"
    );

    let (status, body) = http(
        address,
        "POST",
        "/api/v1/auth/register",
        r#"{"username":"auth_user_b","password":"Password-456"}"#,
        &[],
    )
    .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&body));
    let second = json(&body);
    let token_b = second["accessToken"].as_str().unwrap();
    assert_ne!(first["userId"], second["userId"]);
    assert_eq!(
        sqlx::query_scalar::<_, String>("SELECT user_id FROM user_sessions WHERE token_hash=?")
            .bind(hash_token(token_a))
            .fetch_one(&pool)
            .await
            .unwrap(),
        first["userId"].as_str().unwrap()
    );
    let mut agent_headers = HeaderMap::new();
    agent_headers.insert("authorization", "Bearer test-agent-token".parse().unwrap());
    assert!(matches!(
        authenticated_user_or_agent(
            &agent_headers,
            &state_for_owner(&pool, None, "test-agent-token").await
        )
        .await,
        Err(AppError::Unauthorized)
    ));
    assert_eq!(
        authenticated_user_or_agent(
            &agent_headers,
            &state_for_owner(
                &pool,
                Some(first["userId"].as_str().unwrap()),
                "test-agent-token"
            )
            .await
        )
        .await
        .unwrap(),
        first["userId"].as_str().unwrap()
    );
    let _ = token_b;

    sqlx::query("UPDATE user_sessions SET expires_at='2000-01-01T00:00:00Z' WHERE token_hash=?")
        .bind(hash_token(&token_a2))
        .execute(&pool)
        .await
        .unwrap();
    let (status, body) = http(
        address,
        "GET",
        "/api/v1/auth/session",
        "",
        &[("Authorization", &format!("Session {token_a2}"))],
    )
    .await;
    assert_eq!(status, 401, "{}", String::from_utf8_lossy(&body));

    let (status, body) = http(
        address,
        "POST",
        "/api/v1/auth/logout",
        "",
        &[("Authorization", &format!("Session {token_a}"))],
    )
    .await;
    assert_eq!(status, 204, "{}", String::from_utf8_lossy(&body));
    let (status, body) = http(
        address,
        "GET",
        "/api/v1/auth/session",
        "",
        &[("Authorization", &format!("Session {token_a}"))],
    )
    .await;
    assert_eq!(status, 401, "{}", String::from_utf8_lossy(&body));
    let (status, _body) = http(
        address,
        "GET",
        "/api/v1/auth/session",
        "",
        &[("X-Orialis-Device-Id", "device-a")],
    )
    .await;
    assert_eq!(
        status, 401,
        "development device auth remains gated off by default"
    );
    server.abort();
}

async fn state_for_owner(pool: &SqlitePool, owner: Option<&str>, token: &str) -> AppState {
    AppState {
        metadata: metadata(VERSION, "test", "http://localhost"),
        pool: pool.clone(),
        agent: AgentRegistry::default(),
        mobile: mobile_realtime::MobileRegistry::default(),
        agent_device_token: Some(token.into()),
        agent_user_id: owner.map(str::to_owned),
        public_url: "http://localhost".into(),
        upload_dir: PathBuf::from("/tmp"),
    }
}
