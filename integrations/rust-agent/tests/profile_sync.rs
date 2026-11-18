use base64::{Engine as _, engine::general_purpose::STANDARD};
use hermes_rust_core::profile_sync::*;
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
use tempfile::TempDir;

fn data(values: &[(&str, &[u8])]) -> Contents {
    values
        .iter()
        .map(|(p, b)| ((*p).to_owned(), b.to_vec()))
        .collect()
}
fn request(node: &str, hub_id: Option<&str>, base: &Contents, live: &Contents) -> Request {
    let b = manifest(base);
    let l = manifest(live);
    Request {
        node: node.into(),
        hub_id: hub_id.map(str::to_owned),
        base: b.clone(),
        live: l.clone(),
        payload: live
            .iter()
            .filter(|(p, _)| b.get(*p) != l.get(*p))
            .map(|(p, bytes)| (p.clone(), STANDARD.encode(bytes)))
            .collect(),
    }
}
fn put(profile: &Path, path: &str, bytes: &[u8]) {
    let p = profile.join(path);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, bytes).unwrap();
}
fn cfg(root: &Path, node: &str) -> SyncConfig {
    let profile = root.join(node);
    fs::create_dir_all(&profile).unwrap();
    SyncConfig {
        profile,
        state_dir: root.join(format!("{node}-state")),
        node: node.into(),
        hub_store: Some(root.join("hub")),
        ssh: vec![],
        force_payload: false,
        allowed_skill_roots: vec![],
    }
}
fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}
fn walk(root: &Path) -> Vec<PathBuf> {
    let mut found = vec![];
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries {
            let p = entry.unwrap().path();
            if p.is_dir() && !p.is_symlink() {
                found.extend(walk(&p));
            } else {
                found.push(p);
            }
        }
    }
    found
}

#[test]
fn scope_normalization_and_collisions() {
    for forbidden in [
        "",
        "/SOUL.md",
        "config.yaml",
        "auth.json",
        "sessions/a",
        "cron/jobs.json",
        "attachments/a",
        "memories/SECRET.md",
        "skills/../secret",
        "skills//a",
        "skills/a/",
        "skills/.env",
        "skills/env/a",
        "skills/a.lock",
        "skills/a\\b",
        "skills/C:foo",
        "skills/a\nb",
    ] {
        assert!(!allowed(forbidden), "allowed {forbidden:?}");
    }
    for path in [
        "SOUL.md",
        "memories/MEMORY.md",
        "memories/USER.md",
        "skills/demo/SKILL.md",
        "skills/demo/run.sh",
    ] {
        assert!(allowed(path));
    }
    assert!(validate_paths(["skills/Demo/SKILL.md", "skills/demo/skill.md"]).is_err());
    assert!(validate_paths(["skills/Straße.md", "skills/STRASSE.md"]).is_err());
    assert!(validate_paths(["skills/foo", "skills/foo/bar"]).is_err());
    assert_eq!(
        normalize(b"\xef\xbb\xbfhello\r\nworld\r"),
        b"hello\nworld\n"
    );
    assert_eq!(normalize(b"hello\0\r\n"), b"hello\0\r\n");
    assert_eq!(normalize(b"\xff\r\n"), b"\xff\r\n");
}
#[test]
fn two_profiles_bootstrap_offline_delete_and_excluded_sentinels() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    for c in [&a, &b] {
        for path in [
            "config.yaml",
            ".env",
            "auth.json",
            "sessions/history.db",
            "attachments/secret.png",
            "cron/jobs.json",
            "skills/demo/.secret",
            "skills/demo/node_modules/package/index.js",
        ] {
            put(&c.profile, path, b"device-only sentinel");
        }
    }
    put(&a.profile, "SOUL.md", b"portable identity\r\n");
    put(
        &a.profile,
        "memories/MEMORY.md",
        "keep\n§\nremove".as_bytes(),
    );
    put(&a.profile, "skills/demo/SKILL.md", b"version one\n");
    assert_eq!(run_sync(&a).unwrap().exit_code(), 0);
    assert_eq!(run_sync(&b).unwrap().applied, 3);
    assert_eq!(
        fs::read(b.profile.join("SOUL.md")).unwrap(),
        b"portable identity\n"
    );
    fs::remove_file(a.profile.join("skills/demo/SKILL.md")).unwrap();
    put(&a.profile, "skills/demo/added.md", b"new");
    run_sync(&a).unwrap();
    assert_eq!(run_sync(&b).unwrap().exit_code(), 0);
    assert!(!b.profile.join("skills/demo/SKILL.md").exists());
    assert_eq!(
        fs::read(b.profile.join("skills/demo/added.md")).unwrap(),
        b"new"
    );
    run_sync(&b).unwrap();
    run_sync(&a).unwrap();
    for c in [&a, &b] {
        for path in [
            "config.yaml",
            ".env",
            "auth.json",
            "sessions/history.db",
            "attachments/secret.png",
            "cron/jobs.json",
            "skills/demo/.secret",
            "skills/demo/node_modules/package/index.js",
        ] {
            assert_eq!(
                fs::read(c.profile.join(path)).unwrap(),
                b"device-only sentinel"
            );
        }
    }
    let hub = read_json(&root.path().join("hub/hub.json"));
    assert_eq!(hub["files"].as_object().unwrap().len(), 3);
    assert!(
        walk(&b.state_dir.join("backups"))
            .iter()
            .any(|p| p.ends_with("files/skills/demo/SKILL.md"))
    );
}
#[test]
fn concurrent_memory_entry_deletions_win_and_additions_deduplicate() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    put(
        &a.profile,
        "memories/MEMORY.md",
        "keep\n§\ndelete-a\n§\ndelete-b".as_bytes(),
    );
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(
        &a.profile,
        "memories/MEMORY.md",
        "keep\n§\ndelete-b\n§\na\n§\nshared".as_bytes(),
    );
    put(
        &b.profile,
        "memories/MEMORY.md",
        "keep\n§\ndelete-a\n§\nb\n§\nshared".as_bytes(),
    );
    run_sync(&a).unwrap();
    assert_eq!(run_sync(&b).unwrap().exit_code(), 0);
    run_sync(&a).unwrap();
    let merged = "keep\n§\na\n§\nshared\n§\nb".as_bytes();
    assert_eq!(
        fs::read(a.profile.join("memories/MEMORY.md")).unwrap(),
        merged
    );
    assert_eq!(
        fs::read(b.profile.join("memories/MEMORY.md")).unwrap(),
        merged
    );
}
#[test]
fn overlapping_soul_conflict_preserves_local_hub_objects_and_old_base() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    put(&a.profile, "SOUL.md", b"common\n");
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(&a.profile, "SOUL.md", b"remote\n");
    put(&b.profile, "SOUL.md", b"local\n");
    run_sync(&a).unwrap();
    let conflict = run_sync(&b).unwrap();
    assert_eq!(conflict.exit_code(), 2);
    assert_eq!(conflict.conflicts, vec!["SOUL.md"]);
    assert_eq!(fs::read(b.profile.join("SOUL.md")).unwrap(), b"local\n");
    assert_eq!(
        read_json(&b.state_dir.join("client.json"))["base"]["SOUL.md"],
        digest(b"common\n")
    );
    for bytes in [b"common\n".as_slice(), b"remote\n", b"local\n"] {
        assert_eq!(
            get_blob(&root.path().join("hub"), &digest(bytes)).unwrap(),
            bytes
        );
    }
    assert_eq!(run_sync(&b).unwrap().exit_code(), 2);
    // Deliberately choosing the already preserved hub version resolves conflict.
    put(&b.profile, "SOUL.md", b"remote\n");
    assert_eq!(run_sync(&b).unwrap().exit_code(), 0);
    assert!(!b.state_dir.join("conflicts.json").exists());
}
#[test]
fn binary_and_edit_delete_conflicts_never_install_markers() {
    for remote in [Some(b"remote\0".as_slice()), None] {
        let root = TempDir::new().unwrap();
        let hub = root.path().join("hub");
        let base = data(&[("skills/blob", b"base\0")]);
        let first = exchange(&hub, &request("a", None, &Contents::new(), &base)).unwrap();
        let theirs = remote
            .map(|b| data(&[("skills/blob", b)]))
            .unwrap_or_default();
        exchange(&hub, &request("a", Some(&first.hub_id), &base, &theirs)).unwrap();
        let ours = data(&[("skills/blob", b"local\0")]);
        let result = exchange(&hub, &request("b", Some(&first.hub_id), &base, &ours)).unwrap();
        assert_eq!(result.conflicts, vec!["skills/blob"]);
        assert!(result.changes.is_empty());
        assert_eq!(get_blob(&hub, &digest(b"local\0")).unwrap(), b"local\0");
    }
}
#[test]
fn nonoverlapping_text_and_soul_edits_merge_with_git() {
    for path in ["SOUL.md", "skills/demo/SKILL.md"] {
        let root = TempDir::new().unwrap();
        let hub = root.path().join("hub");
        let base = data(&[(path, b"one\ntwo\nthree\n")]);
        let first = exchange(&hub, &request("a", None, &Contents::new(), &base)).unwrap();
        exchange(
            &hub,
            &request(
                "a",
                Some(&first.hub_id),
                &base,
                &data(&[(path, b"ONE\ntwo\nthree\n")]),
            ),
        )
        .unwrap();
        let result = exchange(
            &hub,
            &request(
                "b",
                Some(&first.hub_id),
                &base,
                &data(&[(path, b"one\ntwo\nTHREE\n")]),
            ),
        )
        .unwrap();
        assert!(result.conflicts.is_empty());
        assert_eq!(
            get_blob(&hub, &result.files[path]).unwrap(),
            b"ONE\ntwo\nTHREE\n"
        );
    }
}
#[test]
fn capacity_overflow_preserves_originals_without_truncating_unicode() {
    let root = TempDir::new().unwrap();
    let hub = root.path().join("hub");
    let path = "memories/MEMORY.md";
    let base = data(&[(path, "中文".as_bytes())]);
    let first = exchange(&hub, &request("a", None, &Contents::new(), &base)).unwrap();
    let mut state = read_json(&hub.join("hub.json"));
    state["memory_limits"] = json!({path:3});
    fs::write(hub.join("hub.json"), state.to_string()).unwrap();
    let live = data(&[(path, "中文很多".as_bytes())]);
    let result = exchange(&hub, &request("b", Some(&first.hub_id), &base, &live)).unwrap();
    assert_eq!(result.conflicts, vec![path]);
    assert_eq!(result.files[path], digest("中文".as_bytes()));
    assert_eq!(
        get_blob(&hub, &digest("中文很多".as_bytes())).unwrap(),
        "中文很多".as_bytes()
    );
}
#[test]
fn lost_response_retry_and_hub_restart_are_idempotent() {
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    put(&config.profile, "SOUL.md", b"identity\n");
    let failed = run_sync_with_transport(&config, |request| {
        exchange(config.hub_store.as_ref().unwrap(), request)?;
        anyhow::bail!("response lost")
    });
    assert!(failed.is_err());
    assert!(!config.state_dir.join("client.json").exists());
    assert_eq!(run_sync(&config).unwrap().revision, 1);
    assert_eq!(run_sync(&config).unwrap().applied, 0);
    assert_eq!(walk(&root.path().join("hub/history")).len(), 1);
}
#[test]
fn corrupt_payload_objects_paths_and_nodes_are_rejected() {
    let root = TempDir::new().unwrap();
    let hub = root.path().join("hub");
    let mut req = request("a", None, &Contents::new(), &data(&[("SOUL.md", b"one")]));
    req.node = "../../escape".into();
    assert!(exchange(&hub, &req).is_err());
    assert!(!hub.exists());
    req.node = "a".into();
    req.payload
        .insert("SOUL.md".into(), STANDARD.encode(b"different"));
    assert!(exchange(&hub, &req).is_err());
    req.payload.insert("SOUL.md".into(), "not base64!!!".into());
    assert!(exchange(&hub, &req).is_err());
    req.payload
        .insert("SOUL.md".into(), STANDARD.encode(b"one"));
    exchange(&hub, &req).unwrap();
    fs::write(hub.join("objects").join(digest(b"one")), b"corrupt").unwrap();
    assert!(exchange(&hub, &req).is_err());
    req.live.insert("config.yaml".into(), digest(b"secret"));
    assert!(exchange(&hub, &req).is_err());
}
#[test]
fn remote_identity_revision_and_all_changes_preflight_before_writes() {
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    put(&config.profile, "SOUL.md", b"old");
    run_sync(&config).unwrap();
    for case in 0..4 {
        let result = run_sync_with_transport(&config, |req| {
            let mut response = exchange(config.hub_store.as_ref().unwrap(), req)?;
            match case {
                0 => response.hub_id = "replacement".into(),
                1 => response.revision = 0,
                2 => {
                    response.files.insert("SOUL.md".into(), digest(b"new"));
                    response
                        .changes
                        .insert("SOUL.md".into(), Some(STANDARD.encode(b"new")));
                    response.files.insert("skills/z".into(), digest(b"z"));
                    response
                        .changes
                        .insert("skills/z".into(), Some("invalid!".into()));
                }
                _ => {
                    response.files.insert("SOUL.md".into(), digest(b"new"));
                }
            }
            Ok(response)
        });
        assert!(result.is_err());
        assert_eq!(fs::read(config.profile.join("SOUL.md")).unwrap(), b"old");
    }
}
#[test]
fn concurrent_live_drift_is_preserved_and_not_acknowledged() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    put(&a.profile, "memories/MEMORY.md", b"base");
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(&a.profile, "memories/MEMORY.md", b"remote");
    run_sync(&a).unwrap();
    let result = run_sync_with_transport(&b, |req| {
        let response = exchange(b.hub_store.as_ref().unwrap(), req)?;
        put(&b.profile, "memories/MEMORY.md", b"concurrent writer");
        Ok(response)
    })
    .unwrap();
    assert_eq!(result.conflicts, vec!["memories/MEMORY.md"]);
    assert_eq!(
        fs::read(b.profile.join("memories/MEMORY.md")).unwrap(),
        b"concurrent writer"
    );
    assert_eq!(
        read_json(&b.state_dir.join("client.json"))["base"]["memories/MEMORY.md"],
        digest(b"base")
    );
}
#[test]
fn partial_apply_retry_retains_backups_and_recovers_without_loss() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    for path in ["skills/a", "skills/z"] {
        put(&a.profile, path, b"old");
    }
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    for path in ["skills/a", "skills/z"] {
        put(&a.profile, path, b"new");
    }
    run_sync(&a).unwrap();
    let failed = run_sync_with_transport(&b, |req| {
        let response = exchange(b.hub_store.as_ref().unwrap(), req)?;
        fs::remove_file(b.profile.join("skills/z"))?;
        fs::create_dir(b.profile.join("skills/z"))?;
        Ok(response)
    });
    assert!(failed.is_err());
    assert!(b.state_dir.join("pending.json").exists());
    assert_eq!(fs::read(b.profile.join("skills/a")).unwrap(), b"new");
    assert_eq!(
        read_json(&b.state_dir.join("client.json"))["base"]["skills/a"],
        digest(b"old")
    );
    fs::remove_dir(b.profile.join("skills/z")).unwrap();
    put(&b.profile, "skills/z", b"old");
    assert_eq!(run_sync(&b).unwrap().exit_code(), 0);
    assert!(!b.state_dir.join("pending.json").exists());
    assert_eq!(fs::read(b.profile.join("skills/z")).unwrap(), b"new");
    assert!(
        walk(&b.state_dir.join("backups"))
            .iter()
            .any(|p| p.ends_with("files/skills/a") && fs::read(p).unwrap() == b"old")
    );
}
#[test]
fn overlapping_client_runs_fail_without_waiting() {
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    let _lock = FileLock::acquire(&config.state_dir.join("run.lock"), false).unwrap();
    let start = Instant::now();
    assert!(
        run_sync(&config)
            .unwrap_err()
            .to_string()
            .contains("Lock busy")
    );
    assert!(start.elapsed() < Duration::from_secs(1));
}
#[cfg(unix)]
#[test]
fn linked_skill_requires_explicit_root_and_materializes_without_modifying_library() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let mut a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    let external = root.path().join("library");
    fs::create_dir_all(&external).unwrap();
    fs::write(external.join("SKILL.md"), b"old").unwrap();
    fs::create_dir(a.profile.join("skills")).unwrap();
    symlink(&external, a.profile.join("skills/shared")).unwrap();
    assert!(run_sync(&a).is_err());
    assert!(!root.path().join("hub").exists());
    a.allowed_skill_roots.push(external.clone());
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(&b.profile, "skills/shared/SKILL.md", b"new");
    run_sync(&b).unwrap();
    run_sync(&a).unwrap();
    assert_eq!(fs::read(external.join("SKILL.md")).unwrap(), b"old");
    assert!(!a.profile.join("skills/shared").is_symlink());
    assert_eq!(
        fs::read(a.profile.join("skills/shared/SKILL.md")).unwrap(),
        b"new"
    );
    assert!(
        walk(&a.state_dir.join("backups"))
            .iter()
            .any(|p| p.ends_with("links/skills/shared.link.json"))
    );
}
#[cfg(unix)]
#[test]
fn unauthorized_external_sentinel_link_escape_and_cycles_never_reach_hub() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let mut config = cfg(root.path(), "a");
    let library = root.path().join("library");
    fs::create_dir(&library).unwrap();
    let secret = root.path().join("private");
    fs::create_dir(&secret).unwrap();
    fs::write(secret.join("password"), b"never transmit sentinel").unwrap();
    fs::create_dir(config.profile.join("skills")).unwrap();
    symlink(&library, config.profile.join("skills/shared")).unwrap();
    config.allowed_skill_roots.push(library.clone());
    symlink(&secret, library.join("escape")).unwrap();
    assert!(run_sync(&config).is_err());
    assert!(!root.path().join("hub").exists());
    fs::remove_file(library.join("escape")).unwrap();
    symlink(&library, library.join("loop")).unwrap();
    assert!(run_sync(&config).is_err());
}
#[cfg(unix)]
#[test]
fn linked_identity_memory_state_hub_are_rejected_without_external_writes() {
    use std::os::unix::fs::symlink;
    for rel in ["SOUL.md", "memories/MEMORY.md", "memories/USER.md"] {
        let root = TempDir::new().unwrap();
        let config = cfg(root.path(), "a");
        let secret = root.path().join("secret");
        fs::write(&secret, b"secret sentinel").unwrap();
        fs::create_dir_all(config.profile.join(rel).parent().unwrap()).unwrap();
        symlink(&secret, config.profile.join(rel)).unwrap();
        assert!(run_sync(&config).is_err());
        assert!(!root.path().join("hub").exists());
        assert_eq!(fs::read(&secret).unwrap(), b"secret sentinel");
    }
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    let outside = root.path().join("outside");
    fs::create_dir(&outside).unwrap();
    symlink(&outside, &config.state_dir).unwrap();
    assert!(run_sync(&config).is_err());
    assert!(walk(&outside).is_empty());
    fs::remove_file(&config.state_dir).unwrap();
    symlink(&outside, root.path().join("hub")).unwrap();
    assert!(run_sync(&config).is_err());
    assert!(walk(&outside).is_empty());
}
#[cfg(unix)]
#[test]
fn memory_lock_interoperates_with_python_flock() {
    let root = TempDir::new().unwrap();
    let path = root.path().join("MEMORY.md.lock");
    let lock = FileLock::acquire(&path, false).unwrap();
    let output = Command::new("python3").args(["-c", "import sys,fcntl\nf=open(sys.argv[1],'a+b')\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nsys.exit(9)"]).arg(&path).output().unwrap();
    assert!(output.status.success());
    drop(lock);
    let mut child = Command::new("python3").args(["-u", "-c", "import sys,fcntl\nf=open(sys.argv[1],'a+b');fcntl.flock(f,fcntl.LOCK_EX);print('locked',flush=True);sys.stdin.readline()"]).arg(&path).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    assert_eq!(line.trim(), "locked");
    assert!(FileLock::acquire(&path, false).is_err());
    child.stdin.take().unwrap().write_all(b"done\n").unwrap();
    assert!(child.wait().unwrap().success());
    FileLock::acquire(&path, false).unwrap();
}
#[test]
fn hub_binary_answers_one_frame_without_eof_and_cli_sync_uses_explicit_argv() {
    let root = TempDir::new().unwrap();
    let hub = root.path().join("hub");
    let mut child = Command::new(env!("CARGO_BIN_EXE_profile_sync"))
        .args(["hub", "--store"])
        .arg(&hub)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let req = request("a", None, &Contents::new(), &Contents::new());
    writeln!(
        child.stdin.as_mut().unwrap(),
        "{}",
        serde_json::to_string(&req).unwrap()
    )
    .unwrap();
    let start = Instant::now();
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        assert!(start.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let response: Response = serde_json::from_str(&line).unwrap();
    assert!(response.files.is_empty());
    let mut config = cfg(root.path(), "b");
    config.hub_store = None;
    config.ssh = vec![
        env!("CARGO_BIN_EXE_profile_sync").into(),
        "hub".into(),
        "--store".into(),
        hub.to_string_lossy().into(),
    ];
    put(&config.profile, "SOUL.md", b"subprocess");
    assert_eq!(run_sync(&config).unwrap().exit_code(), 0);
    let conf = root.path().join("config.json");
    fs::write(&conf, serde_json::to_vec(&config).unwrap()).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_profile_sync"))
        .args(["sync", "--config"])
        .arg(conf)
        .output()
        .unwrap();
    assert!(output.status.success());
}
#[test]
fn local_transport_timeout_returns_without_shell_interpretation() {
    let req = request("a", None, &Contents::new(), &Contents::new());
    let start = Instant::now();
    let error = exchange_command(
        &[
            "python3".into(),
            "-c".into(),
            "import time;time.sleep(20)".into(),
        ],
        &req,
        Duration::from_millis(50),
    )
    .unwrap_err();
    assert!(error.to_string().contains("timed out"));
    assert!(start.elapsed() < Duration::from_secs(2));
}
#[test]
fn oversized_frame_is_bounded_and_invalid_json_is_rejected() {
    // A lazy reader avoids constructing a >128 MiB source fixture.
    let mut oversized = BufReader::new(std::io::repeat(b' ').take(MAX_REQUEST as u64 + 1));
    use std::io::Read;
    assert!(
        read_request(&mut oversized)
            .unwrap_err()
            .to_string()
            .contains("size limit")
    );
    assert!(read_request(&mut std::io::Cursor::new(b"not-json\n")).is_err());
}
#[test]
fn python_and_rust_hubs_and_clients_share_protocol_and_state_files() {
    let script = std::env::var_os("ORIALIS_PROFILE_SYNC_PY")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../orialis/integrations/hermes/profile_sync/profile_sync.py")
        });
    if !script.is_file() {
        eprintln!(
            "Cross-language fixture unavailable; set ORIALIS_PROFILE_SYNC_PY to pinned source. Native protocol tests still run."
        );
        return;
    }
    let root = TempDir::new().unwrap();
    let mut a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    a.hub_store = None;
    a.ssh = vec![
        "python3".into(),
        script.to_string_lossy().into(),
        "hub".into(),
        "--store".into(),
        root.path().join("hub").to_string_lossy().into(),
    ];
    put(&a.profile, "SOUL.md", b"Python hub, Rust client\n");
    run_sync(&a).unwrap();
    let mut python_config = serde_json::to_value(&b).unwrap();
    python_config["hub_store"] = Value::Null;
    python_config["ssh"] = json!([
        env!("CARGO_BIN_EXE_profile_sync"),
        "hub",
        "--store",
        root.path().join("hub")
    ]);
    let config = root.path().join("python-client.json");
    fs::write(&config, python_config.to_string()).unwrap();
    let output = Command::new("python3")
        .arg(&script)
        .args(["sync", "--config"])
        .arg(&config)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read(b.profile.join("SOUL.md")).unwrap(),
        b"Python hub, Rust client\n"
    );
    put(&b.profile, "SOUL.md", b"Rust hub, Python client\n");
    let output = Command::new("python3")
        .arg(&script)
        .args(["sync", "--config"])
        .arg(&config)
        .output()
        .unwrap();
    assert!(output.status.success());
    run_sync(&a).unwrap();
    assert_eq!(
        fs::read(a.profile.join("SOUL.md")).unwrap(),
        b"Rust hub, Python client\n"
    );
    // Rust reopens a Python-written client.json without reset or rebootstrap.
    assert_eq!(run_sync(&b).unwrap().applied, 0);
}

#[test]
fn memory_apply_waits_for_writer_lock_then_rechecks_live_bytes() {
    use std::sync::mpsc;
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    put(&a.profile, "memories/MEMORY.md", b"base");
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(&a.profile, "memories/MEMORY.md", b"remote");
    run_sync(&a).unwrap();
    let (locked_tx, locked_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let target = b.profile.join("memories/MEMORY.md");
    let writer_target = target.clone();
    let writer = std::thread::spawn(move || {
        let _guard = FileLock::acquire(&writer_target.with_extension("md.lock"), false).unwrap();
        locked_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        std::thread::sleep(Duration::from_millis(30));
        fs::write(writer_target, b"writer retained").unwrap();
    });
    locked_rx.recv().unwrap();
    let result = run_sync_with_transport(&b, |req| {
        let response = exchange(b.hub_store.as_ref().unwrap(), req)?;
        release_tx.send(()).unwrap();
        Ok(response)
    })
    .unwrap();
    writer.join().unwrap();
    assert_eq!(result.conflicts, vec!["memories/MEMORY.md"]);
    assert_eq!(fs::read(target).unwrap(), b"writer retained");
}
#[test]
fn transport_rejects_oversized_stderr_promptly() {
    let req = request("a", None, &Contents::new(), &Contents::new());
    let start = Instant::now();
    let result = exchange_command(
        &[
            "python3".into(),
            "-c".into(),
            "import os,time;os.write(2,b'x'*(2*1024*1024));time.sleep(20)".into(),
        ],
        &req,
        Duration::from_secs(10),
    );
    assert!(result.unwrap_err().to_string().contains("size limit"));
    assert!(start.elapsed() < Duration::from_secs(2));
}
#[test]
fn malformed_response_cannot_delete_a_file_missing_from_hub_manifest() {
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    put(&config.profile, "SOUL.md", b"retain");
    run_sync(&config).unwrap();
    let result = run_sync_with_transport(&config, |req| {
        let mut response = exchange(config.hub_store.as_ref().unwrap(), req)?;
        response.changes.insert("SOUL.md".into(), None);
        Ok(response)
    });
    assert!(result.is_err());
    assert_eq!(fs::read(config.profile.join("SOUL.md")).unwrap(), b"retain");
}
#[cfg(unix)]
#[test]
fn hardlinked_skill_replacement_does_not_modify_external_inode() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let b = cfg(root.path(), "b");
    let library = root.path().join("library.txt");
    fs::write(&library, b"old").unwrap();
    fs::create_dir(a.profile.join("skills")).unwrap();
    fs::hard_link(&library, a.profile.join("skills/file")).unwrap();
    run_sync(&a).unwrap();
    run_sync(&b).unwrap();
    put(&b.profile, "skills/file", b"new");
    run_sync(&b).unwrap();
    run_sync(&a).unwrap();
    assert_eq!(fs::read(&library).unwrap(), b"old");
    assert_eq!(fs::read(a.profile.join("skills/file")).unwrap(), b"new");
}

#[cfg(target_os = "linux")]
#[test]
fn concurrent_symlink_swaps_cannot_read_write_delete_or_lock_external_files() {
    use std::{
        os::unix::fs::symlink,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
    };
    let root = TempDir::new().unwrap();
    let profile = root.path().join("profile");
    let selected = profile.join("skills/demo");
    fs::create_dir_all(&selected).unwrap();
    fs::write(selected.join("SKILL.md"), b"local").unwrap();
    let external = root.path().join("secret");
    fs::create_dir(&external).unwrap();
    fs::write(external.join("SKILL.md"), b"secret sentinel").unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    let victim = selected.clone();
    let private = external.clone();
    let swapped = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let swap_count = swapped.clone();
    let worker = std::thread::spawn(move || {
        use std::os::unix::ffi::OsStrExt;
        let swap = victim.with_file_name(".swap");
        symlink(&private, &swap).unwrap();
        let victim_c = std::ffi::CString::new(victim.as_os_str().as_bytes()).unwrap();
        let swap_c = std::ffi::CString::new(swap.as_os_str().as_bytes()).unwrap();
        while !stopped.load(Ordering::Relaxed) {
            assert_eq!(
                unsafe {
                    libc::renameat2(
                        libc::AT_FDCWD,
                        victim_c.as_ptr(),
                        libc::AT_FDCWD,
                        swap_c.as_ptr(),
                        libc::RENAME_EXCHANGE,
                    )
                },
                0
            );
            swap_count.fetch_add(1, Ordering::Relaxed);
            std::thread::yield_now();
            assert_eq!(
                unsafe {
                    libc::renameat2(
                        libc::AT_FDCWD,
                        victim_c.as_ptr(),
                        libc::AT_FDCWD,
                        swap_c.as_ptr(),
                        libc::RENAME_EXCHANGE,
                    )
                },
                0
            );
        }
        fs::remove_file(swap).unwrap();
    });
    for _ in 0..300 {
        if let Ok(files) = scan(&profile) {
            assert!(files.values().all(|bytes| bytes != b"secret sentinel"));
        }
        if let Ok(Some(bytes)) = read_plain(&selected.join("SKILL.md"), 1024) {
            assert_ne!(bytes, b"secret sentinel");
        }
        let _ = atomic_write(&selected.join("SKILL.md"), b"local", false);
        let _ = remove_plain(&selected.join("unused"));
        let _ = FileLock::acquire(&selected.join("test.lock"), false);
    }
    stop.store(true, Ordering::Relaxed);
    worker.join().unwrap();
    assert!(swapped.load(Ordering::Relaxed) > 0);
    assert_eq!(
        fs::read(external.join("SKILL.md")).unwrap(),
        b"secret sentinel"
    );
    assert_eq!(walk(&external), vec![external.join("SKILL.md")]);
}
#[cfg(unix)]
#[test]
fn concurrent_identity_link_swaps_never_escape_scan_scope() {
    use std::{
        os::unix::fs::symlink,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
    };
    let root = TempDir::new().unwrap();
    let profile = root.path().join("profile");
    fs::create_dir(&profile).unwrap();
    let selected = profile.join("SOUL.md");
    fs::write(&selected, b"local").unwrap();
    let external = root.path().join("secret");
    fs::write(&external, b"secret sentinel").unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    let victim = selected.clone();
    let worker = std::thread::spawn(move || {
        let holding = victim.with_file_name(".holding");
        while !stopped.load(Ordering::Relaxed) {
            fs::rename(&victim, &holding).unwrap();
            symlink(&external, &victim).unwrap();
            std::thread::yield_now();
            fs::remove_file(&victim).unwrap();
            fs::rename(&holding, &victim).unwrap();
        }
    });
    for _ in 0..500 {
        if let Ok(files) = scan(&profile) {
            assert!(files.values().all(|bytes| bytes != b"secret sentinel"));
        }
    }
    stop.store(true, Ordering::Relaxed);
    worker.join().unwrap();
}
#[test]
fn bridge_quarantine_marker_and_memory_safety_gate_prevent_upload() {
    let root = TempDir::new().unwrap();
    let config = cfg(root.path(), "a");
    put(
        &config.profile,
        ".native-bridge-status.json",
        br#"{"version":1,"ready":false}"#,
    );
    let mut called = false;
    assert!(
        run_sync_with_transport(&config, |_| {
            called = true;
            anyhow::bail!("must not call")
        })
        .is_err()
    );
    assert!(!called);
    fs::remove_file(config.profile.join(".native-bridge-status.json")).unwrap();
    put(
        &config.profile,
        "memories/MEMORY.md",
        b"api_key=\"sk-proj-THIS_IS_SYNTHETIC_SECRET_1234567890\"",
    );
    let result = run_sync_with_transport(&config, |_| {
        called = true;
        anyhow::bail!("must not call")
    });
    assert!(result.is_err());
    assert!(!called);
}

#[test]
fn state_lineage_cannot_be_reused_for_an_unrelated_profile() {
    let root = TempDir::new().unwrap();
    let a = cfg(root.path(), "a");
    let mut b = cfg(root.path(), "b");
    put(&a.profile, "SOUL.md", b"retained hub identity");
    run_sync(&a).unwrap();
    b.state_dir = a.state_dir.clone();
    b.node = a.node.clone();
    assert!(
        run_sync(&b)
            .unwrap_err()
            .to_string()
            .contains("different profile")
    );
    assert_eq!(
        read_json(&root.path().join("hub/hub.json"))["files"]["SOUL.md"],
        digest(b"retained hub identity")
    );
}

#[cfg(unix)]
#[test]
fn interrupted_link_materialization_blocks_upload_until_deliberate_recovery() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let mut config = cfg(root.path(), "a");
    let library = root.path().join("library");
    fs::create_dir(&library).unwrap();
    fs::write(library.join("a.md"), b"a").unwrap();
    fs::write(library.join("z.md"), b"z").unwrap();
    fs::create_dir(config.profile.join("skills")).unwrap();
    symlink(&library, config.profile.join("skills/shared")).unwrap();
    config.allowed_skill_roots.push(library.clone());
    run_sync(&config).unwrap();
    // Deterministic crash fixture: durable marker, old link backed up, only the
    // first selected file copied. z.md is absent but must not become deletion.
    let backup = config
        .state_dir
        .join("backups/interrupted/links/skills/shared");
    fs::create_dir_all(backup.parent().unwrap()).unwrap();
    fs::write(
        config.state_dir.join("materialization-incomplete.json"),
        json!({"path":"skills/shared/a.md", "backup":backup}).to_string(),
    )
    .unwrap();
    fs::rename(config.profile.join("skills/shared"), &backup).unwrap();
    put(&config.profile, "skills/shared/a.md", b"a");
    let mut called = false;
    let result = run_sync_with_transport(&config, |_| {
        called = true;
        anyhow::bail!("must not upload")
    });
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("Interrupted skill materialization")
    );
    assert!(!called);
    assert!(
        read_json(&root.path().join("hub/hub.json"))["files"]
            .get("skills/shared/z.md")
            .is_some()
    );
    // Reviewed manual recovery of the preserved original link makes retry safe.
    fs::remove_dir_all(config.profile.join("skills/shared")).unwrap();
    fs::rename(&backup, config.profile.join("skills/shared")).unwrap();
    fs::remove_file(config.state_dir.join("materialization-incomplete.json")).unwrap();
    assert_eq!(run_sync(&config).unwrap().exit_code(), 0);
    assert_eq!(fs::read(library.join("z.md")).unwrap(), b"z");
}

#[test]
fn private_state_and_hub_overlap_are_rejected_before_any_metadata_or_upload() {
    for private_kind in ["state", "hub"] {
        let root = TempDir::new().unwrap();
        let mut config = cfg(root.path(), "a");
        let forbidden = config.profile.join("skills/private/nested/store");
        if private_kind == "state" {
            config.state_dir = forbidden.clone();
        } else {
            config.hub_store = Some(forbidden.clone());
        }
        let mut called = false;
        assert!(
            run_sync_with_transport(&config, |_| {
                called = true;
                anyhow::bail!("must not upload")
            })
            .is_err()
        );
        assert!(!called);
        assert!(run_sync(&config).is_err());
        assert!(!forbidden.exists());
        assert!(!config.state_dir.exists());
        assert!(walk(&config.profile).is_empty());
    }
    let root = TempDir::new().unwrap();
    let mut config = cfg(root.path(), "a");
    config.state_dir = config.profile.join("missing/../skills/state");
    assert!(run_sync(&config).is_err());
    assert!(walk(&config.profile).is_empty());
}
#[test]
fn skill_root_grants_cannot_alias_private_stores_or_excluded_profile_files() {
    for case in [
        "contains-state",
        "inside-hub",
        "profile-root",
        "profile-config",
    ] {
        let root = TempDir::new().unwrap();
        let mut config = cfg(root.path(), "a");
        let library = root.path().join("library");
        fs::create_dir(&library).unwrap();
        match case {
            "contains-state" => {
                config.state_dir = library.join("private/state");
                config.allowed_skill_roots.push(library.clone());
            }
            "inside-hub" => {
                config.hub_store = Some(library.clone());
                config.allowed_skill_roots.push(library.join("objects"));
            }
            "profile-root" => config.allowed_skill_roots.push(config.profile.clone()),
            _ => {
                let excluded = config.profile.join("local-config");
                fs::create_dir(&excluded).unwrap();
                config.allowed_skill_roots.push(excluded);
            }
        }
        assert!(run_sync(&config).is_err(), "accepted {case}");
        assert!(!config.state_dir.exists());
        assert!(walk(&library).is_empty());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let root = TempDir::new().unwrap();
        let mut config = cfg(root.path(), "a");
        fs::create_dir(config.profile.join("skills")).unwrap();
        let alias = root.path().join("alias");
        symlink(config.profile.join("skills"), &alias).unwrap();
        config.state_dir = alias.join("new/state");
        assert!(run_sync(&config).is_err());
        assert!(!config.profile.join("skills/new").exists());
    }
}
