use anyhow::Result;
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use hermes_rust_core::{ChatRequest, Core, Provider, Store};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
#[derive(Clone, Default)]
struct Seen(Arc<Mutex<Vec<(String, Value)>>>);
async fn primary(State(seen): State<Seen>, Json(payload): Json<Value>) -> Response {
    seen.0
        .lock()
        .unwrap()
        .push(("primary".into(), payload.clone()));
    if payload["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["role"] == "tool")
    {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    Json(json!({"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"write-once","type":"function","function":{"name":"memory","arguments":"{\"target\":\"user\",\"action\":\"add\",\"content\":\"User prefers concise answers\"}"}}]}}]})).into_response()
}
async fn fallback(State(seen): State<Seen>, Json(payload): Json<Value>) -> Json<Value> {
    seen.0
        .lock()
        .unwrap()
        .push(("fallback".into(), payload.clone()));
    assert!(
        payload["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["role"] == "tool")
    );
    Json(
        json!({"choices":[{"message":{"role":"assistant","content":"Saved once, continued with alternate model."}}]}),
    )
}
#[tokio::test]
async fn alternate_model_continues_after_known_tool_without_reexecuting_it() -> Result<()> {
    let seen = Seen::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let origin = format!("http://{}", listener.local_addr()?);
    let router = Router::new()
        .route("/primary", post(primary))
        .route("/fallback", post(fallback))
        .with_state(seen.clone());
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("state.sqlite");
    let provider = Provider::new(format!("{origin}/primary"), "primary".into(), None, false)?
        .with_fallbacks(vec![Provider::new(
            format!("{origin}/fallback"),
            "fallback".into(),
            None,
            false,
        )?])?;
    let core = Core::new(Store::open(&path)?, provider)
        .with_session_context("synthetic-owner".into(), Default::default())?;
    let answer = core
        .chat(ChatRequest {
            session_id: "route".into(),
            message: "Remember this preference".into(),
        })
        .await?;
    assert_eq!(answer.answer, "Saved once, continued with alternate model.");
    assert_eq!(
        Store::open(&path)?.memory("user")?,
        vec!["User prefers concise answers"]
    );
    assert_eq!(core.history("route".into()).await?.len(), 4);
    let calls = seen.0.lock().unwrap();
    assert_eq!(calls.len(), 3);
    assert_eq!(calls[1].1["messages"], calls[2].1["messages"]);
    assert_eq!(calls[1].1["tools"], calls[2].1["tools"]);
    task.abort();
    Ok(())
}
#[tokio::test]
async fn auth_failure_does_not_leak_prompt_to_alternate_route() -> Result<()> {
    let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let c = count.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let origin = format!("http://{}", listener.local_addr()?);
    let app = Router::new()
        .route("/primary", post(|| async { StatusCode::UNAUTHORIZED }))
        .route(
            "/fallback",
            post(move || {
                let c = c.clone();
                async move {
                    c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    StatusCode::OK
                }
            }),
        );
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let provider = Provider::new(format!("{origin}/primary"), "primary".into(), None, false)?
        .with_fallbacks(vec![Provider::new(
            format!("{origin}/fallback"),
            "fallback".into(),
            None,
            false,
        )?])?;
    assert!(
        provider
            .complete(&[json!({"role":"user","content":"hello"})])
            .await
            .is_err()
    );
    assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 0);
    task.abort();
    Ok(())
}

#[tokio::test]
async fn partial_stream_fails_over_without_mixed_preview_or_credential_reuse() -> Result<()> {
    use axum::http::HeaderMap;
    let captured = Seen::default();
    let seen = captured.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let origin = format!("http://{}", listener.local_addr()?);
    let app=Router::new()
        .route("/primary",post(|headers:HeaderMap,Json(body):Json<Value>|async move{
            assert_eq!(headers.get("authorization").unwrap(),"Bearer primary-only-secret");
            assert_eq!(body["stream"],true);
            let chunks = futures_util::stream::unfold(0, |step| async move {
                match step {
                    0 => Some((Ok::<_,std::io::Error>("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Unfinished primary prefix\"},\"finish_reason\":null}]}\n\n"),1)),
                    1 => {tokio::time::sleep(std::time::Duration::from_millis(50)).await;Some((Ok("data: invalid-json\n\n"),2))},
                    _ => None,
                }
            });
            ([("content-type","text/event-stream")],axum::body::Body::from_stream(chunks))
        }))
        .route("/alternate",post(move|headers:HeaderMap,Json(body):Json<Value>|{let seen=seen.clone();async move{
            assert!(headers.get("authorization").is_none());assert_eq!(body["stream"],false);
            seen.0.lock().unwrap().push(("alternate".into(),body));
            Json(json!({"choices":[{"message":{"role":"assistant","content":"Independent complete alternate answer."}}]}))
        }}));
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let provider = Provider::new(
        format!("{origin}/primary"),
        "primary".into(),
        Some("primary-only-secret".into()),
        false,
    )?
    .with_fallbacks(vec![Provider::new(
        format!("{origin}/alternate"),
        "alternate".into(),
        None,
        false,
    )?])?;
    let messages = vec![json!({"role":"user","content":"question"})];
    let (tx, mut rx) = tokio::sync::mpsc::channel(8);
    let result = provider
        .complete_with_tools(&messages, &[], Some(tx))
        .await?;
    assert_eq!(result["content"], "Independent complete alternate answer.");
    let mut fragments = Vec::new();
    while let Some(fragment) = rx.recv().await {
        fragments.push(fragment);
    }
    assert_eq!(fragments, vec!["Unfinished primary prefix"]);
    assert_eq!(captured.0.lock().unwrap()[0].1["messages"], json!(messages));
    task.abort();
    Ok(())
}
