//! Isolated outbound artifact persistence, permission and HTTP recovery tests.
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Request, State},
    http::header,
    response::Response,
};
use hermes_rust_core::{
    attachments::{AttachmentConfig, AttachmentMetadata, AttachmentTransport},
    output_files::*,
};
use serde_json::json;
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

#[derive(Clone, Default)]
struct ServerState {
    calls: Arc<AtomicUsize>,
    stored: Arc<Mutex<HashMap<String, AttachmentMetadata>>>,
    bodies: Arc<Mutex<Vec<Vec<u8>>>>,
    invalid_first: Arc<AtomicBool>,
    hold_first: Arc<AtomicBool>,
    release: Arc<tokio::sync::Notify>,
}
struct Server {
    base: String,
    state: ServerState,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.state.release.notify_waiters();
        self.task.abort();
    }
}
async fn server() -> Server {
    async fn upload(State(state): State<ServerState>, request: Request) -> Response {
        assert_eq!(
            request.headers()[header::AUTHORIZATION],
            "Bearer fixture-token"
        );
        assert_eq!(request.headers()["X-Orialis-Device-Id"], "TE_ST_Rust");
        let key = request.headers()["Idempotency-Key"]
            .to_str()
            .unwrap()
            .to_owned();
        let host = request.headers()[header::HOST].to_str().unwrap().to_owned();
        let body = to_bytes(request.into_body(), 25 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec();
        let raw = String::from_utf8_lossy(&body);
        let name = raw
            .split("filename=\"")
            .nth(1)
            .unwrap()
            .split('"')
            .next()
            .unwrap()
            .to_owned();
        let mime = raw
            .split("Content-Type: ")
            .nth(1)
            .unwrap()
            .split("\r\n")
            .next()
            .unwrap()
            .to_owned();
        let begin = body.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        let end = body.windows(4).rposition(|w| w == b"\r\n--").unwrap();
        let size = (end - begin) as u64;
        let metadata = {
            let mut stored = state.stored.lock().unwrap();
            let count = stored.len() + 1;
            stored
                .entry(key)
                .or_insert_with(|| AttachmentMetadata {
                    id: format!("file-{count}"),
                    name,
                    mime_type: mime,
                    size: Some(size),
                    download_url: format!("http://{host}/api/v1/attachments/file-{count}/download"),
                })
                .clone()
        };
        state.bodies.lock().unwrap().push(body);
        let call = state.calls.fetch_add(1, Ordering::SeqCst) + 1;
        if call == 1 && state.hold_first.load(Ordering::SeqCst) {
            state.release.notified().await;
        }
        if call == 1 && state.invalid_first.load(Ordering::SeqCst) {
            return Response::builder()
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("committed but response lost"))
                .unwrap();
        }
        Response::builder()
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(json!({"items":[metadata]}).to_string()))
            .unwrap()
    }
    let state = ServerState::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new().fallback(upload).with_state(state.clone());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Server { base, state, task }
}
fn transport(base: &str, dir: &Path, token: &str) -> AttachmentTransport {
    AttachmentTransport::new(AttachmentConfig::new(
        base.into(),
        "TE_ST_Rust".into(),
        token.into(),
        dir.join("cache"),
    ))
    .unwrap()
}
fn config(dir: &Path) -> OutputConfig {
    OutputConfig::new(dir.join("outputs.sqlite"), dir.join("spool"))
}
fn scope() -> OutputScope {
    OutputScope {
        conversation_id: "fixture-conversation".into(),
        input_id: "input-1".into(),
    }
}
async fn service(server: &Server, dir: &Path) -> OutputFiles {
    OutputFiles::open(config(dir), transport(&server.base, dir, "fixture-token"))
        .await
        .unwrap()
}

#[tokio::test]
async fn default_denial_and_turn_registered_file_identity() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"original").unwrap();
    assert!(
        files
            .resolve_media(&scope(), path.to_str().unwrap())
            .await
            .is_err()
    );
    let artifact = files
        .register_tool_artifact(&scope(), "tool-call-1", &path, None, "text/plain")
        .await
        .unwrap();
    assert_eq!(
        files
            .resolve_media(&scope(), path.to_str().unwrap())
            .await
            .unwrap(),
        artifact
    );
    let other = OutputScope {
        input_id: "other-input".into(),
        ..scope()
    };
    assert!(
        files
            .resolve_media(&other, path.to_str().unwrap())
            .await
            .is_err()
    );
    assert!(
        files
            .resolve_media(&other, &format!("artifact://{}", artifact.artifact_id))
            .await
            .is_err()
    );
    std::fs::remove_file(&path).unwrap();
    assert_eq!(
        files
            .register_tool_artifact(&scope(), "tool-call-1", &path, None, "text/plain")
            .await
            .unwrap(),
        artifact
    );
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn immutable_snapshot_upload_replay_events_and_retention() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"SNAPSHOT-ORIGINAL").unwrap();
    let artifact = files
        .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
        .await
        .unwrap();
    std::fs::write(&path, b"SOURCE-CHANGED").unwrap();
    let outcome = files.upload(&scope(), &artifact.artifact_id).await.unwrap();
    assert!(matches!(outcome, UploadOutcome::Uploaded { .. }));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    let body = server.state.bodies.lock().unwrap()[0].clone();
    assert!(String::from_utf8_lossy(&body).contains("SNAPSHOT-ORIGINAL"));
    assert!(!String::from_utf8_lossy(&body).contains("SOURCE-CHANGED"));
    let events = files.pending_events(&scope()).await.unwrap();
    assert_eq!(
        events
            .iter()
            .map(|e| e.payload["type"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec![
            "artifact.started",
            "artifact.progress",
            "artifact.progress",
            "artifact.completed"
        ]
    );
    assert!(
        events[3].payload["artifact"]["uri"]
            .as_str()
            .unwrap()
            .starts_with(&server.base)
    );
    drop(files);
    let restarted = service(&server, dir.path()).await;
    assert_eq!(
        restarted
            .upload(&scope(), &artifact.artifact_id)
            .await
            .unwrap(),
        outcome
    );
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    assert_eq!(restarted.prune_delivered_before(i64::MAX).await.unwrap(), 0);
    restarted
        .mark_delivered(&scope(), &artifact.artifact_id)
        .await
        .unwrap();
    assert_eq!(restarted.prune_delivered_before(i64::MAX).await.unwrap(), 0);
    for event in events {
        restarted
            .acknowledge_event(&scope(), event.id)
            .await
            .unwrap();
    }
    assert_eq!(restarted.prune_delivered_before(i64::MAX).await.unwrap(), 1);
}

#[tokio::test]
async fn unknown_commit_requires_explicit_same_key_reconciliation() {
    let server = server().await;
    server.state.invalid_first.store(true, Ordering::SeqCst);
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"hello").unwrap();
    let artifact = files
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    assert_eq!(server.state.stored.lock().unwrap().len(), 1);
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    drop(files);
    let files = service(&server, dir.path()).await;
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    assert!(matches!(
        files
            .reconcile_upload(&scope(), &artifact.artifact_id)
            .await
            .unwrap(),
        UploadOutcome::Uploaded { .. }
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 2);
    assert_eq!(server.state.stored.lock().unwrap().len(), 1);
    let events = files.pending_events(&scope()).await.unwrap();
    assert!(events.iter().any(|e| e.payload["type"] == "artifact.failed"
        && e.payload["metadata"]["outcomeUnknown"] == true));
    assert_eq!(events.last().unwrap().payload["type"], "artifact.completed");
}

#[tokio::test]
async fn cancelled_upload_is_unknown_after_restart_and_not_reposted() {
    let server = server().await;
    server.state.hold_first.store(true, Ordering::SeqCst);
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"hello").unwrap();
    let artifact = files
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    let cloned = files.clone();
    let id = artifact.artifact_id.clone();
    let upload = tokio::spawn(async move { cloned.upload(&scope(), &id).await });
    for _ in 0..100 {
        if server.state.calls.load(Ordering::SeqCst) == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    upload.abort();
    let _ = upload.await;
    drop(files);
    let files = service(&server, dir.path()).await;
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    assert!(
        !files
            .pending_events(&scope())
            .await
            .unwrap()
            .iter()
            .any(|e| e.payload["type"] == "artifact.completed")
    );
    server.state.release.notify_waiters();
}

#[tokio::test]
async fn snapshot_tampering_and_identity_changes_are_refused() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"hello").unwrap();
    let artifact = files
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    std::fs::write(
        dir.path()
            .join("spool")
            .join(format!("{}.bin", artifact.artifact_id)),
        b"other",
    )
    .unwrap();
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::Failed { .. }
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 0);
    drop(files);
    assert!(
        OutputFiles::open(
            config(dir.path()),
            transport(&server.base, dir.path(), "different-token")
        )
        .await
        .is_err()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn configured_roots_reject_symlinks_traversal_and_credential_paths() {
    use std::os::unix::fs::symlink;
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let root = dir.path().join("exports");
    std::fs::create_dir(&root).unwrap();
    let mut cfg = config(dir.path());
    cfg.artifact_roots.push(root.clone());
    let files = OutputFiles::open(cfg, transport(&server.base, dir.path(), "fixture-token"))
        .await
        .unwrap();
    std::fs::write(root.join("allowed.txt"), b"allowed").unwrap();
    std::fs::write(outside.path().join("secret.txt"), b"outside").unwrap();
    symlink(outside.path(), root.join("link")).unwrap();
    std::fs::write(root.join(".env"), b"fixture-no-secret").unwrap();
    assert!(
        files
            .resolve_media(&scope(), root.join("allowed.txt").to_str().unwrap())
            .await
            .is_ok()
    );
    for path in [
        root.join("link/secret.txt"),
        root.join("../outside"),
        root.join(".env"),
        outside.path().join("secret.txt"),
    ] {
        assert!(
            files
                .resolve_media(&scope(), path.to_str().unwrap())
                .await
                .is_err()
        );
    }
    assert!(files.resolve_media(&scope(), "relative.txt").await.is_err());
}

#[tokio::test]
async fn final_media_is_uploaded_before_markers_are_removed() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report with spaces.txt");
    std::fs::write(&path, b"delivered").unwrap();
    files
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    let body = format!("Here is the report.\nMEDIA:\"{}\"\n", path.display());
    let result = files.finalize_media(&scope(), &body).await.unwrap();
    assert_eq!(result.text, "Here is the report.");
    assert_eq!(result.attachments.len(), 1);
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    let second = files.finalize_media(&scope(), &body).await.unwrap();
    assert_eq!(second.attachments, result.attachments);
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn media_examples_and_unicode_boundaries_are_not_actions() {
    let body = "Example `MEDIA:/tmp/secret.txt`\n```text\nMEDIA:/tmp/secret.txt\n```\n> MEDIA:/tmp/secret.txt\n正文 MEDIA:\"/tmp/真实 文件.txt\"\nMEDIA:artifact://artifact_123\n";
    let markers = parse_media_markers(body);
    assert_eq!(markers.len(), 2);
    assert_eq!(markers[0].reference, "/tmp/真实 文件.txt");
    assert_eq!(markers[1].reference, "artifact://artifact_123");
    for marker in markers {
        assert!(body[marker.start..marker.end].starts_with("MEDIA:"));
    }
}

#[tokio::test]
#[ignore = "requires the real local Orialis server binary; set ORIALIS_TEST_SERVER_BINARY"]
async fn real_orialis_artifact_snapshot_replay_and_download() {
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
    let server_database = dir.path().join("server.db");
    let _process = Process(
        std::process::Command::new(binary)
            .env_remove("ORIALIS_AGENT_USER_ID")
            .env("ORIALIS_ENV", "development")
            .env("ORIALIS_HOST", "127.0.0.1")
            .env("ORIALIS_PORT", port.to_string())
            .env("ORIALIS_PUBLIC_URL", &base)
            .env("ORIALIS_DEV_DEVICE_AUTH", "0")
            .env("ORIALIS_AGENT_DEVICE_TOKEN", "fixture-token")
            .env(
                "ORIALIS_DATABASE_URL",
                format!("sqlite://{}?mode=rwc", server_database.display()),
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
    assert!(ready, "real server did not start");
    let response = client
        .post(format!("{base}/api/v1/auth/register"))
        .json(&json!({"username":"output-fixture-owner","password":"Local-test-password-1234"}))
        .send()
        .await
        .unwrap();
    assert!(response.status().is_success());
    let owner: serde_json::Value = response.json().await.unwrap();
    let response = client
        .post(format!("{base}/api/v1/conversations"))
        .header(
            "Authorization",
            format!("Session {}", owner["accessToken"].as_str().unwrap()),
        )
        .json(&json!({"id":scope().conversation_id,"title":"outbound artifact fixture"}))
        .send()
        .await
        .unwrap();
    assert!(response.status().is_success());
    let files = OutputFiles::open(
        config(dir.path()),
        transport(&base, dir.path(), "fixture-token"),
    )
    .await
    .unwrap();
    let path = dir.path().join("真实报告.txt");
    let original = b"real Orialis persisted outbound artifact";
    std::fs::write(&path, original).unwrap();
    let handle = files
        .register_tool_artifact(&scope(), "trusted-tool-result-1", &path, None, "text/plain")
        .await
        .unwrap();
    std::fs::write(&path, b"subsequent source content must not be sent").unwrap();
    let first = files
        .finalize_media(
            &scope(),
            &format!("Report ready.\nMEDIA:artifact://{}", handle.artifact_id),
        )
        .await
        .unwrap();
    assert_eq!(first.text, "Report ready.");
    assert_eq!(first.attachments.len(), 1);
    let attachment = first.attachments[0].clone();
    let response = client
        .get(&attachment.download_url)
        .bearer_auth("fixture-token")
        .header("X-Orialis-Device-Id", "TE_ST_Rust")
        .send()
        .await
        .unwrap();
    assert!(response.status().is_success());
    assert_eq!(response.bytes().await.unwrap().as_ref(), original);
    let events = files.pending_events(&scope()).await.unwrap();
    assert_eq!(events.len(), 4);
    assert_eq!(
        events.last().unwrap().payload["artifact"]["metadata"]["attachment_id"],
        attachment.id
    );
    let connection = rusqlite::Connection::open(&server_database).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM attachments", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM attachment_uploads", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
    drop(files);
    std::fs::remove_file(&path).unwrap();
    let files = OutputFiles::open(
        config(dir.path()),
        transport(&base, dir.path(), "fixture-token"),
    )
    .await
    .unwrap();
    let replay = files
        .finalize_media(
            &scope(),
            &format!("Report ready.\nMEDIA:artifact://{}", handle.artifact_id),
        )
        .await
        .unwrap();
    assert_eq!(replay.attachments, first.attachments);
    assert_eq!(files.pending_events(&scope()).await.unwrap().len(), 4);
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM attachments", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}

#[tokio::test]
async fn orphan_snapshots_count_toward_quota_and_record_limits() {
    use std::os::unix::fs::OpenOptionsExt;
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = config(dir.path());
    cfg.max_spool_bytes = 20 * 1024 * 1024;
    cfg.max_records = 1;
    let files = OutputFiles::open(cfg, transport(&server.base, dir.path(), "fixture-token"))
        .await
        .unwrap();
    let leftover = dir.path().join("spool/.part-crash-leftover");
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&leftover)
        .unwrap();
    file.set_len(20 * 1024 * 1024).unwrap();
    drop(file);
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"hello").unwrap();
    assert!(
        files
            .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
            .await
            .unwrap_err()
            .to_string()
            .contains("quota")
    );
    assert!(leftover.exists());
    std::fs::remove_file(&leftover).unwrap();
    let first = files
        .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
        .await
        .unwrap();
    assert!(
        files
            .register_tool_artifact(&scope(), "tool-2", &path, None, "text/plain")
            .await
            .unwrap_err()
            .to_string()
            .contains("full")
    );
    assert_eq!(
        files
            .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
            .await
            .unwrap(),
        first
    );
}

#[tokio::test]
async fn one_writer_and_preflight_prevent_duplicate_or_partial_uploads() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    assert!(
        OutputFiles::open(
            config(dir.path()),
            transport(&server.base, dir.path(), "fixture-token")
        )
        .await
        .is_err()
    );
    let mut other_database = config(dir.path());
    other_database.database = dir.path().join("other.db");
    assert!(
        OutputFiles::open(
            other_database,
            transport(&server.base, dir.path(), "fixture-token")
        )
        .await
        .is_err()
    );
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"hello").unwrap();
    let first = files
        .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
        .await
        .unwrap();
    std::fs::write(&path, b"newer").unwrap();
    let latest = files
        .register_tool_artifact(&scope(), "tool-2", &path, None, "text/plain")
        .await
        .unwrap();
    assert_eq!(
        files
            .resolve_media(&scope(), path.to_str().unwrap())
            .await
            .unwrap(),
        latest
    );
    let body = format!(
        "MEDIA:artifact://{}\nMEDIA:/not-authorized.txt",
        first.artifact_id
    );
    assert!(files.finalize_media(&scope(), &body).await.is_err());
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 0);
    drop(files);
    assert!(
        OutputFiles::open(
            config(dir.path()),
            transport(&server.base, dir.path(), "fixture-token")
        )
        .await
        .is_ok()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn automatic_root_exports_reject_hardlinks_and_keep_root_descriptor() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("export");
    std::fs::create_dir(&root).unwrap();
    let outside = dir.path().join("outside.txt");
    std::fs::write(&outside, b"outside fixture").unwrap();
    std::fs::hard_link(&outside, root.join("hardlink.txt")).unwrap();
    std::fs::write(root.join("inside.txt"), b"original root").unwrap();
    let mut cfg = config(dir.path());
    cfg.artifact_roots.push(root.clone());
    let files = OutputFiles::open(cfg, transport(&server.base, dir.path(), "fixture-token"))
        .await
        .unwrap();
    assert!(
        files
            .resolve_media(&scope(), root.join("hardlink.txt").to_str().unwrap())
            .await
            .is_err()
    );
    std::fs::rename(&root, dir.path().join("renamed-root")).unwrap();
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("inside.txt"), b"replacement root").unwrap();
    let handle = files
        .resolve_media(&scope(), root.join("inside.txt").to_str().unwrap())
        .await
        .unwrap();
    files.upload(&scope(), &handle.artifact_id).await.unwrap();
    let bodies = server.state.bodies.lock().unwrap();
    let body = &bodies[0];
    let begin = body.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    let end = body.windows(4).rposition(|w| w == b"\r\n--").unwrap();
    assert_eq!(&body[begin..end], b"original root");
}

#[tokio::test]
async fn verified_transport_refuses_changed_snapshot_before_http() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"changed").unwrap();
    let t = transport(&server.base, dir.path(), "fixture-token");
    assert!(
        t.upload_verified_file(
            &scope().conversation_id,
            &path,
            None,
            "text/plain",
            "snapshot-verification",
            &"0".repeat(64)
        )
        .await
        .is_err()
    );
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn media_markdown_wrappers_and_long_code_fences_are_safe() {
    let body = "**MEDIA:/tmp/report.txt**\n_MEDIA:\"/tmp/spaced report.txt\"_\n````\n```\nMEDIA:/tmp/secret.txt\n````\nNOTMEDIA:/tmp/not-a-directive.txt\n\\MEDIA:/tmp/escaped.txt\n    MEDIA:/tmp/indented-code.txt\n";
    let markers = parse_media_markers(body);
    assert_eq!(markers.len(), 2, "{markers:?}");
    assert_eq!(
        &body[markers[0].start..markers[0].end],
        "**MEDIA:/tmp/report.txt**"
    );
    assert_eq!(
        &body[markers[1].start..markers[1].end],
        "_MEDIA:\"/tmp/spaced report.txt\"_"
    );
}

#[tokio::test]
async fn lost_snapshot_does_not_erase_prior_remote_uncertainty() {
    let server = server().await;
    server.state.invalid_first.store(true, Ordering::SeqCst);
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"original").unwrap();
    let artifact = files
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    assert!(matches!(
        files.upload(&scope(), &artifact.artifact_id).await.unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    std::fs::remove_file(
        dir.path()
            .join("spool")
            .join(format!("{}.bin", artifact.artifact_id)),
    )
    .unwrap();
    assert!(matches!(
        files
            .reconcile_upload(&scope(), &artifact.artifact_id)
            .await
            .unwrap(),
        UploadOutcome::OutcomeUnknown { .. }
    ));
    assert!(matches!(
        files
            .outcome(&scope(), &artifact.artifact_id)
            .await
            .unwrap(),
        Some(UploadOutcome::OutcomeUnknown { .. })
    ));
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 1);
    assert_eq!(server.state.stored.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn final_binding_is_exact_durable_and_only_successful_ack_allows_cleanup() {
    let server = server().await;
    let dir = tempfile::tempdir().unwrap();
    let files = service(&server, dir.path()).await;
    let path = dir.path().join("report.txt");
    std::fs::write(&path, b"first").unwrap();
    let first = files
        .register_tool_artifact(&scope(), "tool-1", &path, None, "text/plain")
        .await
        .unwrap();
    assert!(
        files
            .bind_final(
                "final-1",
                &scope(),
                std::slice::from_ref(&first.artifact_id)
            )
            .await
            .is_err()
    );
    files.upload(&scope(), &first.artifact_id).await.unwrap();
    std::fs::write(&path, b"second").unwrap();
    let second = files
        .register_tool_artifact(&scope(), "tool-2", &path, None, "text/plain")
        .await
        .unwrap();
    files.upload(&scope(), &second.artifact_id).await.unwrap();
    files
        .bind_final(
            "final-1",
            &scope(),
            std::slice::from_ref(&first.artifact_id),
        )
        .await
        .unwrap();
    files
        .bind_final(
            "final-1",
            &scope(),
            std::slice::from_ref(&first.artifact_id),
        )
        .await
        .unwrap();
    assert!(
        files
            .bind_final(
                "final-1",
                &scope(),
                std::slice::from_ref(&second.artifact_id)
            )
            .await
            .is_err()
    );
    let other = OutputScope {
        input_id: "other-turn".into(),
        ..scope()
    };
    assert!(
        files
            .bind_final(
                "final-other",
                &other,
                std::slice::from_ref(&first.artifact_id)
            )
            .await
            .is_err()
    );
    for event in files.pending_events_all().await.unwrap() {
        files
            .acknowledge_event(&event.scope, event.id)
            .await
            .unwrap();
    }
    assert_eq!(files.prune_delivered_before(i64::MAX).await.unwrap(), 0);
    drop(files);
    let files = service(&server, dir.path()).await;
    assert_eq!(
        files.pending_final_bindings(None).await.unwrap(),
        vec!["final-1"]
    );
    assert!(
        files
            .pending_final_bindings(Some("final-1"))
            .await
            .unwrap()
            .is_empty()
    );
    assert!(!files.ack_final("unrelated-ack").await.unwrap());
    assert!(files.ack_final("final-1").await.unwrap());
    assert!(files.ack_final("final-1").await.unwrap());
    assert!(files.pending_final_bindings(None).await.unwrap().is_empty());
    assert_eq!(files.prune_delivered_before(i64::MAX).await.unwrap(), 1);
    assert!(files.outcome(&scope(), &first.artifact_id).await.is_err());
    assert!(matches!(
        files.outcome(&scope(), &second.artifact_id).await.unwrap(),
        Some(UploadOutcome::Uploaded { .. })
    ));
    assert!(!files.ack_final("final-1").await.unwrap());
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn journal_epochs_do_not_reuse_artifact_ids_and_plain_body_stays_exact() {
    let server = server().await;
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let first = service(&server, a.path()).await;
    let second = service(&server, b.path()).await;
    let path = a.path().join("report.txt");
    std::fs::write(&path, b"same source").unwrap();
    let one = first
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    let two = second
        .register_tool_artifact(&scope(), "tool", &path, None, "text/plain")
        .await
        .unwrap();
    assert_ne!(one.artifact_id, two.artifact_id);
    let body = "  preserve whitespace without any directives\n\n";
    let final_text = first.finalize_media(&scope(), body).await.unwrap();
    assert_eq!(final_text.text, body);
    assert!(final_text.attachments.is_empty());
    assert!(final_text.artifacts.is_empty());
    assert_eq!(server.state.calls.load(Ordering::SeqCst), 0);
}
