//! Local-only attachment HTTP contract and adversarial tests. No live credentials.
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Request, State},
    http::{StatusCode, header},
    response::Response,
};
use hermes_rust_core::attachments::*;
use serde_json::json;
use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

type ObservedRequest = (String, String, String, Vec<u8>);
#[derive(Clone, Default)]
struct MockState {
    seen: Arc<Mutex<Vec<ObservedRequest>>>,
}
struct MockServer {
    base: String,
    state: MockState,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for MockServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn server() -> MockServer {
    async fn handler(State(state): State<MockState>, request: Request) -> Response {
        let path = request.uri().path().to_owned();
        let auth = request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let device = request
            .headers()
            .get("x-orialis-device-id")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let host = request.headers()[header::HOST].to_str().unwrap().to_owned();
        let key = request
            .headers()
            .get("idempotency-key")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let ct = request
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let body = to_bytes(request.into_body(), 25 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec();
        state
            .seen
            .lock()
            .unwrap()
            .push((path.clone(), auth.clone(), device, body.clone()));
        if auth != "Bearer local-test-token" {
            return Response::builder().status(401).body(Body::empty()).unwrap();
        }
        if path.contains("/conversations/") {
            assert_eq!(key, "upload-key");
            assert!(ct.starts_with("multipart/form-data; boundary=orialis-rust-"));
            assert!(
                String::from_utf8_lossy(&body).contains("name=\"file\"; filename=\"报告.txt\"")
            );
            assert!(body.windows(5).any(|w| w == b"hello"));
            return Response::builder().header(header::CONTENT_TYPE,"application/json").body(Body::from(json!({"items":[{"id":"uploaded","name":"报告.txt","mimeType":"text/plain","size":5,"downloadUrl":format!("http://{host}/api/v1/attachments/uploaded/download")}]}).to_string())).unwrap();
        }
        match path.as_str() {
            "/api/v1/attachments/redirect/download" => Response::builder()
                .status(302)
                .header(header::LOCATION, "/must-not-hit")
                .body(Body::empty())
                .unwrap(),
            "/api/v1/attachments/wrongmime/download" => Response::builder()
                .header(header::CONTENT_TYPE, "application/pdf")
                .body(Body::from("hello"))
                .unwrap(),
            "/api/v1/attachments/chunked/download" => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::from_stream(futures_util::stream::iter([
                    Ok::<_, std::io::Error>("hello"),
                    Ok("oversize"),
                ])))
                .unwrap(),
            "/api/v1/attachments/large/download" => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .header(header::CONTENT_LENGTH, MAX_ATTACHMENT_BYTES)
                .body(Body::from_stream(futures_util::stream::iter(
                    (0..320).map(|_| Ok::<_, std::io::Error>(vec![b'a'; 64 * 1024])),
                )))
                .unwrap(),
            "/api/v1/attachments/slow/download" => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::from_stream(futures_util::stream::unfold(
                    0,
                    |n| async move {
                        if n > 0 {
                            tokio::time::sleep(Duration::from_secs(30)).await;
                        }
                        Some((Ok::<_, std::io::Error>(vec![b'a'; 64 * 1024]), n + 1))
                    },
                )))
                .unwrap(),
            "/api/v1/attachments/empty/download" => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::empty())
                .unwrap(),
            "/api/v1/attachments/png/download" => Response::builder()
                .header(header::CONTENT_TYPE, "image/png")
                .body(Body::from(png()))
                .unwrap(),
            "/api/v1/attachments/pdf/download" => Response::builder()
                .header(header::CONTENT_TYPE, "application/pdf")
                .body(Body::from("%PDF-test"))
                .unwrap(),
            "/api/v1/attachments/badutf/download" => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::from(vec![0xff, 0xfe]))
                .unwrap(),
            _ => Response::builder()
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::from("hello"))
                .unwrap(),
        }
    }
    let state = MockState::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new().fallback(handler).with_state(state.clone());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    MockServer { base, state, task }
}
fn transport(base: &str, dir: &Path) -> AttachmentTransport {
    AttachmentTransport::new(AttachmentConfig::new(
        base.into(),
        "TE_ST_Rust".into(),
        "local-test-token".into(),
        dir.join("cache"),
    ))
    .unwrap()
}
fn item(base: &str, id: &str, mime: &str, size: Option<u64>) -> AttachmentMetadata {
    AttachmentMetadata {
        id: id.into(),
        name: "../../same.txt".into(),
        mime_type: mime.into(),
        size,
        download_url: format!("{base}/api/v1/attachments/{id}/download"),
    }
}
fn png() -> Vec<u8> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPQAAAABJRU5ErkJggg==").unwrap()
}

#[tokio::test]
async fn authenticated_download_cache_permissions_reuse_and_model_text() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let metadata = vec![
        item(&mock.base, "one", "text/plain", Some(5)),
        item(&mock.base, "two", "text/plain", Some(5)),
    ];
    let files = t
        .fetch_message("中文 /+", "message", &metadata)
        .await
        .unwrap();
    assert_ne!(files[0].path, files[1].path);
    assert!(!files[0].path.to_string_lossy().contains("same.txt"));
    assert_eq!(std::fs::read(&files[0].path).unwrap(), b"hello");
    let same = t
        .fetch_message("中文 /+", "message", &metadata)
        .await
        .unwrap();
    assert_eq!(same[0].path, files[0].path);
    let seen = mock.state.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 2);
    assert!(
        seen.iter()
            .all(|(_, a, d, _)| a == "Bearer local-test-token" && d == "TE_ST_Rust")
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        assert_eq!(
            std::fs::metadata(&files[0].path).unwrap().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(files[0].path.parent().unwrap())
                .unwrap()
                .mode()
                & 0o777,
            0o700
        );
    }
    let prepared = prepare_model_input("summarize", &files, &ModelInputLimits::default())
        .await
        .unwrap();
    assert_eq!(prepared.message["role"], "user");
    assert!(prepared.notices.is_empty());
    let raw = prepared.message.to_string();
    assert!(raw.contains("untrusted_content"));
    assert!(!raw.contains("download_url"));
    assert!(!raw.contains("local-test-token"));
    assert!(!raw.contains("http://"));
}

#[tokio::test]
async fn url_ssrf_redirect_and_credential_guards() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let good = item(&mock.base, "one", "text/plain", Some(5));
    for url in [
        "http://evil.invalid/api/v1/attachments/one/download".to_owned(),
        mock.base.replace("http://", "https://") + "/api/v1/attachments/one/download",
        format!("{}/api/v1/conversations", mock.base),
        format!("{}/api/v1/attachments/two/download", mock.base),
        format!(
            "{}/api/v1/attachments/one/download?forward=http://evil.invalid",
            mock.base
        ),
        format!("{}/api/v1/attachments/one/download#secret", mock.base),
        mock.base.replace("http://", "http://user:secret@") + "/api/v1/attachments/one/download",
        format!("{}/api/v1/attachments/foo/../one/download", mock.base),
    ] {
        let mut bad = good.clone();
        bad.download_url = url;
        assert!(t.fetch_message("c", "m", &[bad]).await.is_err());
    }
    assert!(mock.state.seen.lock().unwrap().is_empty());
    assert!(
        t.fetch_message(
            "c",
            "m",
            &[item(&mock.base, "redirect", "text/plain", None)]
        )
        .await
        .is_err()
    );
    assert_eq!(mock.state.seen.lock().unwrap().len(), 1);
    assert!(
        !mock
            .state
            .seen
            .lock()
            .unwrap()
            .iter()
            .any(|(p, _, _, _)| p == "/must-not-hit")
    );
}

#[tokio::test]
async fn failed_streams_mime_size_and_partial_cleanup() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    for (id, size) in [
        ("wrongmime", Some(5)),
        ("chunked", Some(5)),
        ("empty", None),
        ("one", Some(6)),
    ] {
        assert!(
            t.fetch_message("c", id, &[item(&mock.base, id, "text/plain", size)])
                .await
                .is_err()
        );
    }
    fn all_files(p: &Path) -> Vec<std::path::PathBuf> {
        std::fs::read_dir(p)
            .unwrap()
            .flat_map(|e| {
                let p = e.unwrap().path();
                if p.is_dir() { all_files(&p) } else { vec![p] }
            })
            .collect()
    }
    assert!(all_files(&dir.path().join("cache")).is_empty());
    let oversized = item(
        &mock.base,
        "one",
        "text/plain",
        Some(MAX_ATTACHMENT_BYTES + 1),
    );
    assert!(t.fetch_message("c", "too-big", &[oversized]).await.is_err());
    let three = vec![item(&mock.base, "one", "text/plain", None); 3];
    assert_eq!(
        t.fetch_message("c", "unknown-size", &three)
            .await
            .unwrap()
            .len(),
        3
    );
    let too_many = vec![item(&mock.base, "one", "text/plain", Some(5)); 17];
    assert!(t.fetch_message("c", "too-many", &too_many).await.is_err());
}

#[tokio::test]
async fn images_and_unsupported_documents_are_honest() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let files = t
        .fetch_message(
            "c",
            "m",
            &[
                item(&mock.base, "png", "image/png", Some(png().len() as u64)),
                item(&mock.base, "pdf", "application/pdf", Some(9)),
                item(&mock.base, "badutf", "text/plain", Some(2)),
            ],
        )
        .await
        .unwrap();
    let no_vision = prepare_model_input("read", &files, &ModelInputLimits::default())
        .await
        .unwrap();
    assert_eq!(no_vision.notices.len(), 3);
    assert!(!no_vision.message.to_string().contains("data:image"));
    let limits = ModelInputLimits {
        supports_images: true,
        ..Default::default()
    };
    let vision = prepare_model_input("read", &files, &limits).await.unwrap();
    assert_eq!(vision.notices.len(), 2);
    assert!(
        vision
            .message
            .to_string()
            .contains("data:image/png;base64,")
    );
    assert!(
        vision
            .notices
            .iter()
            .any(|s| s.contains("does not extract PDF"))
    );
    let small = ModelInputLimits {
        supports_images: true,
        max_text_bytes: 1,
        max_image_bytes: 1,
        ..Default::default()
    };
    assert_eq!(
        prepare_model_input("x", &files, &small)
            .await
            .unwrap()
            .notices
            .len(),
        3
    );
}

#[tokio::test]
async fn authenticated_streaming_upload_and_unicode_conversation() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let path = dir.path().join("报告.txt");
    std::fs::write(&path, b"hello").unwrap();
    let result = t
        .upload_file("中文 /+", &path, None, "text/plain", "upload-key")
        .await
        .unwrap();
    assert_eq!(result.id, "uploaded");
    assert_eq!(result.size, Some(5));
    let seen = mock.state.seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(
        seen[0].0,
        "/api/v1/conversations/%E4%B8%AD%E6%96%87%20%2F+/attachments"
    );
    assert_eq!(seen[0].1, "Bearer local-test-token");
    assert_eq!(seen[0].2, "TE_ST_Rust");
}

#[test]
fn exact_metadata_contract_and_reply_correlation() {
    let metadata:AttachmentMetadata=serde_json::from_value(json!({"id":"a","name":"报告.txt","mimeType":"text/plain","size":5,"downloadUrl":"http://localhost/api/v1/attachments/a/download"})).unwrap();
    let anchor = json!({"conversation_id":"中文 /+","message_id":"m1"});
    let reply = attachment_reply(&anchor, "答复", &[metadata]).unwrap();
    assert_eq!(reply["reply_to"], "m1");
    assert_eq!(reply["conversation_id"], "中文 /+");
    assert!(reply["attachments"][0].get("mime_type").is_some());
    assert!(reply["attachments"][0].get("mimeType").is_none());
    // Produced independently with Python json.dumps(..., ensure_ascii=False,sort_keys=True).
    assert_eq!(reply["message_id"], "final_8bb3cf254a8f61bc383a6154");
    for invalid in [
        json!({"id":"a","name":"a","mime_type":"text/plain","download_url":"http://x/a","size":true}),
        json!({"id":"a","name":"a","mime_type":"text/plain","download_url":"http://x/a","content":"not metadata"}),
    ] {
        assert!(serde_json::from_value::<AttachmentMetadata>(invalid).is_err());
    }
    assert_eq!(
        safe_filename("C:\\secrets\\../../报告\"\r\n.txt"),
        "报告___.txt"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn unsafe_cache_symlink_hardlink_and_upload_types_refused() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let files = t
        .fetch_message("c", "m", &[item(&mock.base, "one", "text/plain", Some(5))])
        .await
        .unwrap();
    let path = files[0].path.clone();
    let target = dir.path().join("target");
    std::fs::write(&target, b"hello").unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::remove_file(&path).unwrap();
    symlink(&target, &path).unwrap();
    assert!(
        t.fetch_message("c", "m", &[item(&mock.base, "one", "text/plain", Some(5))])
            .await
            .is_err()
    );
    std::fs::remove_file(&path).unwrap();
    std::fs::hard_link(&target, &path).unwrap();
    assert!(
        prepare_model_input("read", &files, &ModelInputLimits::default())
            .await
            .is_err()
    );
    let alias = dir.path().join("alias");
    symlink(&target, &alias).unwrap();
    assert!(
        t.upload_file("c", &alias, None, "text/plain", "upload-key")
            .await
            .is_err()
    );
    assert!(
        t.upload_file("c", dir.path(), None, "text/plain", "upload-key")
            .await
            .is_err()
    );
    let bad = dir.path().join("unsafe");
    std::fs::create_dir(&bad).unwrap();
    std::fs::set_permissions(&bad, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(
        AttachmentTransport::new(AttachmentConfig::new(
            mock.base.clone(),
            "dev".into(),
            "token".into(),
            bad
        ))
        .is_err()
    );
}

#[tokio::test]
#[ignore = "requires the local real Orialis server binary; set ORIALIS_TEST_SERVER_BINARY"]
async fn real_orialis_server_upload_download_idempotency_and_owner_auth() {
    struct Process(std::process::Child);
    impl Drop for Process {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let binary = std::env::var("ORIALIS_TEST_SERVER_BINARY").expect("ORIALIS_TEST_SERVER_BINARY");
    let dir = tempfile::tempdir().unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let base = format!("http://127.0.0.1:{port}");
    let _process = Process(
        std::process::Command::new(binary)
            .env_remove("ORIALIS_AGENT_USER_ID")
            .env("ORIALIS_ENV", "development")
            .env("ORIALIS_HOST", "127.0.0.1")
            .env("ORIALIS_PORT", port.to_string())
            .env("ORIALIS_PUBLIC_URL", &base)
            .env("ORIALIS_DEV_DEVICE_AUTH", "0")
            .env("ORIALIS_AGENT_DEVICE_TOKEN", "local-test-token")
            .env(
                "ORIALIS_DATABASE_URL",
                format!(
                    "sqlite://{}?mode=rwc",
                    dir.path().join("server.db").display()
                ),
            )
            .env("ORIALIS_UPLOAD_DIR", dir.path().join("uploads"))
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let mut ready = false;
    for _ in 0..100 {
        if client
            .get(format!("{base}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(ready, "real Orialis server did not start");
    let registered = client
        .post(format!("{base}/api/v1/auth/register"))
        .json(&json!({"username":"attachment-fixture-owner","password":"Local-test-password-1234"}))
        .send()
        .await
        .unwrap();
    assert!(registered.status().is_success(), "registration failed");
    let registered: serde_json::Value = registered.json().await.unwrap();
    let session = registered["accessToken"]
        .as_str()
        .expect("registration session token");
    let response = client
        .post(format!("{base}/api/v1/conversations"))
        .header("Authorization", format!("Session {session}"))
        .json(&json!({"id":"attachment-fixture","title":"attachment fixture"}))
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "{}",
        response.text().await.unwrap()
    );
    let inspect = client
        .get(format!("{base}/api/v1/conversations"))
        .bearer_auth("local-test-token")
        .header("X-Orialis-Device-Id", "TE_ST_Rust")
        .send()
        .await
        .unwrap();
    assert!(inspect.status().is_success(), "agent owner mapping failed");
    let t = transport(&base, dir.path());
    let path = dir.path().join("roundtrip.txt");
    let bytes = "actual Orialis upload/download 中文".as_bytes();
    std::fs::write(&path, bytes).unwrap();
    let first = t
        .upload_file(
            "attachment-fixture",
            &path,
            None,
            "text/plain",
            "real-upload-1",
        )
        .await
        .unwrap();
    let second = t
        .upload_file(
            "attachment-fixture",
            &path,
            None,
            "text/plain",
            "real-upload-1",
        )
        .await
        .unwrap();
    assert_eq!(first, second);
    assert_eq!(
        client
            .get(&first.download_url)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let fetched = t
        .fetch_message("attachment-fixture", "inbound-message", &[first])
        .await
        .unwrap();
    assert_eq!(std::fs::read(&fetched[0].path).unwrap(), bytes);
    let prepared = prepare_model_input(
        "read the attachment",
        &fetched,
        &ModelInputLimits::default(),
    )
    .await
    .unwrap();
    assert!(
        prepared
            .message
            .to_string()
            .contains("actual Orialis upload/download 中文")
    );
}

#[tokio::test]
async fn full_gateway_count_and_over_multipart_limit_are_supported() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let small = vec![item(&mock.base, "one", "text/plain", None); MAX_ATTACHMENTS];
    assert_eq!(
        t.fetch_message("c", "sixteen", &small).await.unwrap().len(),
        16
    );
    let large = vec![
        item(
            &mock.base,
            "large",
            "text/plain",
            Some(MAX_ATTACHMENT_BYTES)
        );
        3
    ];
    let files = t.fetch_message("c", "sixty-mib", &large).await.unwrap();
    assert_eq!(files.iter().map(|f| f.size).sum::<u64>(), 60 * 1024 * 1024);
    assert!(
        files
            .iter()
            .all(|f| std::fs::metadata(&f.path).unwrap().len() == MAX_ATTACHMENT_BYTES)
    );
}

#[tokio::test]
async fn cancelled_download_removes_partial_file() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let metadata = [item(&mock.base, "slow", "text/plain", None)];
    assert!(
        tokio::time::timeout(
            Duration::from_millis(100),
            t.fetch_message("c", "slow", &metadata)
        )
        .await
        .is_err()
    );
    fn files(p: &Path) -> Vec<std::path::PathBuf> {
        std::fs::read_dir(p)
            .unwrap()
            .flat_map(|e| {
                let p = e.unwrap().path();
                if p.is_dir() { files(&p) } else { vec![p] }
            })
            .collect()
    }
    assert!(files(&dir.path().join("cache")).is_empty());
}

#[tokio::test]
async fn active_leases_pin_retention_and_credentials_isolate_cache() {
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut config = AttachmentConfig::new(
        mock.base.clone(),
        "TE_ST_Rust".into(),
        "local-test-token".into(),
        dir.path().join("cache"),
    );
    config.retention = Duration::ZERO;
    let t = AttachmentTransport::new(config.clone()).unwrap();
    let metadata = [item(&mock.base, "one", "text/plain", Some(5))];
    let files = t.fetch_message("c", "pinned", &metadata).await.unwrap();
    let old = files[0].path.clone();
    drop(t.fetch_message("c", "new", &metadata).await.unwrap());
    assert!(old.exists());
    drop(files);
    drop(t.fetch_message("c", "newer", &metadata).await.unwrap());
    assert!(!old.exists());
    config.device_id = "TE_ST_Other".into();
    let other = AttachmentTransport::new(config).unwrap();
    let a = t.fetch_message("c", "same", &metadata).await.unwrap();
    let b = other.fetch_message("c", "same", &metadata).await.unwrap();
    assert_ne!(a[0].path, b[0].path);
}

#[cfg(unix)]
#[tokio::test]
async fn actual_byte_quota_and_message_count_bound_preserve_pins() {
    use std::os::unix::fs::OpenOptionsExt;
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut config = AttachmentConfig::new(
        mock.base.clone(),
        "TE_ST_Rust".into(),
        "local-test-token".into(),
        dir.path().join("cache"),
    );
    config.max_cache_bytes = MAX_TOTAL_ATTACHMENT_BYTES;
    config.max_cache_messages = 2;
    let t = AttachmentTransport::new(config).unwrap();
    let known = [item(&mock.base, "one", "text/plain", Some(5))];
    let held = t.fetch_message("c", "held", &known).await.unwrap();
    // Simulate an old private partial file from an interrupted process; sparse
    // allocation exercises byte accounting without hundreds of MiB of test RAM.
    let stale = held[0].path.parent().unwrap().join(".part-recovered");
    std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(stale)
        .unwrap()
        .set_len(MAX_TOTAL_ATTACHMENT_BYTES - 10)
        .unwrap();
    let unknown = [item(&mock.base, "two", "text/plain", None)];
    let small = t.fetch_message("c", "small", &unknown).await.unwrap();
    assert_eq!(
        small[0].size, 5,
        "unknown sizes must not reserve the per-file maximum"
    );
    assert!(t.fetch_message("c", "full", &known).await.is_err());
    assert!(held[0].path.exists());
    assert!(small[0].path.exists());
    let old = held[0].path.clone();
    drop(held);
    let recovered = t.fetch_message("c", "full", &known).await.unwrap();
    assert_eq!(recovered[0].size, 5);
    assert!(!old.exists());
    assert!(small[0].path.exists());
}

#[cfg(unix)]
#[tokio::test]
async fn crash_leftover_temporary_name_does_not_break_first_retry() {
    use std::os::unix::fs::OpenOptionsExt;
    let mock = server().await;
    let dir = tempfile::tempdir().unwrap();
    let t = transport(&mock.base, dir.path());
    let metadata = [item(&mock.base, "one", "text/plain", Some(5))];
    let initial = t.fetch_message("c", "crash", &metadata).await.unwrap();
    let path = initial[0].path.clone();
    std::fs::remove_file(&path).unwrap();
    let leftover = path
        .parent()
        .unwrap()
        .join(format!(".part-{}-0", std::process::id()));
    std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&leftover)
        .unwrap();
    let retry = t.fetch_message("c", "crash", &metadata).await.unwrap();
    assert_eq!(std::fs::read(&retry[0].path).unwrap(), b"hello");
    assert!(
        leftover.exists(),
        "unknown partial files must not be deleted while their message is pinned"
    );
}
