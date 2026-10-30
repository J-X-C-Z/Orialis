use super::*;
use crate::{metadata, AgentRegistry, SqlitePoolOptions, VERSION};
use axum::{body::to_bytes, http::HeaderValue};

struct TestState(Arc<AppState>);
impl TestState {
    async fn new() -> Self {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        for user in ["alice", "bob"] {
            sqlx::query("INSERT INTO users(id,username,password_hash) VALUES(?,?,'unused')")
                .bind(user)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES(?,?,?,'2099-01-01T00:00:00Z')").bind(user).bind(user).bind(crate::hash_token(user)).execute(&pool).await.unwrap();
        }
        Self(Arc::new(AppState {
            metadata: metadata(VERSION, "test", "http://localhost"),
            pool,
            agent: AgentRegistry::default(),
            mobile: crate::mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".into(),
            upload_dir: std::env::temp_dir()
                .join(format!("orialis-memory-records-{}", uuid::Uuid::new_v4())),
        }))
    }
    fn state(&self) -> State<Arc<AppState>> {
        State(self.0.clone())
    }
}
impl Drop for TestState {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0.upload_dir);
    }
}
fn headers(user: &str) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(
        header::AUTHORIZATION,
        HeaderValue::from_str(&format!("Session {user}")).unwrap(),
    );
    h
}
fn record(id: &str) -> Map<String, Value> {
    json!({"id":id,"createdAt":"2026-10-31T00:00:00.000Z","sourcePackage":"test","sourceLabel":"test","visibleText":"original 原文","sharedText":"shared","urls":["https://example.com/?x=keep%2Bsignature"],"title":"title","summary":"# Notes\n\nSummary","notes":"private annotation","analysisStatus":"completed","category":"other"}).as_object().unwrap().clone()
}
async fn put(
    s: &TestState,
    user: &str,
    id: &str,
    r: Map<String, Value>,
    version: i64,
) -> Result<Value, AppError> {
    put_record(
        s.state(),
        headers(user),
        Path(id.into()),
        Json(PutRecord {
            record: r,
            expected_version: version,
        }),
    )
    .await
    .map(|v| v.0)
}
async fn list(
    s: &TestState,
    user: &str,
    query: Option<&str>,
    limit: i64,
    offset: i64,
    deleted: bool,
) -> Value {
    list_records(
        s.state(),
        headers(user),
        Query(ListQuery {
            query: query.map(str::to_owned),
            limit: Some(limit),
            offset: Some(offset),
            include_deleted: Some(deleted),
        }),
    )
    .await
    .unwrap()
    .0
}

#[tokio::test]
async fn account_records_roundtrip_search_pagination_and_auth() {
    let s = TestState::new().await;
    let original = record("one");
    let stored = put(&s, "alice", "one", original.clone(), 0).await.unwrap();
    assert_eq!(stored["version"], 1);
    for (k, v) in original {
        assert_eq!(stored[&k], v);
    }
    assert!(matches!(
        get_record(s.state(), HeaderMap::new(), Path("one".into())).await,
        Err(AppError::Unauthorized)
    ));
    assert!(matches!(
        get_record(s.state(), headers("bob"), Path("one".into())).await,
        Err(AppError::NotFound)
    ));
    assert_eq!(
        list(&s, "bob", None, 100, 0, true).await["items"],
        json!([])
    );
    put(&s, "alice", "two", record("two"), 0).await.unwrap();
    let page = list(&s, "alice", None, 1, 0, true).await;
    assert_eq!(page["items"][0]["id"], "one");
    assert_eq!(page["hasMore"], true);
    let page = list(&s, "alice", None, 1, 1, true).await;
    assert_eq!(page["items"][0]["id"], "two");
    assert_eq!(page["hasMore"], false);
    assert_eq!(
        list(&s, "alice", Some("原文"), 100, 0, true).await["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        list(&s, "alice", Some("private annotation"), 100, 0, true).await["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        list(&s, "alice", Some("_"), 100, 0, true).await["items"],
        json!([])
    );
}
#[tokio::test]
async fn cas_retries_conflicts_and_tombstones_do_not_lose_other_edits() {
    let s = TestState::new().await;
    let a = record("one");
    put(&s, "alice", "one", a.clone(), 0).await.unwrap();
    assert_eq!(
        put(&s, "alice", "one", a.clone(), 0).await.unwrap()["version"],
        1
    );
    let mut b = a.clone();
    b.insert("notes".into(), json!("new note"));
    assert_eq!(
        put(&s, "alice", "one", b.clone(), 1).await.unwrap()["version"],
        2
    );
    let mut stale = a.clone();
    stale.insert("notes".into(), json!("stale note"));
    assert!(matches!(
        put(&s, "alice", "one", stale, 1).await,
        Err(AppError::Conflict(_))
    ));
    assert_eq!(
        put(&s, "alice", "one", b.clone(), 1).await.unwrap()["version"],
        2
    );
    assert!(matches!(
        delete_record(
            s.state(),
            headers("alice"),
            Path("one".into()),
            Query(DeleteQuery {
                expected_version: 1
            })
        )
        .await,
        Err(AppError::Conflict(_))
    ));
    let deleted = delete_record(
        s.state(),
        headers("alice"),
        Path("one".into()),
        Query(DeleteQuery {
            expected_version: 2,
        }),
    )
    .await
    .unwrap()
    .0;
    assert_eq!(deleted["version"], 3);
    assert!(deleted["deletedAt"].is_string());
    assert_eq!(deleted["notes"], "new note");
    assert!(matches!(
        put(&s, "alice", "one", b, 3).await,
        Err(AppError::Conflict(_))
    ));
    assert_eq!(
        list(&s, "alice", None, 100, 0, true).await["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        list(&s, "alice", None, 100, 0, false).await["items"],
        json!([])
    );
}
#[tokio::test]
async fn original_image_bytes_hash_and_account_ownership_are_preserved() {
    let s = TestState::new().await;
    let bytes = Bytes::from_static(b"\x89PNG\r\n\x1a\noriginal-image-bytes");
    let hash = format!("{:x}", Sha256::digest(&bytes));
    let meta = put_image(
        s.state(),
        headers("alice"),
        Path(hash.clone()),
        bytes.clone(),
    )
    .await
    .unwrap()
    .0;
    assert_eq!(meta["size"], bytes.len());
    assert_eq!(meta["mimeType"], "image/png");
    let _ = put_image(
        s.state(),
        headers("alice"),
        Path(hash.clone()),
        bytes.clone(),
    )
    .await
    .unwrap();
    let response = get_image(s.state(), headers("alice"), Path(hash.clone()))
        .await
        .unwrap();
    assert_eq!(
        response.headers()[header::CACHE_CONTROL],
        "private, no-store"
    );
    assert_eq!(
        to_bytes(response.into_body(), MAX_IMAGE_BYTES)
            .await
            .unwrap(),
        bytes
    );
    assert!(matches!(
        get_image(s.state(), headers("bob"), Path(hash.clone())).await,
        Err(AppError::NotFound)
    ));
    let mut r = record("one");
    r.insert("imageSha256".into(), json!(hash));
    assert!(matches!(
        put(&s, "bob", "one", r.clone(), 0).await,
        Err(AppError::BadRequest(_))
    ));
    assert_eq!(
        put(&s, "alice", "one", r, 0).await.unwrap()["imageSha256"],
        hash
    );
    assert!(matches!(
        put_image(s.state(), headers("alice"), Path("a".repeat(64)), bytes).await,
        Err(AppError::BadRequest(_))
    ));
    assert!(matches!(
        get_image(s.state(), headers("alice"), Path("../../etc/passwd".into())).await,
        Err(AppError::NotFound)
    ));
    assert!(matches!(
        put_image(
            s.state(),
            headers("alice"),
            Path(hash),
            Bytes::from_static(b"not-an-image")
        )
        .await,
        Err(AppError::BadRequest(_))
    ));
}
#[tokio::test]
async fn reject_device_paths_unknown_fields_bad_metadata_and_missing_images() {
    let s = TestState::new().await;
    for (key, value) in [
        ("imagePath", json!("/private/device/image.png")),
        ("unknown", json!("x")),
        ("category", json!("bad")),
        ("createdAt", json!("bad")),
        ("urls", json!(["file:///private/image"])),
        ("sourceUrl", json!("https://user:password@example.com/")),
        ("imageSha256", json!("a".repeat(64))),
    ] {
        let mut r = record("one");
        r.insert(key.into(), value);
        assert!(
            matches!(
                put(&s, "alice", "one", r, 0).await,
                Err(AppError::BadRequest(_))
            ),
            "{key}"
        );
    }
    assert!(matches!(
        put(&s, "alice", "../bad", record("../bad"), 0).await,
        Err(AppError::BadRequest(_))
    ));
}

#[tokio::test]
async fn mcp_and_client_share_versions_notes_originals_and_audit_history() {
    let s = TestState::new().await;
    let image = Bytes::from_static(b"\xff\xd8\xfforiginal-jpeg");
    let hash = format!("{:x}", Sha256::digest(&image));
    let _ = put_image(s.state(), headers("alice"), Path(hash.clone()), image)
        .await
        .unwrap();
    let mut original = record("one");
    original.insert("imageSha256".into(), json!(hash));
    original.insert("analysisRequestId".into(), json!("request-one"));
    put(&s, "alice", "one", original.clone(), 0).await.unwrap();
    let patch = serde_json::from_value(
        json!({"baseVersion":1,"changeReason":"Keep this useful note","notes":"MCP edited note"}),
    )
    .unwrap();
    let _ = crate::screen_memories::patch_record(
        s.state(),
        headers("alice"),
        Path("one".into()),
        Json(patch),
    )
    .await
    .unwrap();
    let cloud = get_record(s.state(), headers("alice"), Path("one".into()))
        .await
        .unwrap()
        .0;
    assert_eq!(cloud["version"], 2);
    assert_eq!(cloud["notes"], "MCP edited note");
    assert_eq!(cloud["imageSha256"], hash);
    assert_eq!(cloud["analysisRequestId"], "request-one");
    let mut stale = original.clone();
    stale.insert("notes".into(), json!("stale mobile note"));
    assert!(matches!(
        put(&s, "alice", "one", stale, 1).await,
        Err(AppError::Conflict(_))
    ));
    let mut next = original.clone();
    next.insert("notes".into(), json!("MCP edited note"));
    next.insert("summary".into(), json!("# Improved\n\nUseful summary"));
    put(&s, "alice", "one", next.clone(), 2).await.unwrap();
    let saved = crate::screen_memories::get_record(s.state(), headers("alice"), Path("one".into()))
        .await
        .unwrap()
        .0;
    let saved = serde_json::to_value(saved).unwrap();
    assert_eq!(saved["summary"], next["summary"]);
    assert_eq!(saved["version"], 3);
    assert_eq!(saved["imageSha256"], hash);
    let history = crate::screen_memories::history(
        s.state(),
        headers("alice"),
        Path("one".into()),
        Query(serde_json::from_value(json!({"limit":10})).unwrap()),
    )
    .await
    .unwrap()
    .0;
    assert_eq!(history["items"].as_array().unwrap().len(), 3);
    assert_eq!(history["items"][1]["source"], "mcp");
    for (field, value) in [
        ("visibleText", json!("changed original")),
        ("imageSha256", Value::Null),
    ] {
        let mut changed = next.clone();
        changed.insert(field.into(), value);
        assert!(matches!(
            put(&s, "alice", "one", changed, 3).await,
            Err(AppError::Conflict(_))
        ));
    }
    let _ = delete_record(
        s.state(),
        headers("alice"),
        Path("one".into()),
        Query(DeleteQuery {
            expected_version: 3,
        }),
    )
    .await
    .unwrap();
    assert!(matches!(
        crate::screen_memories::get_record(s.state(), headers("alice"), Path("one".into())).await,
        Err(AppError::NotFound)
    ));
    let patch = serde_json::from_value(
        json!({"baseVersion":4,"changeReason":"Must not resurrect","notes":"new note"}),
    )
    .unwrap();
    assert!(matches!(
        crate::screen_memories::patch_record(
            s.state(),
            headers("alice"),
            Path("one".into()),
            Json(patch)
        )
        .await,
        Err(AppError::Conflict(_))
    ));
    assert!(get_image(s.state(), headers("alice"), Path(hash))
        .await
        .is_ok());
}

#[tokio::test]
async fn equivalent_capture_timestamp_spellings_preserve_original_across_both_facades() {
    let s = TestState::new().await;
    for (id, raw) in [
        ("zulu", "2026-10-31T00:00:00Z"),
        ("offset", "2026-10-31T00:00:00+00:00"),
    ] {
        let mut original = record(id);
        original.insert("createdAt".into(), json!(raw));
        let input = serde_json::from_value(json!(original)).unwrap();
        let _ = crate::screen_memories::put_record(
            s.state(),
            headers("alice"),
            Path(id.into()),
            Json(input),
        )
        .await
        .unwrap();
        let mut client = original.clone();
        client.insert("createdAt".into(), json!("2026-10-31T00:00:00.000Z"));
        client.insert("notes".into(), json!("Client note"));
        let saved = put(&s, "alice", id, client.clone(), 1).await.unwrap();
        assert_eq!(saved["version"], 2);
        assert_eq!(saved["createdAt"], raw);
        assert_eq!(saved["notes"], "Client note");
        assert_eq!(put(&s, "alice", id, client, 1).await.unwrap()["version"], 2);
        let mut mcp = original.clone();
        mcp.insert(
            "createdAt".into(),
            json!("2026-10-31T00:00:00.000000+00:00"),
        );
        mcp.insert("notes".into(), json!("MCP note"));
        mcp.insert("baseVersion".into(), json!(2));
        let saved = crate::screen_memories::put_record(
            s.state(),
            headers("alice"),
            Path(id.into()),
            Json(serde_json::from_value(json!(mcp.clone())).unwrap()),
        )
        .await
        .unwrap()
        .0;
        let saved = serde_json::to_value(saved).unwrap();
        assert_eq!(saved["version"], 3);
        assert_eq!(saved["createdAt"], raw);
        assert_eq!(saved["notes"], "MCP note");
        let mut different = original;
        different.insert("createdAt".into(), json!("2026-10-31T00:00:00.001Z"));
        assert!(matches!(
            put(&s, "alice", id, different, 3).await,
            Err(AppError::Conflict(_))
        ));
        mcp.insert("createdAt".into(), json!("2026-10-31T00:00:00.001Z"));
        mcp.insert("baseVersion".into(), json!(3));
        assert!(matches!(
            crate::screen_memories::put_record(
                s.state(),
                headers("alice"),
                Path(id.into()),
                Json(serde_json::from_value(json!(mcp)).unwrap())
            )
            .await,
            Err(AppError::Conflict(_))
        ));
        let history = crate::screen_memories::history(
            s.state(),
            headers("alice"),
            Path(id.into()),
            Query(serde_json::from_value(json!({"limit":10})).unwrap()),
        )
        .await
        .unwrap()
        .0;
        for entry in history["items"].as_array().unwrap().iter().take(2) {
            assert!(!entry["changedFields"]
                .as_array()
                .unwrap()
                .contains(&json!("createdAt")));
        }
    }
}
