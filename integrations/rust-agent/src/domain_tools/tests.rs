use super::*;
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Request, State},
    http::{Response, StatusCode},
    routing::any,
};
use std::{
    collections::VecDeque,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::task::JoinHandle;

#[derive(Clone, Debug)]
struct Captured {
    method: String,
    uri: String,
    auth: Option<String>,
    device: Option<String>,
    body: Value,
}
struct Reply {
    status: u16,
    body: Vec<u8>,
    location: Option<String>,
    stream: bool,
}
impl Reply {
    fn json(status: u16, body: Value) -> Self {
        Self {
            status,
            body: serde_json::to_vec(&body).unwrap(),
            location: None,
            stream: false,
        }
    }
}
#[derive(Default)]
struct FakeState {
    requests: Mutex<Vec<Captured>>,
    replies: Mutex<VecDeque<Reply>>,
    delay: u64,
    active: AtomicUsize,
    peak: AtomicUsize,
}
async fn handler(State(state): State<Arc<FakeState>>, request: Request) -> Response<Body> {
    let active = state.active.fetch_add(1, Ordering::SeqCst) + 1;
    state.peak.fetch_max(active, Ordering::SeqCst);
    let headers = request.headers();
    let captured = Captured {
        method: request.method().to_string(),
        uri: request.uri().to_string(),
        auth: headers
            .get("authorization")
            .map(|v| v.to_str().unwrap().into()),
        device: headers
            .get("x-orialis-device-id")
            .map(|v| v.to_str().unwrap().into()),
        body: Value::Null,
    };
    let bytes = to_bytes(request.into_body(), MAX_ARGUMENT_BYTES + 1024)
        .await
        .unwrap();
    let mut captured = captured;
    if !bytes.is_empty() {
        captured.body = serde_json::from_slice(&bytes).unwrap();
    }
    state.requests.lock().unwrap().push(captured);
    if state.delay > 0 {
        tokio::time::sleep(Duration::from_millis(state.delay)).await;
    }
    let reply = state
        .replies
        .lock()
        .unwrap()
        .pop_front()
        .unwrap_or_else(|| Reply::json(200, json!({"id":"saved","version":1})));
    let mut response = Response::builder()
        .status(StatusCode::from_u16(reply.status).unwrap())
        .header("content-type", "application/json");
    if let Some(location) = reply.location {
        response = response.header("Location", location);
    }
    let body = if reply.stream {
        let chunks: Vec<Result<Vec<u8>, std::io::Error>> =
            reply.body.chunks(4096).map(|b| Ok(b.to_vec())).collect();
        Body::from_stream(futures_util::stream::iter(chunks))
    } else {
        Body::from(reply.body)
    };
    state.active.fetch_sub(1, Ordering::SeqCst);
    response.body(body).unwrap()
}
struct Fake {
    state: Arc<FakeState>,
    url: String,
    task: JoinHandle<()>,
}
impl Drop for Fake {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fake {
    async fn new(replies: Vec<Reply>) -> Self {
        Self::with_delay(replies, 0).await
    }
    async fn with_delay(replies: Vec<Reply>, delay: u64) -> Self {
        let state = Arc::new(FakeState {
            replies: Mutex::new(replies.into()),
            delay,
            ..FakeState::default()
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/api/v1/agent/ws", listener.local_addr().unwrap());
        let app = Router::new()
            .fallback(any(handler))
            .with_state(state.clone());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self { state, url, task }
    }
    fn client(&self) -> DomainClient {
        DomainClient::new(
            &self.url,
            "User_Test_Hermes",
            "device-secret",
            Some("publisher-secret"),
        )
        .unwrap()
    }
    fn requests(&self) -> Vec<Captured> {
        self.state.requests.lock().unwrap().clone()
    }
}
fn create_args(kind: &str) -> Value {
    match kind {
        "task" => json!({"title":"Task"}),
        "project" => json!({"name":"Project"}),
        "milestone" => json!({"projectId":"p1","title":"Milestone"}),
        "schedule" => {
            json!({"title":"Meeting","startAt":"2030-01-02T09:00:00+08:00","endAt":"2030-01-02T10:00:00+08:00"})
        }
        "conversation" => json!({"title":"Chat"}),
        "message" => json!({"conversationId":"c1","content":"Hello"}),
        _ => unreachable!(),
    }
}
fn args_for(name: &str, route: Route) -> Value {
    let mut args = if route.method == "POST" {
        create_args(route.kind)
    } else {
        json!({})
    };
    if route.path.contains("{projectId}") {
        args["projectId"] = json!("p1");
    }
    if route.path.contains("{conversationId}") {
        args["conversationId"] = json!("c1");
    }
    if route.path.contains("{id}") {
        args["id"] = json!("item1");
    }
    if matches!(route.method, "PATCH" | "DELETE") {
        args["baseVersion"] = json!(3);
    }
    if name == "update_conversation" {
        args["title"] = json!("New title");
    }
    args
}

#[test]
fn inventory_is_complete_unique_and_matches_fixed_upstream() {
    assert_eq!(tool_names().len(), 39);
    let registered: HashSet<_> = tool_names().into_iter().collect();
    let exported: HashSet<_> = schemas()
        .into_iter()
        .map(|s| s["function"]["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(exported.len(), 39);
    assert!(registered.iter().all(|n| exported.contains(*n)));
    for name in registered {
        assert!(
            route(name).is_some()
                || batch_single(name).is_some()
                || matches!(name, "orialis_capabilities" | "news.publish")
        );
    }
    assert_eq!(
        schema("create_calendar_event").unwrap()["name"],
        "create_calendar_event"
    );
    assert_eq!(
        schema("list_tasks").unwrap()["parameters"]["properties"]["limit"]["maximum"],
        100
    );
    assert_eq!(
        schema("list_messages").unwrap()["parameters"]["properties"]["limit"]["maximum"],
        500
    );
}

#[tokio::test]
async fn every_single_tool_uses_real_route_method_and_scoped_headers() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    for name in tool_names() {
        let Some(route) = route(name) else {
            continue;
        };
        if matches!(name, "get_schedule" | "get_calendar_event") {
            continue;
        }
        let args = args_for(name, route);
        let result = client.execute(name, args.clone()).await;
        assert_eq!(result["ok"], true, "{name}: {result}");
        let request = fake.requests().pop().unwrap();
        assert_eq!(request.method, route.method, "{name}");
        assert_eq!(
            request.uri,
            route
                .path
                .replace("{projectId}", "p1")
                .replace("{conversationId}", "c1")
                .replace("{id}", "item1"),
            "{name}"
        );
        assert_eq!(request.auth.as_deref(), Some("Bearer device-secret"));
        assert_eq!(request.device.as_deref(), Some("User_Test_Hermes"));
        if route.method == "DELETE" {
            assert_eq!(request.body, json!({"baseVersion":3}));
        }
        if route.method == "GET" {
            assert_eq!(request.body, Value::Null);
        }
        if name == "create_schedule" {
            assert_eq!(result["schedule"]["id"], "saved");
            assert!(
                request.body["id"]
                    .as_str()
                    .is_some_and(|v| Uuid::parse_str(v).is_ok())
            );
        }
        if name == "create_calendar_event" {
            assert_eq!(result["result"]["id"], "saved");
        }
    }
}

#[tokio::test]
async fn pagination_query_and_paths_are_encoded_without_changing_origin() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    assert_eq!(
        client
            .execute(
                "list_messages",
                json!({"conversationId":"room/1?x=#@","after":"x&limit=500","limit":42})
            )
            .await["ok"],
        true
    );
    let request = fake.requests().pop().unwrap();
    assert_eq!(
        request.uri,
        "/api/v1/conversations/room%2F1%3Fx%3D%23%40/messages?after=x%26limit%3D500&limit=42"
    );
    assert_eq!(
        client
            .execute("get_project_summary", json!({"id":"%2e%2e/evil"}))
            .await["ok"],
        true
    );
    assert_eq!(
        fake.requests().pop().unwrap().uri,
        "/api/v1/projects/%252e%252e%2Fevil/summary"
    );
    let before = fake.requests().len();
    for id in [".", "..", "", " x", "x\n"] {
        assert_eq!(
            client
                .execute("get_project_summary", json!({"id":id}))
                .await["ok"],
            false
        );
    }
    assert_eq!(fake.requests().len(), before);
}

#[tokio::test]
async fn patches_preserve_nulls_and_creates_preserve_ids() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    for kind in ["task", "project", "schedule", "conversation", "message"] {
        let name = format!("create_{kind}");
        let mut args = create_args(kind);
        args["id"] = json!("stable-id");
        assert_eq!(client.execute(&name, args).await["ok"], true);
        assert_eq!(fake.requests().pop().unwrap().body["id"], "stable-id");
    }
    for (name, patch) in [
        (
            "update_task",
            json!({"id":"t","baseVersion":1,"projectId":null,"notes":null,"important":null,"recurrence":null,"manualPosition":null}),
        ),
        (
            "update_project",
            json!({"id":"p","baseVersion":2,"due":null,"nextActionTaskId":null,"description":null}),
        ),
        (
            "update_schedule",
            json!({"id":"s","baseVersion":3,"description":null,"location":null,"reminderMinutes":null}),
        ),
        (
            "update_milestone",
            json!({"id":"m","projectId":"p","baseVersion":4,"due":null}),
        ),
        (
            "update_conversation",
            json!({"id":"c","title":"Chat","baseVersion":5,"manualPosition":null}),
        ),
    ] {
        assert_eq!(client.execute(name, patch.clone()).await["ok"], true);
        let actual = fake.requests().pop().unwrap().body;
        for (k, v) in patch.as_object().unwrap() {
            if k != "id" && !(k == "projectId" && name == "update_milestone") {
                assert_eq!(actual[k], *v);
            }
        }
    }
}

#[tokio::test]
async fn schedule_reader_follows_collections_and_rejects_loops_and_malformed_pages() {
    for name in ["get_schedule", "get_calendar_event"] {
        let fake = Fake::new(vec![
            Reply::json(
                200,
                json!({"items":[{"id":"other"}],"hasMore":true,"nextCursor":"next+page"}),
            ),
            Reply::json(
                200,
                json!({"items":[{"id":"wanted","title":"Found"}],"hasMore":false}),
            ),
        ])
        .await;
        let result = fake.client().execute(name, json!({"id":"wanted"})).await;
        assert_eq!(result["result"]["title"], "Found");
        assert_eq!(fake.requests().len(), 2);
        assert!(
            fake.requests()[1]
                .uri
                .ends_with("?after=next%2Bpage&limit=100")
        );
    }
    for (pages, expected) in [
        (
            vec![json!({"items":[],"hasMore":false})],
            "Schedule not found",
        ),
        (
            vec![
                json!({"items":[],"hasMore":true,"nextCursor":"again"}),
                json!({"items":[],"hasMore":true,"nextCursor":"again"}),
            ],
            "invalid pagination cursor",
        ),
        (
            vec![json!({"items":[],"hasMore":true})],
            "invalid pagination cursor",
        ),
        (
            vec![json!({"wrong":[]})],
            "invalid schedule collection response",
        ),
        (
            vec![json!({"items":[]})],
            "invalid schedule pagination response",
        ),
    ] {
        let fake = Fake::new(pages.into_iter().map(|p| Reply::json(200, p)).collect()).await;
        assert_eq!(
            fake.client()
                .execute("get_schedule", json!({"id":"wanted"}))
                .await["error"],
            expected
        );
    }
}

#[tokio::test]
async fn every_batch_prevalidates_all_items_and_keeps_sequential_results() {
    for name in tool_names()
        .into_iter()
        .filter(|n| batch_single(n).is_some())
    {
        let fake = Fake::new(vec![
            Reply::json(201, json!({"id":"first"})),
            Reply::json(409, json!({"error":"conflict"})),
            Reply::json(201, json!({"id":"third"})),
        ])
        .await;
        let client = fake.client();
        let kind = route(batch_single(name).unwrap()).unwrap().kind;
        let args = create_args(kind);
        let result = client
            .execute(
                name,
                json!({"items":[args.clone(),args.clone(),args.clone()]}),
            )
            .await;
        assert_eq!(result["ok"], false, "{name}: {result}");
        assert_eq!(result["atomic"], false);
        assert_eq!(result["succeeded"], 2);
        assert_eq!(result["failed"], 1);
        assert_eq!(fake.requests().len(), 3);
        for i in 0..3 {
            assert_eq!(result["results"][i]["index"], i);
        }
        if kind != "milestone" {
            let ids: HashSet<_> = result["results"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["submitted"]["id"].as_str().unwrap())
                .collect();
            assert_eq!(ids.len(), 3);
            assert!(ids.into_iter().all(|id| Uuid::parse_str(id).is_ok()));
        }
        let before = fake.requests().len();
        let bad = client
            .execute(name, json!({"items":[args, {"unknown":"bad"}]}))
            .await;
        assert_eq!(bad["written"], 0);
        assert_eq!(bad["validationIndex"], 1);
        assert_eq!(fake.requests().len(), before);
    }
}

#[tokio::test]
async fn batch_duplicate_bounds_and_uncertain_post_are_not_retried() {
    let fake = Fake::new(vec![Reply::json(
        503,
        json!({"error":"already might have committed"}),
    )])
    .await;
    let client = fake.client();
    for args in [
        json!({"items":[]}),
        json!({"items":vec![json!({"title":"x"});201]}),
        json!({"items":[{"title":"x","id":"same"},{"title":"y","id":"same"}]}),
        json!({"items":[{"title":"x"}],"url":"https://evil.test"}),
    ] {
        assert_eq!(client.execute("create_tasks", args).await["written"], 0);
    }
    assert!(fake.requests().is_empty());
    let result = client
        .execute(
            "create_tasks",
            json!({"items":[{"id":"t1","title":"Task"}]}),
        )
        .await;
    assert_eq!(result["results"][0]["outcomeUnknown"], true);
    assert_eq!(result["results"][0]["submitted"]["id"], "t1");
    assert_eq!(fake.requests().len(), 1);
}

#[tokio::test]
async fn invalid_fields_types_dates_ranges_and_domain_invariants_never_write() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    let cases = vec![
        ("list_tasks", json!({"limit":101})),
        ("list_messages", json!({"conversationId":"c","limit":501})),
        ("list_tasks", json!({"after":{},"url":"https://evil.test"})),
        ("list_projects", json!({"status":"wrong"})),
        ("update_task", json!({"id":"t","title":"x"})),
        ("delete_task", json!({"id":"t","baseVersion":true})),
        ("delete_task", json!({"id":"t","baseVersion":0})),
        ("create_task", json!({"title":"x","important":1})),
        ("create_task", json!({"title":"x","due":"2030-02-30"})),
        ("create_task", json!({"title":"x","dueTime":"23:59"})),
        (
            "create_task",
            json!({"title":"x","due":"2030-01-01","dueTime":"24:00"}),
        ),
        ("create_task", json!({"title":"x","reminderMinutes":-1})),
        (
            "create_task",
            json!({"title":"x","completedAt":"2030-01-01T00:00:00Z"}),
        ),
        (
            "create_task",
            json!({"title":"x","id":"t","parentTaskId":"t"}),
        ),
        (
            "create_task",
            json!({"title":"x","parentTaskId":"p","scheduleId":"s"}),
        ),
        (
            "create_task",
            json!({"title":"x","recurrence":{"rule":"DAILY","until":"2030-01-01"}}),
        ),
        (
            "create_task",
            json!({"title":"x","recurrence":{"rule":"FREQ=WRONG","until":"2030-01-01"}}),
        ),
        ("create_project", json!({"name":"x","status":"bad"})),
        ("create_project", json!({"name":"x","nextActionTaskId":"t"})),
        (
            "create_milestone",
            json!({"projectId":"p","title":"m","position":-1}),
        ),
        (
            "create_conversation",
            json!({"title":"c","manualPosition":5}),
        ),
        (
            "create_message",
            json!({"conversationId":"c","content":" "}),
        ),
        (
            "create_message",
            json!({"conversationId":"c","content":"x","attachments":[{"id":"a","downloadUrl":"https://evil.test"}]}),
        ),
        (
            "create_schedule",
            json!({"title":"x","startAt":"2030-01-01T00:00:00","endAt":"2030-01-01T01:00:00Z"}),
        ),
        (
            "create_calendar_event",
            json!({"title":"x","startAt":"2030-01-01T00:00:00Z","endAt":"2030-01-01T00:00:00Z"}),
        ),
        (
            "update_schedule",
            json!({"id":"s","baseVersion":1,"description":"上午：摄影\n下午：校区参观"}),
        ),
        (
            "list_schedules",
            json!({"from":"2030-01-02T00:00:00Z","to":"2030-01-01T00:00:00Z"}),
        ),
        (
            "create_task",
            json!({"title":"x","userId":"another-account"}),
        ),
        (
            "create_task",
            json!({"title":"x","Authorization":"Bearer attacker"}),
        ),
        ("orialis_capabilities", json!({"url":"http://evil.test"})),
    ];
    for (name, args) in cases {
        let result = client.execute(name, args.clone()).await;
        assert_eq!(result["ok"], false, "{name} {args}: {result}");
    }
    assert!(fake.requests().is_empty());
}

#[test]
fn timestamps_compare_timezones_leap_days_and_subnanosecond_values() {
    assert!(date("2028-02-29", "date").is_ok());
    assert!(date("2027-02-29", "date").is_err());
    assert_eq!(
        instant("2030-01-01T09:00:00+08:00", "x").unwrap(),
        instant("2030-01-01T01:00:00Z", "x").unwrap()
    );
    assert!(
        instant("2030-01-01T01:00:00.0000000001Z", "x").unwrap()
            < instant("2030-01-01T01:00:00.0000000002Z", "x").unwrap()
    );
    assert!(instant("2030-01-01T01:00:00−01:00", "x").is_err());
    assert!(instant("2030-02-30T01:00:00Z", "x").is_err());
    assert!(validate_domain("schedule","POST",&json!({"startAt":"2030-01-01T23:00:00Z","endAt":"2030-01-02T08:00:00Z","description":"Continuous overnight train"})).is_ok());
}

#[test]
fn publisher_hashes_match_python_fixtures_including_unicode_and_floats() {
    let fixtures: Value =
        serde_json::from_str(include_str!("../../tests/fixtures/news_idempotency.json")).unwrap();
    for item in fixtures.as_array().unwrap() {
        let raw =
            json!(["github.daily",{"source":"githot.dev","result":item["arguments"]["result"]}]);
        let canonical = canonical_json(&raw).unwrap();
        let expected = item["canonical"].as_str().unwrap();
        if canonical != expected {
            let index = canonical
                .chars()
                .zip(expected.chars())
                .position(|(a, b)| a != b)
                .unwrap_or(0);
            panic!(
                "Python canonical mismatch at character {index}: rust {:?}, python {:?}",
                canonical
                    .chars()
                    .skip(index.saturating_sub(20))
                    .take(80)
                    .collect::<String>(),
                expected
                    .chars()
                    .skip(index.saturating_sub(20))
                    .take(80)
                    .collect::<String>()
            );
        }
        let (_, payload) = news_payload(item["arguments"].clone()).unwrap();
        assert_eq!(
            payload["idempotencyKey"], item["id"],
            "{}",
            item["canonical"]
        );
    }
}

#[tokio::test]
async fn all_news_datasets_use_separate_identity_fixed_routes_and_stable_ids() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    let cases = [
        (
            "aihot.hot",
            json!([]),
            "/api/v1/news/publish/aihot/hot",
            "aihot.news",
        ),
        (
            "aihot.items",
            json!([]),
            "/api/v1/news/publish/aihot/items",
            "aihot.news",
        ),
        (
            "aihot.events",
            json!({"publicId":"event"}),
            "/api/v1/news/publish/aihot/events",
            "aihot.news",
        ),
        (
            "aihot.reports.daily",
            json!({}),
            "/api/v1/news/publish/aihot/reports/daily",
            "aihot.news",
        ),
        (
            "aihot.reports.weekly",
            json!({}),
            "/api/v1/news/publish/aihot/reports/weekly",
            "aihot.news",
        ),
        (
            "aihot.reports.monthly",
            json!({}),
            "/api/v1/news/publish/aihot/reports/monthly",
            "aihot.news",
        ),
        (
            "github.daily",
            json!([]),
            "/api/v1/news/publish/github/daily",
            "githot.dev",
        ),
        (
            "github.weekly",
            json!({"repositories":[]}),
            "/api/v1/news/publish/github/weekly",
            "githot.dev",
        ),
        (
            "projects.daily",
            json!({}),
            "/api/v1/news/projects/publish",
            "orialis-project-report/hermes",
        ),
        (
            "projects.weekly",
            json!({}),
            "/api/v1/news/projects/publish",
            "orialis-project-report/hermes",
        ),
    ];
    for (dataset, result, path, source) in cases {
        let mut args = json!({"dataset":dataset,"result":result});
        if dataset.starts_with("projects.") {
            args["projectId"] = json!("p");
            args["reportDate"] = json!(if dataset.ends_with("weekly") {
                "2030-W01"
            } else {
                "2030-01-01"
            });
        }
        assert_eq!(
            client.execute("news.publish", args.clone()).await["ok"],
            true
        );
        let a = fake.requests().pop().unwrap();
        assert_eq!(a.uri, path);
        assert_eq!(a.method, "POST");
        assert_eq!(a.auth.as_deref(), Some("Bearer publisher-secret"));
        assert_eq!(a.device, None);
        assert_eq!(a.body["source"], source);
        assert!(a.body.get("userId").is_none());
        assert_eq!(client.execute("news.publish", args).await["ok"], true);
        assert_eq!(
            a.body["idempotencyKey"],
            fake.requests().pop().unwrap().body["idempotencyKey"]
        );
    }
}

#[tokio::test]
async fn news_validation_and_missing_separate_credentials_never_write() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    for args in [
        json!({"dataset":"../../tasks","result":{}}),
        json!({"dataset":"aihot.hot","result":{}}),
        json!({"dataset":"aihot.events","result":{}}),
        json!({"dataset":"github.daily","result":{"items":{}}}),
        json!({"dataset":"projects.daily","result":{},"reportDate":"2030-02-30"}),
        json!({"dataset":"projects.weekly","result":{},"reportDate":"2030-W54"}),
        json!({"dataset":"aihot.hot","result":[],"projectId":"p"}),
        json!({"dataset":"aihot.hot","result":[],"userId":"other"}),
        json!({"dataset":"aihot.hot","result":[],"generatedAt":"2030-01-01T00:00:00"}),
        json!({"dataset":"aihot.hot","result":["x".repeat(MAX_NEWS_RESULT_BYTES)]}),
    ] {
        assert_eq!(client.execute("news.publish", args).await["ok"], false);
    }
    let no_publisher =
        DomainClient::new(&fake.url, "User_Test_Hermes", "device-secret", None).unwrap();
    let result = no_publisher
        .execute("news.publish", json!({"dataset":"aihot.hot","result":[]}))
        .await;
    assert!(
        result["error"]
            .as_str()
            .unwrap()
            .contains("ORIALIS_NEWS_PUBLISHER_TOKEN")
    );
    let no_device =
        DomainClient::new(&fake.url, "User_Test_Hermes", "", Some("publisher-secret")).unwrap();
    assert_eq!(
        no_device.execute("list_tasks", json!({})).await["ok"],
        false
    );
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn capabilities_discovery_preserves_contract_and_scrubs_url_secrets() {
    let fake = Fake::new(vec![Reply::json(
        200,
        json!({"api_version":"v1","capabilities":["tasks"],"response_ui":{"version":1}}),
    )])
    .await;
    let client = DomainClient::new(
        &format!("{}?token=do-not-show", fake.url),
        "User_Test_Hermes",
        "",
        None,
    )
    .unwrap();
    let result = client.execute("orialis_capabilities", json!({})).await;
    assert_eq!(result["ok"], true);
    assert_eq!(result["plugin"]["tools"].as_array().unwrap().len(), 39);
    assert_eq!(result["server"]["api_version"], "v1");
    assert_eq!(result["server"]["response_ui"]["version"], 1);
    assert!(!result.to_string().contains("do-not-show"));
    assert!(fake.requests()[0].auth.is_none());
    assert_eq!(fake.requests()[0].uri, "/api/v1/capabilities");
}

#[tokio::test]
async fn redirects_are_not_followed_and_credentials_never_cross_origin() {
    let target = Fake::new(vec![]).await;
    for status in [301, 302, 303, 307, 308] {
        let fake = Fake::new(vec![Reply {
            status,
            body: vec![],
            location: Some(target.url.replace("ws://", "http://")),
            stream: false,
        }])
        .await;
        let result = fake
            .client()
            .execute("create_task", json!({"title":"x"}))
            .await;
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], status);
        assert_eq!(fake.requests().len(), 1);
    }
    assert!(target.requests().is_empty());
}

#[tokio::test]
async fn status_body_limits_invalid_json_and_mutation_uncertainty() {
    for (reply, method, args, unknown) in [
        (
            Reply::json(401, json!({"error":"secret echoed device-secret"})),
            "list_tasks",
            json!({}),
            false,
        ),
        (
            Reply::json(409, json!({"error":"conflict"})),
            "update_task",
            json!({"id":"t","baseVersion":1}),
            false,
        ),
        (
            Reply::json(500, json!({"error":"failed"})),
            "delete_task",
            json!({"id":"t","baseVersion":1}),
            true,
        ),
        (
            Reply {
                status: 200,
                body: b"not JSON".to_vec(),
                location: None,
                stream: false,
            },
            "create_task",
            json!({"title":"x"}),
            true,
        ),
        (
            Reply {
                status: 200,
                body: vec![b'x'; MAX_RESPONSE_BYTES + 1],
                location: None,
                stream: false,
            },
            "create_task",
            json!({"title":"x"}),
            true,
        ),
        (
            Reply {
                status: 200,
                body: vec![b'x'; MAX_RESPONSE_BYTES + 1],
                location: None,
                stream: true,
            },
            "list_tasks",
            json!({}),
            false,
        ),
    ] {
        let fake = Fake::new(vec![reply]).await;
        let result = fake.client().execute(method, args).await;
        assert_eq!(result["ok"], false);
        assert_eq!(result["outcomeUnknown"], unknown);
        assert!(!result.to_string().contains("device-secret"));
        assert_eq!(fake.requests().len(), 1);
    }
    let fake = Fake::new(vec![Reply {
        status: 204,
        body: vec![],
        location: None,
        stream: false,
    }])
    .await;
    assert_eq!(
        fake.client()
            .execute("delete_task", json!({"id":"t","baseVersion":1}))
            .await,
        json!({"ok":true,"status":204})
    );
}

#[test]
fn url_and_credentials_reject_unsafe_config_and_debug_never_contains_tokens() {
    for url in [
        "file:///etc/passwd",
        "ftp://example.test",
        "/api/v1/tasks",
        "http://user:password@example.test/",
        "https://example.test/#token",
    ] {
        assert!(DomainClient::new(url, "User_Test_Hermes", "secret", None).is_err());
    }
    assert!(
        DomainClient::new(
            "http://example.test",
            "User_Test_Hermes",
            "secret\r\nX-Injected: x",
            None
        )
        .is_err()
    );
    assert!(DomainClient::new("http://example.test", "x\r\n", "secret", None).is_err());
    let client = DomainClient::new(
        "wss://example.test/path?token=hidden",
        "User_Test_Hermes",
        "secret",
        Some("other-secret"),
    )
    .unwrap();
    assert_eq!(client.origin.as_str(), "https://example.test/");
    let debug = format!("{client:?}");
    assert!(!debug.contains("secret"));
    assert!(!debug.contains("hidden"));
}

#[tokio::test]
async fn shared_client_limits_concurrency_without_serializing_independent_calls() {
    let fake = Fake::with_delay(vec![], 50).await;
    let client = fake.client();
    let mut tasks = vec![];
    for _ in 0..12 {
        let client = client.clone();
        tasks.push(tokio::spawn(async move {
            client.execute("list_tasks", json!({})).await
        }));
    }
    for task in tasks {
        assert_eq!(task.await.unwrap()["ok"], true);
    }
    assert_eq!(fake.requests().len(), 12);
    assert_eq!(fake.state.peak.load(Ordering::SeqCst), 4);
}

struct ServerChild(std::process::Child);
impl Drop for ServerChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
async fn real_call(
    client: &DomainClient,
    covered: &mut HashSet<String>,
    name: &str,
    args: Value,
) -> Value {
    let result = client.execute(name, args.clone()).await;
    assert_eq!(result["ok"], true, "real server: {name} {args}: {result}");
    covered.insert(name.into());
    result
}

/// Runs only with a caller-supplied local build of the pinned real Orialis server.
/// Creates an isolated database, synthetic owners/tokens and loopback listener; no live services.
#[tokio::test]
#[ignore = "requires ORIALIS_REAL_SERVER_BIN pointing to a local pinned Orialis server executable"]
async fn real_server_all_39_tools_crud_news_owner_scope_and_versions() {
    let binary = std::env::var("ORIALIS_REAL_SERVER_BIN").expect("set ORIALIS_REAL_SERVER_BIN");
    let dir = tempfile::tempdir().unwrap();
    let reservation = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = reservation.local_addr().unwrap().port();
    drop(reservation);
    let origin = format!("http://127.0.0.1:{port}");
    let database = dir.path().join("real-domain.sqlite");
    let child = std::process::Command::new(binary)
        .env_clear()
        .env("ORIALIS_HOST", "127.0.0.1")
        .env("ORIALIS_PORT", port.to_string())
        .env("ORIALIS_ENV", "development")
        .env("ORIALIS_DEV_DEVICE_AUTH", "false")
        .env("ORIALIS_PUBLIC_URL", &origin)
        .env(
            "ORIALIS_DATABASE_URL",
            format!("sqlite://{}?mode=rwc", database.display()),
        )
        .env("ORIALIS_UPLOAD_DIR", dir.path().join("uploads"))
        .env("ORIALIS_AGENT_DEVICE_TOKEN", "local-test-agent-token")
        .env("ORIALIS_AGENT_USER_ID", "domain-owner")
        .env("ORIALIS_NEWS_PUBLISHER_TOKEN", "local-test-publisher-token")
        .env("ORIALIS_NEWS_PUBLISHER_USER_ID", "domain-owner")
        .env("RUST_LOG", "error")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .expect("start local real Orialis server");
    let _server = ServerChild(child);
    let http = Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(200))
        .build()
        .unwrap();
    let mut ready = false;
    for _ in 0..100 {
        if http
            .get(format!("{origin}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(ready, "local real server did not become healthy");
    let db = rusqlite::Connection::open(&database).unwrap();
    db.busy_timeout(Duration::from_secs(5)).unwrap();
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('domain-owner','domain-owner','local-only-no-login'),('other-owner','other-owner','local-only-no-login')",[]).unwrap();
    db.execute(
        "INSERT INTO tasks(id,user_id,title) VALUES('foreign-task','other-owner','private task')",
        [],
    )
    .unwrap();
    db.execute("INSERT INTO projects(id,user_id,name,status) VALUES('foreign-project','other-owner','private project','active')",[]).unwrap();
    let client = DomainClient::new(
        &origin,
        "User_Test_Hermes",
        "local-test-agent-token",
        Some("local-test-publisher-token"),
    )
    .unwrap();
    let mut covered = HashSet::new();
    let caps = real_call(&client, &mut covered, "orialis_capabilities", json!({})).await;
    assert_eq!(caps["server"]["discovery"]["ok"], true);

    real_call(
        &client,
        &mut covered,
        "create_project",
        json!({"id":"p1","name":"Project","goal":"Goal","color":"blue"}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "create_projects",
        json!({"items":[{"id":"p2","name":"Second project"},{"id":"p3","name":"Third project"}]}),
    )
    .await;
    let projects = real_call(
        &client,
        &mut covered,
        "list_projects",
        json!({"limit":1,"status":"active"}),
    )
    .await;
    assert_eq!(projects["result"]["hasMore"], true);
    let next = real_call(
        &client,
        &mut covered,
        "list_projects",
        json!({"after":projects["result"]["nextCursor"],"limit":100}),
    )
    .await;
    assert_eq!(next["result"]["items"].as_array().unwrap().len(), 2);
    let project = real_call(
        &client,
        &mut covered,
        "update_project",
        json!({"id":"p1","baseVersion":1,"color":null,"due":"2030-05-01"}),
    )
    .await;
    assert_eq!(project["result"]["color"], Value::Null);
    let task = real_call(&client,&mut covered,"create_task",json!({"id":"t1","title":"Task","projectId":"p1","notes":"remove me","due":"2030-04-01","dueTime":"09:00","recurrence":{"rule":"FREQ=WEEKLY;BYDAY=MO","until":"2030-05-01"}})).await;
    assert_eq!(task["result"]["version"], 1);
    real_call(&client,&mut covered,"create_tasks",json!({"items":[{"id":"t2","title":"Subtask","parentTaskId":"t1"},{"id":"t3","title":"Other task","projectId":"p1"}]})).await;
    let tasks = real_call(&client, &mut covered, "list_tasks", json!({"limit":100})).await;
    assert_eq!(tasks["result"]["items"].as_array().unwrap().len(), 3);
    assert!(!tasks.to_string().contains("private task"));
    let task = real_call(
        &client,
        &mut covered,
        "update_task",
        json!({"id":"t1","baseVersion":1,"notes":null,"important":true}),
    )
    .await;
    assert_eq!(task["result"]["notes"], Value::Null);
    let summary = real_call(
        &client,
        &mut covered,
        "get_project_summary",
        json!({"id":"p1"}),
    )
    .await;
    assert_eq!(summary["result"]["project"]["id"], "p1");
    let milestone = real_call(
        &client,
        &mut covered,
        "create_milestone",
        json!({"projectId":"p1","title":"Milestone","due":"2030-04-01","position":0}),
    )
    .await;
    let milestone_id = milestone["result"]["id"].clone();
    real_call(&client,&mut covered,"create_milestones",json!({"items":[{"projectId":"p1","title":"Second milestone"},{"projectId":"p1","title":"Third milestone"}]})).await;
    let milestones = real_call(
        &client,
        &mut covered,
        "list_milestones",
        json!({"projectId":"p1","limit":100}),
    )
    .await;
    assert_eq!(milestones["result"]["items"].as_array().unwrap().len(), 3);
    real_call(
        &client,
        &mut covered,
        "get_milestone",
        json!({"projectId":"p1","id":milestone_id}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "update_milestone",
        json!({"projectId":"p1","id":milestone_id,"baseVersion":1,"due":null,"completed":true}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "delete_milestone",
        json!({"projectId":"p1","id":milestone_id,"baseVersion":2}),
    )
    .await;

    let mut event = create_args("schedule");
    event["id"] = json!("s1");
    let saved = real_call(&client, &mut covered, "create_schedule", event.clone()).await;
    assert_eq!(saved["schedule"]["id"], "s1");
    event["id"] = json!("s2");
    real_call(
        &client,
        &mut covered,
        "create_calendar_event",
        event.clone(),
    )
    .await;
    event["id"] = json!("s3");
    real_call(
        &client,
        &mut covered,
        "create_schedules",
        json!({"items":[event.clone()]}),
    )
    .await;
    event["id"] = json!("s4");
    real_call(
        &client,
        &mut covered,
        "create_calendar_events",
        json!({"items":[event]}),
    )
    .await;
    for name in ["list_schedules", "list_calendar_events"] {
        let data = real_call(
            &client,
            &mut covered,
            name,
            json!({"from":"2030-01-01T00:00:00Z","to":"2030-01-03T00:00:00Z","limit":100}),
        )
        .await;
        assert_eq!(data["result"]["items"].as_array().unwrap().len(), 4);
    }
    real_call(&client, &mut covered, "get_schedule", json!({"id":"s1"})).await;
    real_call(
        &client,
        &mut covered,
        "get_calendar_event",
        json!({"id":"s2"}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "update_schedule",
        json!({"id":"s1","baseVersion":1,"location":null,"description":"Single activity"}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "update_calendar_event",
        json!({"id":"s2","baseVersion":1,"important":true}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "delete_schedule",
        json!({"id":"s1","baseVersion":2}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "delete_calendar_event",
        json!({"id":"s2","baseVersion":2}),
    )
    .await;

    real_call(
        &client,
        &mut covered,
        "create_conversation",
        json!({"id":"c1","title":"Conversation"}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "create_conversations",
        json!({"items":[{"id":"c2","title":"Second conversation"}]}),
    )
    .await;
    let conversations = real_call(&client, &mut covered, "list_conversations", json!({})).await;
    assert!(
        conversations["result"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == "c1")
    );
    real_call(
        &client,
        &mut covered,
        "update_conversation",
        json!({"id":"c1","title":"Renamed","baseVersion":1,"pinned":true,"manualPosition":5}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "create_message",
        json!({"conversationId":"c1","id":"m1","content":"First message"}),
    )
    .await;
    let messages = real_call(&client,&mut covered,"create_messages",json!({"items":[{"conversationId":"c1","id":"m2","content":"Second message","replyToMessageId":"m1"},{"conversationId":"c1","id":"m3","content":"Third message"}]})).await;
    assert_eq!(messages["results"][0]["result"]["replyToMessageId"], "m1");
    let listed = real_call(
        &client,
        &mut covered,
        "list_messages",
        json!({"conversationId":"c1","limit":100}),
    )
    .await;
    assert_eq!(listed["result"]["items"].as_array().unwrap().len(), 3);
    real_call(
        &client,
        &mut covered,
        "delete_conversation",
        json!({"id":"c1","baseVersion":2}),
    )
    .await;

    for dataset in [
        "aihot.hot",
        "aihot.items",
        "aihot.events",
        "aihot.reports.daily",
        "aihot.reports.weekly",
        "aihot.reports.monthly",
        "github.daily",
        "github.weekly",
        "projects.daily",
        "projects.weekly",
    ] {
        let value = if matches!(
            dataset,
            "aihot.hot" | "aihot.items" | "github.daily" | "github.weekly"
        ) {
            json!([])
        } else if dataset == "aihot.events" {
            json!({"publicId":"local-test-event","title":"Test"})
        } else {
            json!({"title":"Local test report"})
        };
        let mut args = json!({"dataset":dataset,"result":value});
        if dataset.starts_with("projects.") {
            args["projectId"] = json!("p1");
            args["reportDate"] = json!(if dataset.ends_with("weekly") {
                "2030-W01"
            } else {
                "2030-01-01"
            });
        }
        real_call(&client, &mut covered, "news.publish", args.clone()).await;
        // Same stable task/idempotency key must be accepted without a duplicate report.
        real_call(&client, &mut covered, "news.publish", args).await;
    }
    // Real server, not a fake response: stale versions and cross-owner resource IDs fail.
    assert_eq!(
        client
            .execute(
                "update_task",
                json!({"id":"t1","baseVersion":1,"title":"Stale"})
            )
            .await["status"],
        409
    );
    assert_eq!(
        client
            .execute(
                "update_task",
                json!({"id":"foreign-task","baseVersion":1,"title":"Wrong owner"})
            )
            .await["status"],
        404
    );
    assert_eq!(
        client
            .execute("get_project_summary", json!({"id":"foreign-project"}))
            .await["status"],
        404
    );
    let wrong = DomainClient::new(
        &origin,
        "User_Test_Hermes",
        "wrong-token",
        Some("local-test-agent-token"),
    )
    .unwrap();
    assert_eq!(wrong.execute("list_tasks", json!({})).await["status"], 401);
    assert_eq!(
        wrong
            .execute("news.publish", json!({"dataset":"aihot.hot","result":[]}))
            .await["status"],
        401
    );
    real_call(
        &client,
        &mut covered,
        "delete_task",
        json!({"id":"t1","baseVersion":task["result"]["version"]}),
    )
    .await;
    real_call(
        &client,
        &mut covered,
        "delete_project",
        json!({"id":"p1","baseVersion":project["result"]["version"]}),
    )
    .await;
    let foreign: String = db
        .query_row("SELECT title FROM tasks WHERE id='foreign-task'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(foreign, "private task");
    let foreign_records: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM tasks WHERE user_id='other-owner'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(foreign_records, 1);
    assert_eq!(
        covered.len(),
        39,
        "not covered: {:?}",
        tool_names()
            .into_iter()
            .filter(|n| !covered.contains(*n))
            .collect::<Vec<_>>()
    );
    println!(
        "REAL ORIALIS: all 39 tools and all 10 news datasets passed; optimistic concurrency, account isolation and separate publisher authentication verified."
    );
}

#[tokio::test]
async fn publisher_preserves_big_integers_normalizes_float_literals_and_rejects_nonfinite_exponents()
 {
    let raw: Value = serde_json::from_str(
        r#"{"a":1.0000,"b":1.23e0005,"c":-0,"d":-0.0,"n":18446744073709551616}"#,
    )
    .unwrap();
    assert_eq!(
        canonical_json(&raw).unwrap(),
        r#"{"a":1.0,"b":123000.0,"c":0,"d":-0.0,"n":18446744073709551616}"#
    );
    let fake = Fake::new(vec![]).await;
    for invalid in ["1e400", "-1e400"] {
        let raw: Value = serde_json::from_str(&format!(
            r#"{{"dataset":"aihot.hot","result":[{invalid}]}}"#
        ))
        .unwrap();
        let result = fake.client().execute("news.publish", raw).await;
        assert_eq!(result["ok"], false);
        assert!(result["error"].as_str().unwrap().contains("finite"));
    }
    assert!(fake.requests().is_empty());
    let result = fake
        .client()
        .execute(
            "news.publish",
            json!({"dataset":"aihot.hot","result":[raw]}),
        )
        .await;
    assert_eq!(result["ok"], true);
    assert_eq!(
        fake.requests()[0].body["result"][0]["n"].to_string(),
        "18446744073709551616"
    );
}

#[tokio::test]
async fn arbitrary_arguments_and_schema_drift_are_rejected_without_panics_or_http() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    for name in tool_names() {
        for args in [
            Value::Null,
            json!(true),
            json!(42),
            json!("text"),
            json!([]),
            json!({"unexpected":true}),
        ] {
            assert_eq!(client.execute(name, args).await["ok"], false, "{name}");
        }
    }
    assert!(fake.requests().is_empty());
    assert_eq!(
        client.execute("send_http_request", json!({})).await["ok"],
        false
    );
    assert_eq!(
        client
            .execute(
                "create_task",
                json!({"title":"x".repeat(MAX_ARGUMENT_BYTES+1)})
            )
            .await["ok"],
        false
    );
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn split_required_matches_upstream_agenda_cases_for_all_six_schedule_writers() {
    let fake = Fake::new(vec![]).await;
    let client = fake.client();
    for description in [
        "【逐日摄影行程】\n11/4（周三）：09:49杭州南抵达→良渚古城。\n11/5（周四）：清晨西湖摄影→中午校园参观。\n11/8（周日）：15:40返程。",
        "08:00–09:00 摄影\n12:00–13:00 校园参观",
        "上午：西湖摄影；下午：校园参观",
        "11月5日：西湖摄影；11月6日：太子湾摄影",
    ] {
        for name in [
            "create_schedule",
            "create_calendar_event",
            "update_schedule",
            "update_calendar_event",
            "create_schedules",
            "create_calendar_events",
        ] {
            let mut event = if name.starts_with("update_") {
                json!({"id":"s","baseVersion":1})
            } else {
                create_args("schedule")
            };
            event["description"] = json!(description);
            let args = if batch_single(name).is_some() {
                json!({"items":[create_args("schedule"),event]})
            } else {
                event
            };
            let result = client.execute(name, args).await;
            assert_eq!(result["ok"], false, "{name}: {description}");
            assert!(result["error"].as_str().unwrap().contains("split_required"));
            if batch_single(name).is_some() {
                assert_eq!(result["written"], 0);
                assert_eq!(result["validationIndex"], 1);
            }
        }
    }
    assert!(fake.requests().is_empty());
}

#[tokio::test]
async fn interrupted_response_marks_mutation_uncertain_without_retrying() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = vec![0u8; 4096];
        let read = socket.read(&mut request).await.unwrap();
        assert!(String::from_utf8_lossy(&request[..read]).starts_with("POST /api/v1/tasks "));
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"id\":").await.unwrap();
        socket.shutdown().await.unwrap();
    });
    let client = DomainClient::new(
        &format!("http://{address}"),
        "User_Test_Hermes",
        "local-token",
        None,
    )
    .unwrap();
    let result = client
        .execute("create_task", json!({"id":"stable","title":"Task"}))
        .await;
    assert_eq!(result["ok"], false);
    assert_eq!(result["status"], 200);
    assert_eq!(result["outcomeUnknown"], true);
    assert_eq!(result["error"], "Orialis response could not be read");
    task.await.unwrap();
}
