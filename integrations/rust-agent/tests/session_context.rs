#![cfg(unix)]
use anyhow::Result;
use context::*;
use hermes_rust_core::Store;
use hermes_rust_core::session_context as context;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

fn open() -> (tempfile::TempDir, PathBuf, Connection, OwnerScope) {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let path = dir.path().join("db.sqlite");
    let mut store = Store::open(&path).unwrap();
    store.load_session("chat").unwrap();
    drop(store);
    let mut db = hermes_rust_core::private_db::open_private(&path).unwrap();
    let owner = OwnerScope::new("trusted-owner-alice").unwrap();
    initialize(&mut db, &owner).unwrap();
    (dir, path, db, owner)
}
fn turns(path: &Path, n: usize, from: usize) {
    let mut store = Store::open(path).unwrap();
    let count = store.history("chat").unwrap().len();
    let mut messages = Vec::new();
    for i in from..from + n {
        messages.extend([json!({"role":"user","content":format!("Turn {i}: chose cedar for the project. {}","detailed evidence ".repeat(100))}),json!({"role":"assistant","content":null,"tool_calls":[call(&format!("t{i}"))]}),json!({"role":"tool","tool_call_id":format!("t{i}"),"content":format!("Observed project artifact {i}; {}","verified output ".repeat(100))}),json!({"role":"assistant","content":format!("Completed turn {i}")})]);
    }
    store.append_turn("chat", count, &messages).unwrap();
}
fn policy() -> CompressionPolicy {
    CompressionPolicy {
        trigger_messages: 8,
        trigger_bytes: usize::MAX,
        retain_turns: 2,
        max_summary_bytes: 2048,
        max_input_bytes: 8 * 1024 * 1024,
        minimum_reduction_percent: 10,
    }
}
fn call(id: &str) -> Value {
    json!({"id":id,"type":"function","function":{"name":"write_file","arguments":"{\"path\":\"synthetic.txt\",\"content\":\"done\"}"}})
}
fn assistant(call: Value) -> Value {
    json!({"role":"assistant","content":null,"tool_calls":[call]})
}
struct FixedModel {
    calls: Arc<AtomicUsize>,
    seen: Arc<Mutex<Vec<Value>>>,
    response: String,
    fail: bool,
}
impl SummaryModel for FixedModel {
    fn summarize(&self, messages: Vec<Value>) -> SummaryFuture<'_> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.seen.lock().unwrap().push(json!(messages));
            if self.fail {
                anyhow::bail!("controlled model failure")
            };
            Ok(self.response.clone())
        })
    }
}
fn model() -> FixedModel {
    FixedModel{calls:Arc::new(AtomicUsize::new(0)),seen:Arc::new(Mutex::new(Vec::new())),response:"The user selected cedar. Prior artifact writes completed successfully; do not repeat them.".into(),fail:false}
}

#[tokio::test]
async fn real_summary_checkpoint_preserves_all_history_prompt_and_pairs() -> Result<()> {
    let (_dir, path, mut db, owner) = open();
    turns(&path, 10, 0);
    let original = Store::open(&path)?.load_session("chat")?;
    let prepared = prepare_compaction(&db, &owner, "chat", &policy())?.unwrap();
    assert_eq!(prepared.retained_from_seq(), 32);
    let model = model();
    let completed = summarize_plan(&model, prepared).await?;
    assert_eq!(commit_compaction(&mut db, &owner, completed)?, 1);
    let view = load_context(&db, &owner, "chat")?;
    assert_eq!(view.total_messages, 40);
    assert_eq!(view.active_from_seq, 32);
    assert!(view.messages.len() < 40);
    assert!(
        view.messages[0]["content"]
            .as_str()
            .unwrap()
            .contains("selected cedar")
    );
    assert_eq!(view.pinned_prompt, original.0);
    assert_eq!(Store::open(&path)?.history("chat")?, original.1);
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert!(
        model.seen.lock().unwrap()[0]
            .to_string()
            .contains("artifact 0")
    );
    for result in view.messages.iter().filter(|m| m["role"] == "tool") {
        assert!(
            view.messages
                .iter()
                .filter_map(|m| m["tool_calls"].as_array())
                .flatten()
                .any(|c| c["id"] == result["tool_call_id"])
        );
    }
    assert!(!search(&db, &owner, "artifact 0", None, None, 10)?.is_empty());
    drop(db);
    let db = hermes_rust_core::private_db::open_private(&path)?;
    assert_eq!(load_context(&db, &owner, "chat")?.active_from_seq, 32);
    Ok(())
}
#[tokio::test]
async fn iterative_summary_uses_previous_summary_and_atomic_revision() -> Result<()> {
    let (_d, path, mut db, o) = open();
    turns(&path, 8, 0);
    let m = model();
    let p = prepare_compaction(&db, &o, "chat", &policy())?.unwrap();
    commit_compaction(&mut db, &o, summarize_plan(&m, p).await?)?;
    turns(&path, 6, 8);
    let p = prepare_compaction(&db, &o, "chat", &policy())?.unwrap();
    assert!(
        p.model_messages()[1]["content"]
            .as_str()
            .unwrap()
            .contains("previous_summary")
    );
    assert!(
        p.model_messages()[1]["content"]
            .as_str()
            .unwrap()
            .contains("selected cedar")
    );
    commit_compaction(&mut db, &o, summarize_plan(&m, p).await?)?;
    assert_eq!(session_info(&db, &o, "chat")?.summary_versions, 2);
    assert_eq!(Store::open(&path)?.history("chat")?.len(), 56);
    Ok(())
}
#[tokio::test]
async fn summary_failure_empty_output_and_cas_leave_original_intact() -> Result<()> {
    let (_d, path, mut db, o) = open();
    turns(&path, 8, 0);
    let before = Store::open(&path)?.history("chat")?;
    let mut failure = model();
    failure.fail = true;
    assert!(
        summarize_plan(
            &failure,
            prepare_compaction(&db, &o, "chat", &policy())?.unwrap()
        )
        .await
        .is_err()
    );
    let mut empty = model();
    empty.response = " ".into();
    assert!(
        summarize_plan(
            &empty,
            prepare_compaction(&db, &o, "chat", &policy())?.unwrap()
        )
        .await
        .is_err()
    );
    assert_eq!(load_context(&db, &o, "chat")?.active_from_seq, 0);
    assert_eq!(Store::open(&path)?.history("chat")?, before);
    let pending = summarize_plan(
        &model(),
        prepare_compaction(&db, &o, "chat", &policy())?.unwrap(),
    )
    .await?;
    turns(&path, 1, 8);
    assert!(commit_compaction(&mut db, &o, pending).is_err());
    assert_eq!(load_context(&db, &o, "chat")?.active_from_seq, 0);
    Ok(())
}
#[tokio::test]
async fn reset_fences_summary_and_new_generation_has_fresh_context() -> Result<()> {
    let (_d, path, mut db, o) = open();
    turns(&path, 8, 0);
    let pending = summarize_plan(
        &model(),
        prepare_compaction(&db, &o, "chat", &policy())?.unwrap(),
    )
    .await?;
    assert_eq!(reset_route(&mut db, &o, "chat")?, 1);
    Store::open(&path)?.load_session("chat.1")?;
    assert!(commit_compaction(&mut db, &o, pending).is_err());
    let view = load_context(&db, &o, "chat")?;
    assert_eq!(view.session_id, "chat.1");
    assert_eq!(view.total_messages, 0);
    assert!(!session_info(&db, &o, "chat")?.current);
    assert!(session_info(&db, &o, "chat.1")?.current);
    assert_eq!(history(&db, &o, "chat", 0, 100, false)?.len(), 32);
    Ok(())
}
#[test]
fn orphan_tool_pairs_and_wrong_owner_fail_closed() -> Result<()> {
    let (_d, path, mut db, o) = open();
    turns(&path, 8, 0);
    let count = Store::open(&path)?.history("chat")?.len();
    Store::open(&path)?.append_turn(
        "chat",
        count,
        &[
            json!({"role":"user","content":"pending"}),
            assistant(call("pending")),
        ],
    )?;
    assert!(prepare_compaction(&db, &o, "chat", &policy()).is_err());
    let other = OwnerScope::new("another-owner")?;
    assert!(initialize(&mut db, &other).is_err());
    assert!(search(&db, &other, "cedar", None, None, 1).is_err());
    assert!(history(&db, &other, "chat", 0, 1, false).is_err());
    assert!(
        begin_turn(
            &mut db,
            &other,
            "chat",
            "input",
            &json!({"role":"user","content":"x"})
        )
        .is_err()
    );
    Ok(())
}
#[test]
fn search_fts_chinese_updates_source_and_safe_literal_query() -> Result<()> {
    let (_d, path, db, o) = open();
    Store::open(&path)?.append_turn(
        "chat",
        0,
        &[
            json!({"role":"user","content":"项目的重要决定使用 cedar"}),
            json!({"role":"assistant","content":"Agreed on cedar."}),
        ],
    )?;
    let hits = search(&db, &o, "cedar", Some("chat"), Some("user"), 10)?;
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].provenance.kind, "runtime");
    assert_eq!(hits[0].sequence, Some(0));
    assert_eq!(search(&db, &o, "重要决定", None, None, 10)?.len(), 1);
    assert_eq!(search(&db, &o, "项目", None, None, 10)?.len(), 1);
    assert!(search(&db, &o, "cedar\" OR *", None, None, 10)?.is_empty());
    db.execute(
        "UPDATE messages SET body=?1 WHERE session_id='chat' AND seq=0",
        [json!({"role":"user","content":"使用 maple"}).to_string()],
    )?;
    assert!(search(&db, &o, "cedar", None, Some("user"), 10)?.is_empty());
    assert_eq!(search(&db, &o, "maple", None, None, 10)?.len(), 1);
    assert_eq!(
        search_tool(&db, &o, &json!({"session_id":"chat"}))?["mode"],
        "history"
    );
    assert_eq!(
        search_tool(&db, &o, &json!({}))?["sessions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(search_tool_schema()["function"]["name"], "session_search");
    Ok(())
}
#[test]
fn durable_tool_receipt_unknown_cancel_and_late_result_are_not_reexecuted() -> Result<()> {
    let (_d, _path, mut db, o) = open();
    let token = begin_turn(
        &mut db,
        &o,
        "chat",
        "input-1",
        &json!({"role":"user","content":"write once"}),
    )?;
    let c = call("effect");
    checkpoint_assistant(&mut db, &o, &token, &assistant(c.clone()))?;
    assert!(matches!(
        reserve_tool(&mut db, &o, &token, &c)?,
        ToolReservation::ExecuteOnce
    ));
    assert!(matches!(
        reserve_tool(&mut db, &o, &token, &c)?,
        ToolReservation::Uncertain
    ));
    let recovery = recover_turns(&db, &o, "chat")?;
    assert_eq!(recovery[0].recovery, "effect_uncertain");
    assert!(resume_turn(&mut db, &o, &recovery[0].token).is_err());
    assert_eq!(cancel_route(&mut db, &o, "chat")?, 1);
    assert_eq!(
        record_tool_result(
            &mut db,
            &o,
            &token,
            "effect",
            &json!({"real_result":"file was written"})
        )?,
        ReceiptWrite::RetainedAfterFence
    );
    let recovered = recover_turns(&db, &o, "chat")?;
    assert_eq!(recovered[0].recovery, "cancelled");
    assert_eq!(
        recovered[0].receipts[0]["result"]["real_result"],
        "file was written"
    );
    assert!(
        finalize_turn(
            &mut db,
            &o,
            &token,
            &json!({"role":"assistant","content":"done"})
        )
        .is_err()
    );
    assert_eq!(load_context(&db, &o, "chat")?.total_messages, 0);
    Ok(())
}
#[test]
fn provider_failure_keeps_known_receipts_and_resume_only_calls_model() -> Result<()> {
    let (_d, path, mut db, o) = open();
    let token = begin_turn(
        &mut db,
        &o,
        "chat",
        "input-2",
        &json!({"role":"user","content":"write once"}),
    )?;
    let c = call("write");
    checkpoint_assistant(&mut db, &o, &token, &assistant(c.clone()))?;
    let effects = AtomicUsize::new(0);
    if matches!(
        reserve_tool(&mut db, &o, &token, &c)?,
        ToolReservation::ExecuteOnce
    ) {
        effects.fetch_add(1, Ordering::SeqCst);
    }
    record_tool_result(
        &mut db,
        &o,
        &token,
        "write",
        &json!({"success":true,"artifact":"synthetic.txt"}),
    )?;
    interrupt_turn(&mut db, &o, &token)?;
    drop(db);
    let mut db = hermes_rust_core::private_db::open_private(&path)?;
    let recovery = recover_turns(&db, &o, "chat")?;
    assert_eq!(recovery[0].recovery, "model_resume_available");
    let (resumed, checkpoint) = resume_turn(&mut db, &o, &recovery[0].token)?;
    assert_eq!(checkpoint.len(), 3);
    if matches!(
        reserve_tool(&mut db, &o, &resumed, &c)?,
        ToolReservation::ExecuteOnce
    ) {
        effects.fetch_add(1, Ordering::SeqCst);
    }
    assert_eq!(effects.load(Ordering::SeqCst), 1);
    assert_eq!(
        finalize_turn(
            &mut db,
            &o,
            &resumed,
            &json!({"role":"assistant","content":"done using preserved receipt"})
        )?,
        4
    );
    assert!(recover_turns(&db, &o, "chat")?.is_empty());
    assert_eq!(Store::open(&path)?.history("chat")?.len(), 4);
    assert_eq!(
        db.query_row("SELECT checkpoint_json FROM context_turns", [], |r| r
            .get::<_, String>(0))?,
        "[]"
    );
    assert_eq!(
        db.query_row("SELECT count(*) FROM context_tool_receipts", [], |r| r
            .get::<_, i64>(0))?,
        1
    );
    assert!(
        finalize_turn(
            &mut db,
            &o,
            &resumed,
            &json!({"role":"assistant","content":"duplicate"})
        )
        .is_err()
    );
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_spawn_blocking_receipt_finishes_only_in_archive() -> Result<()> {
    let (_d, path, mut db, o) = open();
    let token = begin_turn(
        &mut db,
        &o,
        "chat",
        "input-race",
        &json!({"role":"user","content":"one effect"}),
    )?;
    let c = call("race");
    checkpoint_assistant(&mut db, &o, &token, &assistant(c.clone()))?;
    reserve_tool(&mut db, &o, &token, &c)?;
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (go_tx, go_rx) = std::sync::mpsc::channel();
    let owner = o.clone();
    let late_token = token.clone();
    let job = tokio::task::spawn_blocking(move || -> Result<ReceiptWrite> {
        let mut db = hermes_rust_core::private_db::open_private(&path)?;
        ready_tx.send(())?;
        go_rx.recv()?;
        record_tool_result(
            &mut db,
            &owner,
            &late_token,
            "race",
            &json!({"completed_after_abort":true}),
        )
    });
    ready_rx.recv()?;
    cancel_route(&mut db, &o, "chat")?;
    go_tx.send(())?;
    assert_eq!(job.await??, ReceiptWrite::RetainedAfterFence);
    assert_eq!(load_context(&db, &o, "chat")?.total_messages, 0);
    assert_eq!(
        recover_turns(&db, &o, "chat")?[0].receipts[0]["result"]["completed_after_abort"],
        true
    );
    Ok(())
}
#[test]
fn finalize_cas_and_input_identity_prevent_silent_overwrite() -> Result<()> {
    let (_d, path, mut db, o) = open();
    let token = begin_turn(
        &mut db,
        &o,
        "chat",
        "stable-input",
        &json!({"role":"user","content":"original"}),
    )?;
    assert!(
        begin_turn(
            &mut db,
            &o,
            "chat",
            "stable-input",
            &json!({"role":"user","content":"changed"})
        )
        .is_err()
    );
    Store::open(&path)?.append_turn(
        "chat",
        0,
        &[
            json!({"role":"user","content":"concurrent"}),
            json!({"role":"assistant","content":"winner"}),
        ],
    )?;
    assert!(
        finalize_turn(
            &mut db,
            &o,
            &token,
            &json!({"role":"assistant","content":"stale"})
        )
        .is_err()
    );
    assert_eq!(Store::open(&path)?.history("chat")?.len(), 2);
    assert_eq!(
        recover_turns(&db, &o, "chat")?[0].checkpoint[0]["content"],
        "original"
    );
    Ok(())
}

struct HttpModel {
    endpoint: String,
}
impl SummaryModel for HttpModel {
    fn summarize(&self, messages: Vec<Value>) -> SummaryFuture<'_> {
        Box::pin(async move {
            let response: Value = reqwest::Client::new()
                .post(&self.endpoint)
                .json(&json!({"model":"controlled-summary","messages":messages}))
                .send()
                .await?
                .error_for_status()?
                .json()
                .await?;
            Ok(response["choices"][0]["message"]["content"]
                .as_str()
                .unwrap()
                .into())
        })
    }
}
#[tokio::test]
async fn actual_http_model_receives_old_turns_and_returns_persisted_summary() -> Result<()> {
    let (_d, path, mut db, o) = open();
    turns(&path, 8, 0);
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let seen = Arc::new(Mutex::new(Value::Null));
    let captured = seen.clone();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut chunk = [0_u8; 8192];
        let (header_end, length) = loop {
            let n = stream.read(&mut chunk).unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&chunk[..n]);
            if let Some(pos) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&bytes[..pos]);
                let length = header
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap();
                break (pos + 4, length);
            }
        };
        while bytes.len() < header_end + length {
            let n = stream.read(&mut chunk).unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&chunk[..n]);
        }
        let request: Value =
            serde_json::from_slice(&bytes[header_end..header_end + length]).unwrap();
        assert!(request.get("tools").is_none());
        assert!(request.to_string().contains("chose cedar"));
        *captured.lock().unwrap() = request;
        let body=json!({"choices":[{"message":{"role":"assistant","content":"Observed prior turns: the user chose cedar and the artifact writes completed. Preserve those decisions; no pending actions."}}]}).to_string();
        write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
    });
    let m = HttpModel {
        endpoint: format!("http://{address}/summary"),
    };
    let prepared =
        summarize_plan(&m, prepare_compaction(&db, &o, "chat", &policy())?.unwrap()).await?;
    commit_compaction(&mut db, &o, prepared)?;
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap()["model"], "controlled-summary");
    assert!(
        load_context(&db, &o, "chat")?.messages[0]["content"]
            .as_str()
            .unwrap()
            .contains("Observed prior turns")
    );
    Ok(())
}

#[test]
fn completed_lookup_bridges_crash_before_outbound_journal_finish() -> Result<()> {
    let (_d, path, mut db, o) = open();
    let t = begin_turn(
        &mut db,
        &o,
        "chat",
        "outbound-gap",
        &json!({"role":"user","content":"question"}),
    )?;
    let answer = json!({"role":"assistant","content":"durably completed answer"});
    finalize_turn(&mut db, &o, &t, &answer)?;
    drop(db);
    let mut db = hermes_rust_core::private_db::open_private(&path)?;
    match lookup_turn(&db, &o, "chat", "outbound-gap")? {
        TurnLookup::Completed {
            token,
            final_assistant,
            ..
        } => {
            assert_eq!(token.turn_id, t.turn_id);
            assert_eq!(final_assistant, answer);
        }
        _ => panic!("completed result unavailable"),
    };
    assert!(matches!(
        cancel_input(&mut db, &o, "chat", "outbound-gap")?,
        TurnLookup::Completed { .. }
    ));
    assert!(matches!(
        cancel_input(&mut db, &o, "chat", "absent")?,
        TurnLookup::CancelledBeforeStart
    ));
    reset_route(&mut db, &o, "chat")?;
    Store::open(&path)?.load_session("chat.1")?;
    assert!(
        begin_turn(
            &mut db,
            &o,
            "chat",
            "outbound-gap",
            &json!({"role":"user","content":"question"})
        )
        .is_err()
    );
    assert!(matches!(
        lookup_turn(&db, &o, "chat", "outbound-gap")?,
        TurnLookup::Completed { .. }
    ));
    Ok(())
}
#[test]
fn targeted_cancel_reports_uncertain_effects_and_preserves_other_routes() -> Result<()> {
    let (_d, path, mut db, o) = open();
    Store::open(&path)?.load_session("other")?;
    let t = begin_turn(
        &mut db,
        &o,
        "chat",
        "a",
        &json!({"role":"user","content":"run"}),
    )?;
    let other = begin_turn(
        &mut db,
        &o,
        "other",
        "b",
        &json!({"role":"user","content":"other"}),
    )?;
    let c = call("pending");
    checkpoint_assistant(&mut db, &o, &t, &assistant(c.clone()))?;
    reserve_tool(&mut db, &o, &t, &c)?;
    assert!(matches!(
        cancel_input(&mut db, &o, "chat", "a")?,
        TurnLookup::Cancelled {
            uncertain_effects: true,
            ..
        }
    ));
    assert!(matches!(
        lookup_turn(&db, &o, "other", "b")?,
        TurnLookup::Pending { .. }
    ));
    finalize_turn(
        &mut db,
        &o,
        &other,
        &json!({"role":"assistant","content":"other completed"}),
    )?;
    Ok(())
}
#[test]
fn migration_archived_inactive_rows_are_searchable_with_original_provenance() -> Result<()> {
    let source = tempfile::tempdir()?;
    fs::set_permissions(source.path(), fs::Permissions::from_mode(0o700))?;
    let original = source.path().join("state.db");
    let db = Connection::open(&original)?;
    fs::set_permissions(&original, fs::Permissions::from_mode(0o600))?;
    db.execute_batch(include_str!("fixtures/hermes_original_schema.sql"))?;
    db.execute("INSERT INTO sessions(id,source,started_at,system_prompt) VALUES('original-session','orialis',0,'pinned')",[])?;
    db.execute("INSERT INTO messages(session_id,role,content,timestamp,active,compacted) VALUES('original-session','user','archived rare decision: birch',0,0,1)",[])?;
    db.execute("INSERT INTO messages(session_id,role,content,timestamp,active) VALUES('original-session','user','active retained cedar',1,1)",[])?;
    drop(db);
    let (_d, _p, mut target, o) = open();
    let plan = hermes_rust_core::migration::inspect_source(
        hermes_rust_core::migration::SourceOptions::new(source.path()),
    )?;
    let reviewed = plan.preview(&target)?;
    plan.apply(&mut target, &reviewed)?;
    initialize(&mut target, &o)?;
    let hits = search(&target, &o, "birch", None, None, 10)?;
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].provenance.kind, "hermes_archive");
    assert_eq!(
        hits[0].provenance.original_session_id.as_deref(),
        Some("original-session")
    );
    assert_eq!(hits[0].provenance.original_message_id, Some(1));
    let all = history(&target, &o, &hits[0].session_id, 0, 10, true)?;
    assert_eq!(all.len(), 2);
    assert_eq!(all[0].body["active"], 0);
    assert_eq!(search(&target, &o, "cedar", None, None, 10)?.len(), 1);
    Ok(())
}
