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
    path::Path,
    time::{Duration, Instant, SystemTime},
};

fn context() -> TurnContext {
    TurnContext {
        conversation_id: "semantics-c".into(),
        input_id: "input".into(),
        session_id: "semantics-s".into(),
    }
}
async fn setup() -> Result<(tempfile::TempDir, std::path::PathBuf, LocalTools)> {
    let tmp = tempfile::tempdir()?;
    let root = tmp.path().join("root");
    fs::create_dir(&root)?;
    let mut cfg = LocalToolsConfig::new("owner".into(), root.clone(), tmp.path().join("state.db"));
    cfg.write = Permission::Allow;
    Ok((tmp, root, LocalTools::open(cfg, None, None).await?))
}
async fn call(tools: &LocalTools, name: &str, args: Value) -> Result<Value> {
    tools.execute(name, args, &context()).await
}
async fn names(tools: &LocalTools, args: Value) -> Result<Vec<String>> {
    let value = call(tools, "search_files", args).await?;
    Ok(paths(&value))
}
fn paths(value: &Value) -> Vec<String> {
    value["matches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["path"].as_str().unwrap().into())
        .collect()
}
fn write(root: &Path, name: &str, text: impl AsRef<[u8]>) -> Result<()> {
    let path = root.join(name);
    fs::create_dir_all(path.parent().unwrap())?;
    fs::write(path, text)?;
    Ok(())
}
fn utf16(text: &str, little: bool, bom: bool) -> Vec<u8> {
    let mut bytes = if bom {
        if little {
            vec![255, 254]
        } else {
            vec![254, 255]
        }
    } else {
        vec![]
    };
    for c in text.encode_utf16() {
        bytes.extend(if little {
            c.to_le_bytes()
        } else {
            c.to_be_bytes()
        });
    }
    bytes
}

#[tokio::test]
async fn pinned_utf16_rescue_and_deliberate_strict_differences() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    let corpus: Value = serde_json::from_str(include_str!(
        "fixtures/local_file_semantics/upstream_utf16.json"
    ))?;
    for fixture in corpus["fixtures"].as_array().unwrap() {
        let name = fixture["name"].as_str().unwrap();
        let data = base64::engine::general_purpose::STANDARD
            .decode(fixture["base64"].as_str().unwrap())?;
        write(&root, name, &data)?;
        let read = call(&tools, "read_file", json!({"path":name})).await;
        if fixture["strict_rust_accepts"] == true {
            let read = read?;
            assert_eq!(read["text_encoding"], fixture["encoding"]);
            assert_eq!(read["transcoded"], true);
            assert_eq!(read["complete_read"], false);
            assert_eq!(read["extracted_document"], false);
            assert_eq!(read["sha256"], format!("{:x}", Sha256::digest(&data)));
            // Upstream counts an extra terminal split item, but its renderer
            // drops the phantom gutter. Rust keeps ordinary line-count semantics.
            assert_eq!(
                read["content"]
                    .as_str()
                    .unwrap()
                    .strip_suffix('\n')
                    .unwrap(),
                fixture["upstream"]["content"].as_str().unwrap()
            );
            assert_eq!(
                read["total_lines"].as_u64().unwrap() + 1,
                fixture["upstream"]["total_lines"].as_u64().unwrap()
            );
        } else {
            assert!(read.is_err(), "{name}: {read:?}");
        }
    }
    Ok(())
}
#[tokio::test]
async fn utf16_pages_search_and_mutations_never_authorize_writes() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    let bytes = utf16("one\r\ntwo\rthree", true, true);
    write(&root, "wide.txt", &bytes)?;
    for (offset, expected) in [(1, "1|one\n"), (2, "2|two\n"), (3, "3|three\n")] {
        let read = call(
            &tools,
            "read_file",
            json!({"path":"wide.txt","offset":offset,"limit":1}),
        )
        .await?;
        assert_eq!(read["content"], expected);
        assert_eq!(read["complete_read"], false);
    }
    let search = call(
        &tools,
        "search_files",
        json!({"pattern":"two","path":"wide.txt"}),
    )
    .await?;
    assert_eq!(search["matches"][0]["line"], 2);
    assert!(
        call(
            &tools,
            "write_file",
            json!({"path":"wide.txt","content":"destroy"})
        )
        .await
        .is_err()
    );
    assert_eq!(fs::read(root.join("wide.txt"))?, bytes);
    write(&root, "stale.txt", "ordinary")?;
    assert_eq!(
        call(&tools, "read_file", json!({"path":"stale.txt"})).await?["complete_read"],
        true
    );
    let changed = utf16("xyz", true, true);
    assert_eq!(changed.len(), 8);
    write(&root, "stale.txt", &changed)?;
    let read = call(&tools, "read_file", json!({"path":"stale.txt"})).await?;
    assert_eq!(read["complete_read"], false);
    assert!(
        call(
            &tools,
            "write_file",
            json!({"path":"stale.txt","content":"destroy"})
        )
        .await
        .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn utf16_detection_is_bounded_strict_and_binary_extension_aware() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    for (i, bytes) in [
        vec![0, 0, 0, 0],
        vec![255, 254],
        vec![255, 254, 0, 220],
        vec![255, 254, 0, 216],
        vec![255, 254, 65, 0, 0, 0],
        vec![0, 65, 0],
        vec![0xff, 0xff],
    ]
    .iter()
    .enumerate()
    {
        let name = format!("bad{i}.txt");
        write(&root, &name, bytes)?;
        assert!(
            call(&tools, "read_file", json!({"path":name}))
                .await
                .is_err()
        );
    }
    for name in [
        "image.PNG",
        "archive.zip",
        "cache.db-wal",
        "side.SQLite3-SHM",
    ] {
        write(&root, name, utf16("ABC", true, true))?;
        assert!(
            call(&tools, "read_file", json!({"path":name}))
                .await
                .is_err()
        );
    }
    // Mixed Latin/CJK rescues via parity, not a high density of NULs.
    for little in [true, false] {
        write(
            &root,
            "mixed.txt",
            utf16("AB日本語日本語日本語", little, false),
        )?;
        assert_eq!(
            call(&tools, "read_file", json!({"path":"mixed.txt"})).await?["transcoded"],
            true
        );
    }
    // No parity evidence within the pinned 512-byte sample: do not guess CJK.
    write(
        &root,
        "no-evidence.txt",
        utf16(&("日本語".repeat(100) + "ABC"), true, false),
    )?;
    assert!(
        call(&tools, "read_file", json!({"path":"no-evidence.txt"}))
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn ignores_apply_nested_type_precedence_and_parent_pruning() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(
        &root,
        ".gitignore",
        "*.log\n!keep.log\n/root-only.txt\ncache/\n!cache/keep.txt\n",
    )?;
    write(&root, ".ignore", "*.tmp\n!force.tmp\nblocked.txt\n")?;
    write(
        &root,
        "sub/.gitignore",
        "!*.tmp\n!blocked.txt\n!local.log\n",
    )?;
    write(&root, "sub/.ignore", "!nested.tmp\n")?;
    for name in [
        "gone.log",
        "keep.log",
        "root-only.txt",
        "sub/root-only.txt",
        "sub/local.log",
        "sub/gone.log",
        "sub/blocked.txt",
        "sub/gone.tmp",
        "sub/nested.tmp",
        "sub/force.tmp",
        "cache/keep.txt",
        "visible.txt",
    ] {
        write(&root, name, "needle")?;
    }
    let got = names(
        &tools,
        json!({"pattern":"needle","output_mode":"files_only"}),
    )
    .await?;
    let mut expected = vec![
        "keep.log",
        "sub/root-only.txt",
        "sub/local.log",
        "sub/nested.tmp",
        "sub/force.tmp",
        "visible.txt",
    ]
    .into_iter()
    .map(String::from)
    .collect::<Vec<_>>();
    let mut got = got;
    got.sort();
    expected.sort();
    assert_eq!(got, expected);
    // A positive query glob does not override visibility controls in this rooted
    // backend, unlike ripgrep's -g override. Direct user-selected paths can.
    assert!(
        names(&tools, json!({"target":"files","pattern":"*.tmp"}))
            .await?
            .iter()
            .all(|p| p.ends_with("force.tmp") || p.ends_with("nested.tmp"))
    );
    assert_eq!(
        names(&tools, json!({"pattern":"needle","path":"gone.log"})).await?,
        ["gone.log"]
    );
    assert_eq!(
        call(&tools, "read_file", json!({"path":"gone.log"})).await?["complete_read"],
        true
    );
    Ok(())
}
#[tokio::test]
async fn ignores_preserve_git_pattern_escaping_and_scope() -> Result<()> {
    let (tmp, root, tools) = setup().await?;
    fs::write(tmp.path().join(".ignore"), "*\n")?;
    write(
        &root,
        ".gitignore",
        "# comment\n\\#literal\n\\!literal\nspace\\ \ntrailing   \nfile[0-2].txt\nbrace{a,b}\na/**/drop.txt\n/anchored\nonlydir/\n",
    )?;
    for name in [
        "#literal",
        "!literal",
        "space ",
        "trailing",
        "file1.txt",
        "brace{a,b}",
        "a/deep/drop.txt",
        "a/drop.txt",
        "anchored",
        "onlydir/child",
        "sub/anchored",
        "file3.txt",
        "bracea",
        "keep",
        "sub/space x",
    ] {
        write(&root, name, "hit")?;
    }
    let mut got = names(&tools, json!({"pattern":"hit","output_mode":"files_only"})).await?;
    got.sort();
    assert_eq!(
        got,
        ["bracea", "file3.txt", "keep", "sub/anchored", "sub/space x"]
    );
    let result = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"keep"}),
    )
    .await?;
    assert_eq!(result["ignore_scope"], "configured_root_only");
    assert_eq!(result["ignore_files"], 1);
    Ok(())
}
#[tokio::test]
async fn explicit_subroot_inherits_only_authorized_ancestors_and_scopes_globs() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(&root, ".ignore", "*.tmp\n")?;
    write(&root, "sub/.ignore", "!keep.tmp\n")?;
    for name in [
        "sub/keep.tmp",
        "sub/drop.tmp",
        "sub/deep/file.rs",
        "outside.rs",
    ] {
        write(&root, name, "needle")?;
    }
    assert_eq!(
        names(
            &tools,
            json!({"target":"files","pattern":"deep/*.rs","path":"sub"})
        )
        .await?,
        ["sub/deep/file.rs"]
    );
    assert_eq!(
        names(
            &tools,
            json!({"pattern":"needle","file_glob":"deep/*.rs","path":"sub"})
        )
        .await?,
        ["sub/deep/file.rs"]
    );
    assert_eq!(
        names(
            &tools,
            json!({"target":"files","pattern":"*.tmp","path":"sub"})
        )
        .await?,
        ["sub/keep.tmp"]
    );
    Ok(())
}
#[tokio::test]
async fn hidden_descendants_are_excluded_but_explicit_roots_are_allowed() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    for name in [
        "visible",
        ".plain",
        ".hidden/visible",
        ".hidden/.nested/miss",
        ".hidden/.dot",
        ".env",
        ".ssh/key",
        ".git/config",
    ] {
        write(&root, name, "hit")?;
    }
    assert_eq!(names(&tools, json!({"pattern":"hit"})).await?, ["visible"]);
    assert_eq!(
        names(&tools, json!({"pattern":"hit","path":".hidden"})).await?,
        [".hidden/visible"]
    );
    assert_eq!(
        names(
            &tools,
            json!({"target":"files","pattern":"*","path":".plain"})
        )
        .await?,
        [".plain"]
    );
    assert!(
        names(&tools, json!({"target":"files","pattern":".*"}))
            .await?
            .is_empty()
    );
    for path in [".env", ".ssh", ".git/config", "../outside", "/etc"] {
        assert!(
            call(
                &tools,
                "search_files",
                json!({"target":"files","pattern":"*","path":path})
            )
            .await
            .is_err()
        );
    }
    Ok(())
}
#[tokio::test]
async fn safe_directory_results_include_empty_dirs_with_global_modified_pages() -> Result<()> {
    let (tmp, root, tools) = setup().await?;
    for name in ["a", "b", "nest/c"] {
        fs::create_dir_all(root.join(name))?;
    }
    write(&root, "file", "hit")?;
    let epoch = SystemTime::UNIX_EPOCH + Duration::from_secs(1000);
    for (name, seconds) in [("a", 4), ("b", 3), ("nest", 2), ("nest/c", 1), ("file", 0)] {
        fs::File::open(root.join(name))?
            .set_times(fs::FileTimes::new().set_modified(epoch + Duration::from_secs(seconds)))?;
    }
    std::os::unix::fs::symlink(tmp.path(), root.join("directory-link"))?;
    let all = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*","order":"modified"}),
    )
    .await?;
    assert_eq!(paths(&all), ["a", "b", "nest", "nest/c", "file"]);
    assert_eq!(all["matches"][0]["is_directory"], true);
    assert_eq!(all["matches"][4]["is_directory"], false);
    let page = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*","order":"modified","limit":2,"offset":2}),
    )
    .await?;
    assert_eq!(paths(&page), ["nest", "nest/c"]);
    assert_eq!(page["next_offset"], 4);
    let last = call(
        &tools,
        "search_files",
        json!({"target":"files","pattern":"*","order":"modified","limit":1,"offset":4}),
    )
    .await?;
    assert_eq!(paths(&last), ["file"]);
    assert!(last["next_offset"].is_null());
    assert!(
        names(&tools, json!({"target":"files","pattern":"*","path":"a"}))
            .await?
            .is_empty()
    );
    assert_eq!(names(&tools, json!({"pattern":"hit"})).await?, ["file"]);
    Ok(())
}
#[tokio::test]
async fn filename_suffix_patterns_match_pinned_rg_branch() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    for name in ["config", "appconfig", "configmore", "src/tool.rs"] {
        write(&root, name, "data")?;
    }
    let mut found = names(&tools, json!({"target":"files","pattern":"config"})).await?;
    found.sort();
    assert_eq!(found, ["appconfig", "config"]);
    Ok(())
}
#[tokio::test]
async fn unsafe_ignore_sources_fail_closed_without_following_links() -> Result<()> {
    for kind in ["symlink", "hardlink", "directory", "fifo"] {
        let (tmp, root, tools) = setup().await?;
        write(&root, "safe.txt", "hit")?;
        fs::write(tmp.path().join("outside"), "*\n")?;
        match kind {
            "symlink" => {
                std::os::unix::fs::symlink(tmp.path().join("outside"), root.join(".ignore"))?
            }
            "hardlink" => fs::hard_link(tmp.path().join("outside"), root.join(".ignore"))?,
            "directory" => fs::create_dir(root.join(".ignore"))?,
            _ => {
                use std::os::unix::ffi::OsStrExt;
                let p = std::ffi::CString::new(root.join(".ignore").as_os_str().as_bytes())?;
                assert_eq!(unsafe { libc::mkfifo(p.as_ptr(), 0o600) }, 0);
            }
        }
        let err = call(&tools, "search_files", json!({"pattern":"hit"}))
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("ignore rule source"),
            "{kind}: {err}"
        );
        assert_eq!(
            names(&tools, json!({"pattern":"hit","path":"safe.txt"})).await?,
            ["safe.txt"]
        );
        assert_eq!(fs::read_to_string(tmp.path().join("outside"))?, "*\n");
    }
    Ok(())
}
#[tokio::test]
async fn malformed_and_over_budget_ignore_rules_do_not_broaden_results() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(&root, "safe", "hit")?;
    for bytes in [
        b"[broken".as_slice(),
        b"unfinished\\",
        b"bad\0rule",
        b"\xff",
        &vec![b'x'; 65537],
    ] {
        write(&root, ".ignore", bytes)?;
        assert!(
            call(&tools, "search_files", json!({"pattern":"hit"}))
                .await
                .is_err()
        );
    }
    write(&root, ".ignore", "a\n".repeat(4097))?;
    assert!(
        call(&tools, "search_files", json!({"pattern":"hit"}))
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn ignored_subtrees_are_pruned_before_descendant_work_and_rule_reads() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(&root, ".ignore", "cache/\n")?;
    write(&root, "cache/.ignore", b"\xff")?;
    for n in 0..1002 {
        write(&root, &format!("cache/{n}"), "hit")?;
    }
    write(&root, "visible", "hit")?;
    assert_eq!(names(&tools, json!({"pattern":"hit"})).await?, ["visible"]);
    assert!(
        call(
            &tools,
            "search_files",
            json!({"pattern":"hit","path":"cache"})
        )
        .await
        .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn rules_do_not_leak_to_siblings_or_cache_across_mutations() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(&root, "a/.ignore", "*.txt\n")?;
    write(&root, "a/file.txt", "hit")?;
    write(&root, "b/file.txt", "hit")?;
    assert_eq!(
        names(&tools, json!({"pattern":"hit"})).await?,
        ["b/file.txt"]
    );
    write(&root, "a/.ignore", "!*.txt\n")?;
    assert_eq!(names(&tools, json!({"pattern":"hit"})).await?.len(), 2);
    Ok(())
}

#[tokio::test]
#[ignore = "isolated benchmark; wait for coordinated quiet window"]
async fn benchmark_local_file_semantics() -> Result<()> {
    let (_tmp, root, tools) = setup().await?;
    write(
        &root,
        "utf16.txt",
        utf16(&"Alpha 日本語 😀\r\n".repeat(4000), true, true),
    )?;
    write(&root, "utf8.txt", "Alpha 日本語 😀\r\n".repeat(4000))?;
    let case =
        std::env::var("FILE_SEMANTICS_BENCH_CASE").unwrap_or_else(|_| "search_ignored".into());
    let (tool, args) = match case.as_str() {
        "read_utf16" => ("read_file", json!({"path":"utf16.txt"})),
        "read_utf8" => ("read_file", json!({"path":"utf8.txt"})),
        "search_ignored" | "search_plain" => {
            if case == "search_ignored" {
                write(&root, ".ignore", "cache/\n*.log\n")?;
            }
            for i in 0..80 {
                write(&root, &format!("source/{i}.txt"), "Alpha\n".repeat(100))?;
                write(&root, &format!("cache/{i}.log"), "Alpha\n".repeat(100))?;
            }
            (
                "search_files",
                json!({"pattern":"Alpha","output_mode":"count","limit":200}),
            )
        }
        "directories" => {
            for i in 0..80 {
                fs::create_dir_all(root.join(format!("dirs/{i}")))?;
            }
            (
                "search_files",
                json!({"pattern":"*","target":"files","order":"modified","limit":200}),
            )
        }
        _ => panic!("unknown benchmark case"),
    };
    let mut wall = vec![];
    let mut cpu = vec![];
    for _ in 0..200 {
        let cpu_start = cpu_ns();
        let start = Instant::now();
        std::hint::black_box(call(&tools, tool, args.clone()).await?);
        wall.push(start.elapsed().as_nanos());
        cpu.push(cpu_ns() - cpu_start);
    }
    let mut ordered = wall.clone();
    ordered.sort_unstable();
    let rss = fs::read_to_string("/proc/self/status")?
        .lines()
        .find(|s| s.starts_with("VmHWM:"))
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse::<usize>()?;
    println!(
        "BENCH {}",
        json!({"case":case,"iterations":200,"elapsed_ns":wall,"cpu_ns":cpu,"median_ns":ordered[99],"p95_ns":ordered[189],"max_rss_kib":rss,"scope":"LocalTools execution after setup, per-call process CPU and wall samples; not full Agent or upstream speed comparison"})
    );
    Ok(())
}
fn cpu_ns() -> u128 {
    let mut time = std::mem::MaybeUninit::<libc::timespec>::uninit();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, time.as_mut_ptr()) },
        0
    );
    let time = unsafe { time.assume_init() };
    time.tv_sec as u128 * 1_000_000_000 + time.tv_nsec as u128
}
