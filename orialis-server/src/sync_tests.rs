use super::*;
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

// Disposable WAL SQLite and loopback HTTP; all users and sessions are synthetic.
struct TestServer {
    address: std::net::SocketAddr,
    pool: SqlitePool,
    database: PathBuf,
    task: tokio::task::JoinHandle<()>,
}

impl TestServer {
    async fn new() -> Self {
        let database = env::temp_dir().join(format!("orialis-sync-test-{}.db", new_id()));
        let options = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(&database)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .busy_timeout(std::time::Duration::from_secs(5));
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .connect_with(options)
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        for user in ["owner", "other"] {
            sqlx::query("INSERT INTO users (id,username,password_hash) VALUES (?,?, 'test')")
                .bind(user)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query(
                "INSERT INTO user_sessions (id,user_id,token_hash,expires_at) VALUES (?,?,?,?)",
            )
            .bind(user)
            .bind(user)
            .bind(hash_token(user))
            .bind((Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .execute(&pool)
            .await
            .unwrap();
        }
        let state = Arc::new(AppState {
            metadata: metadata(VERSION, "test", "http://localhost"),
            pool: pool.clone(),
            agent: AgentRegistry::default(),
            mobile: mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".into(),
            upload_dir: env::temp_dir(),
        });
        let app = Router::new()
            .route("/api/v1/sync/events", get(sync_events))
            .route("/api/v1/sync/snapshot", get(sync_snapshot))
            .with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            address,
            pool,
            database,
            task,
        }
    }

    async fn request(
        &self,
        user: &str,
        method: &str,
        path: &str,
        body: Option<Value>,
        key: Option<&str>,
    ) -> (u16, Value) {
        let body = body.map(|value| value.to_string()).unwrap_or_default();
        let mut request = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: Session {user}\r\n");
        if !body.is_empty() {
            request.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            ));
        }
        if let Some(key) = key {
            request.push_str(&format!("Idempotency-Key: {key}\r\n"));
        }
        request.push_str("\r\n");
        request.push_str(&body);
        let mut stream = TcpStream::connect(self.address).await.unwrap();
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
        let body = &response[split + 4..];
        let value = if body.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(body)
                .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(body).into()))
        };
        (status, value)
    }

    async fn expect(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        key: Option<&str>,
        status: u16,
    ) -> Value {
        let (actual, value) = self.request("owner", method, path, body, key).await;
        assert_eq!(actual, status, "{method} {path}: {value}");
        value
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
        let pool = self.pool.clone();
        let database = self.database.clone();
        tokio::spawn(async move {
            pool.close().await;
            let _ = tokio::fs::remove_file(database).await;
        });
    }
}

async fn seed_collection(pool: &SqlitePool, user: &str, suffix: &str, deleted: bool) {
    let id = format!("{user}-{suffix}");
    let deleted_at = deleted.then_some("2026-01-01T00:00:00Z");
    sqlx::query("INSERT INTO tasks(id,user_id,title,deleted_at) VALUES (?,?,?,?)")
        .bind(&id)
        .bind(user)
        .bind(&id)
        .bind(deleted_at)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO projects(id,user_id,name,deleted_at) VALUES (?,?,?,?)")
        .bind(&id)
        .bind(user)
        .bind(&id)
        .bind(deleted_at)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO calendar_events(id,user_id,title,start_at,end_at,deleted_at) VALUES (?,?,?,'2026-01-01T10:00:00Z','2026-01-01T11:00:00Z',?)")
        .bind(&id).bind(user).bind(&id).bind(deleted_at).execute(pool).await.unwrap();
    sqlx::query("INSERT INTO project_milestones(id,project_id,title,deleted_at) VALUES (?,?,?,?)")
        .bind(&id)
        .bind(&id)
        .bind(&id)
        .bind(deleted_at)
        .execute(pool)
        .await
        .unwrap();
}

fn event<'a>(
    user: &'a str,
    id: &'a str,
    operation: &'a str,
    version: i64,
    key: Option<&str>,
) -> AppendEvent<'a> {
    AppendEvent {
        user_id: user,
        entity_type: "task",
        entity_id: id,
        operation,
        entity_version: version,
        payload_json: Some(json!({"id": id, "version": version}).to_string()),
        mutation_id: key.map(str::to_owned),
    }
}

#[tokio::test]
async fn mutation_keys_and_append_events_keep_user_scope_tombstones_and_rollback() {
    let server = TestServer::new().await;
    let mut headers = HeaderMap::new();
    assert!(mutation_id(&headers).is_none());
    headers.insert("idempotency-key", "   ".parse().unwrap());
    assert!(mutation_id(&headers).is_none());
    headers.insert(
        "idempotency-key",
        axum::http::HeaderValue::from_bytes(&[0xff]).unwrap(),
    );
    assert!(mutation_id(&headers).is_none());
    headers.insert("idempotency-key", "  replay-key  ".parse().unwrap());
    assert_eq!(mutation_id(&headers).as_deref(), Some("replay-key"));
    reject_replayed_mutation(&server.pool, "owner", &headers)
        .await
        .unwrap();
    let mut tx = server.pool.begin().await.unwrap();
    append_event(
        &mut *tx,
        event("owner", "rolled-back", "upsert", 1, Some("replay-key")),
    )
    .await
    .unwrap();
    tx.rollback().await.unwrap();
    reject_replayed_mutation(&server.pool, "owner", &headers)
        .await
        .unwrap();
    append_event(
        &server.pool,
        event("owner", "kept", "upsert", 1, Some("replay-key")),
    )
    .await
    .unwrap();
    assert!(matches!(
        reject_replayed_mutation(&server.pool, "owner", &headers).await,
        Err(AppError::Conflict(_))
    ));
    reject_replayed_mutation(&server.pool, "other", &headers)
        .await
        .unwrap();
    append_event(
        &server.pool,
        event("other", "other", "upsert", 1, Some("replay-key")),
    )
    .await
    .unwrap();
    append_event(&server.pool, event("owner", "kept", "delete", 2, None))
        .await
        .unwrap();
    let rows: Vec<(String, i64, i64, Option<String>, String, String)> = sqlx::query_as("SELECT user_id,cursor,tombstone,deleted_at,created_at,updated_at FROM sync_events ORDER BY user_id,cursor")
        .fetch_all(&server.pool).await.unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!((&rows[0].0, rows[0].1), (&"other".to_owned(), 1));
    assert_eq!(
        (&rows[1].0, rows[1].1, rows[1].2),
        (&"owner".to_owned(), 1, 0)
    );
    assert!(rows[1].3.is_none());
    assert_eq!((rows[2].1, rows[2].2), (2, 1));
    assert_eq!(rows[2].3.as_ref(), Some(&rows[2].4));
    assert_eq!(rows[2].4, rows[2].5);
    let response = server
        .expect("GET", "/api/v1/sync/events", None, None, 200)
        .await;
    assert_eq!(response["events"][0]["mutationId"], "replay-key");
    assert_eq!(response["events"][1]["tombstone"], true);
    assert_eq!(response["events"][1]["entityVersion"], 2);
    assert_eq!(response["nextCursor"], 2);
    assert_eq!(
        response["events"][1]["payloadJson"],
        json!({"id":"kept","version":2}).to_string()
    );
}

#[tokio::test]
async fn sync_http_preserves_cursor_pagination_clamping_and_account_isolation() {
    let server = TestServer::new().await;
    let mut tx = server.pool.begin().await.unwrap();
    for index in 1..=502 {
        append_event(
            &mut *tx,
            event("owner", &format!("task-{index}"), "upsert", index, None),
        )
        .await
        .unwrap();
    }
    append_event(&mut *tx, event("other", "private", "upsert", 1, None))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let page = server
        .expect("GET", "/api/v1/sync/events", None, None, 200)
        .await;
    assert_eq!(page["events"].as_array().unwrap().len(), 100);
    assert_eq!(page["nextCursor"], 100);
    let max = server
        .expect("GET", "/api/v1/sync/events?limit=9999", None, None, 200)
        .await;
    assert_eq!(max["events"].as_array().unwrap().len(), 500);
    for (index, row) in max["events"].as_array().unwrap().iter().enumerate() {
        assert_eq!(row["cursor"], index + 1);
        assert_eq!(row["entityId"], format!("task-{}", index + 1));
    }
    for limit in ["0", "-10", "1"] {
        let page = server
            .expect(
                "GET",
                &format!("/api/v1/sync/events?after=500&limit={limit}"),
                None,
                None,
                200,
            )
            .await;
        assert_eq!(page["events"].as_array().unwrap().len(), 1);
        assert_eq!(page["nextCursor"], 501);
    }
    let end = server
        .expect("GET", "/api/v1/sync/events?after=500", None, None, 200)
        .await;
    assert_eq!(end["events"].as_array().unwrap().len(), 2);
    assert_eq!(end["nextCursor"], 502);
    let future = server
        .expect("GET", "/api/v1/sync/events?after=999", None, None, 200)
        .await;
    assert_eq!(future, json!({"events":[],"nextCursor":999}));
    let other = server
        .request("other", "GET", "/api/v1/sync/events", None, None)
        .await;
    assert_eq!(other.0, 200);
    assert_eq!(other.1["events"].as_array().unwrap().len(), 1);
    assert_eq!(other.1["events"][0]["entityId"], "private");
    assert_eq!(
        server
            .request("invalid", "GET", "/api/v1/sync/events", None, None)
            .await
            .0,
        401
    );
    assert_eq!(
        server
            .request("invalid", "GET", "/api/v1/sync/snapshot", None, None)
            .await
            .0,
        401
    );
}

#[tokio::test]
async fn snapshot_filters_deleted_rows_and_parent_milestones_without_cross_account_leaks() {
    let server = TestServer::new().await;
    let empty = server
        .expect("GET", "/api/v1/sync/snapshot", None, None, 200)
        .await;
    assert_eq!(
        empty,
        json!({"cursor":0,"tasks":[],"projects":[],"calendarEvents":[],"milestones":[]})
    );
    seed_collection(&server.pool, "owner", "active", false).await;
    seed_collection(&server.pool, "owner", "deleted", true).await;
    seed_collection(&server.pool, "other", "active", false).await;
    // An active milestone with a deleted parent must also stay out of a snapshot.
    sqlx::query("UPDATE project_milestones SET deleted_at=NULL WHERE id='owner-deleted'")
        .execute(&server.pool)
        .await
        .unwrap();
    append_event(
        &server.pool,
        event("owner", "owner-active", "upsert", 1, None),
    )
    .await
    .unwrap();
    append_event(
        &server.pool,
        event("owner", "owner-deleted", "delete", 2, None),
    )
    .await
    .unwrap();
    let snapshot = server
        .expect("GET", "/api/v1/sync/snapshot", None, None, 200)
        .await;
    assert_eq!(snapshot["cursor"], 2);
    for collection in ["tasks", "projects", "calendarEvents", "milestones"] {
        assert_eq!(
            snapshot[collection].as_array().unwrap().len(),
            1,
            "{collection}"
        );
        assert_eq!(snapshot[collection][0]["id"], "owner-active");
        assert_eq!(snapshot[collection][0]["version"], 1);
    }
    assert_eq!(snapshot["milestones"][0]["projectId"], "owner-active");
    assert_eq!(snapshot["milestones"][0]["userId"], "owner");
    let other = server
        .request("other", "GET", "/api/v1/sync/snapshot", None, None)
        .await;
    assert_eq!(other.0, 200);
    assert_eq!(other.1["cursor"], 0);
    for collection in ["tasks", "projects", "calendarEvents", "milestones"] {
        assert_eq!(other.1[collection][0]["id"], "other-active");
    }
}

#[tokio::test]
async fn snapshot_reads_collections_and_cursor_from_one_transaction_during_commits() {
    let server = TestServer::new().await;
    seed_collection(&server.pool, "owner", "active", false).await;
    append_event(
        &server.pool,
        event("owner", "owner-active", "upsert", 1, None),
    )
    .await
    .unwrap();
    let pool = server.pool.clone();
    let writer = tokio::spawn(async move {
        for version in 2..=30 {
            let mut tx = pool.begin().await.unwrap();
            for table in ["tasks", "projects", "calendar_events", "project_milestones"] {
                sqlx::query(&format!(
                    "UPDATE {table} SET version=? WHERE id='owner-active'"
                ))
                .bind(version)
                .execute(&mut *tx)
                .await
                .unwrap();
                tokio::task::yield_now().await;
            }
            append_event(
                &mut *tx,
                event("owner", "owner-active", "upsert", version, None),
            )
            .await
            .unwrap();
            tx.commit().await.unwrap();
            tokio::task::yield_now().await;
        }
    });
    for _ in 0..50 {
        let snapshot = server
            .expect("GET", "/api/v1/sync/snapshot", None, None, 200)
            .await;
        for collection in ["tasks", "projects", "calendarEvents", "milestones"] {
            assert_eq!(
                snapshot[collection][0]["version"], snapshot["cursor"],
                "{collection}: {snapshot}"
            );
        }
    }
    writer.await.unwrap();
    let snapshot = server
        .expect("GET", "/api/v1/sync/snapshot", None, None, 200)
        .await;
    assert_eq!(snapshot["cursor"], 30);
}
