use axum::{
    Json, Router,
    body::Body,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use hermes_rust_core::{
    attachments::{AttachmentConfig, AttachmentMetadata, AttachmentTransport},
    tool_runtime::{ToolExecutor, ToolRouter, TurnContext},
    vision_tools::{VisionConfig, VisionProviderConfig, VisionTools},
    workspace::ProtectedRoot,
};
use image::{DynamicImage, GenericImageView, ImageFormat};
use serde_json::{Value, json};
use std::{
    io::Cursor,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Notify;

#[derive(Clone)]
struct Fixture {
    mode: Arc<Mutex<String>>,
    calls: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<(HeaderMap, Value)>>>,
    started: Arc<Notify>,
    pixels: Vec<u8>,
}
struct Server {
    url: String,
    state: Fixture,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn provider(
    State(s): State<Fixture>,
    headers: HeaderMap,
    Json(payload): Json<Value>,
) -> Response {
    s.calls.fetch_add(1, Ordering::SeqCst);
    s.requests.lock().unwrap().push((headers, payload));
    s.started.notify_one();
    let mode = s.mode.lock().unwrap().clone();
    match mode.as_str() {
        "slow"=>{tokio::time::sleep(Duration::from_secs(60)).await;Json(json!({"choices":[{"message":{"content":"late"}}]})).into_response()},
        "empty"=>Json(json!({"choices":[{"message":{"content":""}}]})).into_response(),
        "error"=>Json(json!({"error":{"message":"super-secret-key"}})).into_response(),
        "status"=>(StatusCode::BAD_REQUEST,"super-secret-key").into_response(),
        "json"=>(StatusCode::OK,"not JSON super-secret-key").into_response(),
        "large"=>Json(json!({"choices":[{"message":{"content":"a".repeat(8192)}}]})).into_response(),
        "chunked"=>Response::new(Body::from_stream(futures_util::stream::iter((0..10).map(|_|Ok::<_,std::io::Error>(vec![b'a';1024]))))),
        "redirect"=>(StatusCode::TEMPORARY_REDIRECT,[("location","/unexpected")],"redirect").into_response(),
        "parts"=>Json(json!({"choices":[{"message":{"content":[{"type":"text","text":"red square"},{"type":"text","text":"two parts"}]}}]})).into_response(),
        "secret"=>Json(json!({"choices":[{"message":{"content":"super-secret-key was echoed"}}]})).into_response(),
        _=>Json(json!({"choices":[{"message":{"content":"A red image. The requested crop is visible."}}]})).into_response(),
    }
}
fn pixels(w: u32, h: u32) -> Vec<u8> {
    let img = DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
        w,
        h,
        image::Rgba([255, 0, 0, 255]),
    ));
    let mut bytes = Cursor::new(Vec::new());
    img.write_to(&mut bytes, ImageFormat::Png).unwrap();
    bytes.into_inner()
}
fn data(bytes: &[u8]) -> String {
    format!("data:image/png;base64,{}", STANDARD.encode(bytes))
}
async fn server() -> Server {
    let state = Fixture {
        mode: Arc::new(Mutex::new("ok".into())),
        calls: Arc::new(AtomicUsize::new(0)),
        requests: Arc::new(Mutex::new(vec![])),
        started: Arc::new(Notify::new()),
        pixels: pixels(40, 20),
    };
    let app = Router::new()
        .route("/vision", post(provider))
        .route(
            "/api/v1/attachments/{id}/download",
            get(|State(s): State<Fixture>, h: HeaderMap| async move {
                assert_eq!(h["authorization"], "Bearer orialis-only-key");
                s.pixels
            }),
        )
        .route(
            "/unexpected",
            post(|| async {
                panic!("redirect must not be followed");
                #[allow(unreachable_code)]
                "bad"
            }),
        )
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Server { url, state, task }
}
fn config(s: &Server) -> VisionConfig {
    let mut c = VisionConfig::new("owner-a".into());
    c.provider = Some(VisionProviderConfig {
        endpoint: format!("{}/vision", s.url),
        model: "explicit-vision-model".into(),
        api_key: Some("super-secret-key".into()),
    });
    c
}
fn context(input: &str, session: &str) -> TurnContext {
    TurnContext {
        conversation_id: "conversation-a".into(),
        input_id: input.into(),
        session_id: session.into(),
    }
}
fn args() -> Value {
    json!({"image_url":data(&pixels(40,20)),"question":"What is this?"})
}

#[tokio::test]
async fn real_provider_receives_pixels_and_only_explicit_credentials() {
    let s = server().await;
    let tools = VisionTools::new(config(&s)).unwrap();
    let ctx = context("i", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let router = ToolRouter::new(vec![Arc::new(tools.clone())]).unwrap();
    assert!(router.contains("vision_analyze"));
    let result = router
        .execute("vision_analyze", args(), &ctx)
        .await
        .unwrap();
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["native_vision"], false);
    assert!(result.get("_multimodal").is_none());
    assert!(!result.to_string().contains("base64"));
    let requests = s.state.requests.lock().unwrap();
    let (headers, body) = &requests[0];
    assert_eq!(headers["authorization"], "Bearer super-secret-key");
    assert!(headers.get("x-orialis-device-id").is_none());
    assert_eq!(body["model"], "explicit-vision-model");
    let embedded = body["messages"][1]["content"][1]["image_url"]["url"]
        .as_str()
        .unwrap();
    assert!(embedded.starts_with("data:image/png;base64,"));
    let image = image::load_from_memory(
        &STANDARD
            .decode(embedded.split_once(',').unwrap().1)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(image.dimensions(), (40, 20));
    assert_eq!(image.to_rgb8().get_pixel(0, 0).0, [255, 0, 0]);
}
#[tokio::test]
async fn crop_clamps_before_resize_and_reports_original_coordinates() {
    let s = server().await;
    let mut cfg = config(&s);
    cfg.max_dimension = 10;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("crop", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let result = tools
        .analyze(
            json!({"image_url":data(&pixels(40,20)),"question":"detail","region":[-3,2,20,14]}),
            &ctx,
        )
        .await;
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["meta"]["original_size"], json!([40, 20]));
    assert_eq!(result["meta"]["crop"], json!([0, 2, 20, 14]));
    assert_eq!(result["meta"]["sent_size"], json!([10, 6]));
}
#[tokio::test]
async fn missing_configuration_and_wrong_owner_or_session_fail_closed() {
    let disabled = VisionTools::new(VisionConfig::new("a".into())).unwrap();
    assert!(disabled.schemas().is_empty());
    assert_eq!(
        disabled.analyze(args(), &context("x", "s")).await["success"],
        false
    );
    let s = server().await;
    let tools = VisionTools::new(config(&s)).unwrap();
    let ctx = context("auth", "s");
    assert!(tools.authorize_turn("owner-b", &ctx, &[]).is_err());
    assert!(
        tools
            .authorize_turn("owner-a", &TurnContext::default(), &[])
            .is_err()
    );
    let guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    assert!(tools.authorize_turn("owner-a", &ctx, &[]).is_err());
    assert_eq!(
        tools
            .analyze(args(), &context("auth", "other-session"))
            .await["success"],
        false
    );
    drop(guard);
    assert_eq!(tools.analyze(args(), &ctx).await["success"], false);
    assert_eq!(s.state.calls.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn schema_args_and_unsafe_sources_are_rejected_before_provider() {
    let s = server().await;
    let tools = VisionTools::new(config(&s)).unwrap();
    let ctx = context("bad", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let invalid = vec![
        json!({}),
        json!({"image_url":"","question":"q"}),
        json!({"image_url":data(&pixels(2,2)),"question":""}),
        json!({"image_url":data(&pixels(2,2)),"question":"q","owner":"owner-a"}),
        json!({"image_url":data(&pixels(2,2)),"question":"q","region":[0,0,1]}),
        json!({"image_url":data(&pixels(2,2)),"question":"q","region":[0,0,true,1]}),
        json!({"image_url":data(&pixels(2,2)),"question":"q","region":[2,2,1,1]}),
    ];
    for args in invalid {
        assert_eq!(
            tools.analyze(args.clone(), &ctx).await["success"],
            false,
            "{args}"
        );
    }
    for source in [
        "/etc/passwd",
        "file:///etc/passwd",
        "../secret.png",
        "workspace:.env",
        "attachment:unregistered",
        "s3://bucket/a.png",
        "http://127.0.0.1/a",
        "http://[::1]/a",
        "http://2130706433/a",
        "http://169.254.169.254/a",
        "http://192.168.1.1/a",
        "http://metadata.google.internal/a",
        "http://example.local/a",
        "https://user:pass@example.com/a",
        "https://example.com/a?token=secret",
        "data:image/png;base64,%%%",
        "data:image/svg+xml;base64,PHN2Zy8+",
        "data:image/png,hello",
    ] {
        let result = tools
            .analyze(json!({"image_url":source,"question":"q"}), &ctx)
            .await;
        assert_eq!(result["success"], false, "{source}: {result}");
    }
    assert_eq!(s.state.calls.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn malformed_truncated_empty_and_pixel_bomb_inputs_fail() {
    let s = server().await;
    let mut cfg = config(&s);
    cfg.max_pixels = 100;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("decode", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let mut truncated = pixels(5, 5);
    truncated.truncate(truncated.len() / 2);
    for bytes in [vec![], b"not an image".to_vec(), truncated, pixels(20, 20)] {
        let result = tools
            .analyze(json!({"image_url":data(&bytes),"question":"q"}), &ctx)
            .await;
        assert_eq!(result["success"], false, "{result}");
    }
    assert_eq!(s.state.calls.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn provider_errors_empty_response_and_overflow_are_not_successes_or_retried() {
    let s = server().await;
    let mut cfg = config(&s);
    cfg.max_response_bytes = 1024;
    let tools = VisionTools::new(cfg).unwrap();
    for (n, mode) in [
        "empty", "error", "status", "json", "large", "chunked", "redirect",
    ]
    .iter()
    .enumerate()
    {
        *s.state.mode.lock().unwrap() = mode.to_string();
        let ctx = context(&format!("mode-{n}"), &format!("s-{n}"));
        let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
        let result = tools.analyze(args(), &ctx).await;
        assert_eq!(result["success"], false, "{mode}: {result}");
        assert!(!result.to_string().contains("super-secret-key"));
        assert_eq!(s.state.calls.load(Ordering::SeqCst), n + 1);
    }
}
#[tokio::test]
async fn provider_text_parts_and_secret_echo_redaction() {
    let s = server().await;
    let tools = VisionTools::new(config(&s)).unwrap();
    for mode in ["parts", "secret"] {
        *s.state.mode.lock().unwrap() = mode.into();
        let ctx = context(mode, mode);
        let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
        let result = tools.analyze(args(), &ctx).await;
        assert_eq!(result["success"], true, "{result}");
        assert!(!result.to_string().contains("super-secret-key"));
        if mode == "parts" {
            assert_eq!(result["analysis"], "red square\ntwo parts");
        }
    }
}
#[tokio::test]
async fn dedup_and_session_repeat_limits_cover_crops_and_different_questions() {
    let s = server().await;
    let mut cfg = config(&s);
    cfg.max_calls_per_image = 2;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("dedup", "s");
    let guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    assert_eq!(tools.analyze(args(), &ctx).await["success"], true);
    assert_eq!(tools.analyze(args(), &ctx).await["success"], false);
    let mut crop = args();
    crop["region"] = json!([0, 0, 10, 10]);
    assert_eq!(tools.analyze(crop, &ctx).await["success"], true);
    let mut other = args();
    other["question"] = json!("different");
    assert_eq!(tools.analyze(other, &ctx).await["success"], false);
    drop(guard);
    let ctx2 = context("next", "s");
    let guard2 = tools.authorize_turn("owner-a", &ctx2, &[]).unwrap();
    assert_eq!(tools.analyze(args(), &ctx2).await["success"], false);
    drop(guard2);
    let ctx3 = context("next", "new-session");
    let _guard3 = tools.authorize_turn("owner-a", &ctx3, &[]).unwrap();
    assert_eq!(tools.analyze(args(), &ctx3).await["success"], true);
    assert_eq!(s.state.calls.load(Ordering::SeqCst), 3);
}
#[tokio::test]
async fn guard_drop_cancels_inflight_and_releases_failed_reservation() {
    let s = server().await;
    *s.state.mode.lock().unwrap() = "slow".into();
    let mut cfg = config(&s);
    cfg.max_calls_per_image = 1;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("cancel", "s");
    let guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let t = tools.clone();
    let c = ctx.clone();
    let job = tokio::spawn(async move { t.analyze(args(), &c).await });
    s.state.started.notified().await;
    assert_eq!(tools.analyze(args(), &ctx).await["success"], false);
    drop(guard);
    let result = tokio::time::timeout(Duration::from_secs(1), job)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result["success"], false);
    assert!(result["error"].as_str().unwrap().contains("cancelled"));
    *s.state.mode.lock().unwrap() = "ok".into();
    let ctx2 = context("retry-explicit", "s");
    let _guard2 = tools.authorize_turn("owner-a", &ctx2, &[]).unwrap();
    assert_eq!(tools.analyze(args(), &ctx2).await["success"], true);
}
#[tokio::test]
async fn aborted_future_releases_pending_dedup_and_budget() {
    let s = server().await;
    *s.state.mode.lock().unwrap() = "slow".into();
    let mut cfg = config(&s);
    cfg.max_calls_per_image = 1;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("abort", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let t = tools.clone();
    let c = ctx.clone();
    let job = tokio::spawn(async move { t.analyze(args(), &c).await });
    s.state.started.notified().await;
    job.abort();
    assert!(job.await.unwrap_err().is_cancelled());
    *s.state.mode.lock().unwrap() = "ok".into();
    assert_eq!(tools.analyze(args(), &ctx).await["success"], true);
}
#[tokio::test]
async fn timeout_and_turn_budget_are_bounded() {
    let s = server().await;
    *s.state.mode.lock().unwrap() = "slow".into();
    let mut cfg = config(&s);
    cfg.timeout = Duration::from_millis(100);
    cfg.download_timeout = cfg.timeout;
    cfg.max_turn_images = 1;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("limit", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    assert_eq!(tools.analyze(args(), &ctx).await["success"], false);
    *s.state.mode.lock().unwrap() = "ok".into();
    assert_eq!(tools.analyze(args(), &ctx).await["success"], true);
    let mut new = args();
    new["image_url"] = json!(data(&pixels(2, 2)));
    assert_eq!(tools.analyze(new, &ctx).await["success"], false);
}
#[tokio::test]
async fn confined_workspace_rejects_traversal_symlinks_and_unconfigured_reads() {
    let s = server().await;
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("image.png"), pixels(2, 2)).unwrap();
    std::fs::write(dir.path().join(".env"), pixels(2, 2)).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(dir.path().join("image.png"), dir.path().join("link.png")).unwrap();
    let tools =
        VisionTools::with_root(config(&s), Some(ProtectedRoot::new(dir.path()).unwrap())).unwrap();
    let ctx = context("workspace", "s");
    let _guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let result = tools
        .analyze(
            json!({"image_url":"workspace:image.png","question":"color?"}),
            &ctx,
        )
        .await;
    assert_eq!(result["success"], true, "{result}");
    for source in [
        "workspace:../image.png",
        "workspace:/etc/passwd",
        "workspace:.env",
        "workspace:link.png",
    ] {
        assert_eq!(
            tools
                .analyze(json!({"image_url":source,"question":"q"}), &ctx)
                .await["success"],
            false,
            "{source}"
        );
    }
}
#[tokio::test]
async fn verified_attachment_aliases_are_bound_to_exact_turn_and_not_provider_credentials() {
    let s = server().await;
    let dir = tempfile::tempdir().unwrap();
    let transport = AttachmentTransport::new(AttachmentConfig::new(
        s.url.clone(),
        "device".into(),
        "orialis-only-key".into(),
        dir.path().join("cache"),
    ))
    .unwrap()
    .with_verified_owner_scope("owner-a".into())
    .unwrap();
    let metadata = AttachmentMetadata {
        id: "a1".into(),
        name: "image.png".into(),
        mime_type: "image/png".into(),
        size: Some(s.state.pixels.len() as u64),
        download_url: format!("{}/api/v1/attachments/a1/download", s.url),
    };
    let cached = transport
        .fetch_message(
            "conversation-a",
            "attachment-turn",
            std::slice::from_ref(&metadata),
        )
        .await
        .unwrap();
    let tools = VisionTools::new(config(&s)).unwrap();
    let ctx = context("attachment-turn", "s");
    let guard = tools.authorize_turn("owner-a", &ctx, &cached).unwrap();
    assert_eq!(
        tools
            .analyze(json!({"image_url":"attachment:a1","question":"q"}), &ctx)
            .await["success"],
        true
    );
    let result = tools
        .analyze(
            json!({"image_url":metadata.download_url,"question":"q"}),
            &ctx,
        )
        .await;
    assert_eq!(result["success"], false, "alias must deduplicate: {result}");
    drop(guard);
    let next = context("next", "s");
    let _next_guard = tools.authorize_turn("owner-a", &next, &[]).unwrap();
    assert_eq!(
        tools
            .analyze(json!({"image_url":cached[0].path,"question":"q"}), &next)
            .await["success"],
        false
    );
    let requests = s.state.requests.lock().unwrap();
    assert!(!requests[0].1.to_string().contains("orialis-only-key"));
    assert_eq!(requests[0].0["authorization"], "Bearer super-secret-key");
}
#[test]
fn provider_settings_validate_without_leaking_secrets() {
    let mut cfg = VisionConfig::new("owner".into());
    cfg.provider = Some(VisionProviderConfig {
        endpoint: "https://example.com/v1/chat/completions?key=bad".into(),
        model: "m".into(),
        api_key: Some("super-secret-key".into()),
    });
    assert!(VisionTools::new(cfg.clone()).is_err());
    assert!(!format!("{cfg:?}").contains("super-secret-key"));
    cfg.provider.as_mut().unwrap().endpoint = "http://example.com/vision".into();
    assert!(VisionTools::new(cfg.clone()).is_err());
    cfg.provider.as_mut().unwrap().endpoint = "https://example.com/vision".into();
    cfg.provider.as_mut().unwrap().model = String::new();
    assert!(VisionTools::new(cfg).is_err());
}

#[tokio::test]
async fn host_prepare_turn_checks_attachment_scope_and_lease_cleanup() {
    let s = server().await;
    let dir = tempfile::tempdir().unwrap();
    let transport = AttachmentTransport::new(AttachmentConfig::new(
        s.url.clone(),
        "device".into(),
        "orialis-only-key".into(),
        dir.path().join("cache"),
    ))
    .unwrap()
    .with_verified_owner_scope("owner-a".into())
    .unwrap();
    let tools = VisionTools::new(config(&s))
        .unwrap()
        .with_transport(transport)
        .unwrap();
    let ctx = context("prepared", "s");
    let metadata = AttachmentMetadata {
        id: "a2".into(),
        name: "image.png".into(),
        mime_type: "image/png".into(),
        size: Some(s.state.pixels.len() as u64),
        download_url: format!("{}/api/v1/attachments/a2/download", s.url),
    };
    let user =
        hermes_rust_core::media_runtime::user_reference("describe", &[metadata], &ctx).unwrap();
    let mut wrong = user.clone();
    wrong[hermes_rust_core::media_runtime::MEDIA_FIELD]["conversation_id"] = json!("other");
    assert!(tools.prepare_turn(&ctx, &wrong).await.is_err());
    let lease = tools.prepare_turn(&ctx, &user).await.unwrap();
    assert_eq!(
        tools
            .analyze(json!({"image_url":"attachment:a2","question":"q"}), &ctx)
            .await["success"],
        true
    );
    drop(lease);
    assert_eq!(tools.analyze(args(), &ctx).await["success"], false);
}

#[tokio::test]
async fn genuine_core_roundtrip_automatically_binds_scheduled_style_empty_attachment_turn() {
    use hermes_rust_core::{ChatRequest, Core, Provider, Store};
    async fn main_model(Json(payload): Json<Value>) -> Json<Value> {
        assert!(
            payload["tools"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["function"]["name"] == "vision_analyze")
        );
        if let Some(tool) = payload["messages"]
            .as_array()
            .unwrap()
            .iter()
            .rev()
            .find(|v| v["role"] == "tool")
        {
            let content = tool["content"].as_str().unwrap();
            let result: Value = serde_json::from_str(content).unwrap();
            assert_eq!(result["success"], true, "{result}");
            assert_eq!(result["native_vision"], false);
            assert!(!content.contains("base64"));
            Json(
                json!({"choices":[{"message":{"role":"assistant","content":"The separately configured vision model describes a red image."}}]}),
            )
        } else {
            Json(
                json!({"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"vision-call","type":"function","function":{"name":"vision_analyze","arguments":"{\"image_url\":\"workspace:image.png\",\"question\":\"What color?\"}"}}]}}]}),
            )
        }
    }
    let aux = server().await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}/main", listener.local_addr().unwrap());
    let main_task = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/main", post(main_model)))
            .await
            .unwrap()
    });
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("image.png"), pixels(10, 10)).unwrap();
    let tools = VisionTools::with_root(config(&aux), Some(ProtectedRoot::new(dir.path()).unwrap()))
        .unwrap();
    let core = Core::new(
        Store::open(&dir.path().join("store.sqlite")).unwrap(),
        Provider::new(
            endpoint,
            "main-model".into(),
            Some("main-only-key".into()),
            false,
        )
        .unwrap(),
    )
    .with_tool_executors(vec![Arc::new(tools.clone())])
    .unwrap();
    let ctx = context("scheduled-input", "scheduled-session");
    let result = core
        .chat_with_context(
            ChatRequest {
                session_id: ctx.session_id.clone(),
                message: "Describe the scheduled image".into(),
            },
            ctx.clone(),
            None,
        )
        .await
        .unwrap();
    assert!(result.answer.contains("red image"));
    assert_eq!(aux.state.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        tools.analyze(args(), &ctx).await["success"],
        false,
        "Core must drop the turn lease on completion"
    );
    main_task.abort();
}

#[tokio::test]
async fn stale_guard_cannot_cancel_reauthorized_turn() {
    let s = server().await;
    let tools = VisionTools::new(config(&s)).unwrap();
    let ctx = context("same", "s");
    let first = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    tools.clear_turn(&ctx);
    let second = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    drop(first);
    assert_eq!(tools.analyze(args(), &ctx).await["success"], true);
    drop(second);
}

#[tokio::test]
async fn generation_advance_resets_image_budget_and_rejects_old_dispatch() {
    let s = server().await;
    let mut cfg = config(&s);
    cfg.max_calls_per_image = 1;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("before", "stable-route");
    tools
        .set_session_generation(&ctx.session_id, 0)
        .await
        .unwrap();
    let guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    assert_eq!(
        tools
            .execute_at_generation("vision_analyze", args(), &ctx, 0)
            .await
            .unwrap()["success"],
        true
    );
    drop(guard);
    tools
        .set_session_generation(&ctx.session_id, 1)
        .await
        .unwrap();
    let next = context("after", "stable-route");
    let guard = tools.authorize_turn("owner-a", &next, &[]).unwrap();
    assert_eq!(
        tools
            .execute_at_generation("vision_analyze", args(), &next, 0)
            .await
            .unwrap()["success"],
        false
    );
    assert_eq!(
        tools
            .execute_at_generation("vision_analyze", args(), &next, 1)
            .await
            .unwrap()["success"],
        true
    );
    tools
        .set_session_generation(&next.session_id, 0)
        .await
        .unwrap();
    assert_eq!(
        tools
            .execute_at_generation("vision_analyze", args(), &next, 0)
            .await
            .unwrap()["success"],
        false
    );
    drop(guard);
    assert_eq!(s.state.calls.load(Ordering::SeqCst), 2);
}
#[tokio::test]
async fn generation_reset_cancels_old_call_without_corrupting_same_context_new_epoch() {
    let s = server().await;
    *s.state.mode.lock().unwrap() = "slow".into();
    let mut cfg = config(&s);
    cfg.max_calls_per_image = 1;
    let tools = VisionTools::new(cfg).unwrap();
    let ctx = context("same-input", "stable-route");
    let old_guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    let t = tools.clone();
    let c = ctx.clone();
    let job = tokio::spawn(async move {
        t.execute_at_generation("vision_analyze", args(), &c, 0)
            .await
            .unwrap()
    });
    s.state.started.notified().await;
    tools
        .set_session_generation(&ctx.session_id, 1)
        .await
        .unwrap();
    let new_guard = tools.authorize_turn("owner-a", &ctx, &[]).unwrap();
    drop(old_guard);
    assert_eq!(job.await.unwrap()["success"], false);
    *s.state.mode.lock().unwrap() = "ok".into();
    assert_eq!(
        tools
            .execute_at_generation("vision_analyze", args(), &ctx, 1)
            .await
            .unwrap()["success"],
        true
    );
    drop(new_guard);
}
