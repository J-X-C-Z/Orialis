//! Real extractor / media-resolver component benchmark. Not a gateway benchmark.
//! Synthetic fixture inputs only. No cache optimization is implemented here.
use anyhow::{Result, ensure};
use axum::{
    Router,
    body::Body,
    http::{HeaderMap, Response, StatusCode},
    routing::get,
};
use clap::Parser;
use hermes_rust_core::{
    attachments::{AttachmentConfig, AttachmentMetadata, AttachmentTransport, ModelInputLimits},
    document_extract::{DocumentCacheConfig, DocumentConfig, DocumentExtractor, ExtractedDocument},
    media_runtime::{MediaResolver, OrialisMediaResolver, user_reference},
    tool_runtime::TurnContext,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    hint::black_box,
    io::Read,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Instant,
};

#[derive(Parser)]
struct Args {
    #[arg(long)]
    file: PathBuf,
    #[arg(long, default_value = "application/octet-stream")]
    mime: String,
    #[arg(long, default_value = "extract")]
    mode: String,
    #[arg(long, default_value_t = 30)]
    iterations: usize,
    #[arg(long, default_value_t = 100_000)]
    budget: usize,
    #[arg(long, default_value_t = 1)]
    history: usize,
    #[arg(long, default_value_t = 1)]
    population: usize,
    #[arg(long, default_value = "/usr/bin/pdftotext")]
    pdf_program: PathBuf,
    /// Same scoped identity and verification path, but disable derived-result storage.
    #[arg(long)]
    disable_cache: bool,
}
#[derive(Clone, Copy)]
struct Usage {
    self_cpu: f64,
    children_cpu: f64,
    self_rss: i64,
    children_rss: i64,
}
fn usage() -> Usage {
    unsafe {
        let mut s: libc::rusage = std::mem::zeroed();
        let mut c: libc::rusage = std::mem::zeroed();
        assert_eq!(libc::getrusage(libc::RUSAGE_SELF, &mut s), 0);
        assert_eq!(libc::getrusage(libc::RUSAGE_CHILDREN, &mut c), 0);
        let cpu = |r: &libc::rusage| {
            r.ru_utime.tv_sec as f64
                + r.ru_stime.tv_sec as f64
                + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) as f64 / 1e6
        };
        Usage {
            self_cpu: cpu(&s),
            children_cpu: cpu(&c),
            self_rss: s.ru_maxrss,
            children_rss: c.ru_maxrss,
        }
    }
}
fn sha_file(path: &std::path::Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut sha = Sha256::new();
    let mut b = [0u8; 65536];
    loop {
        let n = file.read(&mut b)?;
        if n == 0 {
            break;
        }
        sha.update(&b[..n]);
    }
    Ok(format!("{:x}", sha.finalize()))
}
fn quantile(raw: &[f64], q: f64) -> f64 {
    let mut v = raw.to_vec();
    v.sort_by(f64::total_cmp);
    v[((v.len() as f64 * q).ceil() as usize)
        .saturating_sub(1)
        .min(v.len() - 1)]
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    let a = Args::parse();
    ensure!(
        a.iterations > 0 && a.history > 0 && a.population >= a.history,
        "invalid benchmark sizes"
    );
    ensure!(
        ["extract", "hash", "hydrate", "fetch"].contains(&a.mode.as_str()),
        "invalid mode"
    );
    let name = a.file.file_name().unwrap().to_str().unwrap().to_owned();
    let extractor = DocumentExtractor::new(DocumentConfig {
        pdf_program: Some(a.pdf_program.clone()),
        ..Default::default()
    })?
    .with_cache_config(if a.disable_cache {
        DocumentCacheConfig {
            max_bytes: 0,
            max_entries: 0,
            ..Default::default()
        }
    } else {
        DocumentCacheConfig::default()
    })?;
    let fixture_bytes = fs::metadata(&a.file)?.len();
    let fixture_sha = sha_file(&a.file)?;
    let download_count = Arc::new(AtomicUsize::new(0));
    let temp = tempfile::tempdir()?;
    let mut task = None;
    let mut transport = None;
    let mut resolver = None;
    let mut messages = Vec::new();
    let mut metadata = None;
    if a.mode == "hydrate" || a.mode == "fetch" {
        let data = Arc::new(fs::read(&a.file)?);
        let counter = download_count.clone();
        let mime = a.mime.clone();
        let app = Router::new().route(
            "/api/v1/attachments/fixture/download",
            get(move |headers: HeaderMap| {
                let data = data.clone();
                let counter = counter.clone();
                let mime = mime.clone();
                async move {
                    if headers.get("authorization").and_then(|h| h.to_str().ok())
                        != Some("Bearer synthetic-profile-token")
                        || headers
                            .get("x-orialis-device-id")
                            .and_then(|h| h.to_str().ok())
                            != Some("profile-device")
                    {
                        return Response::builder()
                            .status(StatusCode::UNAUTHORIZED)
                            .body(Body::empty())
                            .unwrap();
                    }
                    counter.fetch_add(1, Ordering::Relaxed);
                    Response::builder()
                        .header("content-type", mime)
                        .body(Body::from(data.as_ref().clone()))
                        .unwrap()
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let origin = format!("http://{}", listener.local_addr()?);
        task = Some(tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap()
        }));
        let t = AttachmentTransport::new(AttachmentConfig::new(
            origin.clone(),
            "profile-device".into(),
            "synthetic-profile-token".into(),
            temp.path().join("cache"),
        ))?
        .with_verified_owner_scope("synthetic-profile-owner".into())?;
        let item = AttachmentMetadata {
            id: "fixture".into(),
            name: name.clone(),
            mime_type: a.mime.clone(),
            size: Some(fixture_bytes),
            download_url: format!("{origin}/api/v1/attachments/fixture/download"),
        };
        for i in 0..a.population {
            let input = format!("source-{i}");
            let files = t
                .fetch_message(
                    "synthetic-conversation",
                    &input,
                    std::slice::from_ref(&item),
                )
                .await?;
            black_box(files);
            if i < a.history {
                messages.push(user_reference(
                    "Synthetic historical document",
                    std::slice::from_ref(&item),
                    &TurnContext {
                        conversation_id: "synthetic-conversation".into(),
                        input_id: input,
                        session_id: "profile-session".into(),
                    },
                )?);
            }
        }
        resolver = Some(OrialisMediaResolver {
            transport: t.clone(),
            limits: ModelInputLimits {
                document_extractor: Some(extractor.clone()),
                max_text_bytes: a.budget,
                ..Default::default()
            },
        });
        transport = Some(t);
        metadata = Some(item);
    }
    #[derive(Default)]
    struct Operation {
        document: Option<ExtractedDocument>,
        messages: Vec<Value>,
        leases: Vec<Box<dyn Send + Sync>>,
        digest: Option<String>,
        file_bytes: usize,
    }
    fn verify(result: &Operation) -> Result<(String, usize, Option<bool>)> {
        let mut signature = Sha256::new();
        let mut size = result.file_bytes;
        let mut truncated = None;
        if let Some(document) = &result.document {
            size += document.text_bytes();
            truncated = Some(document.truncated);
            signature.update(serde_json::to_vec(document)?);
        }
        for message in &result.messages {
            let bytes = serde_json::to_vec(message)?;
            ensure!(
                String::from_utf8_lossy(&bytes).contains("untrusted_document"),
                "expected actual document content"
            );
            size += bytes.len();
            signature.update(bytes);
        }
        if let Some(digest) = &result.digest {
            signature.update(digest);
        }
        Ok((format!("{:x}", signature.finalize()), size, truncated))
    }
    let one = || async {
        let mut result = Operation::default();
        match a.mode.as_str() {
            "extract" => {
                result.document = Some(extractor.extract(&a.file, &a.mime, &name, a.budget).await?);
            }
            "hash" => {
                result.digest = Some(sha_file(&a.file)?);
            }
            "hydrate" => {
                for message in &messages {
                    let resolved = resolver.as_ref().unwrap().hydrate(message).await?;
                    result.messages.push(resolved.message);
                    result.leases.push(resolved.lease);
                }
            }
            "fetch" => {
                for i in 0..a.history {
                    let files = transport
                        .as_ref()
                        .unwrap()
                        .fetch_message(
                            "synthetic-conversation",
                            &format!("source-{i}"),
                            std::slice::from_ref(metadata.as_ref().unwrap()),
                        )
                        .await?;
                    result.file_bytes += files.iter().map(|f| f.size as usize).sum::<usize>();
                    result.leases.push(Box::new(files));
                }
            }
            _ => unreachable!(),
        }
        Ok::<_, anyhow::Error>(black_box(result))
    };
    let first_start = Instant::now();
    let first_result = one().await?;
    let first_ms = first_start.elapsed().as_secs_f64() * 1000.0;
    let first = verify(&first_result)?;
    drop(first_result);
    for _ in 0..2 {
        let warm = one().await?;
        ensure!(verify(&warm)? == first, "nondeterministic warmup");
    }
    let warm_downloads = download_count.load(Ordering::Relaxed);
    let warm_cache = extractor.cache_stats();
    let mut self_cpu = 0.0;
    let mut children_cpu = 0.0;
    let mut samples = Vec::new();
    let started = Instant::now();
    for _ in 0..a.iterations {
        let before = usage();
        let start = Instant::now();
        let result = one().await?;
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
        let after = usage();
        self_cpu += after.self_cpu - before.self_cpu;
        children_cpu += after.children_cpu - before.children_cpu;
        // Validation and result destruction are deliberately outside latency/CPU.
        ensure!(verify(&result)? == first, "non-deterministic extraction");
    }
    let elapsed = started.elapsed().as_secs_f64();
    let after = usage();
    let downloads = download_count.load(Ordering::Relaxed);
    ensure!(downloads == warm_downloads, "unexpected repeated download");
    let cache = extractor.cache_stats();
    if a.mode == "hydrate" && !a.disable_cache {
        ensure!(
            cache.hits - warm_cache.hits == (a.iterations * a.history) as u64,
            "expected every measured historical extraction to hit scoped cache"
        );
    }
    let report: Value = json!({
        "scope":"Real Rust extractor/media-resolver component; no gateway/model/mobile/WAN",
        "synthetic_owner_bound":true,"derived_cache_enabled":!a.disable_cache,
        "cache_entries":cache.entries,"cache_bytes":cache.bytes,"cache_warm_hits":warm_cache.hits,
        "cache_measured_hits":cache.hits-warm_cache.hits,"cache_measured_misses":cache.misses-warm_cache.misses,
        "cache_lifetime_misses":cache.misses,"cache_evictions":cache.evictions,
        "mode":a.mode,"file":name,"file_bytes":fixture_bytes,"file_sha256":fixture_sha,
        "iterations":a.iterations,"remaining_text_budget":a.budget,"history_messages":a.history,
        "cache_population":a.population,"download_requests_setup":warm_downloads,
        "download_requests_measured":downloads-warm_downloads,
        "output_bytes":first.1,"output_sha256":first.0,"truncated":first.2,
        "first_unprimed_operation_ms":first_ms,"loop_wall_seconds_including_validation":elapsed,
        "measured_operation_seconds":samples.iter().sum::<f64>()/1000.0,
        "p50_ms":quantile(&samples,0.5),"p95_ms":quantile(&samples,0.95),"p99_ms":quantile(&samples,0.99),
        "self_cpu_ms_per_iteration":self_cpu*1000.0/a.iterations as f64,
        "reaped_children_cpu_ms_per_iteration":children_cpu*1000.0/a.iterations as f64,
        "combined_cpu_ms_per_iteration":(self_cpu+children_cpu)*1000.0/a.iterations as f64,
        "self_lifetime_peak_rss_kib":after.self_rss,"largest_reaped_child_peak_rss_kib":after.children_rss,
        "validation_excluded_from_latency_and_cpu":true,"raw_ms":samples
    });
    println!("{}", serde_json::to_string_pretty(&report)?);
    if let Some(task) = task {
        task.abort();
    }
    Ok(())
}
