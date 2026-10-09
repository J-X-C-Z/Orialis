use super::*;
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

// The same loopback HTTP + in-memory SQLite pattern as tasks_tests, with no
// filesystem fixture or production account. Both sessions are synthetic.
struct TestServer {
    address: std::net::SocketAddr,
    pool: SqlitePool,
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
            .route(
                "/api/v1/calendar-events",
                get(list_events).post(create_event),
            )
            .route(
                "/api/v1/calendar-events/{id}",
                patch(update_event).delete(delete_event),
            )
            .route("/api/v1/schedules", get(list_events).post(create_event))
            .route(
                "/api/v1/schedules/{id}",
                patch(update_event).delete(delete_event),
            )
            .with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            address,
            pool,
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

    async fn events(
        &self,
    ) -> Vec<(
        i64,
        String,
        String,
        i64,
        i64,
        Option<String>,
        Option<String>,
    )> {
        sqlx::query_as("SELECT cursor,entity_type,operation,entity_version,tombstone,mutation_id,payload_json FROM sync_events ORDER BY cursor")
            .fetch_all(&self.pool).await.unwrap()
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn event(id: &str, start: &str) -> Value {
    json!({"id":id,"title":" Schedule ","description":"notes","location":"room",
        "startAt":start,"endAt":start,"allDay":true,"important":true,"reminderMinutes":5})
}

#[tokio::test]
async fn calendar_aliases_patch_versions_replay_and_ownership() {
    let s = TestServer::new().await;
    let first = s
        .expect(
            "POST",
            "/api/v1/schedules",
            Some(event("one", "2026-10-09T09:00:00+08:00")),
            Some("create"),
            201,
        )
        .await;
    assert_eq!(first["title"], "Schedule");
    assert_eq!(first["startAt"], "2026-10-09T09:00:00+08:00");
    let duplicate = s
        .expect(
            "POST",
            "/api/v1/calendar-events",
            Some(event("one", "2026-10-09T10:00:00Z")),
            None,
            200,
        )
        .await;
    assert_eq!(first, duplicate);
    assert_eq!(s.events().await.len(), 1);
    s.expect(
        "POST",
        "/api/v1/schedules",
        Some(event("two", "2026-10-09T09:00:00Z")),
        Some("create"),
        409,
    )
    .await;
    assert_eq!(
        s.request(
            "other",
            "POST",
            "/api/v1/schedules",
            Some(event("one", "2026-10-09T09:00:00Z")),
            None
        )
        .await
        .0,
        409
    );
    assert_eq!(
        s.request(
            "other",
            "PATCH",
            "/api/v1/calendar-events/one",
            Some(json!({"baseVersion":1,"title":"stolen"})),
            None
        )
        .await
        .0,
        404
    );
    for patch in [
        json!({"baseVersion":1,"title":null}),
        json!({"baseVersion":1,"startAt":null}),
        json!({"baseVersion":1,"allDay":null}),
        json!({"baseVersion":1,"reminderMinutes":-1}),
    ] {
        s.expect("PATCH", "/api/v1/schedules/one", Some(patch), None, 400)
            .await;
    }
    let updated=s.expect("PATCH","/api/v1/calendar-events/one",Some(json!({"baseVersion":1,"description":null,"location":null,"reminderMinutes":null,"important":false})),Some("patch"),200).await;
    assert_eq!(updated["version"], 2);
    assert_eq!(updated["title"], "Schedule");
    assert_eq!(updated["startAt"], first["startAt"]);
    assert_eq!(updated["allDay"], true);
    for field in ["description", "location", "reminderMinutes"] {
        assert!(updated[field].is_null());
    }
    assert_eq!(updated["important"], false);
    s.expect(
        "PATCH",
        "/api/v1/schedules/one",
        Some(json!({"baseVersion":1,"title":"stale"})),
        None,
        409,
    )
    .await;
    s.expect(
        "DELETE",
        "/api/v1/schedules/one",
        Some(json!({"baseVersion":1})),
        None,
        409,
    )
    .await;
    assert_eq!(
        s.request(
            "other",
            "DELETE",
            "/api/v1/schedules/one",
            Some(json!({"baseVersion":2})),
            None
        )
        .await
        .0,
        404
    );
    assert_eq!(s.events().await.len(), 2);
    let hidden = s
        .request("other", "GET", "/api/v1/schedules", None, None)
        .await;
    assert_eq!(hidden.0, 200);
    assert_eq!(hidden.1["items"], json!([]));
}

#[tokio::test]
async fn calendar_keyset_range_and_cursor_validation() {
    let s = TestServer::new().await;
    for (id, start) in [
        ("b", "2026-10-09T09:00:00Z"),
        ("a", "2026-10-09T09:00:00Z"),
        ("c", "2026-10-09T10:00:00Z"),
    ] {
        s.expect(
            "POST",
            "/api/v1/calendar-events",
            Some(event(id, start)),
            None,
            201,
        )
        .await;
    }
    let first = s
        .expect(
            "GET",
            "/api/v1/schedules?limit=1&from=2026-10-09T09:00:00Z&to=2026-10-09T10:00:00Z",
            None,
            None,
            200,
        )
        .await;
    assert_eq!(first["items"][0]["id"], "a");
    assert_eq!(first["hasMore"], true);
    let after = first["nextCursor"].as_str().unwrap();
    let next=s.expect("GET",&format!("/api/v1/calendar-events?limit=1&after={after}&from=2026-10-09T09:00:00Z&to=2026-10-09T10:00:00Z"),None,None,200).await;
    assert_eq!(next["items"][0]["id"], "b");
    assert_eq!(next["hasMore"], false);
    assert!(next["nextCursor"].is_null());
    for query in [
        "limit=0",
        "limit=101",
        "after=!!!",
        "from=bad",
        "to=bad",
        "from=2026-10-10T00:00:00Z&to=2026-10-09T00:00:00Z",
    ] {
        s.expect(
            "GET",
            &format!("/api/v1/schedules?{query}"),
            None,
            None,
            400,
        )
        .await;
    }
    for value in [
        json!({"v":2,"start_at":"x","id":"a"}),
        json!({"v":1,"start_at":"","id":"a"}),
        json!({"v":1,"start_at":"x","id":""}),
    ] {
        let after = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap());
        s.expect(
            "GET",
            &format!("/api/v1/schedules?after={after}"),
            None,
            None,
            400,
        )
        .await;
    }
    // Preserve offset-aware validation and the existing SQLite lexical range constraint.
    // A chronologically valid mixed-offset range currently reaches SQLite and fails (500).
    let mut valid = event("offset", "2026-10-09T09:00:00+08:00");
    valid["endAt"] = json!("2026-10-09T02:00:00Z");
    s.expect("POST", "/api/v1/schedules", Some(valid), None, 500)
        .await;
    let mut invalid = event("bad", "2026-10-09T09:00:00Z");
    invalid["endAt"] = json!("2026-10-09T09:30:00+08:00");
    s.expect("POST", "/api/v1/schedules", Some(invalid), None, 400)
        .await;
}

#[tokio::test]
async fn calendar_delete_cascade_order_and_late_failure_rollback() {
    let s = TestServer::new().await;
    s.expect(
        "POST",
        "/api/v1/schedules",
        Some(event("parent", "2026-10-09T09:00:00Z")),
        None,
        201,
    )
    .await;
    sqlx::query("INSERT INTO tasks (id,user_id,title,schedule_id) VALUES ('child','owner','Child','parent')").execute(&s.pool).await.unwrap();
    // Fail only after both the parent tombstone and child row mutation exist.
    sqlx::query("CREATE TRIGGER fail_late_calendar_delete BEFORE INSERT ON sync_events WHEN NEW.entity_id='child' AND NEW.operation='delete' AND EXISTS(SELECT 1 FROM calendar_events WHERE id='parent' AND deleted_at IS NOT NULL) AND EXISTS(SELECT 1 FROM tasks WHERE id='child' AND deleted_at IS NOT NULL) AND EXISTS(SELECT 1 FROM sync_events WHERE entity_id='parent' AND operation='delete') BEGIN SELECT RAISE(ABORT,'late calendar delete fault'); END").execute(&s.pool).await.unwrap();
    s.expect(
        "DELETE",
        "/api/v1/calendar-events/parent",
        Some(json!({"baseVersion":1})),
        Some("delete"),
        500,
    )
    .await;
    for table in ["calendar_events", "tasks"] {
        let (version, deleted): (i64, Option<String>) =
            sqlx::query_as(&format!("SELECT version,deleted_at FROM {table} LIMIT 1"))
                .fetch_one(&s.pool)
                .await
                .unwrap();
        assert_eq!(version, 1);
        assert!(deleted.is_none());
    }
    assert_eq!(s.events().await.len(), 1);
    sqlx::query("DROP TRIGGER fail_late_calendar_delete")
        .execute(&s.pool)
        .await
        .unwrap();
    s.expect(
        "DELETE",
        "/api/v1/schedules/parent",
        Some(json!({"baseVersion":1})),
        Some("delete"),
        204,
    )
    .await;
    let rows:Vec<(String,String,i64,i64)>=sqlx::query_as("SELECT entity_type,entity_id,entity_version,tombstone FROM sync_events WHERE operation='delete' ORDER BY cursor").fetch_all(&s.pool).await.unwrap();
    assert_eq!(
        rows,
        vec![
            ("calendar_event".into(), "parent".into(), 2, 1),
            ("task".into(), "child".into(), 2, 1)
        ]
    );
    let parent: (String, String, i64) = sqlx::query_as(
        "SELECT deleted_at,updated_at,version FROM calendar_events WHERE id='parent'",
    )
    .fetch_one(&s.pool)
    .await
    .unwrap();
    let child: (String, String, i64) =
        sqlx::query_as("SELECT deleted_at,updated_at,version FROM tasks WHERE id='child'")
            .fetch_one(&s.pool)
            .await
            .unwrap();
    assert_eq!(parent, child);
    assert_eq!(parent.0, parent.1);
    assert_eq!(parent.2, 2);
    s.expect(
        "POST",
        "/api/v1/schedules",
        Some(event("parent", "2026-10-09T09:00:00Z")),
        None,
        409,
    )
    .await;
    s.expect(
        "DELETE",
        "/api/v1/schedules/parent",
        Some(json!({"baseVersion":2})),
        None,
        404,
    )
    .await;
    let list = s.expect("GET", "/api/v1/schedules", None, None, 200).await;
    assert_eq!(list["items"], json!([]));
}
