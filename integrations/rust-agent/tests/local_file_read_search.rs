#![cfg(target_os = "linux")]
use anyhow::Result;
use base64::Engine;
use hermes_rust_core::{
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Cursor, Write},
    time::{Duration, Instant, SystemTime},
};

fn context() -> TurnContext {
    TurnContext {
        conversation_id: "read-search-conversation".into(),
        input_id: "input".into(),
        session_id: "read-search-session".into(),
    }
}
async fn setup() -> Result<(tempfile::TempDir, std::path::PathBuf, LocalTools)> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("root");
    fs::create_dir(&root)?;
    let mut cfg = LocalToolsConfig::new(
        "owner".into(),
        root.clone(),
        dir.path().join("state.sqlite"),
    );
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, None).await?;
    Ok((dir, root, tools))
}
async fn call(tools: &LocalTools, name: &str, args: Value) -> Result<Value> {
    tools.execute(name, args, &context()).await
}
fn zip(parts: &[(&str, &str)]) -> Result<Vec<u8>> {
    let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for (name, text) in parts {
        z.start_file(
            *name,
            zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated),
        )?;
        z.write_all(text.as_bytes())?;
    }
    Ok(z.finish()?.into_inner())
}
fn display_text(value: &Value) -> String {
    value["content"]
        .as_str()
        .unwrap()
        .lines()
        .map(|s| s.split_once('|').unwrap().1)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}
#[tokio::test]
async fn read_bom_newlines_and_raw_snapshot_are_distinct() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    let original = b"\xef\xbb\xbfone\r\n\r\nthree\rfour";
    fs::write(root.join("text.txt"), original)?;
    let first = call(&tools, "read_file", json!({"path":"text.txt","limit":2})).await?;
    assert_eq!(first["content"], "1|one\n2|\n");
    assert_eq!(first["total_lines"], 4);
    assert_eq!(first["next_offset"], 3);
    assert_eq!(first["complete_read"], false);
    assert_eq!(first["sha256"], format!("{:x}", Sha256::digest(original)));
    let last = call(
        &tools,
        "read_file",
        json!({"path":"text.txt","offset":3,"limit":2}),
    )
    .await?;
    assert_eq!(last["content"], "3|three\n4|four\n");
    assert_eq!(last["complete_read"], true);
    assert!(last["next_offset"].is_null());
    fs::write(root.join("text.txt"), b"one\n\nthree\nfour")?;
    assert!(
        call(
            &tools,
            "write_file",
            json!({"path":"text.txt","content":"lost update"})
        )
        .await
        .is_err()
    );
    for (name, bytes, total, content) in [
        ("empty", b"".as_slice(), 0, ""),
        ("one_blank", b"\n".as_slice(), 1, "1|\n"),
        ("two_blank", b"\r\n\r".as_slice(), 2, "1|\n2|\n"),
    ] {
        fs::write(root.join(name), bytes)?;
        let result = call(&tools, "read_file", json!({"path":name})).await?;
        assert_eq!(result["total_lines"], total);
        assert_eq!(result["content"], content);
        assert_eq!(result["complete_read"], true);
    }
    fs::write(root.join("invalid.txt"), [0xff, 0xfe])?;
    assert!(
        call(&tools, "read_file", json!({"path":"invalid.txt"}))
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn upstream_notebook_and_docx_fixtures_render_without_granting_writes() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    let fixtures: Value = serde_json::from_str(include_str!(
        "fixtures/local_file_read_search/upstream.json"
    ))?;
    for fixture in fixtures["fixtures"].as_array().unwrap() {
        let name = fixture["name"].as_str().unwrap();
        fs::write(
            root.join(name),
            base64::engine::general_purpose::STANDARD
                .decode(fixture["base64"].as_str().unwrap())?,
        )?;
        let read = call(&tools, "read_file", json!({"path":name})).await?;
        assert_eq!(read["extracted_document"], true, "{name}");
        assert_eq!(read["complete_read"], false);
        assert_eq!(read["extraction_complete"], true);
        let text = display_text(&read);
        let expected = fixture["text"].as_str().unwrap();
        if fixture["match"] == "exact" {
            assert_eq!(text, expected, "{name}");
        } else {
            assert!(text.contains(expected.trim()), "{text}");
        }
        assert!(
            call(
                &tools,
                "write_file",
                json!({"path":name,"content":"not authorized"})
            )
            .await
            .is_err()
        );
    }
    fs::write(root.join("broken.ipynb"), "{invalid JSON")?;
    let raw = call(&tools, "read_file", json!({"path":"broken.ipynb"})).await?;
    assert_eq!(raw["extracted_document"], false);
    assert_eq!(raw["complete_read"], true);
    Ok(())
}
#[tokio::test]
async fn office_extraction_is_bounded_confined_and_never_invokes_fallbacks() -> Result<()> {
    let (dir, root, tools) = setup().await?;
    let w = "<w:document xmlns:w='urn:test'><w:body><w:p><w:r><w:t>safe text</w:t></w:r></w:p></w:body></w:document>";
    fs::write(root.join("good.docx"), zip(&[("word/document.xml", w)])?)?;
    std::os::unix::fs::symlink(root.join("good.docx"), root.join("link.docx"))?;
    fs::hard_link(root.join("good.docx"), dir.path().join("hard.docx"))?;
    for name in ["good.docx", "link.docx"] {
        assert!(
            call(&tools, "read_file", json!({"path":name}))
                .await
                .is_err()
        );
    }
    fs::write(root.join("bad.docx"), b"PK\x03\x04bad zip")?;
    fs::write(
        root.join("unsafe.docx"),
        zip(&[("../outside.xml", w), ("word/document.xml", w)])?,
    )?;
    let huge = format!(
        "<document><p>{}</p></document>",
        "a".repeat(5 * 1024 * 1024)
    );
    fs::write(
        root.join("bomb.docx"),
        zip(&[("word/document.xml", &huge)])?,
    )?;
    fs::write(
        root.join("entities.docx"),
        zip(&[(
            "word/document.xml",
            "<!DOCTYPE document [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><document><p>&x;</p></document>",
        )])?,
    )?;
    fs::write(root.join("unsupported.pdf"), b"%PDF-1.4 safe fixture")?;
    for name in [
        "bad.docx",
        "unsafe.docx",
        "bomb.docx",
        "entities.docx",
        "unsupported.pdf",
    ] {
        assert!(
            call(&tools, "read_file", json!({"path":name}))
                .await
                .is_err(),
            "{name}"
        );
    }
    Ok(())
}
#[tokio::test]
async fn spreadsheet_presentation_and_odt_views_report_sources_and_warnings() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    let xlsx = zip(&[
        (
            "xl/workbook.xml",
            "<workbook xmlns:r='urn:r'><sheets><sheet name='Budget' r:id='r1'/></sheets></workbook>",
        ),
        (
            "xl/_rels/workbook.xml.rels",
            "<Relationships><Relationship Id='r1' Target='worksheets/sheet1.xml'/></Relationships>",
        ),
        (
            "xl/worksheets/sheet1.xml",
            "<worksheet><sheetData><row><c r='A1' t='inlineStr'><is><t>Revenue</t></is></c><c r='B1'><f>1+2</f><v>3</v></c></row></sheetData></worksheet>",
        ),
    ])?;
    let pptx = zip(&[
        (
            "ppt/presentation.xml",
            "<presentation xmlns:r='urn:r'><sldIdLst><sldId r:id='r1'/></sldIdLst></presentation>",
        ),
        (
            "ppt/_rels/presentation.xml.rels",
            "<Relationships><Relationship Id='r1' Target='slides/slide1.xml'/></Relationships>",
        ),
        (
            "ppt/slides/slide1.xml",
            "<sld><p><r><t>Hello slide</t></r></p></sld>",
        ),
    ])?;
    let odt = zip(&[(
        "content.xml",
        "<document-content><body><p>Hello document</p></body></document-content>",
    )])?;
    for (name, bytes, expected) in [
        ("book.xlsx", xlsx, "B1: 3 [cached formula value]"),
        ("slides.pptx", pptx, "Hello slide"),
        ("note.odt", odt, "Hello document"),
    ] {
        fs::write(root.join(name), bytes)?;
        let read = call(&tools, "read_file", json!({"path":name})).await?;
        assert!(
            read["content"].as_str().unwrap().contains(expected),
            "{read}"
        );
        assert!(!read["warnings"].as_array().unwrap().is_empty());
        assert_eq!(read["complete_read"], false);
    }
    Ok(())
}
#[tokio::test]
async fn search_pagination_requires_an_extra_match_including_inside_last_file() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    fs::write(root.join("single.txt"), "hit\nhit\nhit\n")?;
    let first = call(&tools, "search_files", json!({"pattern":"hit","limit":2})).await?;
    assert_eq!(first["matches"].as_array().unwrap().len(), 2);
    assert_eq!(first["next_offset"], 2);
    let last = call(
        &tools,
        "search_files",
        json!({"pattern":"hit","limit":2,"offset":2}),
    )
    .await?;
    assert_eq!(last["matches"][0]["line"], 3);
    assert!(last["next_offset"].is_null());
    assert_eq!(last["bounded"], false);
    fs::write(root.join("single.txt"), "hit\nhit\n")?;
    fs::write(root.join("z_nonmatch.txt"), "miss\n")?;
    let exact = call(&tools, "search_files", json!({"pattern":"hit","limit":2})).await?;
    assert!(exact["next_offset"].is_null());
    assert_eq!(exact["bounded"], false);
    let counts = call(
        &tools,
        "search_files",
        json!({"pattern":"hit","output_mode":"count"}),
    )
    .await?;
    assert_eq!(counts["matches"][0]["count"], 2);
    let paths = call(
        &tools,
        "search_files",
        json!({"pattern":"hit","output_mode":"files_only"}),
    )
    .await?;
    assert_eq!(paths["matches"][0], json!({"path":"single.txt"}));
    Ok(())
}
#[tokio::test]
async fn filename_globs_order_and_private_links_remain_confined() -> Result<()> {
    let (dir, root, tools) = setup().await?;
    fs::create_dir(root.join("src"))?;
    fs::create_dir(root.join("src/deep"))?;
    for path in ["a.rs", "b.py", "src/c.rs", "src/deep/d.rs", "src/deep/e.py"] {
        fs::write(root.join(path), "needle\n")?;
    }
    let paths = |v: &Value| {
        v["matches"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["path"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    let found = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*.{rs,py}"}),
    )
    .await?;
    assert_eq!(paths(&found).len(), 5);
    let shallow = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"src/*.rs"}),
    )
    .await?;
    assert_eq!(paths(&shallow), ["src/c.rs"]);
    let recursive = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"**/[acd].rs"}),
    )
    .await?;
    assert_eq!(paths(&recursive).len(), 3);
    let filtered = call(
        &tools,
        "search_files",
        json!({"pattern":"needle","file_glob":"src/**/*.rs"}),
    )
    .await?;
    assert_eq!(paths(&filtered).len(), 2);
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(2000);
    fs::File::open(root.join("a.rs"))?.set_times(fs::FileTimes::new().set_modified(now))?;
    fs::File::open(root.join("b.py"))?
        .set_times(fs::FileTimes::new().set_modified(now + Duration::from_secs(100)))?;
    let newest = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*","path":".","order":"modified","limit":1}),
    )
    .await?;
    assert_ne!(newest["matches"][0]["path"], "a.rs");
    let pair = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"{a.rs,b.py}","order":"modified"}),
    )
    .await?;
    assert_eq!(paths(&pair), ["b.py", "a.rs"]);
    fs::write(dir.path().join("outside"), "secret")?;
    fs::hard_link(dir.path().join("outside"), root.join("hard"))?;
    std::os::unix::fs::symlink(dir.path().join("outside"), root.join("link"))?;
    fs::write(root.join(".env"), "secret")?;
    let found = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*"}),
    )
    .await?;
    for name in ["hard", "link", ".env"] {
        assert!(!paths(&found).iter().any(|s| s == name));
    }
    for pattern in ["[", "{a,b", "\\", "{a,{b,c}}"] {
        assert!(
            call(
                &tools,
                "search_files",
                json!({"target":"files","pattern":pattern})
            )
            .await
            .is_err()
        );
    }
    assert!(
        call(
            &tools,
            "search_files",
            json!({"pattern":"(","target":"content"})
        )
        .await
        .is_err()
    );
    assert!(
        call(
            &tools,
            "search_files",
            json!({"pattern":"x","order":"modified"})
        )
        .await
        .is_err()
    );
    assert!(
        call(&tools, "search_files", json!({"pattern":"x","order":3}))
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn search_work_and_output_bounds_report_real_continuation() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    fs::write(root.join("big.txt"), "x".repeat(1024 * 1024 + 1))?;
    let skipped = call(&tools, "search_files", json!({"pattern":"needle"})).await?;
    assert_eq!(skipped["incomplete"], true);
    assert_eq!(skipped["skipped_files"], 1);
    assert!(skipped["next_offset"].is_null());
    fs::remove_file(root.join("big.txt"))?;
    let payload = "x".repeat(1024 * 1024);
    for i in 0..34 {
        fs::write(root.join(format!("{i:02}.txt")), &payload)?;
    }
    let bounded = call(&tools, "search_files", json!({"pattern":"needle"})).await?;
    assert_eq!(bounded["incomplete_reason"], "scan_bytes");
    assert!(bounded["next_offset"].is_null());
    assert_eq!(bounded["scanned_bytes"], 32 * 1024 * 1024);
    for i in 0..34 {
        fs::remove_file(root.join(format!("{i:02}.txt")))?;
    }
    fs::write(
        root.join("lines.txt"),
        ("hit ".to_owned() + &"é".repeat(1400) + "\n").repeat(150),
    )?;
    let out = call(
        &tools,
        "search_files",
        json!({"pattern":"hit","limit":200,"context":3}),
    )
    .await?;
    assert!(out["matches"].as_array().unwrap().len() < 150);
    assert!(out["next_offset"].as_u64().is_some());
    assert_eq!(out["incomplete"], false);
    assert_eq!(out["matches"][0]["content_truncated"], true);
    assert!(serde_json::to_vec(&out)?.len() < 130 * 1024);
    Ok(())
}
#[tokio::test]
async fn read_pages_and_document_truncation_do_not_claim_missing_bytes() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    fs::write(root.join("long.txt"), ("é".repeat(500) + "\n").repeat(110))?;
    let page = call(&tools, "read_file", json!({"path":"long.txt"})).await?;
    assert!(page["content"].as_str().unwrap().len() <= 100_000);
    assert_eq!(page["complete_read"], false);
    let next = page["next_offset"].as_u64().unwrap();
    let last = call(
        &tools,
        "read_file",
        json!({"path":"long.txt","offset":next}),
    )
    .await?;
    assert_eq!(last["complete_read"], true);
    let notebook = json!({"cells":[{"cell_type":"markdown","source":"a\n".repeat(150_000)}]});
    fs::write(root.join("large.ipynb"), serde_json::to_vec(&notebook)?)?;
    let doc = call(&tools, "read_file", json!({"path":"large.ipynb"})).await?;
    assert_eq!(doc["document_truncated"], true);
    assert_eq!(doc["complete_read"], false);
    assert_eq!(doc["extraction_complete"], false);
    fs::write(root.join("huge_line"), "a".repeat(100_001))?;
    assert!(
        call(&tools, "read_file", json!({"path":"huge_line"}))
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn notebook_output_and_traversal_work_limits_are_explicit() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    let outputs = vec![json!({"output_type":"stream","text":""}); 12_000];
    fs::write(
        root.join("many.ipynb"),
        serde_json::to_vec(
            &json!({"cells":[{"cell_type":"code","source":"x","outputs":outputs}]}),
        )?,
    )?;
    let read = call(&tools, "read_file", json!({"path":"many.ipynb"})).await?;
    assert_eq!(read["document_truncated"], true);
    assert_eq!(read["extraction_complete"], false);
    assert!(
        read["content"]
            .as_str()
            .unwrap()
            .contains("output truncated")
    );
    fs::create_dir(root.join("src"))?;
    fs::write(root.join("src/file"), "data")?;
    let no_cross = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"src[!x]*"}),
    )
    .await?;
    assert!(no_cross["matches"].as_array().unwrap().is_empty());
    fs::create_dir(root.join("wide"))?;
    for i in 0..1001 {
        fs::write(root.join(format!("wide/{i}")), "")?;
    }
    assert!(
        call(
            &tools,
            "search_files",
            json!({"target":"files","pattern":"*","path":"wide"})
        )
        .await
        .is_err()
    );
    let mut deep = root.join("deep");
    for _ in 0..18 {
        fs::create_dir(&deep)?;
        deep = deep.join("child");
    }
    assert!(
        call(
            &tools,
            "search_files",
            json!({"target":"files","pattern":"*","path":"deep"})
        )
        .await
        .is_err()
    );
    Ok(())
}

#[tokio::test]
#[ignore = "isolated process microbenchmark; run --ignored --exact benchmark_local_read_search --nocapture"]
async fn benchmark_local_read_search() -> Result<()> {
    let (_dir, root, tools) = setup().await?;
    let input = ("ordinary line\n".repeat(10) + "needle\n").repeat(700);
    fs::write(root.join("text.txt"), input)?;
    let fixtures: Value = serde_json::from_str(include_str!(
        "fixtures/local_file_read_search/upstream.json"
    ))?;
    for fixture in fixtures["fixtures"].as_array().unwrap() {
        fs::write(
            root.join(fixture["name"].as_str().unwrap()),
            base64::engine::general_purpose::STANDARD
                .decode(fixture["base64"].as_str().unwrap())?,
        )?;
    }
    let case = std::env::var("FILE_BENCH_CASE").unwrap_or_else(|_| "read_text".into());
    let (name, args) = match case.as_str() {
        "read_text" => ("read_file", json!({"path":"text.txt"})),
        "read_docx" => ("read_file", json!({"path":"paragraphs.docx"})),
        "read_notebook" => ("read_file", json!({"path":"notebook_0.ipynb"})),
        "search" => (
            "search_files",
            json!({"pattern":"needle","path":"text.txt","limit":200}),
        ),
        _ => panic!("unknown case"),
    };
    let mut times = vec![];
    let cpu_start = cpu_seconds();
    for _ in 0..200 {
        let begin = Instant::now();
        let v = call(&tools, name, args.clone()).await?;
        std::hint::black_box(v);
        times.push(begin.elapsed().as_nanos());
    }
    let cpu = cpu_seconds() - cpu_start;
    let raw_times = times.clone();
    times.sort_unstable();
    let rss = fs::read_to_string("/proc/self/status")?
        .lines()
        .find(|l| l.starts_with("VmHWM:"))
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse::<usize>()?;
    println!(
        "BENCH {}",
        json!({"case":case,"runtime":"rust","iterations":200,"elapsed_ns":raw_times,"median_ns":times[99],"p95_ns":times[189],"cpu_seconds":cpu,"max_rss_kib":rss,"scope":"LocalTools execute after setup; no startup/cache"})
    );
    Ok(())
}
fn cpu_seconds() -> f64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    unsafe {
        libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr());
        let u = usage.assume_init();
        (u.ru_utime.tv_sec + u.ru_stime.tv_sec) as f64
            + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) as f64 / 1_000_000.0
    }
}
