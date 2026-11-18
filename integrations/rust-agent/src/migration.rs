//! Memory compatibility helpers adapted from Hermes tools/memory_tool_store.py,
//! copyright (c) 2025 Nous Research, MIT; see LICENSE.hermes and NOTICE.
//!
//! Explicit, offline migration from a selected Hermes profile; never discovers user files.
//!
//! `inspect_source` reads only memories/{MEMORY,USER}.md, state.db (+ WAL), and
//! sessions/sessions.json. Source files are opened read-only and never chmodded,
//! checkpointed, locked, or opened by SQLite. SQLite only opens a private copy.
//! A reviewed dry run is mandatory; apply is one transaction and never overwrites
//! destination sessions, routes, memory entries, or earlier migration snapshots.
use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params, types::ValueRef};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

pub const ENTRY_DELIMITER: &str = "\n§\n";
const FORMAT: &str = "hermes-profile-v1";
const MIGRATION_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS migration_manifests (
 source_id TEXT NOT NULL, snapshot_digest TEXT NOT NULL, format TEXT NOT NULL,
 manifest_json TEXT NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(source_id,snapshot_digest));
CREATE TABLE IF NOT EXISTS migration_sessions (
 source_id TEXT NOT NULL, source_session_id TEXT NOT NULL, session_digest TEXT NOT NULL,
 target_session_id TEXT NOT NULL, route_id TEXT, prompt_origin TEXT NOT NULL,
 source_json TEXT NOT NULL, tool_names TEXT, PRIMARY KEY(source_id,source_session_id,session_digest));
CREATE TABLE IF NOT EXISTS migration_messages (
 source_id TEXT NOT NULL, source_session_id TEXT NOT NULL, session_digest TEXT NOT NULL,
 source_message_id INTEGER NOT NULL, source_json TEXT NOT NULL,
 PRIMARY KEY(source_id,source_session_id,session_digest,source_message_id));
CREATE TABLE IF NOT EXISTS migration_memory (
 source_id TEXT NOT NULL, snapshot_digest TEXT NOT NULL, target TEXT NOT NULL,
 ordinal INTEGER NOT NULL, content TEXT NOT NULL, disposition TEXT NOT NULL,
 PRIMARY KEY(source_id,snapshot_digest,target,ordinal));
CREATE TABLE IF NOT EXISTS migration_routes (
 source_id TEXT NOT NULL, snapshot_digest TEXT NOT NULL, ordinal INTEGER NOT NULL,
 source_json TEXT NOT NULL, PRIMARY KEY(source_id,snapshot_digest,ordinal));
";

#[derive(Clone)]
pub struct SourceOptions {
    /// Explicit profile directory, not a parent to search recursively.
    pub profile_dir: PathBuf,
    /// Hard limits prevent accidental or malicious unbounded materialization.
    pub max_file_bytes: u64,
    pub max_rows: usize,
    pub max_decoded_bytes: usize,
    pub memory_char_limit: usize,
    pub user_char_limit: usize,
}
impl SourceOptions {
    pub fn new(profile_dir: impl Into<PathBuf>) -> Self {
        Self {
            profile_dir: profile_dir.into(),
            max_file_bytes: 512 * 1024 * 1024,
            max_rows: 250_000,
            max_decoded_bytes: 256 * 1024 * 1024,
            memory_char_limit: 2200,
            user_char_limit: 1375,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Counts {
    pub source_sessions: usize,
    pub source_messages: usize,
    pub replay_messages: usize,
    pub source_memory_entries: usize,
    pub sessions_to_insert: usize,
    pub sessions_already_imported: usize,
    pub active_routes_to_insert: usize,
    pub active_route_conflicts: usize,
    pub memory_to_insert: usize,
    pub memory_already_present: usize,
    pub memory_quarantined: usize,
    pub unresolved_routes: usize,
    pub missing_pinned_prompts: usize,
}
/// Safe to serialize or print: never includes source content, paths, IDs, prompts, or secrets.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DryRun {
    pub format: String,
    pub source_id: String,
    pub snapshot_digest: String,
    pub review_digest: String,
    pub already_applied: bool,
    pub counts: Counts,
    pub warnings: Vec<String>,
}
#[derive(Clone, Serialize)]
struct MemoryEntry {
    target: String,
    ordinal: usize,
    content: String,
    unsafe_entry: bool,
}
#[derive(Clone, Serialize)]
struct Session {
    id: String,
    digest: String,
    desired_route: Option<String>,
    prompt: Option<String>,
    prompt_origin: String,
    tool_names: Option<String>,
    raw: Value,
    messages: Vec<Value>,
    replay: Vec<Value>,
}
/// Contains private data. Deliberately has no Serialize implementation and redacts Debug.
pub struct ImportPlan {
    options: SourceOptions,
    source_id: String,
    snapshot_digest: String,
    files: Vec<FileFingerprint>,
    sessions: Vec<Session>,
    memories: Vec<MemoryEntry>,
    routes: Vec<Value>,
    counts: Counts,
    warnings: Vec<String>,
}
impl std::fmt::Debug for ImportPlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImportPlan")
            .field("source_id", &self.source_id)
            .field("snapshot_digest", &self.snapshot_digest)
            .field("counts", &self.counts)
            .finish_non_exhaustive()
    }
}
#[derive(Clone)]
struct FileFingerprint {
    relative: &'static str,
    digest: Option<String>,
}
struct DestinationPlan {
    report: DryRun,
    destinations: Vec<(String, bool, bool)>,
    memory: Vec<String>,
}

/// Strict UTF-8 (including UTF-8 BOM), universal newlines, full delimiter only,
/// whitespace stripping, first-occurrence deduplication: Hermes load semantics.
pub fn parse_memory_file(bytes: &[u8]) -> Result<Vec<String>> {
    let text = std::str::from_utf8(bytes).context("memory file is not valid UTF-8")?;
    let text = text
        .strip_prefix('\u{feff}')
        .unwrap_or(text)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let mut seen = BTreeSet::new();
    Ok(text
        .split(ENTRY_DELIMITER)
        .map(|s| s.trim_matches(python_whitespace))
        .filter(|s| !s.is_empty())
        .filter(|s| seen.insert((*s).to_owned()))
        .map(str::to_owned)
        .collect())
}

/// Decode the exact Orialis mapping, without treating arbitrary Hermes chats as Orialis.
pub fn conversation_from_chat(chat_id: &str) -> Result<String> {
    let raw = chat_id
        .strip_prefix("orialis:")
        .context("not an Orialis chat")?;
    let bytes = raw.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'%' {
            ensure!(
                bytes.get(i + 1).is_some_and(u8::is_ascii_hexdigit)
                    && bytes.get(i + 2).is_some_and(u8::is_ascii_hexdigit),
                "invalid Orialis chat encoding"
            );
        }
    }
    let decoded = percent_encoding::percent_decode_str(raw)
        .decode_utf8()
        .context("invalid Orialis chat UTF-8")?
        .into_owned();
    ensure!(!decoded.trim().is_empty(), "empty Orialis conversation");
    Ok(decoded)
}

pub fn inspect_source(options: SourceOptions) -> Result<ImportPlan> {
    ensure!(
        options.max_file_bytes > 0 && options.max_rows > 0 && options.max_decoded_bytes > 0,
        "invalid import limits"
    );
    let root = checked_root(&options.profile_dir)?;
    let mut options = options;
    options.profile_dir = root;
    let source_id = digest(options.profile_dir.as_os_str().as_encoded_bytes());
    let mut files = Vec::new();
    let mut memories = Vec::new();
    for (target, relative) in [
        ("memory", "memories/MEMORY.md"),
        ("user", "memories/USER.md"),
    ] {
        let bytes = read_selected(&options, relative)?;
        files.push(FileFingerprint {
            relative,
            digest: bytes.as_ref().map(|b| digest(b)),
        });
        if let Some(bytes) = bytes {
            for (ordinal, content) in parse_memory_file(&bytes)?.into_iter().enumerate() {
                let unsafe_entry = crate::memory_safety::validate_memory(&content).is_err();
                memories.push(MemoryEntry {
                    target: target.into(),
                    ordinal,
                    content,
                    unsafe_entry,
                });
            }
        }
    }
    let db_bytes = read_selected(&options, "state.db")?;
    let wal_bytes = read_selected(&options, "state.db-wal")?;
    let journal = read_selected(&options, "state.db-journal")?;
    // A rollback journal might contain uncommitted main-file pages. Do not guess.
    ensure!(
        journal.as_ref().is_none_or(|j| j.is_empty()),
        "source has a rollback journal; stop Hermes cleanly and retry"
    );
    ensure!(
        db_bytes.is_some() || wal_bytes.is_none(),
        "source WAL exists without its database"
    );
    for (relative, bytes) in [
        ("state.db", &db_bytes),
        ("state.db-wal", &wal_bytes),
        ("state.db-journal", &journal),
    ] {
        files.push(FileFingerprint {
            relative,
            digest: bytes.as_ref().map(|b| digest(b)),
        });
    }
    let mirror = read_selected(&options, "sessions/sessions.json")?;
    files.push(FileFingerprint {
        relative: "sessions/sessions.json",
        digest: mirror.as_ref().map(|b| digest(b)),
    });
    ensure!(
        files.iter().any(|f| f.digest.is_some()),
        "selected profile contains no supported source files"
    );
    let mut raw_sessions = Vec::new();
    let mut raw_messages = Vec::new();
    let mut routes = Vec::new();
    let mut prompts = BTreeMap::new();
    let mut used_bytes = memories.iter().map(|m| m.content.len()).sum::<usize>();
    ensure!(
        used_bytes <= options.max_decoded_bytes,
        "source decoded size limit exceeded"
    );
    if let Some(db_bytes) = db_bytes {
        let snapshot = PrivateSnapshot::new()?;
        snapshot.write("state.db", &db_bytes)?;
        if let Some(wal) = wal_bytes {
            snapshot.write("state.db-wal", &wal)?;
        }
        let db = Connection::open_with_flags(
            snapshot.0.join("state.db"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;")?;
        let check: String = db.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
        ensure!(check == "ok", "source database consistency check failed");
        ensure!(
            table_exists(&db, "sessions")? && table_exists(&db, "messages")?,
            "unsupported Hermes database schema"
        );
        raw_sessions = read_rows(
            &db,
            "SELECT * FROM sessions ORDER BY id",
            options.max_rows,
            &mut used_bytes,
            options.max_decoded_bytes,
        )?;
        raw_messages = read_rows(
            &db,
            "SELECT * FROM messages ORDER BY id",
            options.max_rows,
            &mut used_bytes,
            options.max_decoded_bytes,
        )?;
        if table_exists(&db, "system_prompts")? {
            for row in read_rows(
                &db,
                "SELECT * FROM system_prompts ORDER BY hash",
                options.max_rows,
                &mut used_bytes,
                options.max_decoded_bytes,
            )? {
                let hash = required_str(&row, "hash")?;
                let prompt = required_str(&row, "prompt")?;
                ensure!(
                    digest(prompt.as_bytes()) == hash,
                    "source pinned prompt hash mismatch"
                );
                prompts.insert(hash.to_owned(), prompt.to_owned());
            }
        }
        if table_exists(&db, "gateway_routing")? {
            routes = read_rows(
                &db,
                "SELECT * FROM gateway_routing ORDER BY scope,session_key",
                options.max_rows,
                &mut used_bytes,
                options.max_decoded_bytes,
            )?;
        }
    }
    let mut route_keys = BTreeSet::new();
    for row in &routes {
        route_keys.insert(required_str(row, "session_key")?.to_owned());
    }
    if let Some(bytes) = mirror {
        let text = std::str::from_utf8(&bytes)
            .context("routing mirror is not UTF-8")?
            .trim_start_matches('\u{feff}');
        let parsed: Value = serde_json::from_str(text).context("routing mirror is not JSON")?;
        for (key, entry) in parsed
            .as_object()
            .context("routing mirror must be an object")?
        {
            if !key.starts_with('_') && !route_keys.contains(key) {
                routes.push(json!({"scope":"legacy_mirror", "session_key":key, "entry_json":serde_json::to_string(entry)?}));
            }
        }
    }
    let session_ids: BTreeSet<_> = raw_sessions
        .iter()
        .map(|s| required_str(s, "id").map(str::to_owned))
        .collect::<Result<_>>()?;
    let mut grouped: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for row in raw_messages {
        let id = required_str(&row, "session_id")?.to_owned();
        ensure!(
            session_ids.contains(&id),
            "source contains orphaned messages"
        );
        ensure!(
            row["id"].as_i64().is_some(),
            "source message has invalid identity"
        );
        grouped.entry(id).or_default().push(row);
    }
    // A route is active only when authoritative routing explicitly names it. Never
    // guess using timestamp/title/latest row: resets and compression make that unsafe.
    let sessions_by_id: BTreeMap<_, _> = raw_sessions
        .iter()
        .map(|row| (row["id"].as_str().unwrap(), row))
        .collect();
    let mut active: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut unresolved_routes = 0;
    let mut warnings = BTreeSet::new();
    for row in &routes {
        let entry: Value = serde_json::from_str(required_str(row, "entry_json")?)
            .context("invalid source routing entry JSON")?;
        if entry["origin"]["platform"]
            .as_str()
            .or(entry["platform"].as_str())
            != Some("orialis")
        {
            continue;
        }
        let Some(session_id) = entry["session_id"].as_str() else {
            unresolved_routes += 1;
            continue;
        };
        let origin_chat = entry["origin"]["chat_id"].as_str();
        let stored = sessions_by_id.get(session_id).copied();
        let db_chat = stored.and_then(|s| s["chat_id"].as_str());
        let ended_boundary = stored.is_some_and(|s| {
            !s["ended_at"].is_null()
                && ![
                    "agent_close",
                    "ws_orphan_reap",
                    "superseded_by_resume",
                    "startup_orphan_reap",
                    "tui_shutdown",
                    "ws_disconnect",
                    "idle_timeout",
                    "lru_evict",
                ]
                .contains(&s["end_reason"].as_str().unwrap_or(""))
        });
        let finalized = stored.is_some_and(|s| s["expiry_finalized"] == 1 || s["archived"] == 1);
        let Some(chat) = origin_chat.or(db_chat) else {
            unresolved_routes += 1;
            continue;
        };
        if !session_ids.contains(session_id)
            || ended_boundary
            || finalized
            || entry["suspended"] == true
            || entry["active_turn_token"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
        {
            unresolved_routes += 1;
            continue;
        }
        if let (Some(a), Some(b)) = (origin_chat, db_chat) {
            ensure!(a == b, "source route and session chat identities disagree");
        }
        let conversation = conversation_from_chat(chat)?;
        active
            .entry(digest(conversation.as_bytes()))
            .or_default()
            .insert(session_id.to_owned());
    }
    let mut selected: BTreeMap<String, String> = BTreeMap::new();
    for (route, ids) in active {
        if ids.len() != 1 {
            unresolved_routes += ids.len();
            continue;
        }
        let id = ids.into_iter().next().unwrap();
        if selected.insert(id, route).is_some() {
            bail!("source session is assigned to multiple conversation routes");
        }
    }
    let mut sessions = Vec::new();
    for raw in raw_sessions {
        let id = required_str(&raw, "id")?.to_owned();
        let inline = raw["system_prompt"].as_str();
        let resolved = raw["system_prompt_hash"]
            .as_str()
            .and_then(|h| prompts.get(h))
            .map(String::as_str);
        ensure!(
            raw["system_prompt_hash"]
                .as_str()
                .is_none_or(|_| resolved.is_some() || inline.is_some()),
            "missing content-addressed pinned prompt"
        );
        let (prompt, prompt_origin) = if let Some(p) = resolved {
            (Some(p.to_owned()), "content_addressed")
        } else if let Some(p) = inline {
            (Some(p.to_owned()), "inline")
        } else {
            (None, "destination_snapshot_fallback")
        };
        let tool_names = raw["tool_names"].as_str().map(|value| {
            prompts
                .get(value)
                .cloned()
                .unwrap_or_else(|| value.to_owned())
        });
        let messages = grouped.remove(&id).unwrap_or_default();
        let replay = messages
            .iter()
            .filter(|m| m["active"].as_i64().unwrap_or(1) == 1)
            .map(replay_message)
            .collect::<Result<Vec<_>>>()?;
        let session_digest = digest(&serde_json::to_vec(
            &json!({"session":raw,"prompt":prompt,"tool_names":tool_names,"messages":messages}),
        )?);
        sessions.push(Session {
            desired_route: selected.remove(&id),
            id,
            digest: session_digest,
            prompt,
            prompt_origin: prompt_origin.into(),
            tool_names,
            raw,
            messages,
            replay,
        });
    }
    let counts = Counts {
        source_sessions: sessions.len(),
        source_messages: sessions.iter().map(|s| s.messages.len()).sum(),
        replay_messages: sessions.iter().map(|s| s.replay.len()).sum(),
        source_memory_entries: memories.len(),
        unresolved_routes,
        missing_pinned_prompts: sessions.iter().filter(|s| s.prompt.is_none()).count(),
        ..Counts::default()
    };
    if counts.missing_pinned_prompts > 0 {
        warnings.insert("Some source sessions have no recorded prompt; imported sessions will pin the destination prompt and safe imported memory. Original prompt parity is unavailable.".into());
    }
    if unresolved_routes > 0 {
        warnings.insert("Some source routes cannot be activated safely; their sessions and metadata remain archived.".into());
    }
    if sessions
        .iter()
        .any(|s| s.desired_route.is_none() && s.raw["source"] == "orialis")
    {
        warnings.insert("Orialis sessions without an unambiguous routing entry are archived, not auto-selected.".into());
    }
    let snapshot_digest = digest(&serde_json::to_vec(
        &json!({"format":FORMAT,"files":files.iter().map(|f| (f.relative,&f.digest)).collect::<Vec<_>>(),"limits":[options.memory_char_limit,options.user_char_limit]}),
    )?);
    let plan = ImportPlan {
        options,
        source_id,
        snapshot_digest,
        files,
        sessions,
        memories,
        routes,
        counts,
        warnings: warnings.into_iter().collect(),
    };
    plan.verify_source_unchanged()?;
    Ok(plan)
}

impl ImportPlan {
    /// Does not create destination tables or mutate the source/destination.
    pub fn preview(&self, destination: &Connection) -> Result<DryRun> {
        Ok(self.destination_plan(destination)?.report)
    }
    /// Rechecks source bytes and the reviewed destination state, then commits atomically.
    /// Any error rolls back the entire import. Reapplying an already committed snapshot
    /// is a no-op, even after the destination has accumulated newer conversation turns.
    pub fn apply(&self, destination: &mut Connection, reviewed: &DryRun) -> Result<DryRun> {
        self.verify_source_unchanged()?;
        ensure!(
            reviewed.source_id == self.source_id
                && reviewed.snapshot_digest == self.snapshot_digest,
            "dry run belongs to a different source snapshot"
        );
        let tx = destination.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let operation = self.destination_plan(&tx)?;
        if operation.report.already_applied {
            return Ok(operation.report);
        }
        ensure!(
            operation.report.review_digest == reviewed.review_digest,
            "destination changed since dry run; review a new dry run before applying"
        );
        tx.execute_batch(MIGRATION_SCHEMA)?;
        for (memory, disposition) in self.memories.iter().zip(&operation.memory) {
            if disposition == "insert" {
                tx.execute(
                    "INSERT INTO memories(target,content) VALUES(?1,?2)",
                    params![memory.target, memory.content],
                )?;
            }
            tx.execute(
                "INSERT INTO migration_memory VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    self.source_id,
                    self.snapshot_digest,
                    memory.target,
                    memory.ordinal as i64,
                    memory.content,
                    disposition
                ],
            )?;
        }
        let fallback_prompt = destination_prompt(&tx)?;
        for (session, (target, insert, activate)) in
            self.sessions.iter().zip(operation.destinations)
        {
            if !insert {
                continue;
            }
            let prompt = session.prompt.as_deref().unwrap_or(&fallback_prompt);
            tx.execute(
                "INSERT INTO sessions(id,prompt) VALUES(?1,?2)",
                params![target, prompt],
            )?;
            for (seq, message) in session.replay.iter().enumerate() {
                tx.execute(
                    "INSERT INTO messages(session_id,seq,body) VALUES(?1,?2,?3)",
                    params![target, seq as i64, serde_json::to_string(message)?],
                )?;
            }
            if activate {
                tx.execute("INSERT INTO routes(id,generation) VALUES(?1,0)", [&target])?;
            }
            tx.execute(
                "INSERT INTO migration_sessions VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    self.source_id,
                    session.id,
                    session.digest,
                    target,
                    session.desired_route,
                    session.prompt_origin,
                    serde_json::to_string(&session.raw)?,
                    session.tool_names
                ],
            )?;
            for message in &session.messages {
                tx.execute(
                    "INSERT INTO migration_messages VALUES(?1,?2,?3,?4,?5)",
                    params![
                        self.source_id,
                        session.id,
                        session.digest,
                        message["id"].as_i64(),
                        serde_json::to_string(message)?
                    ],
                )?;
            }
        }
        for (i, route) in self.routes.iter().enumerate() {
            tx.execute(
                "INSERT INTO migration_routes VALUES(?1,?2,?3,?4)",
                params![
                    self.source_id,
                    self.snapshot_digest,
                    i as i64,
                    serde_json::to_string(route)?
                ],
            )?;
        }
        tx.execute("INSERT INTO migration_manifests(source_id,snapshot_digest,format,manifest_json) VALUES(?1,?2,?3,?4)", params![self.source_id,self.snapshot_digest,FORMAT,serde_json::to_string(&operation.report)?])?;
        // Close the read/copy race before changing destination state durably.
        self.verify_source_unchanged()?;
        tx.commit()?;
        Ok(operation.report)
    }
    fn verify_source_unchanged(&self) -> Result<()> {
        checked_root(&self.options.profile_dir)?;
        for file in &self.files {
            let current = read_selected(&self.options, file.relative)?
                .as_ref()
                .map(|b| digest(b));
            ensure!(
                current == file.digest,
                "source changed during migration; stop Hermes and repeat inspection"
            );
        }
        Ok(())
    }
    fn destination_plan(&self, db: &Connection) -> Result<DestinationPlan> {
        check_destination_permissions(db)?;
        if let Some(path) = db.path().filter(|p| !p.is_empty() && *p != ":memory:") {
            ensure!(
                !fs::canonicalize(path)?.starts_with(&self.options.profile_dir),
                "destination database must be outside the selected source profile"
            );
        }
        for table in ["sessions", "routes", "messages", "memories"] {
            ensure!(
                table_exists(db, table)?,
                "destination Store schema is not initialized"
            );
        }
        let mut report = DryRun {
            format: FORMAT.into(),
            source_id: self.source_id.clone(),
            snapshot_digest: self.snapshot_digest.clone(),
            review_digest: String::new(),
            already_applied: false,
            counts: self.counts.clone(),
            warnings: self.warnings.clone(),
        };
        if table_exists(db, "migration_manifests")?
            && db
                .query_row(
                    "SELECT 1 FROM migration_manifests WHERE source_id=?1 AND snapshot_digest=?2",
                    params![self.source_id, self.snapshot_digest],
                    |_| Ok(()),
                )
                .optional()?
                .is_some()
        {
            report.already_applied = true;
            report.counts.sessions_already_imported = self.sessions.len();
            report.review_digest =
                digest(format!("{}:already-applied", self.snapshot_digest).as_bytes());
            return Ok(DestinationPlan {
                report,
                destinations: Vec::new(),
                memory: Vec::new(),
            });
        }
        let mut state_hash = Sha256::new();
        for table in [
            "sessions",
            "routes",
            "messages",
            "memories",
            "migration_sessions",
            "migration_manifests",
            "migration_memory",
        ] {
            if table_exists(db, table)? {
                let mut statement = db.prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))?;
                let names = statement
                    .column_names()
                    .into_iter()
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                let mut rows = statement.query([])?;
                state_hash.update(table.as_bytes());
                while let Some(row) = rows.next()? {
                    state_hash.update(serde_json::to_vec(&row_value(row, &names)?)?);
                    state_hash.update([0]);
                }
            }
        }
        state_hash.update(self.snapshot_digest.as_bytes());
        state_hash.update(self.source_id.as_bytes());
        report.review_digest = format!("{:x}", state_hash.finalize());
        let mut contents: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for target in ["memory", "user"] {
            let mut q = db.prepare("SELECT content FROM memories WHERE target=?1 ORDER BY id")?;
            contents.insert(
                target.into(),
                q.query_map([target], |r| r.get(0))?
                    .collect::<rusqlite::Result<_>>()?,
            );
        }
        let mut prior_memory = BTreeSet::<(String, String)>::new();
        if table_exists(db, "migration_memory")? {
            let mut q = db.prepare("SELECT DISTINCT target,content FROM migration_memory WHERE source_id=?1 AND disposition IN ('insert','already_present')")?;
            prior_memory.extend(
                q.query_map([&self.source_id], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<rusqlite::Result<Vec<_>>>()?,
            );
        }
        let mut memory = Vec::new();
        for entry in &self.memories {
            let current = contents.get_mut(&entry.target).unwrap();
            let limit = if entry.target == "memory" {
                self.options.memory_char_limit
            } else {
                self.options.user_char_limit
            };
            let disposition = if entry.unsafe_entry {
                report.counts.memory_quarantined += 1;
                "quarantine_unsafe"
            } else if current.contains(&entry.content) {
                report.counts.memory_already_present += 1;
                "already_present"
            } else if prior_memory.contains(&(entry.target.clone(), entry.content.clone())) {
                report.counts.memory_quarantined += 1;
                "quarantine_destination_changed"
            } else if current.iter().map(|s| s.chars().count()).sum::<usize>()
                + current.len() * ENTRY_DELIMITER.chars().count()
                + entry.content.chars().count()
                > limit
            {
                report.counts.memory_quarantined += 1;
                "quarantine_over_budget"
            } else {
                current.push(entry.content.clone());
                report.counts.memory_to_insert += 1;
                "insert"
            };
            memory.push(disposition.to_owned());
        }
        let has_ledger = table_exists(db, "migration_sessions")?;
        let mut reserved = BTreeSet::new();
        let mut destinations = Vec::new();
        for session in &self.sessions {
            let previous: Option<String> = if has_ledger {
                db.query_row("SELECT target_session_id FROM migration_sessions WHERE source_id=?1 AND source_session_id=?2 AND session_digest=?3", params![self.source_id,session.id,session.digest], |r| r.get(0)).optional()?
            } else {
                None
            };
            if let Some(id) = previous {
                ensure!(
                    db.query_row("SELECT 1 FROM sessions WHERE id=?1", [&id], |_| Ok(()))
                        .optional()?
                        .is_some(),
                    "destination migration ledger references a missing session"
                );
                report.counts.sessions_already_imported += 1;
                if session
                    .desired_route
                    .as_ref()
                    .is_some_and(|route| route != &id)
                {
                    report.counts.active_route_conflicts += 1;
                }
                destinations.push((id, false, false));
                continue;
            }
            let archive = format!(
                "import_{}",
                digest(
                    format!("{}\0{}\0{}", self.source_id, session.id, session.digest).as_bytes()
                )
            );
            let mut activate = false;
            let mut target = archive;
            if let Some(route) = &session.desired_route {
                let occupied = db.query_row("SELECT 1 FROM sessions WHERE id=?1 UNION ALL SELECT 1 FROM routes WHERE id=?1 LIMIT 1", [route], |_| Ok(())).optional()?.is_some() || reserved.contains(route);
                if occupied {
                    report.counts.active_route_conflicts += 1;
                } else {
                    target = route.clone();
                    activate = true;
                    report.counts.active_routes_to_insert += 1;
                }
            }
            ensure!(
                db.query_row("SELECT 1 FROM sessions WHERE id=?1", [&target], |_| Ok(()))
                    .optional()?
                    .is_none()
                    && reserved.insert(target.clone()),
                "import session identity conflicts with destination; nothing overwritten"
            );
            report.counts.sessions_to_insert += 1;
            destinations.push((target, true, activate));
        }
        if report.counts.active_route_conflicts > 0 {
            report.warnings.push("Existing destination sessions and routes are preserved; conflicting source selections remain archived.".into());
        }
        if report.counts.memory_quarantined > 0 {
            report.warnings.push("Unsafe, over-budget, or previously removed destination memory is retained only in the private migration archive and excluded from new-session prompts.".into());
        }
        Ok(DestinationPlan {
            report,
            destinations,
            memory,
        })
    }
}

#[cfg(unix)]
fn check_destination_permissions(db: &Connection) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if let Some(path) = db.path().filter(|p| !p.is_empty() && *p != ":memory:") {
        let path = Path::new(path);
        checked_root(path.parent().context("destination directory unavailable")?)?;
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut name = path.as_os_str().to_os_string();
            name.push(suffix);
            match fs::symlink_metadata(PathBuf::from(name)) {
                Ok(m) => ensure!(
                    m.is_file()
                        && !m.file_type().is_symlink()
                        && m.uid() == unsafe { libc::geteuid() }
                        && m.nlink() == 1
                        && m.mode() & 0o077 == 0,
                    "destination files must be private, owned, single-linked, and regular"
                ),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound && !suffix.is_empty() => {}
                Err(e) => return Err(e.into()),
            }
        }
    }
    Ok(())
}
#[cfg(not(unix))]
fn check_destination_permissions(_: &Connection) -> Result<()> {
    bail!("profile migration requires Unix owner and permission checks");
}

fn destination_prompt(db: &Connection) -> Result<String> {
    let mut p = crate::BASE_PROMPT.to_owned();
    for target in ["memory", "user"] {
        let mut q = db.prepare("SELECT content FROM memories WHERE target=?1 ORDER BY id")?;
        let entries: Vec<String> = q
            .query_map([target], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        if !entries.is_empty() {
            p.push_str(&format!(
                "\n<saved_{target}>\n{}\n</saved_{target}>",
                entries.join(ENTRY_DELIMITER)
            ));
        }
    }
    Ok(p)
}
fn replay_message(row: &Value) -> Result<Value> {
    let role = required_str(row, "role")?;
    ensure!(
        ["user", "assistant", "tool", "system", "developer"].contains(&role),
        "unsupported source message role"
    );
    let mut content = row["content"].clone();
    if let Some(s) = content.as_str().and_then(|s| s.strip_prefix("\0json:"))
        && let Ok(v) = serde_json::from_str(s)
    {
        content = v;
    }
    let mut out = json!({"role":role,"content":content});
    for key in [
        "tool_call_id",
        "tool_name",
        "effect_disposition",
        "timestamp",
        "token_count",
        "finish_reason",
        "reasoning",
        "reasoning_content",
        "api_content",
        "display_kind",
        "message_uid",
        "tool_call_uid",
        "_compressed_summary",
        "observed",
    ] {
        if !row[key].is_null() {
            out[key] = row[key].clone();
        }
    }
    if !row["platform_message_id"].is_null() {
        out["message_id"] = row["platform_message_id"].clone();
    }
    for key in [
        "tool_calls",
        "reasoning_details",
        "codex_reasoning_items",
        "codex_message_items",
        "display_metadata",
        "absorbed_message_uids",
        "tool_call_uids",
    ] {
        if let Some(s) = row[key].as_str().filter(|s| !s.is_empty()) {
            out[key] =
                serde_json::from_str(s).context("invalid source structured message metadata")?;
        }
    }
    Ok(out)
}
fn required_str<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .context("source schema has a missing or invalid required text field")
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn table_exists(db: &Connection, name: &str) -> Result<bool> {
    Ok(db
        .query_row(
            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1",
            [name],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}
fn read_rows(
    db: &Connection,
    sql: &str,
    max: usize,
    used: &mut usize,
    budget: usize,
) -> Result<Vec<Value>> {
    let mut query = db.prepare(sql)?;
    let names = query
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut cursor = query.query([])?;
    let mut values = Vec::new();
    while let Some(row) = cursor.next()? {
        ensure!(values.len() < max, "source row limit exceeded");
        let value = row_value(row, &names)?;
        *used = used
            .checked_add(serde_json::to_vec(&value)?.len())
            .context("source size overflow")?;
        ensure!(*used <= budget, "source decoded size limit exceeded");
        values.push(value);
    }
    Ok(values)
}
fn row_value(row: &rusqlite::Row<'_>, names: &[String]) -> Result<Value> {
    let mut object = Map::new();
    for (i, name) in names.iter().enumerate() {
        let value = match row.get_ref(i)? {
            ValueRef::Null => Value::Null,
            ValueRef::Integer(i) => json!(i),
            ValueRef::Real(f) => {
                ensure!(f.is_finite(), "source contains non-finite numeric metadata");
                json!(f)
            }
            ValueRef::Text(b) => Value::String(
                std::str::from_utf8(b)
                    .context("source database contains invalid UTF-8")?
                    .to_owned(),
            ),
            ValueRef::Blob(b) => {
                json!({"$sqlite_blob_base64":base64::engine::general_purpose::STANDARD.encode(b)})
            }
        };
        object.insert(name.clone(), value);
    }
    Ok(Value::Object(object))
}

#[cfg(unix)]
fn checked_root(path: &Path) -> Result<PathBuf> {
    use std::os::unix::fs::MetadataExt;
    ensure!(
        !path.as_os_str().is_empty()
            && !path.components().any(|c| matches!(c, Component::ParentDir)),
        "source path must not contain parent traversal"
    );
    let path = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    };
    let uid = unsafe { libc::geteuid() };
    for ancestor in path.ancestors() {
        let m = fs::symlink_metadata(ancestor)?;
        ensure!(
            m.is_dir() && !m.file_type().is_symlink(),
            "source ancestors must be real directories"
        );
        ensure!(
            m.uid() == uid || m.uid() == 0,
            "source ancestors have an untrusted owner"
        );
        ensure!(
            m.mode() & 0o022 == 0 || (ancestor != path && m.uid() == 0 && m.mode() & 0o1000 != 0),
            "source ancestor is writable by other users"
        );
        if ancestor == path {
            ensure!(
                m.uid() == uid && m.mode() & 0o077 == 0,
                "source profile must be private and owned by current user"
            );
        }
    }
    Ok(fs::canonicalize(path)?)
}
#[cfg(not(unix))]
fn checked_root(_: &Path) -> Result<PathBuf> {
    bail!("profile migration requires Unix owner and permission checks");
}
#[cfg(unix)]
fn read_selected(options: &SourceOptions, relative: &str) -> Result<Option<Vec<u8>>> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let path = options.profile_dir.join(relative);
    if let Some(parent) = path.parent().filter(|p| *p != options.profile_dir) {
        match fs::symlink_metadata(parent) {
            Ok(m) => ensure!(
                m.is_dir()
                    && !m.file_type().is_symlink()
                    && m.uid() == unsafe { libc::geteuid() }
                    && m.mode() & 0o077 == 0,
                "source subdirectory must be private, owned, and not a symlink"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    }
    let m = match fs::symlink_metadata(&path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    ensure!(
        m.is_file()
            && !m.file_type().is_symlink()
            && m.uid() == unsafe { libc::geteuid() }
            && m.nlink() == 1
            && m.mode() & 0o077 == 0,
        "source file must be private, single-linked, owned, and regular"
    );
    ensure!(
        m.len() <= options.max_file_bytes,
        "source file exceeds size limit"
    );
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)?;
    let opened = file.metadata()?;
    ensure!(
        m.dev() == opened.dev() && m.ino() == opened.ino(),
        "source file changed while opening"
    );
    let mut bytes = Vec::new();
    file.take(options.max_file_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(
        (bytes.len() as u64) <= options.max_file_bytes,
        "source file exceeds size limit"
    );
    let after = fs::symlink_metadata(path)?;
    ensure!(
        after.dev() == m.dev()
            && after.ino() == m.ino()
            && after.len() == m.len()
            && after.mtime() == m.mtime()
            && after.mtime_nsec() == m.mtime_nsec(),
        "source changed while reading"
    );
    Ok(Some(bytes))
}
#[cfg(not(unix))]
fn read_selected(_: &SourceOptions, _: &str) -> Result<Option<Vec<u8>>> {
    bail!("profile migration requires Unix owner and permission checks");
}
struct PrivateSnapshot(PathBuf);
impl PrivateSnapshot {
    fn new() -> Result<Self> {
        let path = std::env::temp_dir().join(format!("hermes-import-{}", uuid::Uuid::new_v4()));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&path)?;
        Ok(Self(path))
    }
    fn write(&self, name: &str, bytes: &[u8]) -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        }
        let mut f = options.open(self.0.join(name))?;
        f.write_all(bytes)?;
        Ok(())
    }
}
impl Drop for PrivateSnapshot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Compatible pure-memory operations. The caller owns transaction, prompt pinning,
/// approval/stale-entry policy, persistence, and per-turn retry accounting.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct MemoryOperation {
    #[serde(default)]
    pub target: Option<String>,
    pub action: String,
    #[serde(default)]
    pub content: Option<String>,
    #[serde(default)]
    pub new_text: Option<String>,
    #[serde(default)]
    pub old_text: Option<String>,
    #[serde(default)]
    pub matched_entry: Option<String>,
}
/// Match exact whole entry first; otherwise exact substring, then typography-folded
/// substring. Duplicate identical matches select the first; distinct matches fail.
pub fn find_memory_match(entries: &[String], old_text: &str) -> Result<usize> {
    let exact = entries
        .iter()
        .enumerate()
        .filter(|(_, e)| e.as_str() == old_text)
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    let matches = if !exact.is_empty() {
        exact
    } else {
        let direct = entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.contains(old_text))
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        if !direct.is_empty() {
            direct
        } else {
            let needle = normalize_match(old_text);
            if !needle.chars().any(char::is_alphanumeric) {
                Vec::new()
            } else {
                entries
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| normalize_match(e).contains(&needle))
                    .map(|(i, _)| i)
                    .collect()
            }
        }
    };
    let first = *matches.first().context("no memory entry matched")?;
    ensure!(
        matches.iter().all(|&i| entries[i] == entries[first]),
        "multiple distinct memory entries matched"
    );
    Ok(first)
}
fn python_whitespace(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}
fn normalize_match(s: &str) -> String {
    let s = s
        .replace("\\n", " ")
        .chars()
        .map(|c| match c {
            '"' | '`' | '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}' | '\u{201c}'
            | '\u{201d}' | '\u{201e}' | '\u{201f}' => '\'',
            '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2015}'
            | '\u{2212}' => '-',
            _ => c,
        })
        .collect::<String>();
    s.split(python_whitespace)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn apply_memory_operations(
    entries: &[String],
    operations: &[MemoryOperation],
    limit: usize,
) -> Result<Vec<String>> {
    ensure!(!operations.is_empty(), "memory operations cannot be empty");
    let mut working = entries.to_vec();
    for op in operations {
        let patch = op.action == "patch";
        let content = op
            .content
            .as_deref()
            .filter(|s| !s.is_empty())
            .or(op.new_text.as_deref())
            .unwrap_or("");
        let old = op.old_text.as_deref().unwrap_or("");
        let (content, old) = if patch {
            (content, old)
        } else {
            (
                content.trim_matches(python_whitespace),
                old.trim_matches(python_whitespace),
            )
        };
        if op.action == "add" || op.action == "replace" {
            ensure!(!content.is_empty(), "memory content required");
            crate::memory_safety::validate_memory(content)?;
        }
        if op.action == "add" {
            if !working.iter().any(|e| e == content) {
                working.push(content.to_owned());
            }
            continue;
        }
        ensure!(
            ["replace", "remove", "patch"].contains(&op.action.as_str()),
            "unknown memory operation"
        );
        ensure!(
            !old.trim_matches(python_whitespace).is_empty(),
            "memory old_text required"
        );
        let i = if let Some(pinned) = &op.matched_entry {
            working
                .iter()
                .position(|e| e == pinned)
                .context("staged memory entry changed")?
        } else {
            find_memory_match(&working, old)?
        };
        match op.action.as_str() {
            "remove" => {
                working.remove(i);
            }
            "replace" => working[i] = content.to_owned(),
            "patch" => {
                ensure!(
                    !content.trim_matches(python_whitespace).is_empty(),
                    "patch content required"
                );
                let occurrences = working[i]
                    .char_indices()
                    .filter(|(at, _)| working[i][*at..].starts_with(old))
                    .count();
                ensure!(occurrences <= 1, "patch span occurs more than once");
                let after = working[i].replacen(old, content, 1);
                ensure!(after != working[i], "patch is a no-op");
                crate::memory_safety::validate_memory(&after)?;
                working[i] = after;
            }
            _ => unreachable!(),
        }
    }
    ensure!(
        entries.is_empty()
            || !working.is_empty()
            || (operations.len() == 1 && operations[0].action == "remove"),
        "batch would empty nonempty memory"
    );
    let grows = !(operations.iter().all(|o| o.action == "remove")
        || (operations.len() == 1 && working == entries));
    ensure!(
        !grows || working.join(ENTRY_DELIMITER).chars().count() <= limit,
        "memory character limit exceeded"
    );
    Ok(working)
}

/// A reviewed command-line plan, bound to one explicit destination pathname.
/// No source paths, source IDs, conversation text or secrets are printed.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PathReview {
    pub destination_id: String,
    pub review: DryRun,
}

impl ImportPlan {
    /// Preview an on-disk destination without opening its pathname through SQLite,
    /// creating it, changing journal mode, or creating/modifying its sidecars.
    /// Existing data is inspected through a private copied DB+WAL; an absent target
    /// is represented by an initialized in-memory Store only.
    pub fn preview_path(&self, target: &Path) -> Result<PathReview> {
        let (root, name) = checked_destination_path(target)?;
        ensure!(
            !root.join(&name).starts_with(&self.options.profile_dir),
            "destination database must be outside the selected source profile"
        );
        let destination_id = digest(root.join(&name).as_os_str().as_encoded_bytes());
        let options = SourceOptions {
            profile_dir: root,
            max_file_bytes: self.options.max_file_bytes,
            max_rows: self.options.max_rows,
            max_decoded_bytes: self.options.max_decoded_bytes,
            memory_char_limit: self.options.memory_char_limit,
            user_char_limit: self.options.user_char_limit,
        };
        let mut captured = Vec::new();
        for suffix in ["", "-wal", "-journal", "-shm"] {
            let filename = format!("{name}{suffix}");
            captured.push((filename.clone(), read_selected(&options, &filename)?));
        }
        ensure!(
            captured[2].1.as_ref().is_none_or(|v| v.is_empty()),
            "destination has a rollback journal; stop its writer cleanly and retry"
        );
        ensure!(
            captured[0].1.is_some() || (captured[1].1.is_none() && captured[3].1.is_none()),
            "destination WAL exists without its database"
        );
        let review = if let Some(database) = &captured[0].1 {
            let snapshot = PrivateSnapshot::new()?;
            snapshot.write("destination.db", database)?;
            if let Some(wal) = &captured[1].1 {
                snapshot.write("destination.db-wal", wal)?;
            }
            let db = Connection::open_with_flags(
                snapshot.0.join("destination.db"),
                rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
                    | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )?;
            db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;")?;
            let check: String = db.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
            ensure!(
                check == "ok",
                "destination database consistency check failed"
            );
            self.preview(&db)?
        } else {
            let store = crate::Store::open(Path::new(":memory:"))?;
            self.preview(&store.db)?
        };
        // Compare complete bytes after the copied snapshot has been read, including
        // the absent->present case. Same-UID adversarial writers are not supported.
        for (filename, before) in captured {
            let after = read_selected(&options, &filename)?;
            ensure!(
                before.as_ref().map(|v| digest(v)) == after.as_ref().map(|v| digest(v)),
                "destination changed during preview; stop its writer and retry"
            );
        }
        Ok(PathReview {
            destination_id,
            review,
        })
    }

    /// Explicit apply command. A read-only preflight rejects changed state and a
    /// mismatched path *before* opening the actual target. Store::open is called
    /// only after this check; the import repeats the state check under its write
    /// transaction. Opening an approved target may create WAL/SHM or initialize a
    /// new Store, but preview never does so.
    pub fn apply_path(&self, target: &Path, reviewed: &PathReview) -> Result<DryRun> {
        let current = self.preview_path(target)?;
        ensure!(
            current.destination_id == reviewed.destination_id,
            "review belongs to a different destination; run preview for this target"
        );
        ensure!(
            current.review.source_id == reviewed.review.source_id
                && current.review.snapshot_digest == reviewed.review.snapshot_digest,
            "source changed since review; run a new preview"
        );
        ensure!(
            current.review.already_applied
                || current.review.review_digest == reviewed.review.review_digest,
            "destination changed since review; run a new preview"
        );
        if current.review.already_applied {
            return Ok(current.review);
        }
        let (root, name) = checked_destination_path(target)?;
        let mut store = crate::Store::open(&root.join(name))?;
        self.apply(&mut store.db, &reviewed.review)
    }
}

fn checked_destination_path(path: &Path) -> Result<(PathBuf, String)> {
    ensure!(
        !path.as_os_str().is_empty()
            && path != Path::new(":memory:")
            && !path.components().any(|c| matches!(c, Component::ParentDir)),
        "an explicit destination file without parent traversal is required"
    );
    let path = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    };
    let root = checked_root(path.parent().context("destination directory required")?)?;
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .context("destination file must have a UTF-8 filename")?
        .to_owned();
    Ok((root, name))
}
