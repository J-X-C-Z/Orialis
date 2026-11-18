use super::*;
use std::{
    collections::VecDeque,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
const BV: &str = "BV1d8pU6xEZX";
const SOURCE: &str =
    "https://www.bilibili.com/video/BV1d8pU6xEZX/?p=2&share_session_id=signed%2Bvalue";
#[derive(Clone)]
struct Call {
    url: String,
    cookie: Option<String>,
}
struct Fixture {
    calls: Mutex<Vec<Call>>,
    view: Mutex<Value>,
    player: Mutex<Value>,
    snapshot: Mutex<Value>,
    captions: Mutex<Value>,
    search: Mutex<Value>,
    sheet: Mutex<Vec<u8>>,
    redirects: Mutex<BTreeMap<String, (u16, String)>>,
    statuses: Mutex<BTreeMap<String, u16>>,
    login: Mutex<VecDeque<(Value, Vec<String>)>>,
    block_poll: AtomicBool,
    poll_entered: tokio::sync::Notify,
    poll_release: tokio::sync::Notify,
}
impl Fixture {
    fn new() -> Arc<Self> {
        let image = image::RgbImage::from_fn(30, 10, |x, _| {
            image::Rgb(match x / 10 {
                0 => [230, 0, 0],
                1 => [0, 230, 0],
                _ => [0, 0, 230],
            })
        });
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            view: Mutex::new(
                json!({"bvid":BV,"aid":1,"title":"人工智能模型演示视频","owner":{"name":"示例UP"},"duration":100,"pages":[{"cid":101,"duration":40},{"cid":202,"duration":60}]}),
            ),
            player: Mutex::new(
                json!({"subtitle":{"subtitles":[{"lan":"zh-CN","subtitle_url":"//aisubtitle.hdslb.com/caption.json"}]}}),
            ),
            snapshot: Mutex::new(
                json!({"image":["//i0.hdslb.com/sheet.png"],"index":[0,30,60],"img_x_size":10,"img_y_size":10}),
            ),
            captions: Mutex::new(
                json!({"body":[{"from":0,"to":2,"content":"模型通过训练学习特征"},{"from":12.5,"to":15,"content":"展示推理效果"}]}),
            ),
            search: Mutex::new(
                json!({"result":[{"bvid":BV,"title":"<em class=\"keyword\">人工智能</em>模型演示视频","author":"示例UP"}]}),
            ),
            sheet: Mutex::new(png.into_inner()),
            redirects: Mutex::new(BTreeMap::new()),
            statuses: Mutex::new(BTreeMap::new()),
            login: Mutex::new(VecDeque::new()),
            block_poll: AtomicBool::new(false),
            poll_entered: tokio::sync::Notify::new(),
            poll_release: tokio::sync::Notify::new(),
        })
    }
    fn api(&self, path: &str) -> Value {
        match path {
            "/x/web-interface/view" => self.view.lock().unwrap().clone(),
            "/x/player/v2" => self.player.lock().unwrap().clone(),
            "/x/player/videoshot" => self.snapshot.lock().unwrap().clone(),
            "/x/web-interface/wbi/search/type" => self.search.lock().unwrap().clone(),
            "/x/web-interface/nav" => {
                json!({"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}})
            }
            _ => panic!("unexpected fixture API {path}"),
        }
    }
    fn requests(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }
    fn login_data(&self, code: Value, cookies: Vec<String>) {
        self.login.lock().unwrap().push_back((
            json!({"code":code,"url":"https://passport.biligame.com/crossDomain?gourl=home"}),
            cookies,
        ));
    }
}
impl http::Transport for Fixture {
    fn get<'a>(
        &'a self,
        url: &'a reqwest::Url,
        cookies: Option<&'a str>,
        _limit: usize,
        _deadline: Instant,
    ) -> BoxFuture<'a, Result<http::Reply>> {
        Box::pin(async move {
            self.calls.lock().unwrap().push(Call {
                url: url.to_string(),
                cookie: cookies.map(str::to_owned),
            });
            let path = url.path();
            if let Some((status, location)) = self.redirects.lock().unwrap().get(path).cloned() {
                return Ok(http::Reply {
                    status,
                    location: Some(location),
                    ..Default::default()
                });
            }
            if let Some(status) = self.statuses.lock().unwrap().get(path).copied() {
                return Ok(http::Reply {
                    status,
                    body: b"PRIVATE_PLATFORM_ERROR_COOKIE".to_vec(),
                    ..Default::default()
                });
            }
            if path.ends_with("/generate") {
                return Ok(http::Reply {
                    status: 200,
                    body: serde_json::to_vec(
                        &json!({"code":0,"data":{"qrcode_key":"PRIVATE_QR_KEY","url":"https://passport.bilibili.com/login?key=PRIVATE_QR_KEY"}}),
                    )?,
                    ..Default::default()
                });
            }
            if path.ends_with("/poll") {
                if self.block_poll.load(Ordering::SeqCst) {
                    self.poll_entered.notify_one();
                    self.poll_release.notified().await;
                }
                let (data, set_cookies) = self
                    .login
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("login fixture response");
                return Ok(http::Reply {
                    status: 200,
                    body: serde_json::to_vec(&json!({"code":0,"data":data}))?,
                    set_cookies,
                    ..Default::default()
                });
            }
            let body = if path.ends_with("caption.json") {
                serde_json::to_vec(&*self.captions.lock().unwrap())?
            } else if path.ends_with("sheet.png") {
                self.sheet.lock().unwrap().clone()
            } else if path.ends_with("pvdata") {
                [0u16, 30, 60]
                    .iter()
                    .flat_map(|s| s.to_be_bytes())
                    .collect()
            } else {
                serde_json::to_vec(&json!({"code":0,"data":self.api(path)}))?
            };
            Ok(http::Reply {
                status: 200,
                body,
                ..Default::default()
            })
        })
    }
}
fn client(f: Arc<Fixture>) -> MemoryVideoClient {
    let p = crate::Provider::new(
        "http://127.0.0.1:1/model".into(),
        "test-vision".into(),
        None,
        false,
    )
    .unwrap();
    let mut c = MemoryVideoClient::new(&p, None).unwrap();
    c.http = http::BiliHttp::mock(f);
    c
}
#[tokio::test]
async fn actual_caption_and_cropped_storyboard_evidence_preserves_exact_source() {
    let f = Fixture::new();
    let c = client(f.clone());
    let e = c.collect_video(&[SOURCE.into()], None, None).await.unwrap();
    assert_eq!(e.status, VideoStatus::Analyzed);
    assert_eq!(e.source_url.as_deref(), Some(SOURCE));
    assert!(e.captions.contains("[12.5s] 展示推理效果"));
    assert_eq!(e.metadata["part"], 2);
    assert_eq!(
        e.frames.iter().map(|f| f.seconds).collect::<Vec<_>>(),
        vec![0., 30., 60.]
    );
    for (i, f) in e.frames.iter().enumerate() {
        let raw = STANDARD.decode(&f.jpeg_base64).unwrap();
        let image = image::load_from_memory(&raw).unwrap().to_rgb8();
        assert_eq!(image.dimensions(), (10, 10));
        let pixel = image.get_pixel(5, 5);
        assert!(pixel[i] > 200);
        assert!(pixel[(i + 1) % 3] < 20);
    }
    assert!(f.requests().iter().any(|r| r.url.contains("cid=202")));
    let coverage = e.model_context()["evidenceCoverage"].clone();
    assert_eq!(coverage["continuousVideo"], false);
    assert_eq!(coverage["audioUnderstood"], false);
}
#[tokio::test]
async fn wrong_track_entirely_discarded_and_visual_failure_keeps_valid_captions() {
    let f = Fixture::new();
    *f.captions.lock().unwrap() = json!({"body":[{"from":0,"to":1,"content":"WRONG_EARLY_LINE"},{"from":175.1,"to":180.7,"content":"WRONG_LAST_LINE"}]});
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.captions, "");
    assert_eq!(e.status, VideoStatus::Analyzed);
    assert_eq!(e.frames.len(), 3);
    assert!(!e.model_context().to_string().contains("WRONG_"));
    let f = Fixture::new();
    *f.sheet.lock().unwrap() = b"not an image".to_vec();
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Analyzed);
    assert!(!e.captions.is_empty());
    assert!(e.frames.is_empty());
    assert!(e.metadata.get("visualWarning").is_some());
}
#[tokio::test]
async fn music_only_is_not_speech_and_no_content_is_never_analyzed() {
    let f = Fixture::new();
    *f.captions.lock().unwrap() = json!({"body":[{"from":0.8,"to":3.1,"content":"♪ 音乐 ♪"},{"from":39.5,"to":44.5,"content":" BGM ♫"}]});
    let e = client(f.clone())
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert!(e.captions.is_empty());
    assert_eq!(e.status, VideoStatus::Analyzed);
    f.snapshot.lock().unwrap()["index"] = json!([]);
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
    assert!(e.captions.is_empty() && e.frames.is_empty());
}
#[tokio::test]
async fn captions_and_dense_frames_keep_endpoints_with_explicit_coverage() {
    let f = Fixture::new();
    f.view.lock().unwrap()["pages"][1]["duration"] = json!(1200);
    f.captions.lock().unwrap()["body"] = json!(
        (0..1000)
            .map(|i| json!({"from":i,"to":i+1,"content":format!("第{i}句{}","内容".repeat(50))}))
            .collect::<Vec<_>>()
    );
    f.snapshot.lock().unwrap()["index"] = json!((0..=1200).step_by(10).collect::<Vec<_>>());
    f.snapshot.lock().unwrap()["image"] = json!(vec!["//i0.hdslb.com/sheet.png"; 41]);
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert!(e.captions.contains("第0句") && e.captions.contains("第999句"));
    assert!(e.captions.len() <= 60000);
    assert_eq!(e.metadata["captionCoverage"]["complete"], false);
    assert_eq!(e.frames.len(), 24);
    assert_eq!(e.frames.first().unwrap().seconds, 0.);
    assert_eq!(e.frames.last().unwrap().seconds, 1200.);
}
#[tokio::test]
async fn milliseconds_and_binary_pvdata_select_correct_tiles() {
    assert_eq!(
        evidence::entries(
            &json!({"index":[0,30000,{"timestamp":60000},-1,"invalid"]}),
            60.
        ),
        vec![(0., 0), (30., 1), (60., 2)]
    );
    let f = Fixture::new();
    {
        let mut s = f.snapshot.lock().unwrap();
        s["index"] = json!([]);
        s["pvdata"] = json!("//i0.hdslb.com/pvdata");
    }
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert_eq!(
        e.frames.iter().map(|f| f.seconds).collect::<Vec<_>>(),
        vec![0., 30., 60.]
    );
}
#[tokio::test]
async fn verified_title_uploader_unique_search_and_second_metadata_check() {
    let f = Fixture::new();
    let e = client(f.clone())
        .collect_video(&[], None, Some(("人工智能模型演示视频", "示例UP")))
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Analyzed);
    assert_eq!(
        e.source_url,
        Some(format!("https://www.bilibili.com/video/{BV}"))
    );
    assert_eq!(e.metadata["matchedBy"], "visible_title_and_uploader");
    assert!(f.requests().iter().any(|r| r.url.contains("w_rid=")));
    for mode in ["ambiguous", "wrong-uploader", "metadata-changed"] {
        let f = Fixture::new();
        if mode == "ambiguous" {
            f.search.lock().unwrap()["result"]
                .as_array_mut()
                .unwrap()
                .push(
                    json!({"bvid":"BV1xx411c7mD","author":"示例UP","title":"人工智能模型演示视频"}),
                );
        } else if mode == "wrong-uploader" {
            f.search.lock().unwrap()["result"][0]["author"] = json!("another");
        } else {
            f.view.lock().unwrap()["owner"]["name"] = json!("another");
        }
        let e = client(f.clone())
            .collect_video(&[], None, Some(("人工智能模型演示视频", "示例UP")))
            .await
            .unwrap();
        assert_eq!(e.status, VideoStatus::Unavailable, "{mode}");
        assert!(e.captions.is_empty() && e.frames.is_empty());
        if mode != "metadata-changed" {
            assert!(!f.requests().iter().any(|r| r.url.contains("/view?")));
        }
    }
}
#[test]
fn wbi_signature_matches_original_sdk_golden() {
    let f = Fixture::new();
    let nav = f.api("/x/web-interface/nav");
    let p = params(&[
        ("keyword", "人工智能 示例UP"),
        ("search_type", "video"),
        ("page", "1"),
        ("page_size", "20"),
    ]);
    let signed = evidence::signed_search(&p, &nav["wbi_img"], 1702204169).unwrap();
    assert_eq!(signed["w_rid"], "8745916ae8b9bb9be5a888fdf02b7eb0");
}
#[tokio::test]
async fn source_and_identifier_precedence_mismatch_and_unsupported_sources() {
    let f = Fixture::new();
    let c = client(f.clone());
    let e = c
        .collect_video(
            &[SOURCE.into()],
            Some("BV1xx411c7mD"),
            Some(("wrong title", "wrong author")),
        )
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Analyzed);
    assert!(!f.requests().iter().any(|r| r.url.contains("search/type")));
    f.view.lock().unwrap()["bvid"] = json!("BV1xx411c7mD");
    let e = c.collect_video(&[SOURCE.into()], None, None).await.unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
    assert!(e.captions.is_empty());
    let f = Fixture::new();
    let e = client(f.clone())
        .collect_video(&["https://www.youtube.com/watch?v=real".into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
    assert!(f.requests().is_empty());
    assert_eq!(
        evidence::observed_bvid("完整BV1d8pU6xEZX可见"),
        Some(BV.into())
    );
    assert!(evidence::observed_bvid("XBV1d8pU6xEZX").is_none());
    assert!(evidence::observed_bvid("BV1d8pU6xEZX0").is_none());
}
#[test]
fn safe_url_and_public_ip_boundaries() {
    for u in [
        "https://127.0.0.1/video",
        "https://bilibili.com.evil.test/video",
        "https://api.bilibili.com@127.0.0.1/",
        "file:///secret",
        "https://api.bilibili.com:444/",
        "https://bilibili.com/\\evil",
        "https://bilibili.com/\n",
    ] {
        assert!(http::allowed_url(u, true, false).is_err(), "{u}");
    }
    assert!(http::allowed_url("//i0.hdslb.com/a.jpg", true, false).is_ok());
    assert!(http::allowed_url("https://i0.hdslb.com/a.jpg", false, false).is_err());
    assert!(http::allowed_url("https://passport.bilibili.com/login", false, false).is_err());
    for ip in [
        "0.0.0.0",
        "127.0.0.1",
        "10.0.0.1",
        "169.254.169.254",
        "100.64.0.1",
        "172.16.0.1",
        "192.168.0.1",
        "192.0.2.1",
        "198.18.0.1",
        "224.0.0.1",
        "::1",
        "::ffff:8.8.8.8",
        "fc00::1",
        "fe80::1",
        "2001:db8::1",
        "2002:7f00:1::",
        "3fff::1",
    ] {
        assert!(!http::public_ip(ip.parse().unwrap()), "{ip}");
    }
    for ip in [
        "8.8.8.8",
        "1.1.1.1",
        "2001:4860:4860::8888",
        "2606:4700:4700::1111",
    ] {
        assert!(http::public_ip(ip.parse().unwrap()), "{ip}");
    }
}
#[tokio::test]
async fn redirects_revalidate_and_cookies_never_reach_shortener_or_cdn() {
    let f = Fixture::new();
    f.redirects.lock().unwrap().insert(
        "/redirect".into(),
        (302, "https://i0.hdslb.com/sheet.png".into()),
    );
    let http = http::BiliHttp::mock(f.clone()).with_credentials(Some(
        Credentials::from_value(&json!({"SESSDATA":"synthetic-session"})).unwrap(),
    ));
    http.fetch(
        "https://api.bilibili.com/redirect",
        true,
        1024 * 1024,
        false,
        Instant::now() + Duration::from_secs(1),
    )
    .await
    .unwrap();
    let calls = f.requests();
    assert!(
        calls[0]
            .cookie
            .as_ref()
            .unwrap()
            .contains("synthetic-session")
    );
    assert!(calls[1].cookie.is_none());
    f.redirects
        .lock()
        .unwrap()
        .insert("/short".into(), (302, SOURCE.into()));
    http.fetch(
        "https://b23.tv/short",
        false,
        512 * 1024,
        true,
        Instant::now() + Duration::from_secs(1),
    )
    .await
    .unwrap();
    assert!(f.requests().last().unwrap().cookie.is_none());
    for evil in [
        "https://127.0.0.1/secrets",
        "https://evil.example/leak",
        "https://api.bilibili.com:8443/private",
    ] {
        f.redirects
            .lock()
            .unwrap()
            .insert("/bad".into(), (302, evil.into()));
        let before = f.requests().len();
        assert!(
            http.fetch(
                "https://api.bilibili.com/bad",
                true,
                100,
                false,
                Instant::now() + Duration::from_secs(1)
            )
            .await
            .is_err()
        );
        assert_eq!(f.requests().len(), before + 1);
    }
    f.redirects
        .lock()
        .unwrap()
        .insert("/loop".into(), (302, "/loop".into()));
    let before = f.requests().len();
    assert!(
        http.fetch(
            "https://api.bilibili.com/loop",
            false,
            100,
            false,
            Instant::now() + Duration::from_secs(1)
        )
        .await
        .is_err()
    );
    assert_eq!(f.requests().len(), before + 4);
}
#[tokio::test]
async fn private_cookie_load_is_lazy_and_errors_never_leak_raw_platform_body() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fixture::new();
    let mut c = client(f.clone());
    c.credentials = Some(CredentialStore::new(&dir.path().join("missing.json")).unwrap());
    let e = c
        .collect_video(&["https://example.com/article".into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::None);
    assert!(f.requests().is_empty());
    let e = c.collect_video(&[SOURCE.into()], None, None).await.unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
    assert!(f.requests().is_empty());
    let f = Fixture::new();
    f.statuses
        .lock()
        .unwrap()
        .insert("/x/web-interface/view".into(), 412);
    let e = client(f)
        .collect_video(&[SOURCE.into()], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
    assert!(
        !e.model_context()
            .to_string()
            .contains("PRIVATE_PLATFORM_ERROR_COOKIE")
    );
}
struct Model {
    endpoint: String,
    calls: Arc<Mutex<Vec<Value>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Model {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Model {
    async fn new(answers: Vec<Value>) -> Self {
        use axum::{Json, Router, routing::post};
        let calls = Arc::new(Mutex::new(Vec::new()));
        let answers = Arc::new(Mutex::new(VecDeque::from(answers)));
        let (c, a) = (calls.clone(), answers.clone());
        let app=Router::new().route("/model",post(move|Json(body):Json<Value>|{let(c,a)=(c.clone(),a.clone());async move{c.lock().unwrap().push(body);let answer=a.lock().unwrap().pop_front().expect("model fixture response");Json(json!({"choices":[{"message":{"role":"assistant","content":answer.to_string()}}]}))}}));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}/model", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            endpoint,
            calls,
            task,
        }
    }
    fn client(&self, f: Arc<Fixture>) -> MemoryVideoClient {
        let mut c = client(f);
        c.endpoint = self.endpoint.clone();
        c
    }
}
fn analysis(video: bool) -> Value {
    json!({"summary":"# 模型演示\n\n模型训练学习特征，画面展示推理效果。","category":"ai","video_detected":video,"video_summary":"模型通过训练学习特征；抽样画面呈现推理效果。未提供音频证据。"})
}
fn request() -> Value {
    json!({"version":1,"type":"memory.analyze","request_id":"memory-1","content":"保存这个链接","source_urls":[SOURCE]})
}
#[tokio::test]
async fn real_http_model_receives_actual_evidence_and_no_history_or_tools() {
    let model = Model::new(vec![analysis(true)]).await;
    let f = Fixture::new();
    let result = model.client(f).analyze(&request()).await.unwrap();
    assert_eq!(result["video_status"], "analyzed");
    assert_eq!(result["source_url"], SOURCE);
    assert!(result["video_summary"].as_str().unwrap().contains("训练"));
    let wire = model.calls.lock().unwrap()[0].clone();
    assert_eq!(wire["messages"].as_array().unwrap().len(), 2);
    assert!(wire.get("tools").is_none() && wire.get("conversation_id").is_none());
    let payload = wire["messages"][1]["content"].as_array().unwrap();
    assert_eq!(
        payload.iter().filter(|p| p["type"] == "image_url").count(),
        3
    );
    assert!(wire.to_string().contains("模型通过训练学习特征"));
    assert!(!wire.to_string().contains("SESSDATA"));
}
#[tokio::test]
async fn no_evidence_or_missing_video_summary_cannot_claim_analyzed() {
    let f = Fixture::new();
    f.player.lock().unwrap()["subtitle"]["subtitles"] = json!([]);
    f.snapshot.lock().unwrap()["index"] = json!([]);
    let model = Model::new(vec![analysis(true)]).await;
    let r = model.client(f).analyze(&request()).await.unwrap();
    assert_eq!(r["video_status"], "unavailable");
    assert!(r.get("video_summary").is_none());
    let mut answer = analysis(true);
    answer.as_object_mut().unwrap().remove("video_summary");
    let model = Model::new(vec![answer]).await;
    let r = model
        .client(Fixture::new())
        .analyze(&request())
        .await
        .unwrap();
    assert_eq!(r["video_status"], "unavailable");
    assert!(r.get("video_summary").is_none());
}
#[tokio::test]
async fn first_pass_visible_search_and_second_pass_fallback_are_truthful() {
    let first = json!({"summary":"# 截图\n\n可见标题与UP主。","category":"other","video_detected":true,"video_platform":"bilibili","video_title":"人工智能模型演示视频","video_uploader":"示例UP"});
    let model = Model::new(vec![first.clone(), analysis(true)]).await;
    let mut req = request();
    req["content"] = json!("人工智能模型演示视频 示例UP");
    req["source_urls"] = json!([]);
    let result = model.client(Fixture::new()).analyze(&req).await.unwrap();
    assert_eq!(result["video_status"], "analyzed");
    assert_eq!(model.calls.lock().unwrap().len(), 2);
    assert!(
        model.calls.lock().unwrap()[1]
            .to_string()
            .contains("visible_title_and_uploader")
    );
    let model = Model::new(vec![
        first.clone(),
        json!({"summary":"bad","category":"other"}),
    ])
    .await;
    let result = model.client(Fixture::new()).analyze(&req).await.unwrap();
    assert_eq!(result["content"], first["summary"]);
    assert_eq!(result["video_status"], "unavailable");
    assert!(result.get("video_summary").is_none());
    // Without an image, a model-invented BV/title absent from text cannot trigger retrieval.
    let mut fabricated = first;
    fabricated["detected_bvid"] = json!(BV);
    let model = Model::new(vec![fabricated]).await;
    req["content"] = json!("unrelated original text");
    let f = Fixture::new();
    let r = model.client(f.clone()).analyze(&req).await.unwrap();
    assert_eq!(r["video_status"], "unavailable");
    assert!(f.requests().is_empty());
}
#[tokio::test]
async fn request_envelope_limits_and_mock_never_fetch() {
    let mut c = client(Fixture::new());
    c.mock = true;
    for patch in [
        json!({"source_urls":vec![SOURCE;33]}),
        json!({"content":"中".repeat(33334)}),
        json!({"image_base64":"not base64"}),
    ] {
        let mut r = request();
        r.as_object_mut()
            .unwrap()
            .extend(patch.as_object().unwrap().clone());
        assert!(c.analyze(&r).await.is_err());
    }
    let r = c.analyze(&request()).await.unwrap();
    assert_eq!(r["video_status"], "unavailable");
    assert!(r["content"].as_str().unwrap().contains("Synthetic"));
}
#[tokio::test(start_paused = true)]
async fn qr_login_states_set_cookie_and_atomic_private_storage() {
    let dir = tempfile::tempdir().unwrap();
    let store = CredentialStore::new(&dir.path().join("credential.json")).unwrap();
    let f = Fixture::new();
    f.login_data(json!(86101), vec![]);
    f.login_data(json!(86090), vec![]);
    f.login_data(
        json!(0),
        vec![
            "SESSDATA=RAW,SESSION; Domain=.bilibili.com; Secure; HttpOnly".into(),
            "bili_jct=CSRF_SECRET; Path=/".into(),
            "DedeUserID=123; Path=/".into(),
            "sid=IGNORED_SECRET".into(),
        ],
    );
    let login = BiliLogin::with_http(store.clone(), http::BiliHttp::mock(f.clone()));
    let mut session = login.begin(Duration::from_secs(30)).await.unwrap();
    assert_eq!(session.state(), LoginState::AwaitingScan);
    assert!(session.qr_png().starts_with(b"\x89PNG\r\n\x1a\n"));
    assert!(image::load_from_memory(session.qr_png()).unwrap().width() > 200);
    session.write_qr(&dir.path().join("qr.png")).await.unwrap();
    assert!(
        session
            .write_qr(&dir.path().join("credential.json"))
            .await
            .is_err()
    );
    assert_eq!(session.poll().await.unwrap(), LoginState::AwaitingScan);
    assert_eq!(
        session.poll().await.unwrap(),
        LoginState::AwaitingConfirmation
    );
    assert!(matches!(
        session.poll().await.unwrap(),
        LoginState::Authorized { .. }
    ));
    // Once committed, cancellation is not a logout and cannot claim the save vanished.
    session.cancellation().cancel();
    session.cancel();
    assert!(matches!(session.state(), LoginState::Authorized { .. }));
    assert!(matches!(
        session.poll().await.unwrap(),
        LoginState::Authorized { .. }
    ));
    let saved: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("credential.json")).unwrap())
            .unwrap();
    assert_eq!(saved["SESSDATA"], "RAW%2CSESSION");
    assert_eq!(saved["bili_jct"], "CSRF_SECRET");
    assert!(saved.get("sid").is_none());
    assert!(format!("{:?}", store.load().await.unwrap()).contains("redacted"));
    assert!(!format!("{:?}", session.state()).contains("CSRF_SECRET"));
    assert!(f.requests().iter().all(|r| r.cookie.is_none()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(dir.path().join("credential.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(dir.path().join("qr.png"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
#[tokio::test(start_paused = true)]
async fn expired_cancelled_unknown_or_missing_session_never_overwrite() {
    for code in [json!(86038), json!(86104), json!(false), json!(0)] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credential.json");
        std::fs::write(&path, b"keep-old").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let f = Fixture::new();
        f.login_data(code, vec!["bili_jct=NO_SESSION".into()]);
        let login = BiliLogin::with_http(
            CredentialStore::new(&path).unwrap(),
            http::BiliHttp::mock(f),
        );
        let mut session = login.begin(Duration::from_secs(15)).await.unwrap();
        let _ = session.poll().await;
        assert_eq!(std::fs::read(&path).unwrap(), b"keep-old");
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("credential.json");
    let f = Fixture::new();
    let login = BiliLogin::with_http(
        CredentialStore::new(&path).unwrap(),
        http::BiliHttp::mock(f.clone()),
    );
    let mut session = login.begin(Duration::from_secs(15)).await.unwrap();
    tokio::time::advance(Duration::from_secs(16)).await;
    assert_eq!(session.poll().await.unwrap(), LoginState::Expired);
    assert_eq!(f.requests().len(), 1);
    assert!(!path.exists());
    let mut session = login.begin(Duration::from_secs(15)).await.unwrap();
    session.cancel();
    assert_eq!(session.poll().await.unwrap(), LoginState::Cancelled);
    assert!(!path.exists());
}
#[tokio::test]
async fn cancellation_during_poll_discards_authorized_cookie() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("credential.json");
    let f = Fixture::new();
    f.login_data(json!(0), vec!["SESSDATA=MUST_NOT_SAVE".into()]);
    f.block_poll.store(true, Ordering::SeqCst);
    let login = BiliLogin::with_http(
        CredentialStore::new(&path).unwrap(),
        http::BiliHttp::mock(f.clone()),
    );
    let mut session = login.begin(Duration::from_secs(15)).await.unwrap();
    let cancel = session.cancellation();
    let job = tokio::spawn(async move { session.poll().await });
    f.poll_entered.notified().await;
    cancel.cancel();
    f.poll_release.notify_one();
    assert_eq!(job.await.unwrap().unwrap(), LoginState::Cancelled);
    assert!(!path.exists());
}
#[tokio::test]
async fn credential_schema_permissions_symlinks_and_lazy_missing() {
    for value in [
        json!({"SESSDATA":"a;b"}),
        json!({"SESSDATA":"a\r\nb"}),
        json!({"SESSDATA":"a b"}),
        json!({"SESSDATA":false}),
        json!({"bili_jct":"no-session"}),
        json!({"SESSDATA":"session","sid":"unknown"}),
    ] {
        assert!(Credentials::from_value(&value).is_err());
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cookie.json");
    assert!(
        CredentialStore::optional(&path)
            .unwrap()
            .load()
            .await
            .unwrap()
            .is_none()
    );
    assert!(CredentialStore::new(&path).unwrap().load().await.is_err());
    assert!(CredentialStore::new(std::path::Path::new("relative.json")).is_err());
    std::fs::write(&path, br#"{"SESSDATA":"synthetic"}"#).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::{PermissionsExt, symlink};
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(CredentialStore::new(&path).unwrap().load().await.is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            CredentialStore::new(&path)
                .unwrap()
                .load()
                .await
                .unwrap()
                .is_some()
        );
        let link = dir.path().join("link.json");
        symlink(&path, &link).unwrap();
        assert!(CredentialStore::new(&link).unwrap().load().await.is_err());
        let hard = dir.path().join("hard.json");
        std::fs::hard_link(&path, &hard).unwrap();
        assert!(CredentialStore::new(&path).unwrap().load().await.is_err());
    }
}

#[tokio::test]
#[ignore = "requires ORIALIS_REAL_SERVER_BIN; Bilibili transport remains fixture-only"]
async fn actual_server_persists_video_analysis_without_chat_history() -> Result<()> {
    use futures_util::{SinkExt, StreamExt};
    use sha2::{Digest, Sha256};
    use tokio_tungstenite::{
        connect_async,
        tungstenite::{Message, client::IntoClientRequest},
    };
    struct Server(std::process::Child);
    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let directory = tempfile::tempdir()?;
    let database = directory.path().join("server.sqlite");
    let port = {
        let socket = std::net::TcpListener::bind("127.0.0.1:0")?;
        socket.local_addr()?.port()
    };
    let origin = format!("http://127.0.0.1:{port}");
    let child = std::process::Command::new(std::env::var("ORIALIS_REAL_SERVER_BIN")?)
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
        .env("ORIALIS_UPLOAD_DIR", directory.path().join("uploads"))
        .env("ORIALIS_AGENT_DEVICE_TOKEN", "synthetic-video-agent-token")
        .env("ORIALIS_AGENT_USER_ID", "video-owner")
        .env("RUST_LOG", "error")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .spawn()?;
    let _server = Server(child);
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()?;
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
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    ensure!(ready, "isolated Orialis server failed to start");
    let db = rusqlite::Connection::open(&database)?;
    for user in ["video-owner", "other-owner"] {
        db.execute(
            "INSERT INTO users(id,username,password_hash) VALUES(?1,?1,'synthetic-no-login')",
            [user],
        )?;
        db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES(?1,?1,?2,'2099-01-01T00:00:00Z')",rusqlite::params![user,format!("{:x}",Sha256::digest(user.as_bytes()))])?;
    }
    let before: i64 = db.query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))?;
    let mut upgrade = format!("ws://127.0.0.1:{port}/api/v1/agent/ws").into_client_request()?;
    upgrade.headers_mut().insert(
        "authorization",
        "Bearer synthetic-video-agent-token".parse()?,
    );
    let (mut ws, _) = connect_async(upgrade).await?;
    ws.send(Message::Text(json!({"version":1,"type":"hello","device_id":"JXCZ_AOZORA_Hermes","client":"orialis-rust-core","plugin_version":"test","platform":"linux","capabilities":["memory.analyze"]}).to_string().into())).await?;
    let hello: Value = serde_json::from_str(ws.next().await.context("hello closed")??.to_text()?)?;
    assert_eq!(hello["type"], "hello_ack");
    ws.send(Message::Text(
        json!({"version":1,"type":"capabilities.hello","capabilities":["memory.analyze"]})
            .to_string()
            .into(),
    ))
    .await?;
    let ack: Value = serde_json::from_str(ws.next().await.context("caps closed")??.to_text()?)?;
    assert_eq!(ack["type"], "capabilities.ack");
    let endpoint = format!("{origin}/api/v1/memory/analyses/capture-video");
    let input = json!({"content":"保存这个视频的重点","sourceUrls":[SOURCE]});
    let submitted = http
        .post(&endpoint)
        .header("authorization", "Session video-owner")
        .json(&input)
        .send()
        .await?;
    ensure!(submitted.status().is_success(), "memory submission failed");
    assert_eq!(submitted.json::<Value>().await?["status"], "analyzing");
    let frame: Value = serde_json::from_str(
        tokio::time::timeout(Duration::from_secs(2), ws.next())
            .await?
            .context("memory request closed")??
            .to_text()?,
    )?;
    assert_eq!(frame["type"], "memory.analyze");
    assert_eq!(frame["source_urls"], json!([SOURCE]));
    let model = Model::new(vec![analysis(true)]).await;
    let answer = model.client(Fixture::new()).analyze(&frame).await?;
    assert_eq!(answer["video_status"], "analyzed");
    ws.send(Message::Text(answer.to_string().into())).await?;
    let stored = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let v = http
                .get(&endpoint)
                .header("authorization", "Session video-owner")
                .send()
                .await?
                .json::<Value>()
                .await?;
            if v["status"] != "analyzing" {
                return Ok::<Value, anyhow::Error>(v);
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await??;
    assert_eq!(stored["status"], "completed");
    assert_eq!(stored["category"], "ai");
    assert_eq!(stored["videoStatus"], "analyzed");
    assert_eq!(stored["sourceUrl"], SOURCE);
    assert_eq!(stored["videoSummary"], answer["video_summary"]);
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM messages", [], |r| r.get::<_, i64>(0))?,
        before
    );
    assert_eq!(
        http.post(&endpoint)
            .header("authorization", "Session video-owner")
            .json(&input)
            .send()
            .await?
            .json::<Value>()
            .await?["status"],
        "completed"
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(50), ws.next())
            .await
            .is_err()
    );
    assert_eq!(
        http.post(&endpoint)
            .header("authorization", "Session video-owner")
            .json(&json!({"content":"changed evidence","sourceUrls":[SOURCE]}))
            .send()
            .await?
            .status()
            .as_u16(),
        409
    );
    assert_eq!(
        http.get(&endpoint)
            .header("authorization", "Session other-owner")
            .send()
            .await?
            .status()
            .as_u16(),
        404
    );
    println!(
        "REAL SCREEN: fixed Orialis memory HTTP -> real agent WS -> genuine fixture caption/cropped-JPEG evidence -> local HTTP model -> memory.result -> persisted category/videoStatus/videoSummary; exact-source preserved, duplicate not rerun, changed evidence 409, other owner 404, no chat messages. Bilibili itself remains mocked, not production-authorized."
    );
    Ok(())
}

#[tokio::test]
async fn real_http_reader_enforces_content_length_chunk_limit_and_redirect_body_avoidance() {
    use axum::{Router, body::Body, http::Response, routing::get};
    let app = Router::new()
        .route(
            "/large",
            get(|| async {
                Response::builder()
                    .header("content-length", "1000")
                    .body(Body::from(vec![0u8; 1000]))
                    .unwrap()
            }),
        )
        .route(
            "/chunked",
            get(|| async {
                let stream = futures_util::stream::iter([
                    Ok::<_, std::io::Error>(vec![0u8; 80]),
                    Ok(vec![0u8; 80]),
                ]);
                Response::builder().body(Body::from_stream(stream)).unwrap()
            }),
        )
        .route(
            "/redirect",
            get(|| async {
                Response::builder()
                    .status(302)
                    .header("location", "https://evil.example/leak")
                    .body(Body::from("PRIVATE_DIAGNOSTIC_BODY".repeat(1000)))
                    .unwrap()
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let reader = http::BiliHttp::loopback_reader();
    for path in ["/large", "/chunked"] {
        assert!(
            reader
                .get(
                    &reqwest::Url::parse(&(base.clone() + path)).unwrap(),
                    None,
                    100,
                    Instant::now() + Duration::from_secs(1)
                )
                .await
                .is_err()
        );
    }
    let reply = reader
        .get(
            &reqwest::Url::parse(&(base + "/redirect")).unwrap(),
            None,
            100,
            Instant::now() + Duration::from_secs(1),
        )
        .await
        .unwrap();
    assert_eq!(reply.status, 302);
    assert!(reply.body.is_empty());
    assert_eq!(reply.location.as_deref(), Some("https://evil.example/leak"));
    task.abort();
}
#[tokio::test]
async fn nonfinite_and_invalid_metadata_fail_closed_without_wrong_evidence() {
    for value in [
        json!(-1),
        json!("not-a-duration"),
        serde_json::from_str("1e999").unwrap(),
    ] {
        let f = Fixture::new();
        f.view.lock().unwrap()["pages"][1]["duration"] = value;
        let e = client(f.clone())
            .collect_video(&[SOURCE.into()], None, None)
            .await
            .unwrap();
        assert_eq!(e.status, VideoStatus::Unavailable);
        assert!(e.captions.is_empty() && e.frames.is_empty());
        assert!(!f.requests().iter().any(|r| r.url.contains("/v2?")));
    }
    for value in [json!(-1), json!("bad"), json!(1921)] {
        let f = Fixture::new();
        f.snapshot.lock().unwrap()["img_x_size"] = value;
        let e = client(f)
            .collect_video(&[SOURCE.into()], None, None)
            .await
            .unwrap();
        assert_eq!(e.status, VideoStatus::Analyzed);
        assert!(e.frames.is_empty());
        assert!(!e.captions.is_empty());
    }
    let f = Fixture::new();
    let e = client(f)
        .collect_video(&[SOURCE.replace("p=2", "p=3")], None, None)
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Unavailable);
}
#[tokio::test]
async fn truncated_titles_only_match_when_long_explicit_and_identity_normalized() {
    let full = "这是一个足够长的人工智能模型演示视频完整版";
    for (observed, status) in [
        ("这是一个足够长的人工智能模型演示…", VideoStatus::Analyzed),
        ("这是一个足够长的人工智能模型演示", VideoStatus::Unavailable),
        ("模型…", VideoStatus::Unavailable),
    ] {
        let f = Fixture::new();
        f.search.lock().unwrap()["result"][0]["title"] = json!(full);
        f.view.lock().unwrap()["title"] = json!(full);
        let e = client(f)
            .collect_video(&[], None, Some((observed, "@示例 UP")))
            .await
            .unwrap();
        assert_eq!(e.status, status, "{observed}");
    }
    let f = Fixture::new();
    f.search.lock().unwrap()["result"][0]["title"] = json!("AI &amp; 模型实测");
    f.search.lock().unwrap()["result"][0]["author"] = json!("Straße");
    f.view.lock().unwrap()["title"] = json!("AI & 模型实测");
    f.view.lock().unwrap()["owner"]["name"] = json!("Straße");
    let e = client(f)
        .collect_video(&[], None, Some(("ＡＩ & 模型实测", "STRASSE")))
        .await
        .unwrap();
    assert_eq!(e.status, VideoStatus::Analyzed);
}
#[tokio::test(start_paused = true)]
async fn total_deadline_includes_waiting_for_worker_capacity() {
    let c = client(Fixture::new());
    let permits = c.permits.clone();
    let _a = permits.acquire().await.unwrap();
    let _b = permits.acquire().await.unwrap();
    let job = tokio::spawn(async move { c.analyze(&request()).await });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(286)).await;
    assert!(job.await.unwrap().is_err());
}

#[tokio::test]
async fn login_preflight_blocks_unsafe_destination_before_http_and_cookies_are_validated() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("credentials.json");
    std::fs::write(&path, b"preserve-existing-file").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let fixture = Fixture::new();
        let login = BiliLogin::with_http(
            CredentialStore::new(&path).unwrap(),
            http::BiliHttp::mock(fixture.clone()),
        );
        assert!(login.begin(Duration::from_secs(30)).await.is_err());
        assert!(fixture.requests().is_empty());
        assert_eq!(std::fs::read(&path).unwrap(), b"preserve-existing-file");
    }
    for (cookie, success) in [
        ("SESSDATA=\"raw,session\"; Domain=.bilibili.com", true),
        ("SESSDATA=\"unterminated; Domain=.bilibili.com", false),
        ("SESSDATA=with space; Domain=.bilibili.com", false),
        ("SESSDATA=value; Domain=evil.example", false),
        ("SESSDATA=value; Max-Age=0", false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let fixture = Fixture::new();
        fixture.login_data(json!(0), vec![cookie.into()]);
        let login = BiliLogin::with_http(
            CredentialStore::new(&path).unwrap(),
            http::BiliHttp::mock(fixture),
        );
        let mut session = login.begin(Duration::from_secs(30)).await.unwrap();
        assert_eq!(session.poll().await.is_ok(), success);
        assert_eq!(path.exists(), success);
        if !success {
            assert_eq!(session.state(), LoginState::Failed);
            session.cancel();
            assert_eq!(session.state(), LoginState::Failed);
        }
    }
}

/// Loopback HTTP fixture whose responses are explicitly released in waves. This
/// verifies actual model requests rather than only inspecting semaphore state.
mod concurrency {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct Counts {
        entered: AtomicUsize,
        active: AtomicUsize,
        peak: AtomicUsize,
        release: tokio::sync::Semaphore,
    }
    struct Active(Arc<Counts>);
    impl Drop for Active {
        fn drop(&mut self) {
            self.0.active.fetch_sub(1, Ordering::SeqCst);
        }
    }
    struct GatedModel {
        provider: crate::Provider,
        counts: Arc<Counts>,
        server: tokio::task::JoinHandle<()>,
    }
    impl Drop for GatedModel {
        fn drop(&mut self) {
            self.counts.release.close();
            self.server.abort();
        }
    }
    impl GatedModel {
        async fn new() -> Self {
            use axum::{Json, Router, routing::post};
            let counts = Arc::new(Counts {
                entered: AtomicUsize::new(0),
                active: AtomicUsize::new(0),
                peak: AtomicUsize::new(0),
                release: tokio::sync::Semaphore::new(0),
            });
            let state = counts.clone();
            let app = Router::new().route(
                "/model",
                post(move |Json(body): Json<Value>| {
                    let counts = state.clone();
                    async move {
                        assert_eq!(body["messages"].as_array().unwrap().len(), 2);
                        assert_eq!(body["messages"][1]["content"][1]["type"], "image_url");
                        let active = counts.active.fetch_add(1, Ordering::SeqCst) + 1;
                        let _active = Active(counts.clone());
                        counts.peak.fetch_max(active, Ordering::SeqCst);
                        counts.entered.fetch_add(1, Ordering::SeqCst);
                        if let Ok(permit) = counts.release.acquire().await {
                            permit.forget();
                        }
                        Json(json!({"choices":[{"message":{"role":"assistant","content":analysis(false).to_string()}}]}))
                    }
                }),
            );
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("http://{}/model", listener.local_addr().unwrap());
            let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            Self {
                provider: crate::Provider::new(endpoint, "fixture".into(), None, false).unwrap(),
                counts,
                server,
            }
        }
        async fn wait_entered(&self, expected: usize) {
            tokio::time::timeout(Duration::from_secs(3), async {
                while self.counts.entered.load(Ordering::SeqCst) < expected {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .expect("expected real HTTP model request did not arrive");
        }
    }
    fn screen_request(id: usize) -> Value {
        let mut jpeg = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::new(2, 2))
            .write_to(&mut jpeg, image::ImageFormat::Jpeg)
            .unwrap();
        json!({"version":1,"type":"memory.analyze","request_id":format!("concurrency-{id}"),"content":"A plain desktop note","image_base64":STANDARD.encode(jpeg.into_inner())})
    }
    fn start(client: &MemoryVideoClient, id: usize) -> tokio::task::JoinHandle<Result<Value>> {
        let client = client.clone();
        let request = screen_request(id);
        tokio::spawn(async move { client.analyze(&request).await })
    }

    #[tokio::test]
    async fn memory_concurrency_real_http_two_and_four_permits_bound_batch_waves() {
        let mut waves = Vec::new();
        for concurrency in [2, 4] {
            let model = GatedModel::new().await;
            let client =
                MemoryVideoClient::new_with_concurrency(&model.provider, None, concurrency)
                    .unwrap();
            // More requests than capacity, using clones of the same client.
            let jobs = (0..4).map(|id| start(&client, id)).collect::<Vec<_>>();
            let mut count = 0;
            for entered in (concurrency..=4).step_by(concurrency) {
                model.wait_entered(entered).await;
                tokio::time::sleep(Duration::from_millis(20)).await;
                assert_eq!(model.counts.entered.load(Ordering::SeqCst), entered);
                assert_eq!(model.counts.active.load(Ordering::SeqCst), concurrency);
                assert_eq!(client.permits.available_permits(), 0);
                model.counts.release.add_permits(concurrency);
                count += 1;
            }
            for (id, job) in jobs.into_iter().enumerate() {
                let result = tokio::time::timeout(Duration::from_secs(3), job)
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                assert_eq!(result["request_id"], format!("concurrency-{id}"));
                assert_eq!(result["video_status"], "none");
            }
            assert_eq!(model.counts.peak.load(Ordering::SeqCst), concurrency);
            assert_eq!(model.counts.active.load(Ordering::SeqCst), 0);
            assert_eq!(client.permits.available_permits(), concurrency);
            waves.push(count);
        }
        assert_eq!(
            waves,
            vec![2, 1],
            "four requests need two waves at 2, one at 4"
        );
    }

    #[tokio::test]
    async fn memory_concurrency_cancelling_queued_and_active_http_calls_releases_capacity() {
        let model = GatedModel::new().await;
        let client = MemoryVideoClient::new_with_concurrency(&model.provider, None, 1).unwrap();
        let active = start(&client, 0);
        model.wait_entered(1).await;
        let queued = start(&client, 1);
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(model.counts.entered.load(Ordering::SeqCst), 1);
        queued.abort();
        assert!(queued.await.unwrap_err().is_cancelled());
        assert_eq!(client.permits.available_permits(), 0);
        active.abort();
        assert!(active.await.unwrap_err().is_cancelled());
        assert_eq!(client.permits.available_permits(), 1);
        let replacement = start(&client, 2);
        model.wait_entered(2).await;
        // A remote model may keep processing an abandoned request; cancellation
        // must still release local admission without waiting for its response.
        model.counts.release.add_permits(2);
        let result = tokio::time::timeout(Duration::from_secs(3), replacement)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(result["request_id"], "concurrency-2");
        assert_eq!(client.permits.available_permits(), 1);
    }

    #[test]
    fn memory_concurrency_constructor_preserves_default_and_rejects_out_of_range() {
        let provider = crate::Provider::new(
            "http://127.0.0.1:1/model".into(),
            "fixture".into(),
            None,
            false,
        )
        .unwrap();
        assert_eq!(
            MemoryVideoClient::new(&provider, None)
                .unwrap()
                .permits
                .available_permits(),
            2
        );
        for concurrency in 1..=4 {
            assert_eq!(
                MemoryVideoClient::new_with_concurrency(&provider, None, concurrency)
                    .unwrap()
                    .permits
                    .available_permits(),
                concurrency
            );
        }
        for concurrency in [0, 5, usize::MAX] {
            let result = MemoryVideoClient::new_with_concurrency(&provider, None, concurrency);
            assert!(result.is_err());
            assert_eq!(
                result.err().unwrap().to_string(),
                "memory concurrency must be between 1 and 4"
            );
        }
    }
}
