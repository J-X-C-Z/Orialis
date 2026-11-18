//! Synthetic private inputs only. Hits still hash bytes and verify the open FD.
use hermes_rust_core::document_extract::*;
use std::os::unix::fs::PermissionsExt;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};
fn scope(owner: &str, credential: &str, conversation: &str) -> DocumentCacheScope {
    DocumentCacheScope::new(owner, credential, conversation).unwrap()
}
fn private(path: &Path) {
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn docx(path: &Path, text: &str) {
    let mut zip = zip::ZipWriter::new(fs::File::create(path).unwrap());
    zip.start_file(
        "word/document.xml",
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
    )
    .unwrap();
    zip.write_all(format!("<w:document xmlns:w='urn:word'><w:body><w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:body></w:document>").as_bytes()).unwrap();
    zip.finish().unwrap();
    private(path);
}
fn output(doc: &ExtractedDocument) -> String {
    serde_json::to_string(doc).unwrap()
}
async fn read(
    ex: &DocumentExtractor,
    path: &Path,
    budget: usize,
    scope: &DocumentCacheScope,
) -> ExtractedDocument {
    ex.extract_scoped(path, "application/octet-stream", "file.docx", budget, scope)
        .await
        .unwrap()
}
fn helper(root: &Path, text: &str) -> PathBuf {
    let p = root.join("pdf-helper");
    fs::write(&p, format!("#!/bin/sh\n{text}\n")).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
    p
}
fn pdf(root: &Path) -> PathBuf {
    let p = root.join("input.pdf");
    fs::copy(
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/documents/pages.pdf"
        ),
        &p,
    )
    .unwrap();
    private(&p);
    p
}
#[tokio::test]
async fn successful_cache_preserves_output_and_private_scope_budget_boundaries() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = dir.path().join("input.docx");
    docx(&p, &"中文 content ".repeat(3000));
    let ex = DocumentExtractor::new(DocumentConfig::default()).unwrap();
    let a = scope("owner-a", "credential-a", "conv-a");
    let first = read(&ex, &p, 100000, &a).await;
    let next = read(&ex, &p, 100000, &a).await;
    assert_eq!(output(&first), output(&next));
    assert_eq!(ex.cache_stats().hits, 1);
    assert_eq!(ex.cache_stats().misses, 1);
    let small = read(&ex, &p, 8192, &a).await;
    assert!(small.truncated);
    assert!(small.text_bytes() <= 8192);
    assert_ne!(output(&first), output(&small));
    for other in [
        scope("owner-b", "credential-a", "conv-a"),
        scope("owner-a", "credential-b", "conv-a"),
        scope("owner-a", "credential-a", "conv-b"),
    ] {
        assert_eq!(output(&read(&ex, &p, 100000, &other).await), output(&first));
    }
    assert_eq!(ex.cache_stats().misses, 5);
    assert_eq!(ex.cache_stats().entries, 5);
    let other = DocumentExtractor::new(DocumentConfig {
        max_output_bytes: 4000,
        ..Default::default()
    })
    .unwrap();
    let restricted = read(&other, &p, 100000, &a).await;
    assert!(restricted.truncated);
    assert!(restricted.text_bytes() <= 4000);
    assert_eq!(other.cache_stats().hits, 0);
    ex.extract(&p, "application/octet-stream", "file.docx", 100000)
        .await
        .unwrap();
    assert_eq!(
        ex.cache_stats().hits,
        1,
        "legacy direct API remains uncached"
    );
}
#[tokio::test]
async fn actual_hash_detects_same_size_replacement_and_in_place_change() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = dir.path().join("input.docx");
    docx(&p, "AAAA");
    let size = fs::metadata(&p).unwrap().len();
    let ex = DocumentExtractor::new(DocumentConfig::default()).unwrap();
    let a = scope("owner", "credential", "conv");
    assert!(output(&read(&ex, &p, 100000, &a).await).contains("AAAA"));
    docx(&p, "BBBB");
    assert_eq!(fs::metadata(&p).unwrap().len(), size);
    assert!(output(&read(&ex, &p, 100000, &a).await).contains("BBBB"));
    let replacement = dir.path().join("replacement");
    docx(&replacement, "CCCC");
    fs::rename(&replacement, &p).unwrap();
    assert_eq!(fs::metadata(&p).unwrap().len(), size);
    assert!(output(&read(&ex, &p, 100000, &a).await).contains("CCCC"));
    assert_eq!(ex.cache_stats().misses, 3);
    assert_eq!(ex.cache_stats().hits, 0);
    docx(&p, "AAAA");
    assert!(output(&read(&ex, &p, 100000, &a).await).contains("AAAA"));
    assert_eq!(
        ex.cache_stats().hits,
        1,
        "safe same-byte reuse is content addressed"
    );
    assert!(
        ex.extract_scoped(&p, "application/pdf", "file.pdf", 100000, &a)
            .await
            .is_err()
    );
}
#[tokio::test]
async fn hits_do_not_bypass_private_permissions_links_or_missing_files() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = dir.path().join("input.docx");
    docx(&p, "private fixture");
    let ex = DocumentExtractor::new(DocumentConfig::default()).unwrap();
    let a = scope("owner", "credential", "conv");
    read(&ex, &p, 100000, &a).await;
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(
        ex.extract_scoped(&p, "application/octet-stream", "file.docx", 100000, &a)
            .await
            .is_err()
    );
    private(&p);
    let link = dir.path().join("hard");
    fs::hard_link(&p, &link).unwrap();
    assert!(
        ex.extract_scoped(&p, "application/octet-stream", "file.docx", 100000, &a)
            .await
            .is_err()
    );
    fs::remove_file(link).unwrap();
    let old = dir.path().join("old");
    fs::rename(&p, &old).unwrap();
    std::os::unix::fs::symlink(&old, &p).unwrap();
    assert!(
        ex.extract_scoped(&p, "application/octet-stream", "file.docx", 100000, &a)
            .await
            .is_err()
    );
    fs::remove_file(&p).unwrap();
    assert!(
        ex.extract_scoped(&p, "application/octet-stream", "file.docx", 100000, &a)
            .await
            .is_err()
    );
    fs::rename(&old, &p).unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(
        ex.extract_scoped(&p, "application/octet-stream", "file.docx", 100000, &a)
            .await
            .is_err()
    );
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(ex.cache_stats().hits, 0);
    assert!(output(&read(&ex, &p, 100000, &a).await).contains("private fixture"));
    assert_eq!(ex.cache_stats().hits, 1);
}
#[tokio::test]
async fn capacity_lru_ttl_disable_and_oversize_results_are_bounded() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = dir.path().join("input.docx");
    let a = scope("owner", "credential", "conv");
    let ex = DocumentExtractor::new(DocumentConfig::default())
        .unwrap()
        .with_cache_config(DocumentCacheConfig {
            max_bytes: 8192,
            max_entries: 2,
            ttl: Duration::from_secs(60),
        })
        .unwrap();
    docx(&p, "A");
    read(&ex, &p, 100000, &a).await;
    docx(&p, "B");
    read(&ex, &p, 100000, &a).await;
    docx(&p, "A");
    read(&ex, &p, 100000, &a).await;
    docx(&p, "C");
    read(&ex, &p, 100000, &a).await;
    let before = ex.cache_stats();
    assert_eq!(before.entries, 2);
    assert!(before.bytes <= 8192);
    assert_eq!(before.evictions, 1);
    docx(&p, "B");
    read(&ex, &p, 100000, &a).await;
    assert_eq!(ex.cache_stats().misses, before.misses + 1);
    let ttl = ex
        .clone()
        .with_cache_config(DocumentCacheConfig {
            ttl: Duration::from_millis(30),
            ..Default::default()
        })
        .unwrap();
    read(&ttl, &p, 100000, &a).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    read(&ttl, &p, 100000, &a).await;
    assert_eq!(ttl.cache_stats().hits, 0);
    assert_eq!(ttl.cache_stats().evictions, 1);
    for max_bytes in [0, 1] {
        let disabled = ex
            .clone()
            .with_cache_config(DocumentCacheConfig {
                max_bytes,
                ..Default::default()
            })
            .unwrap();
        read(&disabled, &p, 100000, &a).await;
        read(&disabled, &p, 100000, &a).await;
        assert_eq!(disabled.cache_stats().entries, 0);
        assert_eq!(disabled.cache_stats().bytes, 0);
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_pdf_requests_single_flight_and_program_identity_changes_invalidate() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = pdf(dir.path());
    let program = helper(dir.path(), "sleep 0.1; printf 'run:%s\\n' \"$$\"");
    let ex = DocumentExtractor::new(DocumentConfig {
        pdf_program: Some(program.clone()),
        ..Default::default()
    })
    .unwrap();
    let a = scope("owner", "credential", "conv");
    let requests = (0..8).map(|_| ex.extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a));
    let results = futures_util::future::join_all(requests).await;
    let first = output(results[0].as_ref().unwrap());
    for doc in results {
        assert_eq!(output(&doc.unwrap()), first);
    }
    assert_eq!(ex.cache_stats().misses, 1);
    assert_eq!(ex.cache_stats().hits, 7);
    helper(dir.path(), "printf 'upgraded-parser\\n'");
    let upgraded = ex
        .extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a)
        .await
        .unwrap();
    assert!(output(&upgraded).contains("upgraded-parser"));
    assert_eq!(ex.cache_stats().misses, 2);
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mutation_during_parse_errors_are_not_cached_and_cancellation_releases_flight() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let p = pdf(dir.path());
    let program = helper(dir.path(), "sleep 0.2; printf 'fixture result\\n'");
    let ex = DocumentExtractor::new(DocumentConfig {
        pdf_program: Some(program),
        ..Default::default()
    })
    .unwrap();
    let a = scope("owner", "credential", "conv");
    let active = {
        let ex = ex.clone();
        let p = p.clone();
        let a = a.clone();
        tokio::spawn(async move {
            ex.extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a)
                .await
        })
    };
    tokio::time::sleep(Duration::from_millis(70)).await;
    fs::write(&p, b"%PDF-changed fixture bytes").unwrap();
    assert!(active.await.unwrap().is_err());
    assert_eq!(ex.cache_stats().entries, 0);
    let active = {
        let ex = ex.clone();
        let p = p.clone();
        let a = a.clone();
        tokio::spawn(async move {
            ex.extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a)
                .await
        })
    };
    tokio::time::sleep(Duration::from_millis(70)).await;
    active.abort();
    let _ = active.await;
    let after = tokio::time::timeout(
        Duration::from_secs(2),
        ex.extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(output(&after).contains("fixture result"));
    assert_eq!(ex.cache_stats().entries, 1);
    fs::write(&p, b"broken").unwrap();
    for _ in 0..2 {
        assert!(
            ex.extract_scoped(&p, "application/pdf", "f.pdf", 100000, &a)
                .await
                .is_err()
        );
    }
    assert_eq!(
        ex.cache_stats().entries,
        1,
        "errors do not become successful cache records"
    );
}

#[tokio::test]
async fn production_media_resolver_requires_verified_owner_and_rebuilds_current_wrapper() {
    use axum::{Router, body::Body, http::HeaderMap, response::Response};
    use hermes_rust_core::{
        attachments::*,
        media_runtime::{MediaResolver, OrialisMediaResolver, user_reference},
        tool_runtime::TurnContext,
    };
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    let dir = tempfile::tempdir().unwrap();
    let bytes = include_bytes!("fixtures/documents/word.docx");
    let downloads = Arc::new(AtomicUsize::new(0));
    let count = downloads.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().fallback(move |headers: HeaderMap| {
                let count = count.clone();
                async move {
                    assert!(headers.get("authorization").is_some());
                    count.fetch_add(1, Ordering::SeqCst);
                    Response::builder()
                        .header("Content-Type", "application/octet-stream")
                        .body(Body::from(bytes.as_slice()))
                        .unwrap()
                }
            }),
        )
        .await
        .unwrap()
    });
    let transport = AttachmentTransport::new(AttachmentConfig::new(
        base.clone(),
        "document-cache".into(),
        "synthetic-token".into(),
        dir.path().join("cache"),
    ))
    .unwrap();
    let extractor = DocumentExtractor::new(DocumentConfig::default()).unwrap();
    let limits = ModelInputLimits {
        document_extractor: Some(extractor.clone()),
        ..Default::default()
    };
    let metadata = AttachmentMetadata {
        id: "file-id".into(),
        name: "first.docx".into(),
        mime_type: "application/octet-stream".into(),
        size: Some(bytes.len() as u64),
        download_url: format!("{base}/api/v1/attachments/file-id/download"),
    };
    let context = TurnContext {
        conversation_id: "conv-a".into(),
        input_id: "input-a".into(),
        session_id: "session".into(),
    };
    let first = user_reference("first request", std::slice::from_ref(&metadata), &context).unwrap();
    let unbound = OrialisMediaResolver {
        transport: transport.clone(),
        limits: limits.clone(),
    };
    unbound.hydrate(&first).await.unwrap();
    unbound.hydrate(&first).await.unwrap();
    assert_eq!(
        extractor.cache_stats().entries,
        0,
        "no verified owner means no derived cache"
    );
    let resolver = OrialisMediaResolver {
        transport: transport
            .clone()
            .with_verified_owner_scope("verified-fixture-owner".into())
            .unwrap(),
        limits: limits.clone(),
    };
    let result = resolver.hydrate(&first).await.unwrap();
    assert!(result.message.to_string().contains("中文 document body"));
    let next = resolver.hydrate(&first).await.unwrap();
    assert_eq!(result.message, next.message);
    assert_eq!(extractor.cache_stats().hits, 1);
    assert_eq!(downloads.load(Ordering::SeqCst), 1);
    let another_input = TurnContext {
        input_id: "input-b".into(),
        ..context.clone()
    };
    let fresh = user_reference(
        "new request",
        std::slice::from_ref(&metadata),
        &another_input,
    )
    .unwrap();
    let next = resolver.hydrate(&fresh).await.unwrap();
    assert!(next.message.to_string().contains("new request"));
    assert!(!next.message.to_string().contains("first request"));
    assert_eq!(
        extractor.cache_stats().hits,
        2,
        "same owner/conv/content can reuse across historical input IDs"
    );
    let renamed = AttachmentMetadata {
        name: "renamed.docx".into(),
        ..metadata.clone()
    };
    let renamed = user_reference("renamed request", &[renamed], &another_input).unwrap();
    let result = resolver.hydrate(&renamed).await.unwrap();
    assert!(result.message.to_string().contains("renamed.docx"));
    assert!(!result.message.to_string().contains("first.docx"));
    let before = extractor.cache_stats().hits;
    let other = OrialisMediaResolver {
        transport: transport
            .with_verified_owner_scope("different-verified-owner".into())
            .unwrap(),
        limits,
    };
    other.hydrate(&first).await.unwrap();
    assert_eq!(
        extractor.cache_stats().hits,
        before,
        "owner cannot reuse another owner's derived text"
    );
    server.abort();
}
