use super::*;
use crate::{metadata, AgentRegistry, AppState, SqlitePoolOptions, VERSION};
use axum::{extract::DefaultBodyLimit, routing::get, Router};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
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
                "/api/v1/memories/{id}",
                get(get_record).put(put_record).patch(patch_record),
            )
            .route("/api/v1/memories", get(list_records))
            .route("/api/v1/memories/{id}/history", get(history))
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
    async fn request(
        &self,
        method: &str,
        user: Option<&str>,
        path: &str,
        body: Value,
    ) -> (u16, Value) {
        let body = body.to_string();
        let mut stream = TcpStream::connect(self.address).await.unwrap();
        let auth = user
            .map(|user| format!("Authorization: Session {user}\r\n"))
            .unwrap_or_default();
        let request = format!("{method} /api/v1/memories{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len());
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
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn evidence(id: &str) -> Value {
    json!({"id":id,"createdAt":"2026-10-31T00:00:00Z","sourcePackage":"example.app","sourceLabel":"Example","visibleText":"original capture","sharedText":null,"urls":["https://example.test/original?x=1"],"title":"Capture","summary":"old summary","notes":"user note","category":"other","sourceUrl":"https://example.test/original?x=1","videoStatus":"none","videoSummary":null,"videoError":null})
}

#[tokio::test]
async fn text_mirror_is_account_scoped_cas_protected_and_audited() {
    let server = Server::new().await;
    let original = evidence("capture-1");
    assert_eq!(
        server
            .request("PUT", None, "/capture-1", original.clone())
            .await
            .0,
        401
    );
    let (status, saved) = server
        .request("PUT", Some("alice"), "/capture-1", original.clone())
        .await;
    assert_eq!(status, 200);
    assert_eq!(saved["version"], 1);
    assert_eq!(
        server
            .request("GET", Some("bob"), "/capture-1", Value::Null)
            .await
            .0,
        404
    );
    assert_eq!(
        server
            .request(
                "PATCH",
                Some("bob"),
                "/capture-1",
                json!({"baseVersion":1,"changeReason":"correct","title":"new"})
            )
            .await
            .0,
        404
    );
    let (status,saved) = server.request("PATCH",Some("alice"),"/capture-1",json!({"baseVersion":1,"changeReason":"User corrected label","title":"Corrected","summary":null,"category":"ai"})).await;
    assert_eq!(status, 200);
    assert_eq!(saved["version"], 2);
    assert_eq!(saved["title"], "Corrected");
    assert_eq!(saved["summary"], Value::Null);
    assert_eq!(saved["visibleText"], original["visibleText"]);
    assert_eq!(saved["notes"], "user note");
    assert_eq!(
        server
            .request(
                "PATCH",
                Some("alice"),
                "/capture-1",
                json!({"baseVersion":1,"changeReason":"stale","notes":"lost"})
            )
            .await
            .0,
        409
    );
    let (_, history) = server
        .request(
            "GET",
            Some("alice"),
            "/capture-1/history?limit=10",
            Value::Null,
        )
        .await;
    assert_eq!(history["items"].as_array().unwrap().len(), 2);
    assert_eq!(history["items"][0]["source"], "mcp");
    assert_eq!(history["items"][1]["source"], "device-sync");
    assert!(history["items"][0].get("visibleText").is_none());
    let (_, bob) = server.request("GET", Some("bob"), "", Value::Null).await;
    assert_eq!(bob["items"], json!([]));
    let mut overwrite = original.clone();
    overwrite["baseVersion"] = json!(2);
    overwrite["visibleText"] = json!("overwrite evidence");
    assert_eq!(
        server
            .request("PUT", Some("alice"), "/capture-1", overwrite)
            .await
            .0,
        409
    );
    let mut sync = original;
    sync["baseVersion"] = json!(2);
    sync["summary"] = json!("updated device analysis");
    assert_eq!(
        server
            .request("PUT", Some("alice"), "/capture-1", sync)
            .await
            .0,
        200
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM screen_memory_history")
        .fetch_one(&server.state.pool)
        .await
        .unwrap();
    assert_eq!(count, 3);
}

#[tokio::test]
async fn literal_search_pagination_and_bounded_reads() {
    let server = Server::new().await;
    for id in ["capture-a", "capture-b", "capture-c"] {
        assert_eq!(
            server
                .request("PUT", Some("alice"), &format!("/{id}"), evidence(id))
                .await
                .0,
            200
        );
    }
    let (_, first) = server
        .request("GET", Some("alice"), "?limit=2&query=original", Value::Null)
        .await;
    assert_eq!(first["items"].as_array().unwrap().len(), 2);
    assert_eq!(first["hasMore"], true);
    assert_eq!(first["nextCursor"], "capture-b");
    assert!(first["items"][0].get("visibleText").is_none());
    let (_, second) = server
        .request(
            "GET",
            Some("alice"),
            "?limit=2&after=capture-b&query=original",
            Value::Null,
        )
        .await;
    assert_eq!(second["items"][0]["id"], "capture-c");
    assert_eq!(second["hasMore"], false);
    let (_, wildcard) = server
        .request("GET", Some("alice"), "?query=%25", Value::Null)
        .await;
    assert_eq!(wildcard["items"], json!([]));
    assert_eq!(
        server
            .request("GET", Some("alice"), "?limit=101", Value::Null)
            .await
            .0,
        400
    );
    assert_eq!(
        server
            .request(
                "GET",
                Some("alice"),
                "/capture-a/history?limit=0",
                Value::Null
            )
            .await
            .0,
        400
    );
}

#[test]
fn rejects_forged_sources_images_and_invalid_metadata() {
    let valid = evidence("capture-1");
    assert!(serde_json::from_value::<PutRecord>(valid.clone()).is_ok());
    for (field, value) in [
        ("imagePath", json!("/device/private.png")),
        ("imageBase64", json!("data")),
        ("source", json!("mcp")),
        ("version", json!(1)),
    ] {
        let mut body = valid.clone();
        body[field] = value;
        assert!(
            serde_json::from_value::<PutRecord>(body).is_err(),
            "{field}"
        );
    }
    for (field, value) in [
        ("createdAt", json!("2026-10-31T01:00:00+01:00")),
        ("category", json!("invalid")),
        ("analysisStatus", json!("invalid")),
        ("imageSha256", json!("not-a-hash")),
        ("urls", json!(["https://user:password@example.test"])),
        ("sourceUrl", json!("file:///private")),
        ("videoStatus", json!("analyzed")),
        ("title", json!(" ")),
    ] {
        let mut body = valid.clone();
        body[field] = value;
        let input: PutRecord = serde_json::from_value(body).unwrap();
        assert!(validate(&input.record).is_err(), "{field}");
    }
    for body in [
        json!({"baseVersion":1,"changeReason":"x","visibleText":"overwrite"}),
        json!({"baseVersion":1,"changeReason":"x","source":"device-sync","summary":"x"}),
        json!({"baseVersion":1,"summary":"x"}),
    ] {
        assert!(serde_json::from_value::<PatchRecord>(body).is_err());
    }
}
