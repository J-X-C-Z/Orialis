//! Durable, bounded, descriptor-confined V4A transactions. Visibility is per file,
//! not atomic across files. A durable commit intent is the irrevocable cut point.
//! Recovery only rolls forward identities proved by the journal; it never restores
//! a backup over a changed target or treats an I/O error as absence.
use super::*;
use std::collections::BTreeSet;

const PREFIX: &str = ".hermes-v4a-";
const JOURNAL_BYTES: usize = 1024 * 1024;
const RECEIPTS: usize = 64;
const TOTAL_BYTES: usize = 8 * 1024 * 1024;

type Checkpoint<'a> = &'a mut dyn FnMut(&str) -> Result<()>;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Identity {
    hash: String,
    inode: u64,
    device: u64,
}
impl From<Snapshot> for Identity {
    fn from(s: Snapshot) -> Self {
        Self {
            hash: s.hash,
            inode: s.inode,
            device: s.device,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Directory {
    inode: u64,
    device: u64,
}
impl Directory {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata()?;
        ensure!(m.is_dir(), "parent must be a directory");
        Ok(Self {
            inode: m.ino(),
            device: m.dev(),
        })
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Entry {
    path: String,
    parent: Directory,
    before: Option<Identity>,
    after_hash: Option<String>,
    staged: Option<Identity>,
    changed: bool,
    applied: bool,
    bytes: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Journal {
    version: u32,
    id: String,
    scope: String,
    root: String,
    phase: String,
    entries: Vec<Entry>,
    notes: Vec<String>,
    work_used: usize,
    patch_hash: String,
    generation: i64,
    call_id: String,
}
struct Prepared {
    journal: Journal,
    bytes: BTreeMap<String, Vec<u8>>,
    action: Value,
    display: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Pending,
    Applied,
    Unchanged,
}

pub(super) fn patch_schema() -> Value {
    let mut s = schema(
        "patch",
        "Replace bounded UTF-8 text after a complete current read, using ordered exact/fuzzy strategies, or apply V4A with mode=patch and patch text (Add/Update/Delete/Move). V4A requires complete reads of every existing source/destination, existing parents, one combined approval, bounded private journal and crash recovery. Visibility is per-file, NOT cross-file atomic. Query mode=status (optional transaction_id) after uncertain results; never blindly repeat. Files become mode 0600. No lint or parent creation.",
        json!({
            "mode":{"enum":["replace","patch","status"]}, "path":{"type":"string"}, "old_string":{"type":"string"}, "new_string":{"type":"string"}, "replace_all":{"type":"boolean"}, "patch":{"type":"string"}, "transaction_id":{"type":"string"}
        }),
        &[],
    );
    s["function"]["parameters"]["anyOf"] = json!([
        {"required":["path","old_string","new_string"]},
        {"required":["patch"]},
        {"required":["mode"],"properties":{"mode":{"const":"status"}}}
    ]);
    s
}
pub(super) fn status_schema() -> Value {
    schema(
        "patch",
        "Read the latest retained V4A transaction receipt in this trusted conversation/session, or select transaction_id. Read-only: all patch writes are disabled by host policy. not_found does not prove an old transaction never ran.",
        json!({"mode":{"enum":["status"]},"transaction_id":{"type":"string"}}),
        &["mode"],
    )
}
fn init(inner: &Inner) -> Result<()> {
    inner.db.lock().unwrap().execute_batch("CREATE TABLE IF NOT EXISTS local_v4a_active(id INTEGER PRIMARY KEY CHECK(id=1),body TEXT NOT NULL CHECK(length(body)<=1048576)); CREATE TABLE IF NOT EXISTS local_v4a_receipts(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,scope TEXT NOT NULL,body TEXT NOT NULL CHECK(length(body)<=1048576));")?;
    Ok(())
}
fn load(inner: &Inner) -> Result<Option<Journal>> {
    let raw = inner
        .db
        .lock()
        .unwrap()
        .query_row("SELECT body FROM local_v4a_active WHERE id=1", [], |r| {
            r.get::<_, String>(0)
        })
        .optional()?;
    raw.map(|raw| {
        ensure!(
            raw.len() <= JOURNAL_BYTES,
            "transaction journal exceeds bound"
        );
        let j: Journal = serde_json::from_str(&raw)?;
        ensure!(
            j.version == 1
                && j.root == inner.root_id
                && j.entries.len() <= 256
                && uuid::Uuid::parse_str(&j.id).is_ok(),
            "invalid transaction journal identity"
        );
        ensure!(
            ["preparing", "committing", "committed"].contains(&j.phase.as_str()),
            "invalid transaction phase"
        );
        let mut paths = BTreeSet::new();
        for e in &j.entries {
            ensure!(
                !e.path.is_empty() && rel(&e.path)? == e.path && paths.insert(&e.path),
                "invalid transaction path"
            );
        }
        Ok(j)
    })
    .transpose()
}
fn save(inner: &Inner, j: &Journal) -> Result<()> {
    let raw = serde_json::to_string(j)?;
    ensure!(
        raw.len() <= JOURNAL_BYTES,
        "transaction journal exceeds bound"
    );
    inner.db.lock().unwrap().execute("INSERT INTO local_v4a_active(id,body) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET body=excluded.body", [raw])?;
    Ok(())
}
pub(super) fn ensure_ready(inner: &Inner) -> Result<()> {
    ensure!(
        load(inner)?.is_none(),
        "an unresolved V4A transaction blocks file writes; use patch mode=status and inspect its receipt, do not repeat the patch"
    );
    Ok(())
}
fn finish(inner: &Inner, j: &Journal, receipt: &Value) -> Result<()> {
    let mut db = inner.db.lock().unwrap();
    let tx = db.transaction()?;
    tx.execute("INSERT INTO local_v4a_receipts(id,scope,body) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET body=excluded.body", params![j.id,j.scope,serde_json::to_string(receipt)?])?;
    tx.execute("DELETE FROM local_v4a_active WHERE id=1", [])?;
    tx.execute("DELETE FROM local_v4a_receipts WHERE sequence NOT IN (SELECT sequence FROM local_v4a_receipts ORDER BY sequence DESC LIMIT ?1)", [RECEIPTS])?;
    tx.commit()?;
    Ok(())
}
fn parent(inner: &Inner, e: &Entry) -> Result<(File, CString)> {
    let (dir, leaf) = inner.root.open_parent(&e.path)?;
    ensure!(
        Directory::of(&dir)? == e.parent,
        "parent directory changed for {}",
        e.path
    );
    Ok((dir, CString::new(leaf)?))
}
fn stage_name(j: &Journal, i: usize) -> CString {
    CString::new(format!("{PREFIX}{}-{i}", j.id)).unwrap()
}
fn at_snapshot(parent: &File, leaf: &CString, limit: usize) -> Result<Option<Identity>> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            leaf.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(e.into());
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let m = file.metadata()?;
    ensure!(
        m.is_file() && m.nlink() == 1 && m.len() <= limit as u64,
        "transaction path is not a bounded single-linked regular file"
    );
    let mut bytes = Vec::with_capacity((m.len() as usize).min(limit));
    Read::by_ref(&mut file)
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    ensure!(
        bytes.len() <= limit
            && after.len() == m.len()
            && after.mtime() == m.mtime()
            && after.mtime_nsec() == m.mtime_nsec()
            && after.ctime() == m.ctime()
            && after.ctime_nsec() == m.ctime_nsec()
            && after.nlink() == 1,
        "transaction file changed while reading"
    );
    Ok(Some(Identity {
        hash: hash(&bytes),
        inode: m.ino(),
        device: m.dev(),
    }))
}
fn inspect(inner: &Inner, j: &Journal, i: usize) -> Result<State> {
    let e = &j.entries[i];
    let (dir, leaf) = parent(inner, e)?;
    let actual = at_snapshot(&dir, &leaf, inner.cfg.file_bytes)?;
    if !e.changed {
        ensure!(actual == e.before, "unchanged guard changed: {}", e.path);
        return Ok(State::Unchanged);
    }
    let temp = at_snapshot(&dir, &stage_name(j, i), inner.cfg.file_bytes)?;
    if e.applied {
        ensure!(actual == e.staged, "committed target changed: {}", e.path);
        ensure!(
            temp.is_none() || (e.before.is_some() && temp == e.before),
            "backup changed: {}",
            e.path
        );
        return Ok(State::Applied);
    }
    if actual == e.before && temp == e.staged {
        return Ok(State::Pending);
    }
    // An unlogged rename is proved by BOTH the installed stage identity and old
    // backup. For Add the original absence and missing stage are sufficient.
    if actual == e.staged && temp == e.before {
        return Ok(State::Applied);
    }
    bail!("transaction target/stage conflict: {}", e.path)
}
fn prepare(inner: &Inner, patch: &str, owner: &str, tool: &LocalTools) -> Result<Prepared> {
    ensure_ready(inner)?;
    let limits = crate::file_patch::PatchLimits {
        max_file_bytes: inner.cfg.file_bytes,
        max_patch_bytes: inner.cfg.file_bytes.min(TOTAL_BYTES),
        ..Default::default()
    };
    let operations = crate::file_patch::parse_v4a(patch, &limits)?;
    let mut paths = BTreeSet::new();
    for op in &operations {
        paths.insert(rel(&op.path)?);
        if let Some(p) = &op.new_path {
            paths.insert(rel(p)?);
        }
    }
    ensure!(
        !paths.is_empty() && paths.len() <= 256,
        "empty or excessive V4A target set"
    );
    ensure!(
        paths.iter().map(String::len).sum::<usize>() <= 128 * 1024,
        "combined transaction path bytes exceed bound"
    );
    let mut snapshots = BTreeMap::new();
    let mut entries = Vec::new();
    let mut total = 0usize;
    for path in paths {
        let (dir, leaf) = inner.root.open_parent(&path)?;
        let current = at_snapshot(&dir, &CString::new(leaf)?, inner.cfg.file_bytes)?;
        let content = if let Some(actual) = &current {
            let remembered=inner.reads.lock().unwrap().get(&(owner.to_owned(),path.clone())).cloned().context("read the complete current file before any update/delete/move or occupied-destination patch")?;
            ensure!(
                Identity::from(remembered) == *actual,
                "file changed since complete read; read and merge again"
            );
            let (bytes, snap) = snapshot(&inner.root, &path, inner.cfg.file_bytes)?;
            ensure!(
                Identity::from(snap) == *actual,
                "file changed while preparing patch"
            );
            total = total
                .checked_add(bytes.len())
                .context("patch byte overflow")?;
            ensure!(
                total <= TOTAL_BYTES,
                "patch combined snapshot byte limit exceeded"
            );
            Some(String::from_utf8(bytes).context("V4A supports UTF-8 text only")?)
        } else {
            None
        };
        snapshots.insert(path.clone(), content);
        entries.push(Entry {
            path,
            parent: Directory::of(&dir)?,
            before: current,
            after_hash: None,
            staged: None,
            changed: false,
            applied: false,
            bytes: 0,
        });
    }
    let plan = crate::file_patch::plan_v4a(patch, &snapshots, &limits)?;
    ensure!(
        !plan.changes.is_empty(),
        "patch has no final filesystem changes"
    );
    let mut bytes = BTreeMap::new();
    for e in &mut entries {
        if let Some(c) = plan.changes.iter().find(|c| c.path == e.path) {
            e.changed = true;
            e.after_hash = c.after.as_ref().map(|s| hash(s.as_bytes()));
            if let Some(s) = &c.after {
                e.bytes = s.len();
                bytes.insert(e.path.clone(), s.as_bytes().to_vec());
            }
        } else {
            e.after_hash = e.before.as_ref().map(|s| s.hash.clone());
        }
    }
    ensure!(
        bytes.values().map(Vec::len).sum::<usize>() <= TOTAL_BYTES,
        "patch combined output byte limit exceeded"
    );
    let patch_hash = hash(patch.as_bytes());
    let binding=entries.iter().map(|e|json!({"path":e.path,"parent":e.parent,"before":e.before,"after_sha256":e.after_hash,"changed":e.changed,"bytes":e.bytes})).collect::<Vec<_>>();
    let action = tool.action(
        "patch",
        &json!({"mode":"patch","patch_sha256":patch_hash,"targets":binding}),
    );
    // Keep every path in the approval preview. Contents are bounded excerpts;
    // the action still binds every complete before/after digest and operation.
    let mut display = format!(
        "Apply V4A transaction: {} operations, {} changed files. Per-file visibility, not cross-file atomic. Durable commit intent cannot be cancelled or rolled back. Files become 0600.\n",
        operations.len(),
        plan.changes.len()
    );
    for e in &entries {
        if e.changed {
            display.push_str(&format!(
                "{} {} ({} bytes)\n",
                if e.before.is_none() {
                    "Add"
                } else if e.after_hash.is_none() {
                    "Delete"
                } else {
                    "Replace"
                },
                e.path,
                e.bytes
            ));
        }
    }
    for op in &operations {
        if let Some(dst) = &op.new_path {
            display.push_str(&format!("Move {} -> {}\n", op.path, dst));
        }
    }
    for n in &plan.notes {
        display.push_str(n);
        display.push('\n');
    }
    let mut end = patch.len().min(8192);
    while !patch.is_char_boundary(end) {
        end -= 1;
    }
    display.push_str(&format!("Patch SHA-256: {patch_hash}\n{}\n{}",&patch[..end],if end<patch.len(){"[Patch preview truncated; approval binds the full patch and every final content digest.]"}else{""}));
    ensure!(display.len() <= 32 * 1024, "approval preview exceeds bound");
    let j = Journal {
        version: 1,
        id: uuid::Uuid::new_v4().to_string(),
        scope: owner.into(),
        root: inner.root_id.clone(),
        phase: "preparing".into(),
        entries,
        notes: plan.notes,
        work_used: plan.work_used,
        patch_hash,
        generation: 0,
        call_id: String::new(),
    };
    ensure!(
        serde_json::to_vec(&j)?.len() <= JOURNAL_BYTES,
        "transaction metadata exceeds bound"
    );
    Ok(Prepared {
        journal: j,
        bytes,
        action,
        display,
    })
}
fn verify_originals(inner: &Inner, j: &Journal) -> Result<()> {
    for e in &j.entries {
        let (p, n) = parent(inner, e)?;
        ensure!(
            at_snapshot(&p, &n, inner.cfg.file_bytes)? == e.before,
            "file changed while awaiting approval; no target bytes written: {}",
            e.path
        );
    }
    Ok(())
}
#[cfg(target_os = "linux")]
fn create_stages(inner: &Inner, prepared: &mut Prepared, point: Checkpoint<'_>) -> Result<()> {
    save(inner, &prepared.journal)?;
    point("journal_preparing")?;
    for i in 0..prepared.journal.entries.len() {
        let e = &prepared.journal.entries[i];
        if !e.changed || e.after_hash.is_none() {
            continue;
        }
        let (parent, _) = parent(inner, e)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                c".".as_ptr(),
                libc::O_TMPFILE | libc::O_RDWR | libc::O_CLOEXEC,
                0o600,
            )
        };
        ensure!(
            fd >= 0,
            "filesystem must support safe unnamed transaction staging: {}",
            std::io::Error::last_os_error()
        );
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(&prepared.bytes[&e.path])?;
        file.sync_all()?;
        point(&format!("stage_data_synced:{i}"))?;
        let m = file.metadata()?;
        prepared.journal.entries[i].staged = Some(Identity {
            hash: e.after_hash.clone().unwrap(),
            inode: m.ino(),
            device: m.dev(),
        });
        save(inner, &prepared.journal)?;
        point(&format!("stage_identity_journaled:{i}"))?;
        ensure!(
            unsafe {
                libc::linkat(
                    file.as_raw_fd(),
                    c"".as_ptr(),
                    parent.as_raw_fd(),
                    stage_name(&prepared.journal, i).as_ptr(),
                    libc::AT_EMPTY_PATH,
                )
            } == 0,
            "cannot link transaction stage: {}",
            std::io::Error::last_os_error()
        );
        point(&format!("stage_linked:{i}"))?;
        parent.sync_all()?;
        point(&format!("stage_parent_synced:{i}"))?;
    }
    Ok(())
}
#[cfg(not(target_os = "linux"))]
fn create_stages(_: &Inner, _: &mut Prepared, _: Checkpoint<'_>) -> Result<()> {
    bail!("safe V4A runtime currently requires Linux O_TMPFILE and renameat2")
}
#[cfg(target_os = "linux")]
fn install(inner: &Inner, j: &Journal, i: usize) -> Result<()> {
    let e = &j.entries[i];
    let (p, n) = parent(inner, e)?;
    let stage = stage_name(j, i);
    let (from, to, flags) = if e.after_hash.is_none() {
        (&n, &stage, libc::RENAME_NOREPLACE)
    } else if e.before.is_none() {
        (&stage, &n, libc::RENAME_NOREPLACE)
    } else {
        (&stage, &n, libc::RENAME_EXCHANGE)
    };
    ensure!(
        unsafe {
            libc::renameat2(
                p.as_raw_fd(),
                from.as_ptr(),
                p.as_raw_fd(),
                to.as_ptr(),
                flags,
            )
        } == 0,
        "transaction rename failed: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}
#[cfg(not(target_os = "linux"))]
fn install(_: &Inner, _: &Journal, _: usize) -> Result<()> {
    bail!("V4A requires Linux renameat2")
}
fn apply(inner: &Inner, j: &mut Journal, point: Checkpoint<'_>) -> Result<()> {
    // Validate the WHOLE remaining set before resuming any interrupted commit.
    for i in 0..j.entries.len() {
        inspect(inner, j, i)?;
    }
    for i in 0..j.entries.len() {
        match inspect(inner, j, i)? {
            State::Unchanged => continue,
            State::Pending => {
                point(&format!("before_target_rename:{i}"))?;
                install(inner, j, i)?;
                point(&format!("target_renamed:{i}"))?;
            }
            State::Applied => {}
        }
        let (p, _) = parent(inner, &j.entries[i])?;
        p.sync_all()?;
        point(&format!("target_parent_synced:{i}"))?;
        ensure!(
            inspect(inner, j, i)? == State::Applied,
            "transaction effect verification failed"
        );
        j.entries[i].applied = true;
        save(inner, j)?;
        point(&format!("target_journaled:{i}"))?;
    }
    j.phase = "committed".into();
    save(inner, j)?;
    point("journal_committed")?;
    Ok(())
}
fn cleanup(inner: &Inner, j: &Journal, point: Checkpoint<'_>) -> Result<()> {
    for (i, e) in j.entries.iter().enumerate() {
        if !e.changed {
            continue;
        }
        let (p, _) = parent(inner, e)?;
        let name = stage_name(j, i);
        let current = at_snapshot(&p, &name, inner.cfg.file_bytes)?;
        let expected = if j.phase == "preparing" {
            e.staged.as_ref()
        } else {
            e.before.as_ref()
        };
        if let Some(current) = current {
            ensure!(
                Some(&current) == expected,
                "staging/backup changed; left untouched for {}",
                e.path
            );
            ensure!(
                unsafe { libc::unlinkat(p.as_raw_fd(), name.as_ptr(), 0) } == 0,
                "cannot clean transaction stage"
            );
            point(&format!("stage_unlinked:{i}"))?;
        }
        p.sync_all()?;
        point(&format!("cleanup_parent_synced:{i}"))?;
    }
    Ok(())
}
fn receipt(inner: &Inner, j: &Journal, error: Option<&str>) -> Value {
    let mut applied = 0;
    let mut pending = 0;
    let mut conflicts = Vec::new();
    let mut changes = Vec::new();
    for (i, e) in j.entries.iter().enumerate() {
        if !e.changed {
            continue;
        }
        let state = if j.phase == "preparing" {
            "not_applied"
        } else {
            match inspect(inner, j, i) {
                Ok(State::Applied) => {
                    applied += 1;
                    "applied"
                }
                Ok(State::Pending) => {
                    pending += 1;
                    "not_applied"
                }
                _ => {
                    conflicts.push(e.path.clone());
                    "outcome_unknown"
                }
            }
        };
        changes.push(json!({"path":e.path,"state":state,"sha256":e.after_hash,"bytes":e.bytes,"deleted":e.after_hash.is_none()}));
    }
    let status = if !conflicts.is_empty() {
        "outcome_unknown"
    } else if j.phase == "preparing" {
        "aborted"
    } else if pending == 0 && j.phase == "committed" {
        "committed"
    } else if pending == 0 {
        "outcome_unknown"
    } else if applied > 0 {
        "partial"
    } else {
        "not_applied"
    };
    let mut value = json!({"transaction_id":j.id,"success":status=="committed","status":status,"phase":j.phase,"atomic_visibility":false,"changes":changes,"conflicts":conflicts,"notes":j.notes,"work_used":j.work_used,"recovery":"Never repeat an uncertain patch. Query mode=status; startup resumes only an intact durable commit intent. Detected conflicts stop recovery. Noncooperating concurrent writers can race filesystem operations; inspect retained backups after outcome_unknown."});
    if status == "committed" {
        if let Some(error) = error {
            value["cleanup_warning"] = json!(error);
        }
    } else {
        value["error"] = json!(error.unwrap_or("Transaction did not reach a verified durable committed outcome; inspect its receipt before any new action."));
    }
    value
}
fn complete(inner: &Inner, j: &Journal, point: Checkpoint<'_>) -> Result<Value> {
    cleanup(inner, j, point)?;
    let r = receipt(inner, j, None);
    finish(inner, j, &r)?;
    point("receipt_finalized")?;
    Ok(r)
}
/// Startup is under the existing exclusive service lock. Recovery never acquires
/// another approval and cannot create a new intent: only a previously consumed,
/// durable intent can continue. No workspace effect is attempted after conflict.
pub(super) fn recover(inner: &Inner) -> Result<()> {
    init(inner)?;
    let _guard = inner.mutation.lock().unwrap();
    let Some(mut j) = load(inner)? else {
        return Ok(());
    };
    let mut point = |_: &str| Ok(());
    let recovery = (|| -> Result<()> {
        if j.phase == "committing" {
            ensure!(
                inner.cfg.write != Permission::Deny,
                "write policy denies forward recovery"
            );
            apply(inner, &mut j, &mut point)?;
        }
        // Committed recovery only removes exact owned backups. It does not touch
        // final files even if they have since changed externally.
        complete(inner, &j, &mut point)?;
        Ok(())
    })();
    // Keep an unresolved bounded journal rather than failing startup/read access.
    // Its live status includes fresh conflicts and blocks new file mutations.
    if recovery.is_err() {
        return Ok(());
    }
    Ok(())
}
impl LocalTools {
    pub(super) async fn patch_status(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["mode", "transaction_id"])?;
        ensure!(string(&args, "mode")? == "status", "invalid patch mode");
        let owner = scope(context)?;
        let id = args
            .get("transaction_id")
            .map(|v| v.as_str().context("transaction_id must be text"))
            .transpose()?
            .map(str::to_owned);
        if let Some(id) = &id {
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "invalid transaction ID");
        }
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move||{
            let _guard=inner.mutation.lock().unwrap();
            if let Some(j)=load(&inner)? && j.scope==owner && id.as_ref().is_none_or(|id|id==&j.id){let mut r=receipt(&inner,&j,Some("Unresolved transaction; further file writes are blocked until safe recovery or host reconciliation."));r["cleanup_pending"]=json!(true);return Ok(r);}
            let db=inner.db.lock().unwrap();
            let raw=if let Some(id)=id {db.query_row("SELECT body FROM local_v4a_receipts WHERE scope=?1 AND id=?2",params![owner,id],|r|r.get::<_,String>(0)).optional()?}else{db.query_row("SELECT body FROM local_v4a_receipts WHERE scope=?1 ORDER BY sequence DESC LIMIT 1",[owner],|r|r.get::<_,String>(0)).optional()?};
            Ok(match raw {Some(raw)=>serde_json::from_str(&raw)?,None=>json!({"status":"not_found","retention_limit":RECEIPTS})})
        }).await?
    }
    pub(super) async fn patch_v4a(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["mode", "patch"])?;
        if let Some(mode) = args.get("mode") {
            ensure!(mode.as_str() == Some("patch"), "V4A requires mode=patch");
        }
        let patch = string(&args, "patch")?.to_owned();
        let owner = self.read_scope(context)?;
        let execution = self.execution_scope(context)?;
        let receipt_scope = scope(context)?;
        ensure!(
            self.inner.cfg.write != Permission::Deny,
            "action denied by host configuration"
        );
        let tool = self.clone();
        let o = owner.clone();
        let mut prepared = tokio::task::spawn_blocking(move || {
            let _guard = tool.inner.mutation.lock().unwrap();
            prepare(&tool.inner, &patch, &o, &tool)
        })
        .await??;
        prepared.journal.generation = execution.generation;
        prepared.journal.call_id = execution.call_id;
        prepared.journal.scope = receipt_scope;
        prepared.action = self.action("patch", &prepared.action["arguments"]);
        let mut permit = self
            .authorize(
                self.inner.cfg.write,
                context,
                &prepared.action,
                &prepared.display,
            )
            .await?;
        let ctx = context.clone();
        let inner = self.inner.clone();
        let artifacts = if self.inner.outputs.is_some() {
            prepared.bytes.clone()
        } else {
            BTreeMap::new()
        };
        let mut result = tokio::task::spawn_blocking(move || -> Result<Value> {
            let _guard = inner.mutation.lock().unwrap();
            ensure_ready(&inner)?;
            verify_originals(&inner, &prepared.journal)?;
            let mut point = |_: &str| Ok(());
            let execution = (|| -> Result<Value> {
                create_stages(&inner, &mut prepared, &mut point)?;
                verify_originals(&inner, &prepared.journal)?;
                for i in 0..prepared.journal.entries.len() {
                    inspect(&inner, &prepared.journal, i)?;
                }
                let _fence = permit.verify(&ctx, &prepared.action)?;
                prepared.journal.phase = "committing".into();
                save(&inner, &prepared.journal)?;
                point("commit_intent_journaled")?;
                apply(&inner, &mut prepared.journal, &mut point)?;
                complete(&inner, &prepared.journal, &mut point)
            })();
            match execution {
                Ok(value) => {
                    let mut reads = inner.reads.lock().unwrap();
                    for e in &prepared.journal.entries {
                        if e.changed {
                            reads.remove(&(owner.clone(), e.path.clone()));
                            if let Some(s) = &e.staged {
                                reads.insert(
                                    (owner.clone(), e.path.clone()),
                                    Snapshot {
                                        hash: s.hash.clone(),
                                        inode: s.inode,
                                        device: s.device,
                                    },
                                );
                            }
                        }
                    }
                    Ok(value)
                }
                Err(error) => {
                    // Pre-intent failures cannot have target effects. Cleanup may
                    // fail closed, but never upgrades the failure to success.
                    let persisted = load(&inner)?;
                    if let Some(j) = persisted {
                        let mut value = receipt(&inner, &j, Some(&error.to_string()));
                        if j.phase == "preparing" && cleanup(&inner, &j, &mut point).is_ok() {
                            finish(&inner, &j, &value)?;
                        } else {
                            value["cleanup_pending"] = json!(true);
                        }
                        Ok(value)
                    } else {
                        Err(error)
                    }
                }
            }
        })
        .await??;
        // Only a fully committed transaction exports generated final contents.
        // A registration error cannot turn committed effects into a retry request.
        if result["success"] == true
            && let Some(outputs) = &self.inner.outputs
        {
            let id = result["transaction_id"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            let mut registered = Vec::new();
            let mut failures = Vec::new();
            for (path, bytes) in artifacts {
                let registered_one = async {
                    let temp = PrivateSnapshot::new(
                        self.inner.cfg.state_database.parent().unwrap(),
                        &bytes,
                    )?;
                    outputs
                        .register_tool_artifact(
                            &OutputScope {
                                conversation_id: context.conversation_id.clone(),
                                input_id: context.input_id.clone(),
                            },
                            &format!("local-v4a:{id}:{}", hash(path.as_bytes())),
                            &temp.0,
                            Path::new(&path).file_name().and_then(|s| s.to_str()),
                            "text/plain",
                        )
                        .await
                }
                .await;
                match registered_one {Ok(artifact)=>registered.push(json!({"path":path,"artifact":artifact,"media_reference":format!("artifact://{}",artifact.artifact_id)})),Err(_)=>failures.push(path)}
            }
            result["artifacts"] = json!(registered);
            if !failures.is_empty() {
                result["artifact_error"] = json!({"paths":failures,"message":"Transaction committed; artifact registration failed. Do not repeat the patch."});
            }
        }
        Ok(result)
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    static TEST_GATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    const MIXED: &str = "*** Update File: a\n@@\n-old\n+new\n*** Move File: b -> moved\n*** Delete File: c\n*** Add File: added\n+created";
    fn config(d: &tempfile::TempDir) -> LocalToolsConfig {
        let mut c = LocalToolsConfig::new(
            "fault-owner".into(),
            d.path().join("root"),
            d.path().join("state.sqlite"),
        );
        c.write = Permission::Allow;
        c
    }
    async fn fixture() -> Result<(tempfile::TempDir, LocalTools, Prepared)> {
        let d = tempfile::tempdir()?;
        fs::create_dir(d.path().join("root"))?;
        for (n, s) in [("a", "old\n"), ("b", "move\n"), ("c", "delete\n")] {
            fs::write(d.path().join("root").join(n), s)?;
        }
        let t = LocalTools::open(config(&d), None, None).await?;
        for n in ["a", "b", "c"] {
            let s = snapshot(&t.inner.root, n, t.inner.cfg.file_bytes)?.1;
            t.inner
                .reads
                .lock()
                .unwrap()
                .insert(("fault-scope".into(), n.into()), s);
        }
        let p = prepare(&t.inner, MIXED, "fault-scope", &t)?;
        Ok((d, t, p))
    }
    fn drive(inner: &Inner, p: &mut Prepared, point: Checkpoint<'_>) -> Result<Value> {
        verify_originals(inner, &p.journal)?;
        create_stages(inner, p, point)?;
        verify_originals(inner, &p.journal)?;
        for i in 0..p.journal.entries.len() {
            inspect(inner, &p.journal, i)?;
        }
        p.journal.phase = "committing".into();
        save(inner, &p.journal)?;
        point("commit_intent_journaled")?;
        apply(inner, &mut p.journal, point)?;
        complete(inner, &p.journal, point)
    }
    fn expected(d: &tempfile::TempDir, after: bool) -> Result<()> {
        let r = d.path().join("root");
        assert_eq!(
            fs::read_to_string(r.join("a"))?,
            if after { "new\n" } else { "old\n" }
        );
        if after {
            assert!(!r.join("b").exists() && !r.join("c").exists());
            assert_eq!(fs::read_to_string(r.join("moved"))?, "move\n");
            assert_eq!(fs::read_to_string(r.join("added"))?, "created");
        } else {
            assert_eq!(fs::read_to_string(r.join("b"))?, "move\n");
            assert_eq!(fs::read_to_string(r.join("c"))?, "delete\n");
            assert!(!r.join("moved").exists() && !r.join("added").exists());
        }
        assert!(
            !fs::read_dir(&r)?.any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(PREFIX))
        );
        Ok(())
    }
    #[tokio::test]
    async fn restart_after_every_durability_point_is_idempotent() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        let (d, t, mut p) = fixture().await?;
        let mut points = Vec::new();
        drive(&t.inner, &mut p, &mut |name| {
            points.push(name.to_owned());
            Ok(())
        })?;
        drop(t);
        drop(d);
        assert!(points.len() > 30);
        println!(
            "{}",
            json!({"v4a_fault_checkpoint_count":points.len(),"checkpoints":points})
        );
        for fail in points {
            let (d, t, mut p) = fixture().await?;
            let mut fired = false;
            assert!(
                drive(&t.inner, &mut p, &mut |name| {
                    if name == fail {
                        fired = true;
                        bail!("simulated abrupt process loss at {name}");
                    }
                    Ok(())
                })
                .is_err()
            );
            assert!(fired, "{fail}");
            if let Some(j) = load(&t.inner)?
                && j.phase != "committed"
            {
                assert_ne!(
                    receipt(&t.inner, &j, None)["success"],
                    true,
                    "unfinalized intent: {fail}"
                );
            }
            let intent = p.journal.phase != "preparing";
            drop(t);
            let reopened = LocalTools::open(config(&d), None, None).await?;
            assert!(load(&reopened.inner)?.is_none(), "{fail}");
            expected(&d, intent)?;
            drop(reopened);
            let reopened = LocalTools::open(config(&d), None, None).await?;
            assert!(load(&reopened.inner)?.is_none(), "second restart {fail}");
            expected(&d, intent)?;
        }
        Ok(())
    }
    #[tokio::test]
    async fn external_mutation_before_recovery_never_overwritten() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        for fail in [
            "commit_intent_journaled",
            "target_renamed:0",
            "target_journaled:0",
            "journal_committed",
        ] {
            let (d, t, mut p) = fixture().await?;
            assert!(
                drive(&t.inner, &mut p, &mut |name| {
                    if name == fail {
                        bail!("crash");
                    }
                    Ok(())
                })
                .is_err()
            );
            // In-place edit keeps inode but hash changes; recovery must not infer
            // ownership merely from names, inode or successful earlier rename.
            fs::write(d.path().join("root/a"), "external surviving content")?;
            drop(t);
            let reopened = LocalTools::open(config(&d), None, None).await?;
            assert_eq!(
                fs::read_to_string(d.path().join("root/a"))?,
                "external surviving content"
            );
            if fail != "journal_committed" {
                let j = load(&reopened.inner)?.context("unresolved journal required")?;
                assert_eq!(
                    receipt(&reopened.inner, &j, None)["status"],
                    "outcome_unknown"
                );
                assert!(ensure_ready(&reopened.inner).is_err());
                assert_eq!(fs::read_to_string(d.path().join("root/b"))?, "move\n");
            }
        }
        Ok(())
    }
    #[tokio::test]
    async fn changed_stage_parent_symlink_and_hardlink_block_recovery() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        for kind in [
            "stage",
            "parent",
            "symlink",
            "hardlink",
            "absent_destination",
        ] {
            let (d, t, mut p) = fixture().await?;
            assert!(
                drive(&t.inner, &mut p, &mut |name| {
                    if name == "commit_intent_journaled" {
                        bail!("crash");
                    }
                    Ok(())
                })
                .is_err()
            );
            let root = d.path().join("root");
            let saved = root.join(stage_name(&p.journal, 0).to_str().unwrap());
            match kind {
                "stage" => fs::write(&saved, "external stage data")?,
                "parent" => {
                    fs::rename(&root, d.path().join("moved-root"))?;
                    fs::create_dir(&root)?;
                    fs::write(root.join("a"), "replacement root")?;
                }
                "symlink" => {
                    fs::remove_file(root.join("a"))?;
                    std::os::unix::fs::symlink("b", root.join("a"))?;
                }
                "hardlink" => fs::hard_link(root.join("a"), root.join("alias"))?,
                "absent_destination" => {
                    fs::write(root.join("added"), "external occupied destination")?
                }
                _ => unreachable!(),
            }
            drop(t);
            let reopened = LocalTools::open(config(&d), None, None).await?;
            let j = load(&reopened.inner)?.context(kind.to_owned())?;
            assert_eq!(
                receipt(&reopened.inner, &j, None)["status"],
                "outcome_unknown",
                "{kind}"
            );
            assert!(ensure_ready(&reopened.inner).is_err());
            if kind == "stage" {
                assert_eq!(fs::read_to_string(saved)?, "external stage data");
            }
            if kind == "absent_destination" {
                assert_eq!(
                    fs::read_to_string(root.join("added"))?,
                    "external occupied destination"
                );
            }
        }
        Ok(())
    }
    #[tokio::test]
    async fn conflict_after_first_rename_reports_partial_and_does_not_touch_rest() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        let (d, t, mut p) = fixture().await?;
        let root = d.path().join("root");
        let r = drive(&t.inner, &mut p, &mut |name| {
            if name == "target_journaled:0" {
                fs::write(root.join("b"), "outside")?;
            }
            Ok(())
        });
        assert!(r.is_err());
        let j = load(&t.inner)?.unwrap();
        let r = receipt(&t.inner, &j, None);
        assert_eq!(r["status"], "outcome_unknown");
        assert_eq!(r["changes"][0]["state"], "applied");
        assert_eq!(fs::read_to_string(root.join("a"))?, "new\n");
        assert_eq!(fs::read_to_string(root.join("b"))?, "outside");
        assert_eq!(fs::read_to_string(root.join("c"))?, "delete\n");
        drop(t);
        let t = LocalTools::open(config(&d), None, None).await?;
        assert!(load(&t.inner)?.is_some());
        assert_eq!(fs::read_to_string(root.join("b"))?, "outside");
        Ok(())
    }
    #[tokio::test]
    async fn preintent_stage_collision_is_left_untouched_and_bounded() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        let (d, t, mut p) = fixture().await?;
        let stage = d
            .path()
            .join("root")
            .join(stage_name(&p.journal, 0).to_str().unwrap());
        fs::write(&stage, "not ours")?;
        assert!(drive(&t.inner, &mut p, &mut |_| Ok(())).is_err());
        assert_eq!(fs::read_to_string(&stage)?, "not ours");
        drop(t);
        let t = LocalTools::open(config(&d), None, None).await?;
        assert!(load(&t.inner)?.is_some());
        assert!(ensure_ready(&t.inner).is_err());
        assert_eq!(fs::read_to_string(&stage)?, "not ours");
        assert_eq!(fs::read_to_string(d.path().join("root/a"))?, "old\n");
        Ok(())
    }
    #[tokio::test]
    async fn pre_rename_writer_race_retains_displaced_external_bytes() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        for index in [0, 2] {
            let (d, t, mut p) = fixture().await?;
            let path = p.journal.entries[index].path.clone();
            assert!(
                drive(&t.inner, &mut p, &mut |name| {
                    if name == format!("before_target_rename:{index}") {
                        fs::write(
                            d.path().join("root").join(&path),
                            "external concurrent edit",
                        )?;
                    }
                    Ok(())
                })
                .is_err()
            );
            let backup = d
                .path()
                .join("root")
                .join(stage_name(&p.journal, index).to_str().unwrap());
            assert_eq!(fs::read_to_string(&backup)?, "external concurrent edit");
            let j = load(&t.inner)?.unwrap();
            assert_eq!(receipt(&t.inner, &j, None)["status"], "outcome_unknown");
            drop(t);
            let t = LocalTools::open(config(&d), None, None).await?;
            assert!(load(&t.inner)?.is_some());
            assert_eq!(fs::read_to_string(&backup)?, "external concurrent edit");
        }
        Ok(())
    }
    #[tokio::test]
    async fn deny_policy_on_restart_does_not_resume_commit_intent() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        let (d, t, mut p) = fixture().await?;
        assert!(
            drive(&t.inner, &mut p, &mut |name| {
                if name == "commit_intent_journaled" {
                    bail!("crash");
                }
                Ok(())
            })
            .is_err()
        );
        drop(t);
        let mut c = config(&d);
        c.write = Permission::Deny;
        let t = LocalTools::open(c, None, None).await?;
        assert!(load(&t.inner)?.is_some());
        assert_eq!(fs::read_to_string(d.path().join("root/a"))?, "old\n");
        Ok(())
    }
    #[test]
    fn crash_child_entry() -> Result<()> {
        let Some(dir) = std::env::var_os("HERMES_V4A_TEST_CRASH_DIR") else {
            return Ok(());
        };
        let fail = std::env::var("HERMES_V4A_TEST_CRASH_POINT")?;
        let dir = PathBuf::from(dir);
        let rt = tokio::runtime::Runtime::new()?;
        rt.block_on(async move {
            let mut c = LocalToolsConfig::new(
                "fault-owner".into(),
                dir.join("root"),
                dir.join("state.sqlite"),
            );
            c.write = Permission::Allow;
            let t = LocalTools::open(c, None, None).await?;
            for n in ["a", "b", "c"] {
                let snap = snapshot(&t.inner.root, n, t.inner.cfg.file_bytes)?.1;
                t.inner
                    .reads
                    .lock()
                    .unwrap()
                    .insert(("fault-scope".into(), n.into()), snap);
            }
            let mut p = prepare(&t.inner, MIXED, "fault-scope", &t)?;
            drive(&t.inner, &mut p, &mut |name| {
                if name == fail {
                    unsafe { libc::_exit(93) }
                }
                Ok(())
            })?;
            anyhow::bail!("crash point did not fire")
        })
    }
    #[tokio::test]
    async fn real_process_exit_without_destructors_recovers() -> Result<()> {
        let _serial = TEST_GATE.lock().await;
        for point in [
            "journal_preparing",
            "stage_identity_journaled:0",
            "stage_linked:0",
            "commit_intent_journaled",
            "target_renamed:0",
            "target_journaled:0",
            "journal_committed",
            "stage_unlinked:0",
            "receipt_finalized",
        ] {
            let (d, t, _) = fixture().await?;
            drop(t);
            let status = std::process::Command::new(std::env::current_exe()?)
                .args([
                    "--exact",
                    "local_tools::v4a::tests::crash_child_entry",
                    "--nocapture",
                ])
                .env("HERMES_V4A_TEST_CRASH_DIR", d.path())
                .env("HERMES_V4A_TEST_CRASH_POINT", point)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            assert_eq!(status.code(), Some(93), "{point}");
            let t = LocalTools::open(config(&d), None, None).await?;
            assert!(load(&t.inner)?.is_none(), "{point}");
            expected(
                &d,
                !point.starts_with("stage_identity")
                    && !point.starts_with("stage_linked")
                    && point != "journal_preparing",
            )?;
        }
        Ok(())
    }
}
