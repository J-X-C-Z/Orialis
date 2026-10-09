use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

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
        let state = Arc::new(AppState {
            metadata: metadata(VERSION, "test", "http://localhost"),
            pool: pool.clone(),
            agent: AgentRegistry::default(),
            mobile: mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".into(),
            upload_dir: env::temp_dir().join(format!("orialis-tasks-{}", new_id())),
        });
        let app = Router::new()
            .merge(auth_router())
            .route("/api/v1/tasks", get(list_tasks).post(create_task))
            .route("/api/v1/tasks/{id}", patch(update_task).delete(delete_task))
            .route("/api/v1/projects", post(create_project))
            .route("/api/v1/schedules", post(create_event))
            .layer(DefaultBodyLimit::max(MAX_ATTACHMENT_REQUEST_BYTES))
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
        method: &str,
        path: &str,
        body: &str,
        headers: &[(&str, &str)],
    ) -> (u16, Vec<u8>) {
        let mut stream = TcpStream::connect(self.address).await.unwrap();
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

    async fn register(&self, username: &str) -> (String, String) {
        let body = format!(r#"{{"username":"{username}","password":"Password-123"}}"#);
        let (status, body) = self
            .request("POST", "/api/v1/auth/register", &body, &[])
            .await;
        assert_eq!(status, 201, "{}", String::from_utf8_lossy(&body));
        let value: Value = serde_json::from_slice(&body).unwrap();
        (
            value["userId"].as_str().unwrap().into(),
            value["accessToken"].as_str().unwrap().into(),
        )
    }

    async fn create_task(
        &self,
        token: &str,
        body: &str,
        idempotency: Option<&str>,
    ) -> (u16, Vec<u8>) {
        let authorization = format!("Session {token}");
        let mut headers = vec![("Authorization", authorization.as_str())];
        if let Some(key) = idempotency {
            headers.push(("Idempotency-Key", key));
        }
        self.request("POST", "/api/v1/tasks", body, &headers).await
    }

    async fn get_task(&self, token: &str, id: &str) -> (u16, Vec<u8>) {
        let authorization = format!("Session {token}");
        let (status, body) = self
            .request(
                "GET",
                "/api/v1/tasks?limit=100",
                "",
                &[("Authorization", &authorization)],
            )
            .await;
        let value: Value = serde_json::from_slice(&body).unwrap();
        let task = value["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["id"] == id)
            .cloned()
            .unwrap_or(Value::Null);
        (status, serde_json::to_vec(&task).unwrap())
    }

    async fn event_count(&self, user_id: &str) -> i64 {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM sync_events WHERE user_id=? AND entity_type='task'",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await
        .unwrap()
    }

    async fn task_state(
        &self,
        id: &str,
    ) -> Option<(
        String,
        String,
        i64,
        i64,
        Option<String>,
        Option<String>,
        Option<String>,
    )> {
        sqlx::query_as(
            "SELECT user_id,title,completed,version,deleted_at,parent_task_id,schedule_id
             FROM tasks WHERE id=?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .unwrap()
    }

    async fn event_state(
        &self,
        user_id: &str,
    ) -> Vec<(i64, String, String, String, i64, i64, Option<String>)> {
        sqlx::query_as(
            "SELECT cursor,entity_type,entity_id,operation,entity_version,tombstone,mutation_id
             FROM sync_events WHERE user_id=? ORDER BY cursor",
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .unwrap()
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn json(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).unwrap()
}

#[tokio::test]
async fn task_http_crud_preserves_patch_tristate_versions_and_mutation_events() {
    let server = TestServer::new().await;
    let (user, token) = server.register("tasks_crud_owner").await;
    let (status, bytes) = server.create_task(&token, r#"{"id":"task-1","title":"  initial  ","notes":"keep","important":true,"urgent":false,"due":"2026-10-10","dueTime":"08:30","recurrence":{"rule":"FREQ=DAILY","until":"2026-10-31"}}"#, Some("create-once")).await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    let created = json(&bytes);
    assert_eq!(created["title"], "initial");
    assert_eq!(created["important"], true);
    assert_eq!(created["recurrence"]["rule"], "FREQ=DAILY");
    assert_eq!(created["version"], 1);
    let events_after_create = server.event_count(&user).await;
    assert_eq!(events_after_create, 1);
    let first_mutation: (String, String, i64, Option<String>) = sqlx::query_as(
        "SELECT user_id,entity_id,cursor,mutation_id FROM sync_events
         WHERE user_id=? AND entity_type='task' AND mutation_id='create-once'",
    )
    .bind(&user)
    .fetch_one(&server.pool)
    .await
    .unwrap();
    assert_eq!(
        first_mutation.0, user,
        "mutation event must belong to the authenticated owner"
    );
    assert_eq!(first_mutation.1, "task-1");
    assert!(
        first_mutation.2 > 0,
        "mutation event must have an assigned sync cursor"
    );
    assert_eq!(first_mutation.3.as_deref(), Some("create-once"));

    let (status, bytes) = server
        .create_task(
            &token,
            r#"{"id":"task-1","title":"ignored"}"#,
            Some("create-once"),
        )
        .await;
    assert_eq!(status, 409, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "conflict");
    assert_eq!(server.event_count(&user).await, events_after_create);

    let events_before_new_id_replay = server.event_state(&user).await;
    let (status, bytes) = server
        .create_task(
            &token,
            r#"{"id":"different-task-id","title":"must not replay"}"#,
            Some("create-once"),
        )
        .await;
    assert_eq!(status, 409, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "conflict");
    let different_id_rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM tasks WHERE user_id=? AND id='different-task-id'")
            .bind(&user)
            .fetch_one(&server.pool)
            .await
            .unwrap();
    assert_eq!(
        different_id_rows, 0,
        "mutation replay with a new task ID must not create a row"
    );
    assert_eq!(server.event_state(&user).await, events_before_new_id_replay);

    let auth = format!("Session {token}");
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/task-1",
            r#"{"baseVersion":1,"notes":null,"important":null,"dueTime":null,"recurrence":null}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
    let updated = json(&bytes);
    assert_eq!(updated["notes"], Value::Null);
    assert_eq!(updated["important"], Value::Null);
    assert_eq!(updated["dueTime"], Value::Null);
    assert_eq!(updated["recurrence"], Value::Null);
    assert_eq!(
        updated["urgent"], false,
        "omitted fields retain their value"
    );
    assert_eq!(updated["version"], 2);

    let before_conflict = server.event_count(&user).await;
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/task-1",
            r#"{"baseVersion":1,"title":"stale"}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 409, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "conflict");
    assert_eq!(server.event_count(&user).await, before_conflict);
    let (_, stored) = server.get_task(&token, "task-1").await;
    assert_eq!(json(&stored)["title"], "initial");

    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/task-1",
            r#"{"baseVersion":2,"title":null}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 400, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "bad_request");
    assert_eq!(server.event_count(&user).await, before_conflict);

    let (status, bytes) = server
        .request(
            "DELETE",
            "/api/v1/tasks/task-1",
            r#"{"baseVersion":1}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 409, "{}", String::from_utf8_lossy(&bytes));
    let (status, bytes) = server
        .request(
            "DELETE",
            "/api/v1/tasks/task-1",
            r#"{"baseVersion":2}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 204, "{}", String::from_utf8_lossy(&bytes));
    let stored_version: (i64, Option<String>) =
        sqlx::query_as("SELECT version,deleted_at FROM tasks WHERE id='task-1'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    assert_eq!(stored_version.0, 3);
    assert!(stored_version.1.is_some());
    let delete_events: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sync_events WHERE user_id=? AND entity_type='task' AND entity_id='task-1' AND operation='delete' AND entity_version=3").bind(&user).fetch_one(&server.pool).await.unwrap();
    assert_eq!(delete_events, 1);
}

#[tokio::test]
async fn task_http_isolates_accounts_and_rejects_cross_owner_project_parent_and_schedule_links() {
    let server = TestServer::new().await;
    let (owner, owner_token) = server.register("tasks_owner_a").await;
    let (other, other_token) = server.register("tasks_owner_b").await;
    let (status, project_bytes) = server
        .request(
            "POST",
            "/api/v1/projects",
            r#"{"id":"foreign-project","name":"Foreign"}"#,
            &[("Authorization", &format!("Session {other_token}"))],
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&project_bytes));
    let (status, schedule_bytes) = server.request("POST", "/api/v1/schedules", r#"{"id":"foreign-schedule","title":"Foreign","startAt":"2026-10-10T09:00:00Z","endAt":"2026-10-10T10:00:00Z"}"#, &[("Authorization", &format!("Session {other_token}"))]).await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&schedule_bytes));
    let (status, parent_bytes) = server
        .create_task(
            &other_token,
            r#"{"id":"foreign-parent","title":"Foreign parent"}"#,
            None,
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&parent_bytes));
    let owner_auth = format!("Session {owner_token}");
    let (status, _) = server.request("POST", "/api/v1/schedules", r#"{"id":"owner-schedule","title":"Owned","startAt":"2026-10-10T09:00:00Z","endAt":"2026-10-10T10:00:00Z"}"#, &[("Authorization", &owner_auth)]).await;
    assert_eq!(status, 201);

    let (status, own_task) = server
        .create_task(
            &owner_token,
            r#"{"id":"private-task","title":"private"}"#,
            None,
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&own_task));
    let (status, visible) = server
        .request(
            "GET",
            "/api/v1/tasks",
            "",
            &[("Authorization", &format!("Session {other_token}"))],
        )
        .await;
    assert_eq!(status, 200);
    assert!(json(&visible)["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|task| task["id"] != "private-task"));
    let other_auth = format!("Session {other_token}");
    let private_before_cross_owner_patch = server.task_state("private-task").await;
    let owner_events_before_cross_owner_patch = server.event_state(&owner).await;
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/private-task",
            r#"{"baseVersion":1,"title":"steal"}"#,
            &[("Authorization", &other_auth)],
        )
        .await;
    assert_eq!(status, 404, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "not_found");
    assert_eq!(
        server.task_state("private-task").await,
        private_before_cross_owner_patch
    );
    assert_eq!(
        server.event_state(&owner).await,
        owner_events_before_cross_owner_patch
    );
    let (status, bytes) = server
        .request(
            "DELETE",
            "/api/v1/tasks/private-task",
            r#"{"baseVersion":1}"#,
            &[("Authorization", &other_auth)],
        )
        .await;
    assert_eq!(status, 404, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "not_found");
    assert_eq!(
        server.task_state("private-task").await,
        private_before_cross_owner_patch
    );
    assert_eq!(
        server.event_state(&owner).await,
        owner_events_before_cross_owner_patch
    );
    let (_, private_after) = server.get_task(&owner_token, "private-task").await;
    assert_eq!(json(&private_after)["title"], "private");

    let (status, scheduled) = server
        .create_task(
            &owner_token,
            r#"{"id":"scheduled-task","title":"scheduled","scheduleId":"owner-schedule"}"#,
            None,
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&scheduled));
    let scheduled_state = server.task_state("scheduled-task").await;
    let owner_events_before_foreign_schedule = server.event_state(&owner).await;
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/scheduled-task",
            r#"{"baseVersion":1,"scheduleId":"foreign-schedule"}"#,
            &[("Authorization", &owner_auth)],
        )
        .await;
    assert_eq!(status, 400, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "bad_request");
    let stored_schedule: String =
        sqlx::query_scalar("SELECT schedule_id FROM tasks WHERE id='scheduled-task'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    assert_eq!(
        stored_schedule, "owner-schedule",
        "failed update must not detach or replace the valid relation"
    );
    assert_eq!(server.task_state("scheduled-task").await, scheduled_state);
    assert_eq!(
        server.event_state(&owner).await,
        owner_events_before_foreign_schedule,
        "foreign-schedule PATCH must not change versions or append events"
    );

    for (id, body) in [
        (
            "cross-project",
            r#"{"id":"cross-project","title":"bad","projectId":"foreign-project"}"#,
        ),
        (
            "cross-parent",
            r#"{"id":"cross-parent","title":"bad","parentTaskId":"foreign-parent"}"#,
        ),
        (
            "cross-schedule",
            r#"{"id":"cross-schedule","title":"bad","scheduleId":"foreign-schedule"}"#,
        ),
        (
            "both-links",
            r#"{"id":"both-links","title":"bad","parentTaskId":"foreign-parent","scheduleId":"foreign-schedule"}"#,
        ),
        (
            "cross-id",
            r#"{"id":"foreign-parent","title":"id collision"}"#,
        ),
    ] {
        let before = server.event_count(&owner).await;
        let owner_events_before = server.event_state(&owner).await;
        let (status, bytes) = server.create_task(&owner_token, body, None).await;
        let value = json(&bytes);
        let (expected_status, expected_code) = match id {
            "cross-project" => (404, "not_found"),
            "cross-parent" | "cross-schedule" | "both-links" => (400, "bad_request"),
            "cross-id" => (409, "conflict"),
            _ => unreachable!(),
        };
        assert_eq!(status, expected_status, "{id}: {value}");
        assert_eq!(value["error"]["code"], expected_code, "{id}: {value}");
        let exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tasks WHERE user_id=? AND id=?")
            .bind(&owner)
            .bind(id)
            .fetch_one(&server.pool)
            .await
            .unwrap();
        assert_eq!(exists, 0, "failed request left a task row: {id}");
        assert_eq!(
            server.event_count(&owner).await,
            before,
            "failed request emitted a task event: {id}"
        );
        assert_eq!(
            server.event_state(&owner).await,
            owner_events_before,
            "{id}: cursor/event state changed"
        );
    }
    let other_owned: String =
        sqlx::query_scalar("SELECT user_id FROM tasks WHERE id='foreign-parent'")
            .fetch_one(&server.pool)
            .await
            .unwrap();
    assert_eq!(other_owned, other);
}

#[tokio::test]
async fn task_parent_completion_and_tombstones_are_transactional_http_effects() {
    let server = TestServer::new().await;
    let (user, token) = server.register("tasks_parent_owner").await;
    let (status, bytes) = server
        .create_task(
            &token,
            r#"{"id":"parent","title":"parent","completed":true}"#,
            None,
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    let parent = json(&bytes);
    assert_eq!(parent["completed"], true);
    let (status, bytes) = server
        .create_task(
            &token,
            r#"{"id":"child-a","title":"child a","parentTaskId":"parent"}"#,
            None,
        )
        .await;
    assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["completed"], false);
    let (_, parent_bytes) = server.get_task(&token, "parent").await;
    assert_eq!(
        json(&parent_bytes)["completed"],
        false,
        "incomplete child reopens parent"
    );
    let auth = format!("Session {token}");
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/child-a",
            r#"{"baseVersion":1,"completed":true}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&bytes));
    let (_, parent_bytes) = server.get_task(&token, "parent").await;
    assert_eq!(
        json(&parent_bytes)["completed"],
        true,
        "all completed children complete parent"
    );
    let (status, bytes) = server
        .request(
            "DELETE",
            "/api/v1/tasks/parent",
            r#"{"baseVersion":3}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 204, "{}", String::from_utf8_lossy(&bytes));
    let rows: Vec<(String, i64, Option<String>)> = sqlx::query_as(
        "SELECT id,version,deleted_at FROM tasks WHERE id IN ('parent','child-a') ORDER BY id",
    )
    .fetch_all(&server.pool)
    .await
    .unwrap();
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|(_, _, deleted_at)| deleted_at.is_some()));
    let tombstones: Vec<(String, i64)> = sqlx::query_as("SELECT entity_id,entity_version FROM sync_events WHERE user_id=? AND entity_type='task' AND operation='delete' ORDER BY cursor").bind(&user).fetch_all(&server.pool).await.unwrap();
    assert_eq!(
        tombstones,
        vec![("parent".into(), 4), ("child-a".into(), 3)]
    );
}

#[tokio::test]
async fn task_create_rolls_back_row_and_event_when_deferred_commit_fails() {
    let server = TestServer::new().await;
    let (user, token) = server.register("tasks_create_commit_failure").await;
    let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(&server.pool)
        .await
        .unwrap();
    assert_eq!(foreign_keys, 1, "deferred-FK commit failure must be active");
    sqlx::query("CREATE TABLE task_test_commit_parent(id INTEGER PRIMARY KEY)")
        .execute(&server.pool)
        .await
        .unwrap();
    sqlx::query("CREATE TABLE task_test_commit_child(parent_id INTEGER, FOREIGN KEY(parent_id) REFERENCES task_test_commit_parent(id) DEFERRABLE INITIALLY DEFERRED)")
        .execute(&server.pool)
        .await
        .unwrap();
    sqlx::query("CREATE TRIGGER task_test_fail_create_commit AFTER INSERT ON tasks WHEN NEW.id='commit-fail-create' BEGIN INSERT INTO task_test_commit_child(parent_id) VALUES(404); END")
        .execute(&server.pool)
        .await
        .unwrap();
    let before_events = server.event_state(&user).await;

    let (status, bytes) = server
        .create_task(
            &token,
            r#"{"id":"commit-fail-create","title":"must roll back"}"#,
            Some("commit-failure-mutation"),
        )
        .await;
    assert_eq!(status, 500, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "database_error");
    assert_eq!(server.task_state("commit-fail-create").await, None);
    assert_eq!(server.event_state(&user).await, before_events);
    let orphan_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM task_test_commit_child")
        .fetch_one(&server.pool)
        .await
        .unwrap();
    assert_eq!(orphan_rows, 0);
}

#[tokio::test]
async fn task_update_rolls_back_parent_reconciliation_and_events_after_child_write() {
    let server = TestServer::new().await;
    let (user, token) = server.register("tasks_update_transaction_failure").await;
    for body in [
        r#"{"id":"parent-reconcile","title":"parent","completed":true}"#,
        r#"{"id":"child-a","title":"child a","completed":true,"parentTaskId":"parent-reconcile"}"#,
        r#"{"id":"child-b","title":"child b","completed":true,"parentTaskId":"parent-reconcile"}"#,
    ] {
        let (status, bytes) = server.create_task(&token, body, None).await;
        assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    }
    let before_parent = server.task_state("parent-reconcile").await;
    let before_child = server.task_state("child-a").await;
    let before_events = server.event_state(&user).await;
    sqlx::query("CREATE TRIGGER task_test_fail_child_update_event BEFORE INSERT ON sync_events WHEN NEW.entity_type='task' AND NEW.entity_id='child-a' AND NEW.operation='upsert' BEGIN SELECT RAISE(ABORT,'forced task update event failure'); END")
        .execute(&server.pool)
        .await
        .unwrap();

    let auth = format!("Session {token}");
    let (status, bytes) = server
        .request(
            "PATCH",
            "/api/v1/tasks/child-a",
            r#"{"baseVersion":1,"completed":false}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 500, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "database_error");
    assert_eq!(server.task_state("parent-reconcile").await, before_parent);
    assert_eq!(server.task_state("child-a").await, before_child);
    assert_eq!(
        server.event_state(&user).await,
        before_events,
        "parent upsert event and cursor must roll back with the child update"
    );
}

#[tokio::test]
async fn task_delete_rolls_back_parent_and_child_tombstones_after_partial_cascade() {
    let server = TestServer::new().await;
    let (user, token) = server.register("tasks_delete_transaction_failure").await;
    for body in [
        r#"{"id":"delete-parent","title":"parent"}"#,
        r#"{"id":"delete-child","title":"child","parentTaskId":"delete-parent"}"#,
    ] {
        let (status, bytes) = server.create_task(&token, body, None).await;
        assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    }
    let before_parent = server.task_state("delete-parent").await;
    let before_child = server.task_state("delete-child").await;
    let before_events = server.event_state(&user).await;
    sqlx::query("CREATE TRIGGER task_test_fail_child_delete_event BEFORE INSERT ON sync_events WHEN NEW.entity_type='task' AND NEW.entity_id='delete-child' AND NEW.operation='delete' BEGIN SELECT RAISE(ABORT,'forced child tombstone failure'); END")
        .execute(&server.pool)
        .await
        .unwrap();

    let auth = format!("Session {token}");
    let (status, bytes) = server
        .request(
            "DELETE",
            "/api/v1/tasks/delete-parent",
            r#"{"baseVersion":1}"#,
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 500, "{}", String::from_utf8_lossy(&bytes));
    assert_eq!(json(&bytes)["error"]["code"], "database_error");
    assert_eq!(server.task_state("delete-parent").await, before_parent);
    assert_eq!(server.task_state("delete-child").await, before_child);
    assert_eq!(
        server.event_state(&user).await,
        before_events,
        "root/child tombstone events and their cursors must roll back"
    );
}

#[tokio::test]
async fn task_pagination_orders_null_due_and_cursor_boundaries_and_rejects_bad_cursors() {
    let server = TestServer::new().await;
    let (_, token) = server.register("tasks_page_owner").await;
    for body in [
        r#"{"id":"due-b","title":"due b","due":"2026-10-11","dueTime":"09:00"}"#,
        r#"{"id":"null-a","title":"null a"}"#,
        r#"{"id":"due-a","title":"due a","due":"2026-10-10","dueTime":"08:00"}"#,
        r#"{"id":"null-b","title":"null b"}"#,
    ] {
        let (status, bytes) = server.create_task(&token, body, None).await;
        assert_eq!(status, 201, "{}", String::from_utf8_lossy(&bytes));
    }
    let auth = format!("Session {token}");
    let (status, first) = server
        .request(
            "GET",
            "/api/v1/tasks?limit=2",
            "",
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 200);
    let first = json(&first);
    assert_eq!(first["hasMore"], true);
    assert_eq!(first["items"].as_array().unwrap().len(), 2);
    let cursor = first["nextCursor"].as_str().unwrap();
    let (status, second) = server
        .request(
            "GET",
            &format!("/api/v1/tasks?limit=2&after={cursor}"),
            "",
            &[("Authorization", &auth)],
        )
        .await;
    assert_eq!(status, 200);
    let second = json(&second);
    assert_eq!(second["hasMore"], false);
    let ids: Vec<&str> = first["items"]
        .as_array()
        .unwrap()
        .iter()
        .chain(second["items"].as_array().unwrap())
        .map(|task| task["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec!["due-a", "due-b", "null-a", "null-b"]);
    for path in [
        "/api/v1/tasks?limit=0",
        "/api/v1/tasks?limit=101",
        "/api/v1/tasks?after=not-a-cursor",
    ] {
        let (status, bytes) = server
            .request("GET", path, "", &[("Authorization", &auth)])
            .await;
        assert_eq!(status, 400, "{path}: {}", String::from_utf8_lossy(&bytes));
        assert_eq!(json(&bytes)["error"]["code"], "bad_request");
    }
}
