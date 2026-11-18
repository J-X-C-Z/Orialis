//! Isolated fixture-only workspace/PTY integration tests.
#[path = "../src/workspace.rs"]
#[allow(dead_code)]
mod workspace;
use base64::Engine;
use serde_json::{Value, json};
use std::{path::Path, process::Command, time::Duration};
use workspace::*;

fn service(path: &Path, terminal: bool) -> WorkspaceService {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let script = path.join("fixture-shell");
        std::fs::write(&script,format!("#!/bin/sh\nexec env -i PATH=/usr/bin:/bin HOME='{}' TERM=xterm-256color COLORTERM=truecolor ENV=/dev/null /bin/sh -i\n",path.display())).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        WorkspaceService::new_with_shell(
            vec![WorkspaceConfig {
                path: path.into(),
                name: Some("Fixture".into()),
                terminal,
            }],
            script,
        )
        .unwrap()
    }
    #[cfg(not(unix))]
    {
        WorkspaceService::new(vec![]).unwrap()
    }
}
async fn call(s: &WorkspaceService, op: &str, path: &str) -> Value {
    s.handle(
        "conversation",
        "socket-a",
        &json!({"op":op,"workspaceId":"w0","path":path}),
    )
    .await
}
fn git(path: &Path, args: &[&str]) {
    assert!(
        Command::new("git")
            .args(args)
            .current_dir(path)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    );
}

#[tokio::test]
async fn defaults_and_capabilities_expose_no_paths() {
    let empty = WorkspaceService::from_json("").unwrap();
    let caps = call(&empty, "capabilities", "").await;
    assert_eq!(caps["data"]["workspaces"], json!([]));
    assert_eq!(
        call(&empty, "read", "x").await["error"]["code"],
        "workspace_not_found"
    );
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), false);
    let caps = call(&s, "capabilities", "").await;
    assert_eq!(caps["data"]["maxFileBytes"], FILE_LIMIT);
    assert_eq!(caps["data"]["workspaces"][0]["terminalEnabled"], false);
    assert!(!caps.to_string().contains(dir.path().to_str().unwrap()));
    assert_eq!(
        s.handle("conversation", "", &json!({"op":"capabilities"}))
            .await["error"]["code"],
        "invalid_request"
    );
    assert_eq!(
        call(&s, "terminal.open", "").await["error"]["code"],
        "terminal_unavailable"
    );
}

#[tokio::test]
async fn real_list_read_download_and_exclusive_upload() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), false);
    std::fs::create_dir(dir.path().join("folder")).unwrap();
    let bytes = "真实 UTF-8 fixture\n".as_bytes();
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
    let request =
        json!({"op":"upload","workspaceId":"w0","path":"folder/笔记.txt","base64":encoded});
    let uploaded = s.handle("conversation", "socket-a", &request).await;
    assert_eq!(uploaded["data"]["size"], bytes.len());
    assert_eq!(
        std::fs::read(dir.path().join("folder/笔记.txt")).unwrap(),
        bytes
    );
    assert_eq!(
        call(&s, "read", "folder/笔记.txt").await["data"],
        json!({"path":"folder/笔记.txt","text":String::from_utf8_lossy(bytes),"truncated":false})
    );
    assert_eq!(
        call(&s, "download", "folder/笔记.txt").await["data"],
        json!({"path":"folder/笔记.txt","name":"笔记.txt","size":bytes.len(),"base64":encoded})
    );
    assert_eq!(
        s.handle("conversation", "socket-a", &request).await["ok"],
        false
    );
    assert_eq!(
        std::fs::read(dir.path().join("folder/笔记.txt")).unwrap(),
        bytes
    );
    let list = call(&s, "list", "").await;
    assert_eq!(
        call(&s, "list", "").await,
        list,
        "root listings must not share directory offsets"
    );
    assert_eq!(list["data"]["entries"][0]["name"], "folder");
    let reply = WorkspaceService::response_frame("request-1", "conversation", uploaded);
    assert_eq!(reply["request_id"], "request-1");
    assert_eq!(reply["type"], "workspace.response");
}

#[tokio::test]
async fn traversal_binary_size_and_invalid_payloads_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), false);
    for path in [
        "/etc/passwd",
        "../secret",
        "folder/../../secret",
        "C:/secret",
        "x:y",
        "\\\\host\\file",
        "x\0y",
    ] {
        assert_eq!(
            call(&s, "read", path).await["error"]["code"],
            "invalid_path",
            "{path}"
        );
    }
    std::fs::write(dir.path().join("binary"), [0, 255, 0]).unwrap();
    assert_eq!(
        call(&s, "read", "binary").await["error"]["code"],
        "binary_file"
    );
    let file = std::fs::File::create(dir.path().join("large")).unwrap();
    file.set_len((FILE_LIMIT + 1) as u64).unwrap();
    assert_eq!(
        call(&s, "download", "large").await["error"]["code"],
        "file_too_large"
    );
    assert_eq!(
        call(&s, "read", "large").await["error"]["code"],
        "file_too_large"
    );
    assert_eq!(
        call(&s, "read", "").await["error"]["code"],
        "unsupported_file"
    );
    assert_eq!(
        s.handle(
            "conversation",
            "socket-a",
            &json!({"op":"upload","workspaceId":"w0","path":"new","base64":"invalid!!"})
        )
        .await["ok"],
        false
    );
    assert!(!dir.path().join("new").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_and_nonregular_files_never_escape() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret"), b"not shared").unwrap();
    let s = service(dir.path(), false);
    symlink(outside.path(), dir.path().join("escape")).unwrap();
    symlink(outside.path().join("secret"), dir.path().join("link")).unwrap();
    for path in ["escape/secret", "link"] {
        assert_eq!(
            call(&s, "read", path).await["error"]["code"],
            "invalid_path"
        );
    }
    let upload = s
        .handle(
            "conversation",
            "socket-a",
            &json!({"op":"upload","workspaceId":"w0","path":"escape/new","base64":"YQ=="}),
        )
        .await;
    assert_eq!(upload["ok"], false);
    assert!(!outside.path().join("new").exists());
    let fifo = std::ffi::CString::new(dir.path().join("fifo").to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    assert_eq!(
        call(&s, "read", "fifo").await["error"]["code"],
        "unsupported_file"
    );
    let entries = call(&s, "list", "").await;
    assert!(!entries.to_string().contains("escape"));
    assert!(!entries.to_string().contains("fifo"));
}

#[tokio::test]
async fn real_git_diff_is_bounded_and_disables_external_helpers() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), false);
    git(dir.path(), &["init", "-q"]);
    git(
        dir.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(dir.path(), &["config", "user.name", "Fixture"]);
    std::fs::write(dir.path().join("tracked.txt"), "before\n").unwrap();
    git(dir.path(), &["add", "tracked.txt"]);
    git(dir.path(), &["commit", "-qm", "fixture"]);
    std::fs::write(dir.path().join("tracked.txt"), "after\n").unwrap();
    git(dir.path(), &["config", "diff.external", "false"]);
    git(dir.path(), &["config", "core.fsmonitor", "false"]);
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    assert!(diff["data"]["text"].as_str().unwrap().contains("+after"));
    assert_eq!(diff["data"]["truncated"], false);
    std::fs::write(dir.path().join("tracked.txt"), "more\n".repeat(TEXT_LIMIT)).unwrap();
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["data"]["truncated"], true);
    assert!(diff["data"]["text"].as_str().unwrap().len() <= TEXT_LIMIT + 3);
    assert_eq!(
        call(&s, "diff", "child").await["error"]["code"],
        "invalid_path"
    );
}

#[cfg(unix)]
async fn open(s: &WorkspaceService, client: &str) -> String {
    let response = s
        .handle(
            "conversation",
            client,
            &json!({"op":"terminal.open","workspaceId":"w0","path":"","columns":100,"rows":30}),
        )
        .await;
    assert_eq!(response["ok"], true, "{response}");
    response["data"]["terminalId"].as_str().unwrap().to_owned()
}
#[cfg(unix)]
async fn write(s: &WorkspaceService, client: &str, id: &str, input: &str) -> Value {
    s.handle(
        "conversation",
        client,
        &json!({"op":"terminal.write","terminalId":id,"input":input}),
    )
    .await
}
#[cfg(unix)]
async fn read_until(s: &WorkspaceService, client: &str, id: &str, needle: &str) -> String {
    let mut output = String::new();
    for _ in 0..100 {
        let response = s
            .handle(
                "conversation",
                client,
                &json!({"op":"terminal.read","terminalId":id}),
            )
            .await;
        assert_eq!(response["ok"], true, "{response}");
        output.push_str(response["data"]["output"].as_str().unwrap());
        if output.contains(needle) {
            return output;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("terminal output did not contain {needle:?}: {output:?}")
}

#[cfg(unix)]
#[tokio::test]
async fn pty_input_output_resize_exit_and_socket_binding() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), true);
    let id = open(&s, "socket-a").await;
    assert_eq!(
        write(
            &s,
            "socket-a",
            &id,
            "printf 'HELLO-%s\\n' '世界'; stty size\n"
        )
        .await["ok"],
        true
    );
    let output = read_until(&s, "socket-a", &id, "30 100").await;
    assert!(output.contains("HELLO-世界"));
    assert_eq!(
        s.handle(
            "other-conversation",
            "socket-a",
            &json!({"op":"terminal.read","terminalId":id})
        )
        .await["error"]["code"],
        "terminal_not_found"
    );
    assert_eq!(s.handle("conversation","socket-b",&json!({"op":"terminal.write","terminalId":id,"input":"echo bad\n","_clientId":"socket-a"})).await["error"]["code"],"terminal_not_found");
    assert_eq!(
        s.handle(
            "conversation",
            "socket-a",
            &json!({"op":"terminal.resize","terminalId":id,"columns":120,"rows":40})
        )
        .await["ok"],
        true
    );
    write(&s, "socket-a", &id, "stty size\n").await;
    read_until(&s, "socket-a", &id, "40 120").await;
    assert_eq!(
        s.handle(
            "conversation",
            "socket-a",
            &json!({"op":"terminal.resize","terminalId":id,"columns":true,"rows":24})
        )
        .await["error"]["code"],
        "invalid_dimensions"
    );
    assert_eq!(
        write(&s, "socket-a", &id, &"x".repeat(8193)).await["error"]["code"],
        "invalid_input"
    );
    write(&s, "socket-a", &id, "exit 7\n").await;
    let mut exited = false;
    for _ in 0..100 {
        let r = s
            .handle(
                "conversation",
                "socket-a",
                &json!({"op":"terminal.read","terminalId":id}),
            )
            .await;
        if r["data"]["exited"] == true {
            assert_eq!(r["data"]["exitCode"], 7);
            exited = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(exited);
    s.close().await;
}

#[tokio::test]
async fn listing_limit_and_pinned_root_survive_path_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let s = service(&root, false);
    std::fs::write(root.join("original"), b"pinned").unwrap();
    let moved = dir.path().join("moved");
    std::fs::rename(&root, &moved).unwrap();
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("original"), b"replacement").unwrap();
    assert_eq!(call(&s, "read", "original").await["data"]["text"], "pinned");
    for i in 0..MAX_ENTRIES {
        std::fs::write(moved.join(format!("entry-{i}")), b"").unwrap();
    }
    assert_eq!(
        call(&s, "list", "").await["error"]["code"],
        "too_many_entries"
    );
}

#[cfg(target_os = "linux")]
fn alive(pid: i32) -> bool {
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|s| s.rsplit_once(") ").map(|(_, v)| v.starts_with('Z')))
        .is_some_and(|zombie| !zombie)
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn socket_disconnect_kills_shell_and_background_job_groups() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), true);
    let a = open(&s, "socket-a").await;
    let b = open(&s, "socket-b").await;
    let command = "sleep 60 & printf '%s\\n' $! > child.pid; printf '%s\\n' $$ > shell.pid\n";
    assert_eq!(write(&s, "socket-a", &a, command).await["ok"], true);
    let mut pids = None;
    for _ in 0..100 {
        if let (Ok(c), Ok(p)) = (
            std::fs::read_to_string(dir.path().join("child.pid")),
            std::fs::read_to_string(dir.path().join("shell.pid")),
        ) && let (Ok(c), Ok(p)) = (c.trim().parse::<i32>(), p.trim().parse::<i32>())
        {
            pids = Some((c, p));
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (child, shell) = pids.expect("fixture pids");
    assert!(alive(child));
    assert!(alive(shell));
    assert_eq!(
        s.handle(
            "conversation",
            "socket-b",
            &json!({"op":"terminal.close_client","_clientId":"socket-a"})
        )
        .await["error"]["code"],
        "unsupported_operation"
    );
    assert!(alive(shell));
    s.close_client("socket-a").await;
    for _ in 0..50 {
        if !alive(child) && !alive(shell) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(!alive(child), "background PTY job survived close_client");
    assert!(!alive(shell));
    assert_eq!(
        write(&s, "socket-b", &b, "printf 'STILL_ALIVE\\n'\n").await["ok"],
        true
    );
    read_until(&s, "socket-b", &b, "STILL_ALIVE").await;
    assert_eq!(
        s.handle(
            "conversation",
            "socket-a",
            &json!({"op":"terminal.read","terminalId":a})
        )
        .await["error"]["code"],
        "terminal_not_found"
    );
    s.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn terminal_limit_and_output_buffer_are_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let s = service(dir.path(), true);
    let mut ids = Vec::new();
    for _ in 0..MAX_TERMINALS {
        ids.push(open(&s, "socket-a").await);
    }
    assert_eq!(
        s.handle(
            "conversation",
            "socket-a",
            &json!({"op":"terminal.open","workspaceId":"w0"})
        )
        .await["error"]["code"],
        "terminal_limit"
    );
    let id = &ids[0];
    write(
        &s,
        "socket-a",
        id,
        "head -c 400000 /dev/zero | tr '\\000' A; printf '\\nBUFFER_DONE\\n'\n",
    )
    .await;
    // Wait for the output producer without draining the terminal buffer.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let response = s
        .handle(
            "conversation",
            "socket-a",
            &json!({"op":"terminal.read","terminalId":id}),
        )
        .await;
    assert_eq!(response["data"]["truncated"], true);
    let output = response["data"]["output"].as_str().unwrap();
    assert!(output.len() <= OUTPUT_LIMIT);
    assert!(output.contains("BUFFER_DONE"));
    s.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_diff_rejects_symlink_metadata_and_ignores_escaped_worktree_config() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let s = service(root.path(), false);
    git(root.path(), &["init", "-q"]);
    git(
        root.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(root.path(), &["config", "user.name", "Fixture"]);
    std::fs::write(root.path().join("tracked"), "inside-before\n").unwrap();
    git(root.path(), &["add", "tracked"]);
    git(root.path(), &["commit", "-qm", "fixture"]);
    std::fs::write(root.path().join("tracked"), "inside-after\n").unwrap();
    std::fs::write(outside.path().join("tracked"), "OUTSIDE_PRIVATE_CONTENT\n").unwrap();
    git(
        root.path(),
        &["config", "core.worktree", outside.path().to_str().unwrap()],
    );
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    let text = diff["data"]["text"].as_str().unwrap();
    assert!(text.contains("inside-after"));
    assert!(!text.contains("OUTSIDE_PRIVATE_CONTENT"));
    let moved = outside.path().join("metadata");
    std::fs::rename(root.path().join(".git"), &moved).unwrap();
    symlink(&moved, root.path().join(".git")).unwrap();
    assert_eq!(call(&s, "diff", "").await["error"]["code"], "invalid_path");
}

#[tokio::test]
async fn git_diff_supports_scoped_subdirectory_and_real_linked_worktree() {
    let repo = tempfile::tempdir().unwrap();
    git(repo.path(), &["init", "-q"]);
    git(
        repo.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(repo.path(), &["config", "user.name", "Fixture"]);
    std::fs::create_dir(repo.path().join("sub")).unwrap();
    std::fs::write(repo.path().join("sub/allowed"), "before\n").unwrap();
    std::fs::write(repo.path().join("outside-scope"), "private-before\n").unwrap();
    git(repo.path(), &["add", "."]);
    git(repo.path(), &["commit", "-qm", "fixture"]);
    let scoped = service(&repo.path().join("sub"), false);
    std::fs::write(repo.path().join("sub/allowed"), "after\n").unwrap();
    std::fs::write(
        repo.path().join("outside-scope"),
        "OUTSIDE_PRIVATE_CONTENT\n",
    )
    .unwrap();
    let diff = call(&scoped, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    assert!(diff["data"]["text"].as_str().unwrap().contains("+after"));
    assert!(!diff.to_string().contains("OUTSIDE_PRIVATE_CONTENT"));
    let worktrees = tempfile::tempdir().unwrap();
    let linked = worktrees.path().join("linked");
    git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-qb",
            "fixture-linked",
            linked.to_str().unwrap(),
        ],
    );
    let s = service(&linked, false);
    std::fs::write(linked.join("sub/allowed"), "linked-after\n").unwrap();
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    assert!(
        diff["data"]["text"]
            .as_str()
            .unwrap()
            .contains("+linked-after")
    );
}

#[tokio::test]
async fn upload_cannot_redirect_gitdir_commondir_or_alternate_objects() {
    let outside = tempfile::tempdir().unwrap();
    git(outside.path(), &["init", "-q"]);
    git(
        outside.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(outside.path(), &["config", "user.name", "Fixture"]);
    std::fs::write(
        outside.path().join("private.txt"),
        "OUTSIDE_PRIVATE_CONTENT\n",
    )
    .unwrap();
    git(outside.path(), &["add", "."]);
    git(outside.path(), &["commit", "-qm", "fixture"]);
    let root = tempfile::tempdir().unwrap();
    let s = service(root.path(), false);
    let redirect = format!("gitdir: {}\n", outside.path().join(".git").display());
    let uploaded=s.handle("conversation","socket-a",&json!({"op":"upload","workspaceId":"w0","path":".git","base64":base64::engine::general_purpose::STANDARD.encode(redirect)})).await;
    assert_eq!(uploaded["ok"], true);
    let response = call(&s, "diff", "").await;
    assert_eq!(response["ok"], false);
    assert!(!response.to_string().contains("OUTSIDE_PRIVATE_CONTENT"));
    std::fs::remove_file(root.path().join(".git")).unwrap();
    git(root.path(), &["init", "-q"]);
    let head = std::fs::read_to_string(root.path().join(".git/HEAD")).unwrap();
    let reference = head.trim().strip_prefix("ref: ").unwrap();
    let hash = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(outside.path())
        .output()
        .unwrap()
        .stdout;
    for (path, contents) in [
        (format!(".git/{reference}"), hash),
        (
            ".git/objects/info/alternates".into(),
            format!("{}\n", outside.path().join(".git/objects").display()).into_bytes(),
        ),
    ] {
        let response=s.handle("conversation","socket-a",&json!({"op":"upload","workspaceId":"w0","path":path,"base64":base64::engine::general_purpose::STANDARD.encode(contents)})).await;
        assert_eq!(response["ok"], true, "{response}");
    }
    let response = call(&s, "diff", "").await;
    assert_eq!(response["error"]["code"], "git_unavailable");
    assert!(!response.to_string().contains("OUTSIDE_PRIVATE_CONTENT"));
    std::fs::remove_file(root.path().join(".git/objects/info/alternates")).unwrap();
    let response=s.handle("conversation","socket-a",&json!({"op":"upload","workspaceId":"w0","path":".git/commondir","base64":base64::engine::general_purpose::STANDARD.encode(outside.path().join(".git").to_str().unwrap())})).await;
    assert_eq!(response["ok"], true);
    assert_eq!(call(&s, "diff", "").await["error"]["code"], "invalid_path");
}

#[tokio::test]
async fn private_git_view_never_executes_clean_filter_and_keeps_staged_changes() {
    let root = tempfile::tempdir().unwrap();
    let s = service(root.path(), false);
    git(root.path(), &["init", "-q"]);
    git(
        root.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(root.path(), &["config", "user.name", "Fixture"]);
    std::fs::write(root.path().join("tracked"), "before\n").unwrap();
    git(root.path(), &["add", "tracked"]);
    git(root.path(), &["commit", "-qm", "fixture"]);
    std::fs::write(root.path().join("staged"), "staged-new-file\n").unwrap();
    git(root.path(), &["add", "staged"]);
    std::fs::write(root.path().join("tracked"), "after\n").unwrap();
    std::fs::write(root.path().join(".gitattributes"), "tracked filter=evil\n").unwrap();
    git(
        root.path(),
        &[
            "config",
            "filter.evil.clean",
            "sh -c 'echo EXECUTED > filter-executed; cat'",
        ],
    );
    git(
        root.path(),
        &[
            "config",
            "core.fsmonitor",
            "sh -c 'echo EXECUTED > fsmonitor-executed'",
        ],
    );
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    assert!(diff["data"]["text"].as_str().unwrap().contains("+after"));
    assert!(
        diff["data"]["text"]
            .as_str()
            .unwrap()
            .contains("+staged-new-file")
    );
    assert!(!root.path().join("filter-executed").exists());
    assert!(!root.path().join("fsmonitor-executed").exists());
}

#[tokio::test]
async fn private_git_view_reads_packed_objects_refs_and_split_index() {
    let root = tempfile::tempdir().unwrap();
    let s = service(root.path(), false);
    git(root.path(), &["init", "-q"]);
    git(
        root.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git(root.path(), &["config", "user.name", "Fixture"]);
    std::fs::write(root.path().join("tracked"), "before\n").unwrap();
    git(root.path(), &["add", "tracked"]);
    git(root.path(), &["commit", "-qm", "fixture"]);
    git(root.path(), &["pack-refs", "--all", "--prune"]);
    git(root.path(), &["gc", "--prune=now"]);
    git(root.path(), &["update-index", "--split-index"]);
    std::fs::write(root.path().join("tracked"), "after-packed\n").unwrap();
    let diff = call(&s, "diff", "").await;
    assert_eq!(diff["ok"], true, "{diff}");
    assert!(
        diff["data"]["text"]
            .as_str()
            .unwrap()
            .contains("+after-packed")
    );
}

#[cfg(unix)]
#[test]
fn protected_root_reuses_descriptor_guards_without_process_authority() {
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let root_path = dir.path().join("root");
    std::fs::create_dir(&root_path).unwrap();
    std::fs::create_dir(root_path.join("sub")).unwrap();
    std::fs::write(root_path.join("sub/file.txt"), b"inside").unwrap();
    std::fs::write(outside.path().join("private.txt"), b"outside").unwrap();
    symlink(outside.path(), root_path.join("link")).unwrap();
    let root = workspace::ProtectedRoot::new(&root_path).unwrap();
    assert!(workspace::ProtectedRoot::new(std::path::Path::new("relative")).is_err());
    for path in [
        "/absolute",
        "../private.txt",
        "sub/../file.txt",
        "link/private.txt",
        "nul\0name",
        "file:stream",
    ] {
        assert!(root.open_file(path).is_err());
    }
    assert!(root.open_file("sub").is_err());
    assert!(root.open_parent("missing/new.txt").is_err());
    assert_eq!(root.list("").unwrap().len(), 1);
    assert_eq!(root.list("").unwrap().len(), 1);
    assert!(root.open_dir("sub").unwrap().metadata().unwrap().is_dir());
    std::fs::rename(&root_path, dir.path().join("original")).unwrap();
    std::fs::create_dir(&root_path).unwrap();
    std::fs::create_dir(root_path.join("sub")).unwrap();
    std::fs::write(root_path.join("sub/file.txt"), b"replacement").unwrap();
    let mut text = String::new();
    root.open_file("sub/file.txt")
        .unwrap()
        .read_to_string(&mut text)
        .unwrap();
    assert_eq!(text, "inside");
    let (parent, name) = root.open_parent("sub/new.txt").unwrap();
    assert_eq!(name, "new.txt");
    let cname = std::ffi::CString::new(name).unwrap();
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            cname.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    assert!(fd >= 0);
    let mut file = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(fd) };
    file.write_all(b"created via descriptor").unwrap();
    file.sync_all().unwrap();
    parent.sync_all().unwrap();
    assert_eq!(
        std::fs::read(dir.path().join("original/sub/new.txt")).unwrap(),
        b"created via descriptor"
    );
    assert!(!root_path.join("sub/new.txt").exists());
}
