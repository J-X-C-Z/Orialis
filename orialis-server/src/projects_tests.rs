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
            .route("/api/v1/projects", get(list_projects).post(create_project))
            .route(
                "/api/v1/projects/{id}",
                patch(update_project).delete(delete_project),
            )
            .route("/api/v1/projects/{id}/summary", get(project_summary))
            .route(
                "/api/v1/projects/{project_id}/milestones",
                get(list_milestones).post(create_milestone),
            )
            .route(
                "/api/v1/projects/{project_id}/milestones/{id}",
                get(get_milestone)
                    .patch(update_milestone)
                    .delete(delete_milestone),
            )
            .route("/api/v1/calendar-events", post(create_event))
            .route(
                "/api/v1/calendar-events/{id}",
                axum::routing::delete(delete_event),
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

#[tokio::test]
async fn project_duplicate_id_keeps_its_distinct_event_and_replay_contract() {
    let server = TestServer::new().await;
    let first = server
        .expect(
            "POST",
            "/api/v1/projects",
            Some(json!({"id":"project-1","name":" First "})),
            Some("project-a"),
            201,
        )
        .await;
    assert_eq!(first["name"], "First");
    let repeated = server
        .expect(
            "POST",
            "/api/v1/projects",
            Some(json!({"id":"project-1","name":"Ignored"})),
            Some("project-b"),
            201,
        )
        .await;
    assert_eq!(first, repeated);
    let events = server.events().await;
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].3, 1);
    assert_eq!(events[1].3, 1);
    assert_eq!(events[0].5.as_deref(), Some("project-a"));
    assert_eq!(events[1].5.as_deref(), Some("project-b"));
    assert_eq!(events[0].6, events[1].6);
    let error = server
        .expect(
            "POST",
            "/api/v1/projects",
            Some(json!({"name":"Replay"})),
            Some("project-a"),
            409,
        )
        .await;
    assert_eq!(
        error["error"]["message"],
        "Idempotency-Key was already used"
    );
    assert_eq!(server.events().await, events);
    assert_eq!(
        server
            .request(
                "other",
                "POST",
                "/api/v1/projects",
                Some(json!({"id":"project-1","name":"Foreign"})),
                None
            )
            .await
            .0,
        404
    );
    assert_eq!(
        server
            .request("invalid", "GET", "/api/v1/projects", None, None)
            .await
            .0,
        401
    );
    assert_eq!(server.events().await, events);

    // Calendar deliberately differs: a fresh key with the same ID returns 200
    // and creates no event. This extraction must not unify these contracts.
    let calendar = json!({"id":"calendar-1","title":"Meeting","startAt":"2026-10-09T09:00:00Z","endAt":"2026-10-09T10:00:00Z"});
    let first = server
        .expect(
            "POST",
            "/api/v1/calendar-events",
            Some(calendar.clone()),
            Some("calendar-a"),
            201,
        )
        .await;
    let events = server.events().await;
    assert_eq!(
        server
            .expect(
                "POST",
                "/api/v1/calendar-events",
                Some(calendar),
                Some("calendar-b"),
                200
            )
            .await,
        first
    );
    assert_eq!(server.events().await, events);
    server
        .expect(
            "DELETE",
            "/api/v1/calendar-events/calendar-1",
            None,
            None,
            415,
        )
        .await;
    server
        .expect(
            "DELETE",
            "/api/v1/calendar-events/calendar-1",
            Some(json!({"baseVersion":0})),
            None,
            409,
        )
        .await;
    server
        .expect(
            "DELETE",
            "/api/v1/calendar-events/calendar-1",
            Some(json!({"baseVersion":1})),
            None,
            204,
        )
        .await;
}

#[tokio::test]
async fn project_and_milestone_patches_pagination_and_summary_keep_their_contract() {
    let server = TestServer::new().await;
    for id in ["project-b", "project-a"] {
        server
            .expect(
                "POST",
                "/api/v1/projects",
                Some(json!({"id":id,"name":id,"goal":"Keep","due":"2026-12-01"})),
                None,
                201,
            )
            .await;
    }
    sqlx::query("UPDATE projects SET created_at='2026-10-09T00:00:00Z'")
        .execute(&server.pool)
        .await
        .unwrap();
    let first = server
        .expect("GET", "/api/v1/projects?limit=1", None, None, 200)
        .await;
    assert_eq!(first["items"][0]["id"], "project-a");
    assert_eq!(first["hasMore"], true);
    let next = format!(
        "/api/v1/projects?limit=1&after={}",
        first["nextCursor"].as_str().unwrap()
    );
    let last = server.expect("GET", &next, None, None, 200).await;
    assert_eq!(last["items"][0]["id"], "project-b");
    assert_eq!(last["hasMore"], false);
    assert!(last["nextCursor"].is_null());
    for path in [
        "/api/v1/projects?limit=0",
        "/api/v1/projects?status=unknown",
        "/api/v1/projects?after=invalid",
    ] {
        server.expect("GET", path, None, None, 400).await;
    }
    let project = server
        .expect(
            "PATCH",
            "/api/v1/projects/project-a",
            Some(json!({"baseVersion":1,"due":null})),
            Some("project-patch"),
            200,
        )
        .await;
    assert_eq!(project["goal"], "Keep");
    assert!(project["due"].is_null());
    assert_eq!(project["version"], 2);
    let events = server.events().await;
    for (body, status) in [
        (json!({"baseVersion":1}), 409),
        (json!({"baseVersion":2,"name":null}), 400),
        (json!({"baseVersion":2,"due":"invalid"}), 400),
    ] {
        server
            .expect(
                "PATCH",
                "/api/v1/projects/project-a",
                Some(body),
                None,
                status,
            )
            .await;
    }
    assert_eq!(server.events().await, events);
    let path = "/api/v1/projects/project-a/milestones";
    let a = server
        .expect(
            "POST",
            path,
            Some(json!({"title":" A ","due":"2026-12-01","position":4})),
            None,
            201,
        )
        .await;
    let b = server
        .expect(
            "POST",
            path,
            Some(json!({"title":"B","position":4})),
            None,
            201,
        )
        .await;
    assert_eq!(a["title"], "A");
    assert_eq!(a["userId"], "owner");
    let first = server
        .expect("GET", &format!("{path}?limit=1"), None, None, 200)
        .await;
    let last = server
        .expect(
            "GET",
            &format!(
                "{path}?limit=1&after={}",
                first["nextCursor"].as_str().unwrap()
            ),
            None,
            None,
            200,
        )
        .await;
    let mut ids = [a["id"].as_str().unwrap(), b["id"].as_str().unwrap()];
    ids.sort();
    assert_eq!(first["items"][0]["id"], ids[0]);
    assert_eq!(last["items"][0]["id"], ids[1]);
    assert_eq!(last["hasMore"], false);
    let item = format!("{path}/{}", a["id"].as_str().unwrap());
    let completed = server
        .expect(
            "PATCH",
            &item,
            Some(json!({"baseVersion":1,"due":null,"completed":true})),
            Some("milestone-patch"),
            200,
        )
        .await;
    assert_eq!(completed["title"], "A");
    assert_eq!(completed["position"], 4);
    assert!(completed["due"].is_null());
    assert!(completed["completedAt"].is_string());
    assert_eq!(completed["version"], 2);
    let unchanged = server
        .expect("PATCH", &item, Some(json!({"baseVersion":2})), None, 200)
        .await;
    assert_eq!(unchanged["completedAt"], completed["completedAt"]);
    let events = server.events().await;
    server
        .expect("PATCH", &item, Some(json!({"baseVersion":2})), None, 409)
        .await;
    server
        .expect(
            "PATCH",
            &item,
            Some(json!({"baseVersion":3,"title":null})),
            None,
            400,
        )
        .await;
    server
        .expect(
            "PATCH",
            &item,
            Some(json!({"baseVersion":3,"position":-1})),
            None,
            400,
        )
        .await;
    server
        .expect("GET", &format!("{path}?after=invalid"), None, None, 400)
        .await;
    assert_eq!(
        server.request("other", "GET", &item, None, None).await.0,
        404
    );
    assert_eq!(
        server.request("other", "DELETE", &item, None, None).await.0,
        404
    );
    assert_eq!(server.events().await, events);
    sqlx::query("INSERT INTO tasks (id,user_id,title,project_id,completed,completed_at,due) VALUES ('task-done','owner','Done','project-a',1,'2026-10-09T00:00:00Z',NULL),('task-next','owner','Next','project-a',0,NULL,'2026-10-10')").execute(&server.pool).await.unwrap();
    let summary = server
        .expect("GET", "/api/v1/projects/project-a/summary", None, None, 200)
        .await;
    assert_eq!(summary["totalTasks"], 2);
    assert_eq!(summary["completedTasks"], 1);
    assert_eq!(summary["totalMilestones"], 2);
    assert_eq!(summary["completedMilestones"], 1);
    assert_eq!(summary["progress"], 50.0);
    assert_eq!(summary["nextAction"]["id"], "task-next");
    let reopened = server
        .expect(
            "PATCH",
            &item,
            Some(json!({"baseVersion":3,"completed":false})),
            None,
            200,
        )
        .await;
    assert!(reopened["completedAt"].is_null());
    // Milestone DELETE has no versioned body extractor, unlike Calendar.
    server
        .expect("DELETE", &item, None, Some("milestone-delete"), 204)
        .await;
    server.expect("GET", &item, None, None, 404).await;
    let deleted = server.events().await.pop().unwrap();
    assert_eq!(
        (deleted.1.as_str(), deleted.2.as_str(), deleted.3, deleted.4),
        ("project_milestone", "delete", 5, 1)
    );
    assert_eq!(deleted.5.as_deref(), Some("milestone-delete"));
    assert!(deleted.6.is_none());
}

#[tokio::test]
async fn project_delete_rolls_back_after_child_events_then_preserves_tombstone_order() {
    let server = TestServer::new().await;
    server
        .expect(
            "POST",
            "/api/v1/projects",
            Some(json!({"id":"cascade","name":"Cascade"})),
            None,
            201,
        )
        .await;
    for title in ["A", "B"] {
        server
            .expect(
                "POST",
                "/api/v1/projects/cascade/milestones",
                Some(json!({"title":title})),
                None,
                201,
            )
            .await;
    }
    sqlx::query("INSERT INTO tasks (id,user_id,title,project_id) VALUES ('keep-task','owner','Keep','cascade')").execute(&server.pool).await.unwrap();
    let before_events = server.events().await;
    let before_project: (i64, String, Option<String>) =
        sqlx::query_as("SELECT version,updated_at,deleted_at FROM projects WHERE id='cascade'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    let before_children: Vec<(String, i64, String, Option<String>)> = sqlx::query_as(
        "SELECT id,version,updated_at,deleted_at FROM project_milestones ORDER BY id",
    )
    .fetch_all(&server.pool)
    .await
    .unwrap();
    // Fire only at the parent's event INSERT, after the parent row update
    // and both child events. A pre-write rejection cannot pass. The current
    // child UPDATE has an unbound third parameter and changes no child rows;
    // preserve that baseline behavior in this extraction rather than fixing it.
    sqlx::query("CREATE TRIGGER fail_parent_delete BEFORE INSERT ON sync_events
        WHEN NEW.entity_type='project' AND NEW.operation='delete'
        AND (SELECT COUNT(*) FROM projects WHERE id='cascade' AND deleted_at IS NOT NULL AND version=2)=1
        AND (SELECT COUNT(*) FROM sync_events WHERE entity_type='project_milestone' AND operation='delete')=2
        BEGIN SELECT RAISE(ABORT, 'injected after child writes'); END")
        .execute(&server.pool).await.unwrap();
    let error = server
        .expect(
            "DELETE",
            "/api/v1/projects/cascade",
            None,
            Some("cascade-delete"),
            500,
        )
        .await;
    assert_eq!(error["error"]["code"], "database_error");
    let after_project: (i64, String, Option<String>) =
        sqlx::query_as("SELECT version,updated_at,deleted_at FROM projects WHERE id='cascade'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    let after_children: Vec<(String, i64, String, Option<String>)> = sqlx::query_as(
        "SELECT id,version,updated_at,deleted_at FROM project_milestones ORDER BY id",
    )
    .fetch_all(&server.pool)
    .await
    .unwrap();
    assert_eq!(after_project, before_project);
    assert_eq!(after_children, before_children);
    assert_eq!(server.events().await, before_events);
    sqlx::query("DROP TRIGGER fail_parent_delete")
        .execute(&server.pool)
        .await
        .unwrap();
    // Failed mutation IDs are reusable; Project DELETE also needs no body.
    server
        .expect(
            "DELETE",
            "/api/v1/projects/cascade",
            None,
            Some("cascade-delete"),
            204,
        )
        .await;
    let events = server.events().await;
    let deleted = &events[before_events.len()..];
    assert_eq!(deleted.len(), 3);
    for event in &deleted[..2] {
        assert_eq!(
            (event.1.as_str(), event.2.as_str(), event.3, event.4),
            ("project_milestone", "delete", 2, 1)
        );
        assert!(event.5.is_none());
        assert!(event.6.is_none());
    }
    assert_eq!(
        (
            deleted[2].1.as_str(),
            deleted[2].2.as_str(),
            deleted[2].3,
            deleted[2].4
        ),
        ("project", "delete", 2, 1)
    );
    assert_eq!(deleted[2].5.as_deref(), Some("cascade-delete"));
    assert!(deleted[2].6.is_none());
    let task: (i64, Option<String>) =
        sqlx::query_as("SELECT version,deleted_at FROM tasks WHERE id='keep-task'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    assert_eq!(task, (1, None));
    server
        .expect("GET", "/api/v1/projects/cascade/summary", None, None, 404)
        .await;
    server
        .expect(
            "GET",
            "/api/v1/projects/cascade/milestones",
            None,
            None,
            404,
        )
        .await;
}
