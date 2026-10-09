use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

struct TestServer {
    address: std::net::SocketAddr,
    pool: SqlitePool,
    upload_dir: PathBuf,
    task: tokio::task::JoinHandle<()>,
}

impl TestServer {
    async fn new() -> Self {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let upload_dir = env::temp_dir().join(format!("orialis-attachments-{}", new_id()));
        let state = Arc::new(AppState {
            metadata: metadata(VERSION, "test", "http://localhost"),
            pool: pool.clone(),
            agent: AgentRegistry::default(),
            mobile: mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".into(),
            upload_dir: upload_dir.clone(),
        });
        let app = Router::new()
            .merge(auth_router())
            .route(
                "/api/v1/conversations/{conversation_id}/attachments",
                post(upload_attachments),
            )
            .route(
                "/api/v1/attachments/{id}/download",
                get(download_attachment),
            )
            .route(
                "/api/v1/conversations/{conversation_id}/messages",
                post(create_message),
            )
            .layer(DefaultBodyLimit::max(MAX_ATTACHMENT_REQUEST_BYTES))
            .with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            address,
            pool,
            upload_dir,
            task,
        }
    }

    async fn request(
        &self,
        method: &str,
        path: &str,
        body: &[u8],
        headers: &[(&str, &str)],
    ) -> (u16, Vec<u8>) {
        let mut stream = TcpStream::connect(self.address).await.unwrap();
        let mut request = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {}\r\n", body.len());
        for (name, value) in headers {
            request.push_str(&format!("{name}: {value}\r\n"));
        }
        request.push_str("\r\n");
        stream.write_all(request.as_bytes()).await.unwrap();
        stream.write_all(body).await.unwrap();
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

    async fn register(&self, username: &str) -> (String, String) {
        let body = format!(r#"{{"username":"{username}","password":"Password-123"}}"#);
        let (status, bytes) = self
            .request(
                "POST",
                "/api/v1/auth/register",
                body.as_bytes(),
                &[("Content-Type", "application/json")],
            )
            .await;
        assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        (
            value["userId"].as_str().unwrap().into(),
            value["accessToken"].as_str().unwrap().into(),
        )
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
        let dir = self.upload_dir.clone();
        tokio::spawn(async move {
            let _ = tokio::fs::remove_dir_all(dir).await;
        });
    }
}

fn multipart(boundary: &str, fields: &[(&str, &[u8])]) -> Vec<u8> {
    let mut body = Vec::new();
    for (filename, bytes) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{filename}\"\r\nContent-Type: text/plain\r\n\r\n").as_bytes());
        body.extend_from_slice(bytes);
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    body
}

async fn stored_file_count(path: &PathBuf) -> usize {
    let mut entries = tokio::fs::read_dir(path).await.unwrap();
    let mut count = 0;
    while entries.next_entry().await.unwrap().is_some() {
        count += 1;
    }
    count
}

async fn create_test_conversation(server: &TestServer, user_id: &str, id: &str) {
    let timestamp = now();
    sqlx::query(
        "INSERT INTO conversations (id,user_id,title,created_at,updated_at) VALUES (?,?,?,?,?)",
    )
    .bind(id)
    .bind(user_id)
    .bind("Attachment test")
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&server.pool)
    .await
    .unwrap();
}

async fn database_attachment_counts(server: &TestServer) -> (i64, i64) {
    let attachments = sqlx::query_scalar("SELECT COUNT(*) FROM attachments")
        .fetch_one(&server.pool)
        .await
        .unwrap();
    let uploads = sqlx::query_scalar("SELECT COUNT(*) FROM attachment_uploads")
        .fetch_one(&server.pool)
        .await
        .unwrap();
    (attachments, uploads)
}

async fn message_count(server: &TestServer, user_id: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE user_id=?")
        .bind(user_id)
        .fetch_one(&server.pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn multipart_upload_persists_file_and_idempotent_replay_creates_no_resources() {
    let server = TestServer::new().await;
    let (user, token) = server.register("attachment_owner").await;
    let body = multipart("feature-boundary", &[(r"C:\\fake\\note.txt", b"hello")]);
    let authorization = format!("Session {token}");
    let headers = [
        (
            "Content-Type",
            "multipart/form-data; boundary=feature-boundary",
        ),
        ("Authorization", authorization.as_str()),
        ("Idempotency-Key", "upload-once"),
    ];
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &body,
            &headers,
        )
        .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    let attachment = &response["items"][0];
    let id = attachment["id"].as_str().unwrap();
    assert_eq!(attachment["name"], "note.txt");
    let path: String = sqlx::query_scalar("SELECT storage_path FROM attachments WHERE id=?")
        .bind(id)
        .fetch_one(&server.pool)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&path).await.unwrap(), b"hello");
    let before: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM attachments WHERE user_id=?")
        .bind(&user)
        .fetch_one(&server.pool)
        .await
        .unwrap();
    let (replay_status, replay) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &[],
            &headers,
        )
        .await;
    assert_eq!(replay_status, 200);
    assert_eq!(serde_json::from_slice::<Value>(&replay).unwrap(), response);
    let after: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM attachments WHERE user_id=?")
        .bind(&user)
        .fetch_one(&server.pool)
        .await
        .unwrap();
    assert_eq!(before, after);
    assert_eq!(stored_file_count(&server.upload_dir).await, 1);
}

#[tokio::test]
async fn message_attachment_http_enforces_user_and_conversation_ownership() {
    let server = TestServer::new().await;
    let (owner, owner_token) = server.register("attachment_message_owner").await;
    let (stranger, stranger_token) = server.register("attachment_message_stranger").await;
    create_test_conversation(&server, &owner, "owner_other").await;
    create_test_conversation(&server, &stranger, "stranger_other").await;

    let upload_body = multipart("message-attachment", &[("canonical.txt", b"hello")]);
    let owner_auth = format!("Session {owner_token}");
    let stranger_auth = format!("Session {stranger_token}");
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &upload_body,
            &[
                (
                    "Content-Type",
                    "multipart/form-data; boundary=message-attachment",
                ),
                ("Authorization", &owner_auth),
                ("Idempotency-Key", "shared-upload-key"),
            ],
        )
        .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
    let upload: Value = serde_json::from_slice(&bytes).unwrap();
    let uploaded = &upload["items"][0];
    let attachment_id = uploaded["id"].as_str().unwrap();
    let initial_counts = database_attachment_counts(&server).await;

    let same_conversation_body = serde_json::json!({
        "content": "Use the uploaded file",
        "attachments": [{"id": attachment_id}]
    });
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/messages",
            &serde_json::to_vec(&same_conversation_body).unwrap(),
            &[
                ("Content-Type", "application/json"),
                ("Authorization", &owner_auth),
            ],
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    let message: Value = serde_json::from_slice(&bytes).unwrap();
    let canonical = &message["attachments"][0];
    assert_eq!(canonical["id"], uploaded["id"]);
    assert_eq!(canonical["name"], "canonical.txt");
    assert_eq!(canonical["mimeType"], "text/plain");
    assert_eq!(canonical["size"], 5);
    assert_eq!(canonical["downloadUrl"], uploaded["downloadUrl"]);
    let expected_message_count = message_count(&server, &owner).await;

    for (conversation, auth, user) in [
        ("owner_other", owner_auth.as_str(), owner.as_str()),
        ("default", stranger_auth.as_str(), stranger.as_str()),
    ] {
        let before = message_count(&server, user).await;
        let (status, bytes) = server
            .request(
                "POST",
                &format!("/api/v1/conversations/{conversation}/messages"),
                &serde_json::to_vec(&same_conversation_body).unwrap(),
                &[
                    ("Content-Type", "application/json"),
                    ("Authorization", auth),
                ],
            )
            .await;
        assert_eq!(status, 400, "{}", String::from_utf8_lossy(&bytes));
        let error: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(error["error"]["code"], "bad_request");
        assert_eq!(message_count(&server, user).await, before);
    }
    assert_eq!(message_count(&server, &owner).await, expected_message_count);

    // Idempotency keys are scoped to both owner and conversation: another
    // conversation or account must create its own resource, never replay this one.
    for (conversation, auth, user, boundary) in [
        (
            "owner_other",
            owner_auth.as_str(),
            owner.as_str(),
            "same-user-other-conversation",
        ),
        (
            "default",
            stranger_auth.as_str(),
            stranger.as_str(),
            "other-user",
        ),
    ] {
        let body = multipart(boundary, &[("separate.txt", b"other")]);
        let content_type = format!("multipart/form-data; boundary={boundary}");
        let (status, bytes) = server
            .request(
                "POST",
                &format!("/api/v1/conversations/{conversation}/attachments"),
                &body,
                &[
                    ("Content-Type", content_type.as_str()),
                    ("Authorization", auth),
                    ("Idempotency-Key", "shared-upload-key"),
                ],
            )
            .await;
        assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
        let created: Value = serde_json::from_slice(&bytes).unwrap();
        let created_id = created["items"][0]["id"].as_str().unwrap();
        assert_ne!(created_id, attachment_id);
        let row: (String, String) =
            sqlx::query_as("SELECT user_id,conversation_id FROM attachments WHERE id=?")
                .bind(created_id)
                .fetch_one(&server.pool)
                .await
                .unwrap();
        assert_eq!(row, (user.to_owned(), conversation.to_owned()));
    }
    assert_eq!(
        database_attachment_counts(&server).await,
        (initial_counts.0 + 2, initial_counts.1 + 2)
    );
}

#[tokio::test]
async fn attachment_http_enforces_owner_or_token_and_removes_failed_upload_files() {
    let server = TestServer::new().await;
    let (_, owner_token) = server.register("attachment_owner_two").await;
    let (_, stranger_token) = server.register("attachment_stranger").await;
    let body = multipart("download-boundary", &[("payload.txt", b"payload")]);
    let owner_authorization = format!("Session {owner_token}");
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &body,
            &[
                (
                    "Content-Type",
                    "multipart/form-data; boundary=download-boundary",
                ),
                ("Authorization", owner_authorization.as_str()),
            ],
        )
        .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    let id = response["items"][0]["id"].as_str().unwrap();
    let stranger_authorization = format!("Session {stranger_token}");
    let (status, _) = server
        .request(
            "GET",
            &format!("/api/v1/attachments/{id}/download"),
            &[],
            &[("Authorization", stranger_authorization.as_str())],
        )
        .await;
    assert_eq!(status, 401);
    let download_token = "known-download-token";
    sqlx::query("UPDATE attachments SET access_token_hash=? WHERE id=?")
        .bind(hash_token(download_token))
        .bind(id)
        .execute(&server.pool)
        .await
        .unwrap();
    let (status, bytes) = server
        .request(
            "GET",
            &format!("/api/v1/attachments/{id}/download?token={download_token}"),
            &[],
            &[],
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(bytes, b"payload");
    let access_hash: String =
        sqlx::query_scalar("SELECT access_token_hash FROM attachments WHERE id=?")
            .bind(id)
            .fetch_one(&server.pool)
            .await
            .unwrap();
    let (status, _) = server
        .request(
            "GET",
            &format!("/api/v1/attachments/{id}/download?token=wrong"),
            &[],
            &[],
        )
        .await;
    assert_eq!(status, 401);
    assert_eq!(access_hash.len(), 64);
    let empty = multipart("empty-boundary", &[("empty.txt", b"")]);
    let (status, _) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &empty,
            &[
                (
                    "Content-Type",
                    "multipart/form-data; boundary=empty-boundary",
                ),
                ("Authorization", owner_authorization.as_str()),
            ],
        )
        .await;
    assert_eq!(status, 400);
    assert_eq!(stored_file_count(&server.upload_dir).await, 1);
    assert_eq!(database_attachment_counts(&server).await, (1, 0));

    let escaped = env::temp_dir().join(format!("orialis-escaped-{}", new_id()));
    tokio::fs::write(&escaped, b"outside").await.unwrap();
    sqlx::query("UPDATE attachments SET storage_path=? WHERE id=?")
        .bind(escaped.to_string_lossy().as_ref())
        .bind(id)
        .execute(&server.pool)
        .await
        .unwrap();
    let (status, _) = server
        .request(
            "GET",
            &format!("/api/v1/attachments/{id}/download"),
            &[],
            &[("Authorization", owner_authorization.as_str())],
        )
        .await;
    assert_eq!(status, 404);
    tokio::fs::remove_file(escaped).await.unwrap();

    sqlx::query("CREATE TRIGGER reject_named_attachment BEFORE INSERT ON attachments WHEN NEW.original_name='reject.txt' BEGIN SELECT RAISE(ABORT, 'test later attachment failure'); END")
        .execute(&server.pool).await.unwrap();
    let failed = multipart(
        "transaction-boundary",
        &[("inserted-first.txt", b"first"), ("reject.txt", b"failure")],
    );
    let before_failure = database_attachment_counts(&server).await;
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &failed,
            &[
                (
                    "Content-Type",
                    "multipart/form-data; boundary=transaction-boundary",
                ),
                ("Authorization", owner_authorization.as_str()),
                ("Idempotency-Key", "partial-failure"),
            ],
        )
        .await;
    assert_eq!(status, 500, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(database_attachment_counts(&server).await, before_failure);
    assert_eq!(stored_file_count(&server.upload_dir).await, 1);

    // A deferred foreign key fails at COMMIT, after attachment and upload rows
    // have both been inserted into the transaction. Verify the handler removes
    // the created file and SQLite rolls both rows back on a real commit error.
    sqlx::query("DROP TRIGGER reject_named_attachment")
        .execute(&server.pool)
        .await
        .unwrap();
    sqlx::query("CREATE TABLE attachment_commit_guard (user_id TEXT REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED)")
        .execute(&server.pool)
        .await
        .unwrap();
    sqlx::query("CREATE TRIGGER reject_attachment_upload_at_commit AFTER INSERT ON attachment_uploads BEGIN INSERT INTO attachment_commit_guard(user_id) VALUES ('missing-user'); END")
        .execute(&server.pool)
        .await
        .unwrap();
    sqlx::query("PRAGMA defer_foreign_keys=ON")
        .execute(&server.pool)
        .await
        .unwrap();
    let commit_failure = multipart("commit-boundary", &[("commit-failed.txt", b"commit")]);
    let (status, bytes) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &commit_failure,
            &[
                (
                    "Content-Type",
                    "multipart/form-data; boundary=commit-boundary",
                ),
                ("Authorization", owner_authorization.as_str()),
                ("Idempotency-Key", "commit-failure"),
            ],
        )
        .await;
    assert_eq!(status, 500, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(database_attachment_counts(&server).await, before_failure);
    assert_eq!(stored_file_count(&server.upload_dir).await, 1);
}

#[tokio::test]
async fn multipart_limits_reject_single_file_total_bytes_and_file_count_without_orphans() {
    let server = TestServer::new().await;
    let (_, token) = server.register("attachment_limits").await;
    let authorization = format!("Session {token}");
    let headers = [
        (
            "Content-Type",
            "multipart/form-data; boundary=limit-boundary",
        ),
        ("Authorization", authorization.as_str()),
    ];

    let too_large = vec![b'x'; MAX_ATTACHMENT_BYTES + 1];
    let body = multipart("limit-boundary", &[("large.bin", too_large.as_slice())]);
    let (status, _) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &body,
            &headers,
        )
        .await;
    assert_eq!(status, 400);
    assert_eq!(stored_file_count(&server.upload_dir).await, 0);
    assert_eq!(database_attachment_counts(&server).await, (0, 0));

    let small = vec![b'x'; 1];
    let count_fields = (0..=MAX_ATTACHMENT_COUNT)
        .map(|i| (format!("{i}.txt"), small.as_slice()))
        .collect::<Vec<_>>();
    let count_refs = count_fields
        .iter()
        .map(|(name, bytes)| (name.as_str(), *bytes))
        .collect::<Vec<_>>();
    let body = multipart("limit-boundary", &count_refs);
    let (status, _) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &body,
            &headers,
        )
        .await;
    assert_eq!(status, 400);
    assert_eq!(stored_file_count(&server.upload_dir).await, 0);
    assert_eq!(database_attachment_counts(&server).await, (0, 0));

    let chunk = vec![b'y'; 16 * 1024 * 1024];
    let total_fields = vec![
        ("a.bin", chunk.as_slice()),
        ("b.bin", chunk.as_slice()),
        ("c.bin", chunk.as_slice()),
        ("d.bin", &b"z"[..]),
    ];
    let body = multipart("limit-boundary", &total_fields);
    let (status, _) = server
        .request(
            "POST",
            "/api/v1/conversations/default/attachments",
            &body,
            &headers,
        )
        .await;
    assert_eq!(status, 400);
    assert_eq!(stored_file_count(&server.upload_dir).await, 0);
    assert_eq!(database_attachment_counts(&server).await, (0, 0));
}
