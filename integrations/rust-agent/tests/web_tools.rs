//! All HTTP servers are children/tasks of this test process. Production has no
//! public/private-network override; only this cfg(test) copy has exact fixtures.
#[path = "../src/web_tools.rs"]
mod web_tools;
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Request, State},
    response::Response,
};
use hermes_rust_core::tool_runtime;
use serde_json::{Value, json};
use std::{
    io::Write,
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};
use web_tools::*;
#[derive(Clone, Default)]
struct StateData {
    requests: Arc<Mutex<Vec<Value>>>,
}
struct Fixture {
    address: SocketAddr,
    base: String,
    state: StateData,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fixture {
    fn tools(&self, config: WebConfig) -> WebTools {
        WebTools::fixture(config, vec![("fixture.example".into(), self.address)]).unwrap()
    }
}
fn response(status: u16, mime: &str, body: impl Into<Body>) -> Response {
    Response::builder()
        .status(status)
        .header("Content-Type", mime)
        .body(body.into())
        .unwrap()
}
async fn fixture() -> Fixture {
    async fn handle(State(state): State<StateData>, request: Request) -> Response {
        let path = request.uri().path().to_owned();
        let query = request.uri().query().unwrap_or("").to_owned();
        let headers = request.headers().clone();
        let method = request.method().to_string();
        let body = to_bytes(request.into_body(), 65536).await.unwrap();
        state.requests.lock().unwrap().push(json!({"path":path,"query":query,"method":method,"authorization":headers.get("Authorization").and_then(|s|s.to_str().ok()),"subscription":headers.get("X-Subscription-Token").and_then(|s|s.to_str().ok()),"cookie":headers.get("Cookie").and_then(|s|s.to_str().ok()),"host":headers.get("Host").and_then(|s|s.to_str().ok()),"body":String::from_utf8_lossy(&body)}));
        if path.ends_with("/link_expansion") {
            return response(200, "text/html", r#"<a href="x">L</a>"#.repeat(10));
        }
        match path.as_str(){
            "/html"=>response(200,"text/html; charset=utf-8",r#"<!doctype html><html><head><title>Real &amp; static page</title><script>STEAL_THIS_SCRIPT</script></head><body><nav>navigation noise</nav><main><h1>Article heading</h1><p>Hello <strong>中文</strong> &amp; world.</p><p><a href="/next">Read more<script>EVIL_ANCHOR_SCRIPT</script></a></p><div hidden>HIDDEN_SECRET</div><div style="display:none">CSS_HIDDEN</div><script>fetch('/side-effect')</script><img alt="fixture image" src="data:image/png;base64,AAAA"/><img alt="external" src="/image.png"/><pre>line one\nline two</pre></main><footer>footer noise</footer></body></html>"#),
            "/redirect"=>Response::builder().status(302).header("Location","/html").body(Body::empty()).unwrap(),
            "/private_redirect"=>Response::builder().status(302).header("Location","http://127.0.0.1/private").body(Body::empty()).unwrap(),
            "/secret_redirect"=>Response::builder().status(302).header("Location","/html?access_token=fixture-secret").body(Body::empty()).unwrap(),
            "/dns_redirect"=>Response::builder().status(302).header("Location","http://untrusted.example/private").body(Body::empty()).unwrap(),
            "/loop"=>Response::builder().status(302).header("Location","/loop").body(Body::empty()).unwrap(),
            "/latin"=>response(200,"text/plain; charset=windows-1252",b"caf\xe9".to_vec()),
            "/meta"=>response(200,"text/html",b"<meta charset='windows-1252'><p>caf\xe9</p>".to_vec()),
            "/utf16"=>response(200,"text/plain",[vec![0xff,0xfe],"BOM text".encode_utf16().flat_map(u16::to_le_bytes).collect()].concat()),
            "/bad_utf8"=>response(200,"text/plain; charset=utf-8",vec![0xff,0xff]),
            "/gzip"|"/bomb"=>{let mut encoder=flate2::write::GzEncoder::new(Vec::new(),flate2::Compression::default());let text=if path=="/bomb"{vec![b'A';100000]}else{b"Real compressed text".to_vec()};encoder.write_all(&text).unwrap();Response::builder().header("Content-Type","text/plain").header("Content-Encoding","gzip").body(Body::from(encoder.finish().unwrap())).unwrap()},
            "/chunked"=>{let chunks=vec![Ok::<_,std::io::Error>(vec![b'a';600]),Ok(vec![b'b';600])];response(200,"text/plain",Body::from_stream(futures_util::stream::iter(chunks)))},
            "/slow"=>response(200,"text/plain",Body::from_stream(futures_util::stream::pending::<Result<Vec<u8>,std::io::Error>>())),
            "/long"=>response(200,"text/plain",format!("HEAD {} TAIL","中".repeat(4000))),
            "/large"=>response(200,"text/plain","A".repeat(10000)),
            "/deep"=>response(200,"text/html",format!("{}text{}","<div>".repeat(300),"</div>".repeat(300))),
            "/nodes"=>response(200,"text/html","<p>A</p>".repeat(100)),
            "/link_expansion"=>response(200,"text/html",r#"<a href="x">L</a>"#.repeat(10)),
            "/pdf"=>response(200,"application/pdf",b"%PDF-fixture".to_vec()),
            "/json"=>response(200,"application/json",r#"{"data":"actual JSON text"}"#),
            "/js_only"=>response(200,"text/html","<html><body><script>document.write('JS result')</script></body></html>"),
            "/brave"=>response(200,"application/json",json!({"web":{"results":[{"title":"Actual result","url":"https://example.org/article","description":"Useful snippet"},{"title":"fixture-search-secret","url":"https://example.org/second","description":"secret echo: fixture-search-secret"},{"title":"private","url":"http://169.254.169.254/","description":"not returned"}]}}).to_string()),
            "/firecrawl"=>response(200,"application/json",json!({"success":true,"data":{"web":[{"title":"Firecrawl result","url":"https://example.org/","description":"Real fixture API output"}]}}).to_string()),
            "/search_redirect"=>Response::builder().status(307).header("Location","/credential-leak").body(Body::empty()).unwrap(),
            "/search_fail"=>response(503,"application/json",r#"{"error":"fixture-search-secret must not appear"}"#),
            _=>response(404,"text/plain","fixture missing"),
        }
    }
    let state = StateData::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let base = format!("http://fixture.example:{}", address.port());
    let clone = state.clone();
    let task = tokio::spawn(async move {
        axum::serve(listener, Router::new().fallback(handle).with_state(clone))
            .await
            .unwrap()
    });
    Fixture {
        address,
        base,
        state,
        task,
    }
}
#[test]
fn public_address_classifier_refuses_every_local_metadata_and_mapped_family() {
    for raw in [
        "0.0.0.0",
        "10.0.0.1",
        "100.100.100.200",
        "127.0.0.1",
        "169.254.169.254",
        "172.16.4.2",
        "192.168.1.1",
        "192.0.0.1",
        "192.0.2.1",
        "198.19.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "255.255.255.255",
        "168.63.129.16",
        "::1",
        "::",
        "::ffff:127.0.0.1",
        "::127.0.0.1",
        "fc00::1",
        "fe80::1",
        "2001:db8::1",
        "2002:0a00:0001::",
        "64:ff9b::a00:1",
        "2001::1234",
        "3fff::1",
    ] {
        assert!(!is_public_ip(raw.parse::<IpAddr>().unwrap()), "{raw}");
    }
    for raw in [
        "8.8.8.8",
        "1.1.1.1",
        "93.184.216.34",
        "2606:4700:4700::1111",
        "2a00:1450:4001::200e",
    ] {
        assert!(is_public_ip(raw.parse().unwrap()), "{raw}");
    }
}
#[tokio::test]
async fn default_search_is_unadvertised_and_unsafe_urls_never_make_http_requests() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig::default());
    assert_eq!(tools.schemas().len(), 1);
    assert_eq!(tools.schemas()[0]["function"]["name"], "web_extract");
    assert_eq!(
        tools
            .execute("web_search", json!({"query":"fixture"}))
            .await["success"],
        false
    );
    for raw in [
        "file:///etc/passwd",
        "ftp://example.org/file",
        "http://127.0.0.1/",
        "http://2130706433/",
        "http://0x7f000001/",
        "http://0177.0.0.1/",
        "http://[::ffff:127.0.0.1]/",
        "http://localhost./",
        "http://metadata.google.internal/",
        "http://user:password@example.org/",
    ] {
        let result = tools.execute("web_extract", json!({"urls":[raw]})).await;
        assert!(!result.to_string().contains("actual JSON text"));
        assert!(
            result["success"] == false || result["results"][0]["error"].is_string(),
            "{result}"
        );
    }
    assert!(fixture.state.requests.lock().unwrap().is_empty());
    let result=tools.execute("web_extract",json!({"urls":[format!("{}/html",fixture.base),"https://example.org/?access_token=secret"]})).await;
    assert_eq!(result["success"], false);
    assert!(fixture.state.requests.lock().unwrap().is_empty());
}
#[tokio::test]
async fn real_html_fetch_extracts_title_text_links_and_never_executes_scripts() {
    let fixture = fixture().await;
    let result = fixture
        .tools(WebConfig::default())
        .execute(
            "web_extract",
            json!({"urls":[format!("{}/redirect",fixture.base)]}),
        )
        .await;
    assert_eq!(result["results"][0]["error"], Value::Null, "{result}");
    let page = &result["results"][0];
    assert_eq!(page["title"], "Real & static page");
    assert_eq!(page["url"], format!("{}/html", fixture.base));
    let content = page["content"].as_str().unwrap();
    for expected in [
        "# Article heading",
        "Hello 中文 & world.",
        "[Read more](http://fixture.example:",
        "[IMAGE: fixture image]",
        "[IMAGE: external]",
    ] {
        assert!(content.contains(expected), "{content}");
    }
    for omitted in [
        "STEAL_THIS_SCRIPT",
        "EVIL_ANCHOR_SCRIPT",
        "HIDDEN_SECRET",
        "CSS_HIDDEN",
        "navigation noise",
        "footer noise",
        "data:image",
    ] {
        assert!(!content.contains(omitted), "{content}");
    }
    let requests = fixture.state.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|r| r["authorization"].is_null()
        && r["subscription"].is_null()
        && r["cookie"].is_null()));
    assert!(
        requests
            .iter()
            .all(|r| r["host"].as_str().unwrap().starts_with("fixture.example:"))
    );
}
#[tokio::test]
async fn every_redirect_is_rechecked_before_any_second_request() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig::default());
    for route in ["private_redirect", "secret_redirect", "loop"] {
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/{route}",fixture.base)]}),
            )
            .await;
        assert!(result["results"][0]["error"].is_string(), "{result}");
    }
    assert_eq!(fixture.state.requests.lock().unwrap().len(), 3);
}
#[tokio::test]
async fn actual_charset_bom_meta_gzip_and_json_are_decoded() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig::default());
    for (route, expected) in [
        ("latin", "café"),
        ("meta", "café"),
        ("utf16", "BOM text"),
        ("gzip", "Real compressed text"),
        ("json", "actual JSON text"),
    ] {
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/{route}",fixture.base)]}),
            )
            .await;
        assert_eq!(result["results"][0]["error"], Value::Null, "{result}");
        assert!(
            result["results"][0]["content"]
                .as_str()
                .unwrap()
                .contains(expected),
            "{result}"
        );
    }
}
#[tokio::test]
async fn response_limits_timeouts_and_unsupported_content_are_explicit() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig {
        max_response_bytes: 1000,
        timeout: Duration::from_millis(150),
        ..Default::default()
    });
    for route in [
        "bomb", "chunked", "large", "slow", "pdf", "bad_utf8", "js_only",
    ] {
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/{route}",fixture.base)]}),
            )
            .await;
        assert!(
            result["success"] == false || result["results"][0]["error"].is_string(),
            "{route}: {result}"
        );
    }
}
#[tokio::test]
async fn order_invalid_items_compatibility_and_unicode_truncation_are_preserved() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig::default());
    let result=tools.execute("web_extract",json!({"urls":[{"url":format!("{}/long",fixture.base),"title":"search row"},null,{"href":format!("{}/json",fixture.base)}],"char_limit":2000,"format":"text"})).await;
    let rows = result["results"].as_array().unwrap();
    assert_eq!(rows.len(), 3);
    let content = rows[0]["content"].as_str().unwrap();
    assert!(
        content.starts_with("HEAD ")
            && content.contains(" TAIL")
            && content.contains("TRUNCATED")
            && content.contains("Full text was not stored")
    );
    assert!(rows[1]["error"].is_string());
    assert!(
        rows[2]["content"]
            .as_str()
            .unwrap()
            .contains("actual JSON text")
    );
    for args in [
        json!({"urls":[format!("{}/html",fixture.base)],"headers":{"Cookie":"secret"}}),
        json!({"urls":[format!("{}/html",fixture.base)],"format":"html"}),
    ] {
        assert!(
            tools.execute("web_extract", args).await["error"]
                .as_str()
                .unwrap()
                .contains("not_supported")
        );
    }
}
#[tokio::test]
async fn brave_and_firecrawl_search_use_explicit_separate_credentials_and_true_metadata() {
    let fixture = fixture().await;
    for (provider, path) in [
        (SearchProvider::Brave, "brave"),
        (SearchProvider::Firecrawl, "firecrawl"),
    ] {
        let config = WebConfig {
            search: Some(SearchConfig {
                provider,
                endpoint: format!("{}/{path}", fixture.base),
                api_key: "fixture-search-secret".into(),
            }),
            ..Default::default()
        };
        assert!(!format!("{config:?}").contains("fixture-search-secret"));
        let tools = fixture.tools(config);
        assert_eq!(tools.schemas().len(), 2);
        let result = tools
            .execute(
                "web_search",
                json!({"query":"fixture query 中文","limit":100}),
            )
            .await;
        assert_eq!(result["success"], true, "{result}");
        assert!(!result.to_string().contains("fixture-search-secret"));
        assert_eq!(result["data"]["web"][0]["position"], 1);
        assert!(
            result["data"]["web"][0]["url"]
                .as_str()
                .unwrap()
                .starts_with("https://example.org/")
        );
    }
    let requests = fixture.state.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["subscription"], "fixture-search-secret");
    assert!(requests[0]["authorization"].is_null());
    assert!(requests[0]["query"].as_str().unwrap().contains("count=20"));
    assert_eq!(requests[1]["authorization"], "Bearer fixture-search-secret");
    assert!(requests[1]["subscription"].is_null());
    let body: Value = serde_json::from_str(requests[1]["body"].as_str().unwrap()).unwrap();
    assert_eq!(body["query"], "fixture query 中文");
    assert_eq!(body["limit"], 100);
}
#[tokio::test]
async fn search_redirect_error_and_bad_configuration_never_leak_or_retry_secrets() {
    let fixture = fixture().await;
    assert!(
        WebTools::new(WebConfig {
            search: Some(SearchConfig {
                provider: SearchProvider::Brave,
                endpoint: format!("{}/brave", fixture.base),
                api_key: "secret".into()
            }),
            ..Default::default()
        })
        .is_err()
    );
    for path in ["search_redirect", "search_fail"] {
        let tools = fixture.tools(WebConfig {
            search: Some(SearchConfig {
                provider: SearchProvider::Brave,
                endpoint: format!("{}/{path}", fixture.base),
                api_key: "fixture-search-secret".into(),
            }),
            ..Default::default()
        });
        let result = tools
            .execute("web_search", json!({"query":"fixture"}))
            .await;
        assert_eq!(result["success"], false);
        assert!(!result.to_string().contains("fixture-search-secret"));
    }
    assert_eq!(fixture.state.requests.lock().unwrap().len(), 2);
    assert!(
        fixture
            .state
            .requests
            .lock()
            .unwrap()
            .iter()
            .all(|r| r["path"] != "/credential-leak")
    );
}

#[tokio::test]
async fn dns_mixed_answers_and_redirect_dns_are_refused_before_connection() {
    let fixture = fixture().await;
    for addresses in [
        vec![fixture.address],
        vec!["8.8.8.8:80".parse().unwrap(), fixture.address],
        vec![],
    ] {
        let tools = fixture
            .tools(WebConfig::default())
            .fixture_dns(vec![("untrusted.example".into(), addresses)]);
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":["http://untrusted.example/private"]}),
            )
            .await;
        assert!(
            result["results"][0]["error"]
                .as_str()
                .unwrap()
                .contains("DNS"),
            "{result}"
        );
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/dns_redirect",fixture.base)]}),
            )
            .await;
        assert!(
            result["results"][0]["error"]
                .as_str()
                .unwrap()
                .contains("DNS"),
            "{result}"
        );
    }
    assert_eq!(fixture.state.requests.lock().unwrap().len(), 3);
    assert!(
        fixture
            .state
            .requests
            .lock()
            .unwrap()
            .iter()
            .all(|r| r["path"] == "/dns_redirect")
    );
}
#[tokio::test]
async fn parser_node_depth_and_expanded_text_budgets_are_enforced() {
    let fixture = fixture().await;
    for (route, config) in [
        ("deep".to_string(), WebConfig::default()),
        (
            "nodes".to_string(),
            WebConfig {
                max_html_nodes: 50,
                ..Default::default()
            },
        ),
        (
            format!("{}/link_expansion", "a".repeat(800)),
            WebConfig {
                max_response_bytes: 1000,
                ..Default::default()
            },
        ),
    ] {
        // The repeated path creates a long URL base without increasing response bytes.
        let result = fixture
            .tools(config)
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/{route}",fixture.base)]}),
            )
            .await;
        assert!(result["results"][0]["error"].is_string(), "{result}");
        assert!(
            !result.to_string().contains("origin HTTP"),
            "fixture route must exist: {result}"
        );
    }
}
#[tokio::test]
async fn encoded_secrets_controls_and_vendor_token_paths_block_the_entire_batch() {
    let fixture = fixture().await;
    let tools = fixture.tools(WebConfig::default());
    for suspect in [
        "https://example.org/?%2561ccess_token=hidden",
        "https://example.org/sk-abcdefghijklmnopqrstuvwx",
        "https://example.org/%0a/private",
        "https://example.org/?X-Amz-Signature=fixture",
        "https://example.org/hf_abcdefghijklmnopqrstuvw",
    ] {
        let result = tools
            .execute(
                "web_extract",
                json!({"urls":[format!("{}/html",fixture.base),suspect]}),
            )
            .await;
        assert_eq!(result["success"], false, "{suspect}: {result}");
    }
    assert!(fixture.state.requests.lock().unwrap().is_empty());
}
