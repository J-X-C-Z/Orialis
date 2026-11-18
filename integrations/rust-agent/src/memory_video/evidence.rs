use super::*;
use image::GenericImageView;
use md5::{Digest, Md5};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;
const WBI_ORDER: [usize; 32] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13,
];
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VideoStatus {
    None,
    Analyzed,
    Unavailable,
}
impl VideoStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Analyzed => "analyzed",
            Self::Unavailable => "unavailable",
        }
    }
}
#[derive(Clone)]
pub struct VideoFrame {
    pub seconds: f64,
    pub jpeg_base64: String,
}
#[derive(Clone)]
pub struct VideoEvidence {
    pub source_url: Option<String>,
    pub status: VideoStatus,
    pub error: Option<String>,
    pub metadata: Value,
    pub captions: String,
    pub frames: Vec<VideoFrame>,
}
impl VideoEvidence {
    pub fn model_context(&self) -> Value {
        json!({"status":self.status.as_str(),"sourceUrl":self.source_url,"metadata":self.metadata,"captions":self.captions,"frameTimesSeconds":self.frames.iter().map(|f|f.seconds).collect::<Vec<_>>(),"evidenceCoverage":{"hasCaptions":!self.captions.is_empty(),"frameCount":self.frames.len(),"continuousVideo":false,"audioUnderstood":false},"limitations":"字幕仅代表平台提供的文字；画面为故事板抽样帧，不代表完整观看或已理解音频。","error":self.error})
    }
    pub(super) fn empty(source: Option<String>) -> Self {
        Self {
            source_url: source,
            status: VideoStatus::None,
            error: None,
            metadata: json!({}),
            captions: String::new(),
            frames: Vec::new(),
        }
    }
}
pub fn valid_bvid(value: &str) -> bool {
    value.len() == 12
        && value.starts_with("BV")
        && value.as_bytes()[2..].iter().all(u8::is_ascii_alphanumeric)
}
pub(super) fn observed_bvid(value: &str) -> Option<String> {
    let b = value.as_bytes();
    b.windows(12).enumerate().find_map(|(i, w)| {
        (w.starts_with(b"BV")
            && w[2..].iter().all(u8::is_ascii_alphanumeric)
            && (i == 0 || !b[i - 1].is_ascii_alphanumeric())
            && (i + 12 == b.len() || !b[i + 12].is_ascii_alphanumeric()))
        .then(|| String::from_utf8(w.to_vec()).expect("ASCII BVID"))
    })
}
fn visible_title(value: &str) -> String {
    static EM: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let no_em = EM
        .get_or_init(|| regex::Regex::new(r"(?i)</?em(?:\s[^>]*)?>").unwrap())
        .replace_all(value, "");
    html_escape::decode_html_entities(&no_em).trim().to_owned()
}
fn identity(value: &str, title: bool) -> String {
    let visible = visible_title(value);
    let folded = visible.nfkc().case_fold().collect::<String>();
    if title {
        folded.chars().filter(|c| c.is_alphanumeric()).collect()
    } else {
        folded
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>()
            .trim_start_matches('@')
            .to_owned()
    }
}
fn title_matches(observed: &str, actual: &str) -> bool {
    let a = identity(observed, true);
    let b = identity(actual, true);
    a.chars().count() >= 4
        && (a == b
            || (a.chars().count() >= 12
                && (observed.trim_end().ends_with('…') || observed.trim_end().ends_with("..."))
                && b.starts_with(&a)))
}
pub(super) fn signed_search(
    params: &BTreeMap<String, String>,
    images: &Value,
    timestamp: u64,
) -> Result<BTreeMap<String, String>> {
    let mut material = String::new();
    for name in ["img_url", "sub_url"] {
        let u = reqwest::Url::parse(images[name].as_str().context("平台未提供有效搜索签名")?)
            .map_err(|_| anyhow::anyhow!("平台未提供有效搜索签名"))?;
        let key = u
            .path()
            .rsplit('/')
            .next()
            .unwrap_or("")
            .split('.')
            .next()
            .unwrap_or("");
        ensure!(
            key.len() == 32 && key.bytes().all(|b| b.is_ascii_hexdigit()),
            "平台未提供有效搜索签名"
        );
        material.push_str(key);
    }
    let key: String = WBI_ORDER
        .iter()
        .map(|i| material.as_bytes()[*i] as char)
        .collect();
    let mut out = params.clone();
    out.insert("web_location".into(), "1550101".into());
    out.insert("wts".into(), timestamp.to_string());
    let signature = format!(
        "{:x}",
        Md5::digest(format!("{}{key}", http::query(&out)).as_bytes())
    );
    out.insert("w_rid".into(), signature);
    Ok(out)
}
async fn search(
    http: &http::BiliHttp,
    title: &str,
    uploader: &str,
    deadline: Instant,
) -> Result<String> {
    ensure!(
        (4..=300).contains(&title.trim().chars().count())
            && (1..=100).contains(&uploader.trim().chars().count()),
        "未看清完整的视频标题和UP主，请分享原视频链接后重试"
    );
    let query = format!(
        "{} {}",
        title.trim().trim_end_matches(['.', '…', ' ']),
        uploader.trim()
    );
    let p = params(&[
        ("keyword", &query),
        ("search_type", "video"),
        ("page", "1"),
        ("page_size", "20"),
    ]);
    let nav = http
        .data("/x/web-interface/nav", &BTreeMap::new(), deadline)
        .await?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let signed = signed_search(&p, &nav["wbi_img"], timestamp)?;
    let data = http
        .data("/x/web-interface/wbi/search/type", &signed, deadline)
        .await?;
    let rows = data["result"].as_array().context("平台返回无效搜索结果")?;
    let mut candidates = std::collections::BTreeSet::new();
    for item in rows.iter().take(20) {
        if let (Some(bvid), Some(author), Some(actual)) = (
            item["bvid"].as_str(),
            item["author"].as_str(),
            item["title"].as_str(),
        ) && valid_bvid(bvid)
            && identity(author, false) == identity(uploader, false)
            && title_matches(title, actual)
        {
            candidates.insert(bvid.to_owned());
        }
    }
    ensure!(
        !candidates.is_empty(),
        "未找到标题与UP主同时匹配的视频；请分享原链接"
    );
    ensure!(
        candidates.len() == 1,
        "有多个标题与UP主相符的视频，暂无法确定原视频"
    );
    Ok(candidates.into_iter().next().unwrap())
}
fn other_video(value: &str) -> bool {
    http::url::parse(value).is_ok_and(|u| {
        let host = u.host_str().unwrap_or("");
        [
            "youtube.com",
            "youtu.be",
            "douyin.com",
            "iesdouyin.com",
            "kuaishou.com",
            "tiktok.com",
            "ixigua.com",
            "xiaohongshu.com",
            "xhslink.com",
            "vimeo.com",
        ]
        .iter()
        .any(|d| host == *d || host.ends_with(&format!(".{d}")))
            || [".mp4", ".webm", ".mov", ".m3u8"]
                .iter()
                .any(|e| u.path().to_ascii_lowercase().ends_with(e))
    })
}
fn number(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str()?.parse::<f64>().ok())
        .filter(|n| n.is_finite())
}
fn positive_id(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_str()?.parse().ok())
        .filter(|n| *n > 0)
}
pub(super) async fn collect(
    client: &MemoryVideoClient,
    urls: &[String],
    detected: Option<&str>,
    hint: Option<(&str, &str)>,
) -> VideoEvidence {
    let source = urls.iter().find(|u| http::source_url(u)).cloned();
    let observed = detected.filter(|s| valid_bvid(s));
    let mut result = VideoEvidence::empty(source.clone().or_else(|| urls.first().cloned()));
    if source.is_none() && observed.is_none() {
        if urls.iter().any(|u| other_video(u)) {
            result.status = VideoStatus::Unavailable;
            result.error =
                Some("当前仅支持哔哩哔哩视频内容理解；此平台的原始链接和截图摘要已保留".into());
            return result;
        }
        if hint.is_none() {
            return result;
        }
    }
    result.status = VideoStatus::Unavailable;
    let deadline = Instant::now() + Duration::from_secs(65);
    let collected = tokio::time::timeout_at(
        deadline + Duration::from_secs(5),
        collect_verified(client, source, observed, hint, deadline, &mut result),
    )
    .await;

    if !matches!(collected, Ok(Ok(()))) {
        result.status = VideoStatus::Unavailable;
        result.error = Some(
            if collected.is_err() {
                "视频内容读取超时，已保留原始链接，可稍后重试"
            } else {
                "暂未取得可理解的视频内容，可能受平台登录、风控、内容权限或来源核验限制；可重试"
            }
            .into(),
        );
    }
    result
}
async fn collect_verified(
    client: &MemoryVideoClient,
    source: Option<String>,
    observed: Option<&str>,
    hint: Option<(&str, &str)>,
    deadline: Instant,
    result: &mut VideoEvidence,
) -> Result<()> {
    let credentials = if let Some(store) = &client.credentials {
        store.load().await?
    } else {
        None
    };
    let http = client.http.with_credentials(credentials);
    let mut page = 1usize;
    let from_search = source.is_none() && observed.is_none();
    let identifier = if let Some(source) = &source {
        let parsed = http::url::parse(source)?;
        let resolved = if parsed.host_str() == Some("b23.tv") {
            http.fetch(source, false, 512 * 1024, true, deadline)
                .await?
                .1
        } else {
            source.clone()
        };
        ensure!(http::source_url(&resolved), "短链接未指向哔哩哔哩视频");
        let parsed = http::url::parse(&resolved)?;
        static IDENTIFIER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        let found = IDENTIFIER
            .get_or_init(|| {
                regex::Regex::new(r"/video/(BV[0-9A-Za-z]{10}|av[0-9]+)(?:/|$)").unwrap()
            })
            .captures(parsed.path())
            .context("原始链接中没有可验证的视频编号")?;
        if let Some((_, p)) = parsed.query_pairs().find(|(k, _)| k == "p") {
            page = p
                .parse()
                .map_err(|_| anyhow::anyhow!("原始链接视频分段无效"))?;
        }
        found[1].to_owned()
    } else if let Some(id) = observed {
        id.to_owned()
    } else {
        let (title, uploader) = hint.unwrap();
        search(&http, title, uploader, deadline).await?
    };
    let p = if identifier.starts_with("BV") {
        params(&[("bvid", &identifier)])
    } else {
        params(&[("aid", &identifier[2..])])
    };
    let info = http.data("/x/web-interface/view", &p, deadline).await?;
    let bvid = info["bvid"].as_str().context("视频编号未通过平台核验")?;
    ensure!(
        valid_bvid(bvid) && (!identifier.starts_with("BV") || bvid == identifier),
        "视频编号未通过平台核验"
    );
    if let Some(aid) = identifier.strip_prefix("av") {
        ensure!(
            positive_id(&info["aid"]).map(|n| n.to_string()).as_deref() == Some(aid),
            "视频编号未通过平台核验"
        );
    }
    if from_search {
        let (title, uploader) = hint.unwrap();
        ensure!(
            title_matches(title, info["title"].as_str().unwrap_or(""))
                && identity(uploader, false)
                    == identity(info["owner"]["name"].as_str().unwrap_or(""), false),
            "搜索结果与原视频的标题或UP主不一致，未采用该视频"
        );
    }
    let fallback = vec![json!({"cid":info["cid"],"duration":info["duration"]})];
    let pages = info["pages"]
        .as_array()
        .filter(|a| !a.is_empty())
        .unwrap_or(&fallback);
    ensure!(
        page >= 1 && page <= pages.len(),
        "原始链接指定的视频分段不存在"
    );
    let part = &pages[page - 1];
    let cid = positive_id(&part["cid"]).context("平台没有返回有效视频分段")?;
    let supplied_duration = part
        .get("duration")
        .filter(|v| !v.is_null() && **v != 0 && **v != "")
        .or_else(|| info.get("duration").filter(|v| !v.is_null() && **v != ""));
    let duration = supplied_duration
        .map(number)
        .unwrap_or(Some(0.))
        .context("平台视频时长无效")?;
    ensure!(duration >= 0., "平台视频时长无效");
    result.source_url = Some(
        source
            .clone()
            .unwrap_or_else(|| format!("https://www.bilibili.com/video/{bvid}")),
    );
    result.metadata = json!({"bvid":bvid,"title":info["title"].as_str().unwrap_or("").chars().take(300).collect::<String>(),"part":page,"parts":pages.len(),"durationSeconds":duration});
    if from_search {
        result.metadata["matchedBy"] = json!("visible_title_and_uploader");
        result.metadata["uploader"] = info["owner"]["name"].clone();
    }
    let params = params(&[("bvid", bvid), ("cid", &cid.to_string())]);
    match captions(&http, &params, duration, deadline).await {
        Ok((text, coverage, warning)) => {
            result.captions = text;
            if let Some(c) = coverage {
                result.metadata["captionCoverage"] = c;
            }
            if let Some(w) = warning {
                result.metadata["captionWarning"] = json!(w);
            }
        }
        Err(_) => {
            result.metadata["captionWarning"] =
                json!("平台字幕不可用或时间与视频分段不一致；未采用该字幕轨");
        }
    }
    match frames(&http, &params, duration, deadline).await {
        Ok(frames) => result.frames = frames,
        Err(_) => {
            result.metadata["visualWarning"] = json!("画面读取失败；未将标题或描述当作视频内容");
        }
    }
    if !result.captions.is_empty() || !result.frames.is_empty() {
        result.status = VideoStatus::Analyzed;
    } else {
        result.error = Some("平台未提供可核验的字幕或故事板画面；已保留截图摘要和原始链接".into());
    }
    Ok::<(), anyhow::Error>(())
}
async fn captions(
    http: &http::BiliHttp,
    params: &BTreeMap<String, String>,
    duration: f64,
    deadline: Instant,
) -> Result<(String, Option<Value>, Option<&'static str>)> {
    let player = http.data("/x/player/v2", params, deadline).await?;
    let warning = if player["need_login_subtitle"] == true {
        Some("平台字幕需要有效的B站专用登录授权；截图和原始链接已保留")
    } else {
        None
    };
    let Some(tracks) = player["subtitle"]["subtitles"].as_array() else {
        return Ok((String::new(), None, warning));
    };
    let track = tracks
        .iter()
        .find(|t| t["lan"].as_str().is_some_and(|s| s.starts_with("zh")))
        .or_else(|| tracks.first());
    let Some(url) = track
        .and_then(|t| t["subtitle_url"].as_str())
        .filter(|s| !s.is_empty())
    else {
        return Ok((String::new(), None, warning));
    };
    let (raw, _) = http.fetch(url, true, 1024 * 1024, false, deadline).await?;
    let body: Value =
        serde_json::from_slice(&raw).map_err(|_| anyhow::anyhow!("invalid caption JSON"))?;
    let segments = body["body"].as_array().context("invalid caption track")?;
    ensure!(
        duration > 0. && duration.is_finite(),
        "字幕时间无法与视频分段核验"
    );
    let latest = duration + (duration * 0.02).max(3.);
    let mut lines = Vec::new();
    for segment in segments {
        let start = number(&segment["from"]).context("invalid caption start")?;
        let end = segment
            .get("to")
            .map(number)
            .unwrap_or(Some(start))
            .context("invalid caption end")?;
        ensure!(
            start >= 0. && end >= start && end <= latest,
            "字幕时间与视频分段不一致"
        );
        let text = segment["content"]
            .as_str()
            .unwrap_or("")
            .trim()
            .chars()
            .take(1000)
            .collect::<String>();
        if !text.is_empty() {
            lines.push((start, format!("[{start:.1}s] {text}")));
        }
    }
    lines.sort_by(|a, b| a.0.total_cmp(&b.0));
    let total = lines.len();
    while lines.iter().map(|(_, s)| s.len() + 1).sum::<usize>() > 60000 && lines.len() > 1 {
        let target = (lines.len() / 2).max(2);
        lines = (0..target)
            .map(|i| {
                lines[((i as f64 * (lines.len() - 1) as f64 / (target - 1) as f64)
                    .round_ties_even()) as usize]
                    .clone()
            })
            .collect();
    }
    let coverage =
        json!({"totalSegments":total,"includedSegments":lines.len(),"complete":lines.len()==total});
    static MUSIC: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let music =
        MUSIC.get_or_init(|| regex::Regex::new(r"(?i)^[♪♫\s]*(?:音乐|music|BGM)[♪♫\s]*$").unwrap());
    if !lines.is_empty()
        && lines
            .iter()
            .all(|(_, s)| music.is_match(s.split_once("] ").unwrap().1))
    {
        return Ok((
            String::new(),
            Some(coverage),
            Some("平台字幕仅包含音乐标记，改用视频抽样画面"),
        ));
    }
    Ok((
        lines
            .into_iter()
            .map(|(_, s)| s)
            .collect::<Vec<_>>()
            .join("\n"),
        Some(coverage),
        warning,
    ))
}
pub(super) fn entries(snapshot: &Value, duration: f64) -> Vec<(f64, usize)> {
    let Some(raw) = snapshot["index"].as_array() else {
        return Vec::new();
    };
    let mut entries = raw
        .iter()
        .take(20000)
        .enumerate()
        .filter_map(|(i, v)| {
            number(if v.is_object() { &v["timestamp"] } else { v })
                .filter(|n| *n >= 0.)
                .map(|n| (n, i))
        })
        .collect::<Vec<_>>();
    let scale = if duration > 0. && entries.iter().any(|(n, _)| *n > duration * 1.5) {
        1000.
    } else {
        1.
    };
    for (n, _) in &mut entries {
        *n /= scale;
    }
    entries
}
async fn decode_sheet(
    http: &http::BiliHttp,
    url: &str,
    deadline: Instant,
) -> Result<image::DynamicImage> {
    let (raw, _) = http
        .fetch(url, true, 5 * 1024 * 1024, false, deadline)
        .await?;
    tokio::task::spawn_blocking(move || {
        let make = || {
            let mut reader = image::ImageReader::new(std::io::Cursor::new(&raw))
                .with_guessed_format()
                .map_err(|_| anyhow::anyhow!("invalid storyboard image"))?;
            let mut limits = image::Limits::default();
            limits.max_alloc = Some(96 * 1024 * 1024);
            reader.limits(limits);
            Ok::<_, anyhow::Error>(reader)
        };
        let dimensions = make()?
            .into_dimensions()
            .map_err(|_| anyhow::anyhow!("invalid storyboard dimensions"))?;
        ensure!(
            u64::from(dimensions.0) * u64::from(dimensions.1) <= 20_000_000,
            "故事板图片尺寸过大"
        );
        let mut reader = make()?;
        let mut limits = image::Limits::default();
        limits.max_alloc = Some(96 * 1024 * 1024);
        reader.limits(limits);
        reader
            .decode()
            .map_err(|_| anyhow::anyhow!("故事板图片不可解码"))
    })
    .await?
}
async fn frames(
    http: &http::BiliHttp,
    params: &BTreeMap<String, String>,
    duration: f64,
    deadline: Instant,
) -> Result<Vec<VideoFrame>> {
    let mut params = params.clone();
    params.insert("index".into(), "1".into());
    let snapshot = http.data("/x/player/videoshot", &params, deadline).await?;
    let mut entries = entries(&snapshot, duration);
    if entries.is_empty()
        && let Some(url) = snapshot["pvdata"].as_str()
    {
        let (raw, _) = http.fetch(url, true, 40000, false, deadline).await?;
        if !raw.is_empty() && raw.len() % 2 == 0 {
            entries = raw
                .as_chunks::<2>()
                .0
                .iter()
                .enumerate()
                .map(|(i, b)| (u16::from_be_bytes([b[0], b[1]]) as f64, i))
                .collect();
        }
    }
    let Some(sheets) = snapshot["image"].as_array().filter(|s| !s.is_empty()) else {
        return Ok(Vec::new());
    };
    entries.retain(|(s, _)| duration <= 0. || *s <= duration);
    entries.sort_by(|a, b| a.0.total_cmp(&b.0));
    if entries.is_empty() {
        return Ok(Vec::new());
    }
    let covered = entries.last().unwrap().0;
    let count = ((covered / 30.).ceil() as usize + 1).clamp(8, 24);
    let mut selected = Vec::new();
    for step in 0..count {
        let target = covered * step as f64 / (count - 1) as f64;
        let nearest = *entries
            .iter()
            .min_by(|a, b| (a.0 - target).abs().total_cmp(&(b.0 - target).abs()))
            .unwrap();
        if !selected.iter().any(|(_, i)| *i == nearest.1) {
            selected.push(nearest);
        }
    }
    let size = |key: &str, default| -> Result<u64> {
        match snapshot.get(key) {
            None | Some(Value::Null) => Ok(default),
            Some(v) if *v == 0 => Ok(default),
            Some(v) => positive_id(v).context("故事板画面尺寸无效"),
        }
    };
    let width = size("img_x_size", 480)?;
    let height = size("img_y_size", 270)?;
    ensure!(width <= 1920 && height <= 1080, "故事板画面尺寸无效");
    let width = width as u32;
    let height = height as u32;
    let first = decode_sheet(
        http,
        sheets[0].as_str().context("invalid storyboard URL")?,
        deadline,
    )
    .await?;
    let (columns, rows) = (first.width() / width, first.height() / height);
    if columns == 0 || rows == 0 {
        return Ok(Vec::new());
    }
    let mut current = Some((0usize, first));
    let mut output = Vec::new();
    for (stamp, index) in selected {
        let per = (columns * rows) as usize;
        let (number, tile) = (index / per, index % per);
        if current.as_ref().map(|(i, _)| *i) != Some(number) {
            drop(current.take());
            let sheet = sheets
                .get(number)
                .and_then(Value::as_str)
                .context("故事板缺少选中画面")?;
            current = Some((number, decode_sheet(http, sheet, deadline).await?));
        }
        let image = &current.as_ref().unwrap().1;
        let (x, y) = (
            (tile as u32 % columns) * width,
            (tile as u32 / columns) * height,
        );
        ensure!(
            x + width <= image.width() && y + height <= image.height(),
            "故事板画面超出图片范围"
        );
        let cropped = image.view(x, y, width, height).to_image();
        let jpeg = tokio::task::spawn_blocking(move || {
            let original = image::DynamicImage::ImageRgba8(cropped);
            let resized = if original.width() > 640 || original.height() > 360 {
                original.thumbnail(640, 360).to_rgb8()
            } else {
                original.to_rgb8()
            };
            let mut bytes = Vec::new();
            image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 80)
                .encode_image(&resized)?;
            ensure!(bytes.len() <= 900 * 1024, "sampled frame exceeds limit");
            Ok::<_, anyhow::Error>(bytes)
        })
        .await??;
        output.push(VideoFrame {
            seconds: (stamp * 10.).round_ties_even() / 10.,
            jpeg_base64: STANDARD.encode(jpeg),
        });
    }
    Ok(output)
}
