//! Opt-in, owner-bound local host tools. Files are FD-rooted; commands require an
//! explicit executable map and a real Linux bubblewrap + seccomp boundary.
#![cfg(unix)]
mod file_read;
mod file_search;
#[cfg(test)]
mod generation_tests;
mod persistent;
mod python_clean;
mod python_output;
mod skills;
mod v4a;
pub use persistent::PythonBridge;
tokio::task_local! {
    static PYTHON_CELL_RETIRED: Arc<AtomicBool>;
    static LOCAL_EXECUTION: LocalExecution;
}

use crate::{
    interactions::{ApprovalPermit, InteractionHub},
    output_files::{OutputFiles, OutputScope},
    tool_runtime::{ToolExecutor, TurnContext},
    workspace::ProtectedRoot,
};
use anyhow::{Context, Result, bail, ensure};
use futures_util::future::BoxFuture;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, OpenOptionsExt},
            process::CommandExt,
        },
    },
    path::{Component, Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    Deny,
    #[default]
    Ask,
    Allow,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Program {
    pub name: String,
    pub executable: PathBuf,
}
#[derive(Clone, Debug)]
pub struct LocalToolsConfig {
    pub owner: String,
    pub root: PathBuf,
    pub state_database: PathBuf,
    pub write: Permission,
    pub execute: Permission,
    pub programs: Vec<Program>,
    pub sandbox: PathBuf,
    pub runtime_roots: Vec<PathBuf>,
    pub python_program: Option<String>,
    pub skills_root: Option<String>,
    pub timeout: Duration,
    pub max_timeout: Duration,
    pub output_bytes: usize,
    pub file_bytes: usize,
    pub max_processes: usize,
    pub python_idle_timeout: Duration,
    pub python_max_cells: usize,
    pub python_max_tool_calls: usize,
    /// Maximum retained positive generation fences. Generation zero is implicit.
    /// Exhaustion during reset fails closed for all untracked sessions until reopen.
    pub max_session_routes: usize,
}
impl LocalToolsConfig {
    pub fn new(owner: String, root: PathBuf, state_database: PathBuf) -> Self {
        Self {
            owner,
            root,
            state_database,
            write: Permission::Ask,
            execute: Permission::Ask,
            programs: vec![],
            sandbox: PathBuf::from("/usr/bin/bwrap"),
            runtime_roots: vec![
                "/usr/bin".into(),
                "/usr/lib".into(),
                "/bin".into(),
                "/lib".into(),
                "/lib64".into(),
            ],
            python_program: None,
            skills_root: None,
            timeout: Duration::from_secs(30),
            max_timeout: Duration::from_secs(600),
            output_bytes: 256 * 1024,
            file_bytes: 1024 * 1024,
            max_processes: 4,
            python_idle_timeout: Duration::from_secs(1800),
            python_max_cells: 1000,
            python_max_tool_calls: 50,
            max_session_routes: 4096,
        }
    }
}
#[derive(Clone)]
pub struct LocalTools {
    inner: Arc<Inner>,
}
struct Inner {
    cfg: LocalToolsConfig,
    root: ProtectedRoot,
    root_id: String,
    db: Mutex<Connection>,
    _lock: File,
    hub: Option<InteractionHub>,
    outputs: Option<OutputFiles>,
    mutation: Mutex<()>,
    effects: Arc<tokio::sync::RwLock<()>>,
    reads: Mutex<HashMap<(String, String), Snapshot>>,
    read_windows: Mutex<HashMap<(String, String), (Snapshot, usize)>>,
    processes: Mutex<HashMap<String, Arc<Process>>>,
    execution_slots: Arc<tokio::sync::Semaphore>,
    python: persistent::Kernels,
    python_bridge: Option<PythonBridge>,
}
#[derive(Clone, PartialEq, Eq)]
struct Snapshot {
    hash: String,
    inode: u64,
    device: u64,
}
struct Process {
    id: String,
    conversation: String,
    session: String,
    child: Mutex<Option<Child>>,
    output: Mutex<VecDeque<u8>>,
    done: AtomicBool,
    exit: Mutex<Option<i32>>,
    timed_out: AtomicBool,
    monitor_failed: AtomicBool,
    limit: usize,
    slot: Mutex<Option<tokio::sync::OwnedSemaphorePermit>>,
}
impl Process {
    fn stop(&self) {
        if let Ok(mut child) = self.child.lock()
            && let Some(child) = child.as_mut()
        {
            kill_owned_child(child);
        }
    }
    fn value(&self) -> Value {
        let output = self
            .output
            .lock()
            .unwrap()
            .iter()
            .copied()
            .collect::<Vec<_>>();
        let mut value = json!({"session_id":self.id,"status":if self.monitor_failed.load(Ordering::Acquire){"outcome_unknown"}else if self.done.load(Ordering::Acquire){"exited"}else{"running"},"exit_code":*self.exit.lock().unwrap(),"timed_out":self.timed_out.load(Ordering::Acquire),"output":bounded_utf8_tail(&output,self.limit),"output_is_bounded_tail":true});
        if self.monitor_failed.load(Ordering::Acquire) {
            value["error"] = json!(
                "Process supervision failed. Inspect workspace before retrying; no automatic rerun."
            );
        }
        value
    }
}
/// Immutable host identity, captured before approval or blocking-worker dispatch.
#[derive(Clone)]
pub(super) struct LocalExecution {
    pub(super) generation: i64,
    pub(super) call_id: String,
    conversation: String,
    session: String,
    input: String,
    retired: Arc<AtomicBool>,
}
impl LocalExecution {
    fn new(context: &TurnContext, generation: i64, call_id: String) -> Result<Self> {
        scope(context)?;
        ensure!(generation >= 0 && !call_id.is_empty() && call_id.len() <= 1024
            && !call_id.chars().any(char::is_control), "invalid local execution identity");
        Ok(Self { generation, call_id, conversation: context.conversation_id.clone(),
            session: context.session_id.clone(), input: context.input_id.clone(), retired: Arc::new(AtomicBool::new(false)) })
    }
    fn matches(&self, context: &TurnContext) -> bool {
        self.conversation == context.conversation_id && self.session == context.session_id
            && self.input == context.input_id
    }
}
struct RetireExecution(Arc<AtomicBool>);
impl Drop for RetireExecution {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
struct Grant {
    inner: Arc<Inner>,
    execution: LocalExecution,
    permit: Option<ApprovalPermit>,
    retired: Option<Arc<AtomicBool>>,
    consumed: bool,
    fence: Option<tokio::sync::OwnedRwLockReadGuard<()>>,
}
impl Grant {
    /// Retain the returned fence until the effect or durable commit intent is
    /// committed. It also survives spawn_blocking: no task-local lookup here.
    fn verify(&mut self, context: &TurnContext, action: &Value) -> Result<tokio::sync::OwnedRwLockReadGuard<()>> {
        ensure!(!self.consumed && self.execution.matches(context), "local grant identity mismatch or already consumed");
        self.consumed = true;
        ensure!(!self.execution.retired.load(Ordering::Acquire), "local execution was cancelled");
        self.inner.python.check_generation(&self.execution.session, self.execution.generation)?;
        let fence = self.fence.take().context("local effect fence already consumed")?;
        if let Some(retired) = &self.retired {
            ensure!(!retired.load(Ordering::Acquire), "Python cell authority was retired");
        }
        if let Some(permit) = self.permit.take() {
            permit.verify(context, action)?;
        }
        if let Some(retired) = &self.retired {
            ensure!(!retired.load(Ordering::Acquire), "Python cell authority was retired");
        }
        Ok(fence)
    }
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn scope(context: &TurnContext) -> Result<String> {
    ensure!(
        !context.session_id.is_empty()
            && !context.conversation_id.is_empty()
            && !context.input_id.is_empty(),
        "trusted turn identity required"
    );
    Ok(hash(
        serde_json::to_string(&json!([context.conversation_id, context.session_id]))?.as_bytes(),
    ))
}
fn string<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args[key]
        .as_str()
        .with_context(|| format!("missing or invalid {key}"))
}
fn number(args: &Value, key: &str, default: usize, max: usize) -> Result<usize> {
    let n = match args.get(key) {
        None => default,
        Some(v) => v.as_u64().context("expected nonnegative integer")? as usize,
    };
    ensure!(n <= max, "argument exceeds configured bound");
    Ok(n)
}
fn known(args: &Value, keys: &[&str]) -> Result<()> {
    let obj = args.as_object().context("tool arguments must be object")?;
    ensure!(
        obj.keys().all(|k| keys.contains(&k.as_str())),
        "unsupported tool argument; consult the configured schema"
    );
    for (key, value) in obj {
        if [
            "path",
            "pattern",
            "target",
            "file_glob",
            "output_mode",
            "category",
            "name",
            "file_path",
            "content",
            "old_string",
            "new_string",
            "file_content",
            "id",
            "status",
            "parent",
            "action",
            "session_id",
            "data",
            "command",
            "code",
            "workdir",
        ]
        .contains(&key.as_str())
        {
            ensure!(value.is_string(), "text argument has wrong type");
        }
        if ["replace_all", "merge", "background", "reset"].contains(&key.as_str()) {
            ensure!(value.is_boolean(), "boolean argument has wrong type");
        }
        if ["offset", "limit", "context", "timeout"].contains(&key.as_str()) {
            ensure!(
                value.as_u64().is_some(),
                "numeric argument must be a nonnegative integer"
            );
        }
        if ["todos", "operations"].contains(&key.as_str()) {
            ensure!(value.is_array(), "list argument must be an array");
        }
    }
    Ok(())
}
fn rel(path: &str) -> Result<String> {
    ensure!(
        !path.starts_with(python_output::OUTPUT_PREFIX),
        "Python output references are read-only"
    );
    ensure!(
        path.len() <= 4096 && !path.contains('\0'),
        "invalid relative path"
    );
    let p = Path::new(path);
    ensure!(
        !p.is_absolute(),
        "paths must be relative to the configured root"
    );
    let mut names = Vec::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::Normal(n) => {
                let n = n.to_str().context("path must be UTF-8")?;
                ensure!(
                    ![".git", ".ssh", ".aws", ".codex", ".gnupg", "credentials"].contains(&n)
                        && ![
                            ".netrc",
                            ".npmrc",
                            ".kube",
                            ".config",
                            "id_rsa",
                            "id_ed25519",
                            "credentials.json"
                        ]
                        .contains(&n)
                        && !n.starts_with(".env")
                        && !n.starts_with(".hermes-v4a-"),
                    "protected private path is not exposed to model tools"
                );
                names.push(n)
            }
            _ => bail!("parent traversal is forbidden"),
        }
    }
    Ok(names.join("/"))
}
fn snapshot(root: &ProtectedRoot, path: &str, limit: usize) -> Result<(Vec<u8>, Snapshot)> {
    let mut file = root.open_file(path)?;
    let m = file.metadata()?;
    ensure!(
        m.is_file() && m.nlink() == 1,
        "file must be regular and not hard-linked"
    );
    ensure!(
        m.len() <= limit as u64,
        "file exceeds configured byte limit"
    );
    let mut data = Vec::new();
    Read::by_ref(&mut file)
        .take(limit as u64 + 1)
        .read_to_end(&mut data)?;
    ensure!(data.len() <= limit, "file grew beyond byte limit");
    let after = file.metadata()?;
    ensure!(
        after.ino() == m.ino()
            && after.len() == m.len()
            && after.mtime() == m.mtime()
            && after.mtime_nsec() == m.mtime_nsec(),
        "file changed while reading"
    );
    Ok((
        data.clone(),
        Snapshot {
            hash: hash(&data),
            inode: m.ino(),
            device: m.dev(),
        },
    ))
}

impl LocalTools {
    pub async fn open(
        config: LocalToolsConfig,
        hub: Option<InteractionHub>,
        outputs: Option<OutputFiles>,
    ) -> Result<Self> {
        Self::open_with_python_bridge(config, hub, outputs, None).await
    }
    /// Extension is selected only by trusted host configuration before any cells run.
    pub async fn open_with_python_bridge(
        config: LocalToolsConfig,
        hub: Option<InteractionHub>,
        outputs: Option<OutputFiles>,
        python_bridge: Option<PythonBridge>,
    ) -> Result<Self> {
        ensure!(
            !config.python_idle_timeout.is_zero()
                && config.python_idle_timeout <= Duration::from_secs(3600)
                && (1..=10000).contains(&config.python_max_cells)
                && (1..=100).contains(&config.python_max_tool_calls)
                && (1..=100_000).contains(&config.max_session_routes),
            "invalid persistent Python limits"
        );
        ensure!(
            !config.owner.trim().is_empty() && config.owner.len() <= 512,
            "trusted owner required"
        );
        ensure!(
            config.file_bytes > 0
                && config.file_bytes <= 16 * 1024 * 1024
                && config.output_bytes >= 1024
                && config.output_bytes <= 1024 * 1024,
            "invalid local tool byte limits"
        );
        ensure!(
            !config.timeout.is_zero()
                && config.timeout <= config.max_timeout
                && config.max_timeout <= Duration::from_secs(3600)
                && config.max_processes > 0
                && config.max_processes <= 16,
            "invalid process limits"
        );
        let prepared=tokio::task::spawn_blocking(move||->Result<_>{
            ensure!(config.root.is_absolute(),"explicit absolute root required");let root=ProtectedRoot::new(&config.root)?;let canonical=fs::canonicalize(&config.root)?;
            rel(canonical.to_str().context("workspace root must be UTF-8")?.trim_start_matches('/')).context("private path cannot be a model workspace root")?;
            ensure!(!["/etc","/proc","/sys","/dev","/usr","/bin","/sbin","/lib","/lib64"].iter().any(|p|canonical.starts_with(p)),"system/private directories cannot be model workspaces");
            if let Some(home)=std::env::var_os("HOME"){ensure!(!Path::new(&home).starts_with(&canonical),"home directory or its ancestors cannot be model workspaces");}
            ensure!(!fs::canonicalize(config.state_database.parent().context("state database parent missing")?)?.starts_with(&canonical),"private state database must be outside model workspace");
            let mut programs=std::collections::HashSet::new();for p in &config.programs{ensure!(!p.name.is_empty()&&p.name.bytes().all(|c|c.is_ascii_alphanumeric()||b"_-".contains(&c))&&programs.insert(p.name.clone()),"invalid or duplicate program alias");ensure!(p.executable.is_absolute()&&p.executable.is_file(),"program must be an existing absolute executable");}
            if let Some(python)=&config.python_program {ensure!(programs.contains(python),"Python runtime alias is not configured");}
            if let Some(skills)=&config.skills_root{root.open_dir(&rel(skills)?)?;}
            let mut lock_options=OpenOptions::new();lock_options.read(true).write(true).create(true).mode(0o600).custom_flags(libc::O_NOFOLLOW|libc::O_CLOEXEC);
            let lock=lock_options.open(config.state_database.with_extension("local.lock"))?;ensure!(unsafe{libc::flock(lock.as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB)}==0,"local tools already own this state database");
            let mut db=crate::private_db::open_private(&config.state_database)?;db.busy_timeout(Duration::from_secs(5))?;
            db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS local_owner(id INTEGER PRIMARY KEY CHECK(id=1),digest TEXT NOT NULL); CREATE TABLE IF NOT EXISTS local_todos(scope TEXT PRIMARY KEY,body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS local_skills(name TEXT NOT NULL,path TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(name,path)); CREATE TABLE IF NOT EXISTS local_skill_tombstones(name TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS local_processes(id TEXT PRIMARY KEY,conversation TEXT NOT NULL,session TEXT NOT NULL,result TEXT NOT NULL);")?;
            let identity=hash(serde_json::to_string(&json!([config.owner,canonical]))?.as_bytes());let tx=db.transaction()?;
            if let Some(old)=tx.query_row("SELECT digest FROM local_owner WHERE id=1",[],|r|r.get::<_,String>(0)).optional()?{ensure!(old==identity,"local state belongs to another owner or root");}else{tx.execute("INSERT INTO local_owner VALUES(1,?1)",[&identity])?;}
            tx.execute("UPDATE local_processes SET result=json_set(result,'$.status','outcome_unknown','$.recovery','Host restarted; never automatically re-run this process') WHERE json_extract(result,'$.status')='running'",[])?;tx.commit()?;
            Ok((config,root,identity,db,lock))
        }).await??;
        let execution_slots = Arc::new(tokio::sync::Semaphore::new(prepared.0.max_processes));
        let tools = Self {
            inner: Arc::new(Inner {
                cfg: prepared.0,
                root: prepared.1,
                root_id: prepared.2,
                db: Mutex::new(prepared.3),
                _lock: prepared.4,
                hub,
                outputs,
                mutation: Mutex::new(()),
                effects: Arc::new(tokio::sync::RwLock::new(())),
                reads: Mutex::new(HashMap::new()),
                read_windows: Mutex::new(HashMap::new()),
                processes: Mutex::new(HashMap::new()),
                execution_slots,
                python: persistent::Kernels::default(),
                python_bridge,
            }),
        };
        let recovery = tools.inner.clone();
        tokio::task::spawn_blocking(move || v4a::recover(&recovery)).await??;
        // Configuration is immutable. Without a Python program no kernel child
        // can be created or retired, so no idle reaper thread is needed.
        if tools.inner.cfg.python_program.is_some() {
            persistent::start_reaper(&tools.inner)?;
        }
        Ok(tools)
    }
    async fn authorize(
        &self,
        permission: Permission,
        context: &TurnContext,
        action: &Value,
        display: &str,
    ) -> Result<Grant> {
        let execution = self.execution_scope(context)?;
        let retired = PYTHON_CELL_RETIRED.try_with(Arc::clone).ok();
        let permit = match permission {
            Permission::Deny => bail!("action denied by host configuration"),
            Permission::Allow => None,
            Permission::Ask => Some(self.inner.hub.as_ref().context("this write/execution requires an approval channel")?
                .approve(context, action, display, "One exact local action inside the explicitly configured workspace. This permission does not enable other actions.").await?),
        };
        // Queue without blocking a runtime thread. The epoch is checked after
        // admission and again at the effect, including after spawn_blocking.
        let fence = self.inner.effects.clone().read_owned().await;
        self.inner.python.check_generation(&execution.session, execution.generation)?;
        Ok(Grant { inner: self.inner.clone(), execution, permit, retired, consumed: false, fence: Some(fence) })
    }
    pub(super) fn execution_scope(&self, context: &TurnContext) -> Result<LocalExecution> {
        let execution = LOCAL_EXECUTION.try_with(Clone::clone)
            .context("local tools require a trusted execution scope")?;
        ensure!(execution.matches(context) && !execution.retired.load(Ordering::Acquire), "local execution context changed or cancelled");
        self.inner.python.check_generation(&execution.session, execution.generation)?;
        Ok(execution)
    }
    pub(super) fn read_scope(&self, context: &TurnContext) -> Result<String> {
        let execution = self.execution_scope(context)?;
        Ok(hash(serde_json::to_string(&json!([
            context.conversation_id, context.session_id, execution.generation
        ]))?.as_bytes()))
    }

    fn action(&self, tool: &str, args: &Value) -> Value {
        let identity = LOCAL_EXECUTION.try_with(|e| json!({"generation":e.generation,"call_id":e.call_id})).unwrap_or(Value::Null);
        json!({"tool":tool,"root":self.inner.root_id,"arguments":args,"execution":identity})
    }
    pub async fn cancel_conversation(&self, conversation: &str) {
        self.inner.python.cancel(Some(conversation));
        if let Some(hub) = &self.inner.hub {
            hub.cancel_conversation(conversation);
        }
        let processes = self
            .inner
            .processes
            .lock()
            .unwrap()
            .values()
            .filter(|p| p.conversation == conversation)
            .cloned()
            .collect::<Vec<_>>();
        for p in processes {
            p.stop();
        }
    }
    pub async fn shutdown(&self) {
        self.inner.python.close();
        let processes = self
            .inner
            .processes
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for p in &processes {
            p.stop();
        }
        for _ in 0..100 {
            if processes.iter().all(|p| p.done.load(Ordering::Acquire))
                && self.inner.python.is_reaped()
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
    async fn read_file(&self, args: Value, context: &TurnContext) -> Result<Value> {
        file_read::read(self, args, context).await
    }
    async fn write_file(&self, args: Value, context: &TurnContext, patch: bool) -> Result<Value> {
        known(
            &args,
            if patch {
                &["mode", "path", "old_string", "new_string", "replace_all"]
            } else {
                &["path", "content"]
            },
        )?;
        if patch && let Some(mode) = args.get("mode") {
            ensure!(mode.as_str() == Some("replace"), "invalid replace patch mode");
        }
        let path = rel(string(&args, "path")?)?;
        ensure!(!path.is_empty(), "file path required");
        let owner = self.read_scope(context)?;
        let inner = self.inner.clone();
        let p = path.clone();
        let a = args.clone();
        let o = owner.clone();
        let (bytes, expected, patch_metadata) = tokio::task::spawn_blocking(move || -> Result<_> {
            let _lock = inner.mutation.lock().unwrap();
            v4a::ensure_ready(&inner)?;
            let current = match snapshot(&inner.root, &p, inner.cfg.file_bytes) {
                Ok(v) => Some(v),
                Err(e) => {
                    if inner.root.open_parent(&p)?.0.metadata()?.is_dir()
                        && !relative_exists(&inner.root, &p)?
                    {
                        None
                    } else {
                        return Err(e);
                    }
                }
            };
            let expected = if let Some((_, actual)) = &current {
                let remembered = inner
                    .reads
                    .lock()
                    .unwrap()
                    .get(&(o, p.clone()))
                    .cloned()
                    .context("read the complete current file before replacing or patching it")?;
                ensure!(
                    &remembered == actual,
                    "file changed since complete read; read and merge again"
                );
                Some(actual.clone())
            } else {
                None
            };
            let mut patch_metadata = None;
            let text = if patch {
                let existing =
                    String::from_utf8(current.context("patch target does not exist")?.0)?;
                let old = string(&a, "old_string")?;
                let new = string(&a, "new_string")?;
                let all = a
                    .get("replace_all")
                    .map(|v| v.as_bool().context("replace_all must be boolean"))
                    .transpose()?
                    .unwrap_or(false);
                let limits = crate::file_patch::PatchLimits {
                    max_file_bytes: inner.cfg.file_bytes,
                    max_patch_bytes: inner.cfg.file_bytes,
                    ..Default::default()
                };
                let plan = crate::file_patch::plan_replace(&existing, old, new, all, &limits)?;
                patch_metadata = Some(json!({
                    "strategy": plan.strategy.name(),
                    "match_count": plan.match_count,
                    "notes": plan.notes,
                    "work_used": plan.work_used,
                }));
                plan.content
            } else {
                string(&a, "content")?.to_owned()
            };
            ensure!(
                text.len() <= inner.cfg.file_bytes,
                "write exceeds configured file byte limit"
            );
            Ok((text.into_bytes(), expected, patch_metadata))
        })
        .await??;
        let action=self.action(if patch{"patch"}else{"write_file"},&json!({"path":path,"old_sha256":expected.as_ref().map(|s|&s.hash),"new_sha256":hash(&bytes),"bytes":bytes.len()}));
        let mut display = format!(
            "{} {} ({} bytes)\n{}",
            if patch { "Patch" } else { "Write" },
            path,
            bytes.len(),
            String::from_utf8_lossy(&bytes)
                .chars()
                .take(4000)
                .collect::<String>()
        );
        if let Some(metadata) = &patch_metadata
            && let Some(notes) = metadata["notes"].as_array()
        {
            for note in notes.iter().filter_map(Value::as_str) {
                display.push('\n');
                display.push_str(note);
            }
        }
        let mut permit = self
            .authorize(self.inner.cfg.write, context, &action, &display)
            .await?;
        let ctx = context.clone();
        let inner = self.inner.clone();
        let p = path.clone();
        let data = bytes.clone();
        let digest = tokio::task::spawn_blocking(move || {
            let _lock = inner.mutation.lock().unwrap();
            v4a::ensure_ready(&inner)?;
            let _fence = permit.verify(&ctx, &action)?;
            let actual = if relative_exists(&inner.root, &p)? {
                Some(snapshot(&inner.root, &p, inner.cfg.file_bytes)?.1)
            } else {
                None
            };
            ensure!(
                actual == expected,
                "file changed while awaiting approval; no bytes written"
            );
            atomic_write(&inner.root, &p, &data)?;
            let verified = snapshot(&inner.root, &p, inner.cfg.file_bytes)?.1;
            ensure!(
                verified.hash == hash(&data),
                "written file changed before verification"
            );
            inner
                .reads
                .lock()
                .unwrap()
                .insert((owner, p), verified.clone());
            Ok::<_, anyhow::Error>(verified.hash)
        })
        .await??;
        let mut result =
            json!({"success":true,"path":path,"bytes":bytes.len(),"sha256":digest,"verified":true});
        if let Some(metadata) = patch_metadata {
            result["strategy"] = metadata["strategy"].clone();
            result["match_count"] = metadata["match_count"].clone();
            result["notes"] = metadata["notes"].clone();
        }
        if let Some(outputs) = &self.inner.outputs {
            // Export our exact generated bytes, not a model-selected host pathname.
            let registration = async {
                let temp =
                    PrivateSnapshot::new(self.inner.cfg.state_database.parent().unwrap(), &bytes)?;
                let op = format!("local-write:{}:{}", hash(path.as_bytes()), digest);
                outputs
                    .register_tool_artifact(
                        &OutputScope {
                            conversation_id: context.conversation_id.clone(),
                            input_id: context.input_id.clone(),
                        },
                        &op,
                        &temp.0,
                        Path::new(&path).file_name().and_then(|s| s.to_str()),
                        "text/plain",
                    )
                    .await
            }
            .await;
            match registration {
                Ok(artifact) => {
                    result["artifact"] = serde_json::to_value(&artifact)?;
                    result["media_reference"] =
                        json!(format!("artifact://{}", artifact.artifact_id));
                }
                Err(_) => {
                    result["artifact_error"] = json!(
                        "File write succeeded, but artifact snapshot registration failed. Do not repeat the write; no upload or send occurred."
                    )
                }
            }
        }
        Ok(result)
    }
    async fn search_files(&self, args: Value) -> Result<Value> {
        file_search::search(self, args).await
    }
    async fn todo(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["todos", "merge"])?;
        let key = scope(context)?;
        let current = self
            .inner
            .db
            .lock()
            .unwrap()
            .query_row("SELECT body FROM local_todos WHERE scope=?1", [&key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .unwrap_or_else(|| "[]".into());
        let Some(incoming) = args.get("todos") else {
            return Ok(json!({"todos":serde_json::from_str::<Value>(&current)?}));
        };
        let mut next = if args["merge"] == true {
            serde_json::from_str::<Vec<Value>>(&current)?
        } else {
            vec![]
        };
        for item in incoming.as_array().context("todos must be array")? {
            known(item, &["id", "content", "status", "parent"])?;
            let id = string(item, "id")?;
            ensure!(
                !id.is_empty() && id.len() <= 128 && string(item, "content")?.len() <= 4000,
                "invalid todo item"
            );
            ensure!(
                ["pending", "in_progress", "completed", "cancelled"]
                    .contains(&string(item, "status")?),
                "invalid todo status"
            );
            if let Some(existing) = next.iter_mut().find(|v| v["id"] == id) {
                ensure!(args["merge"] == true, "duplicate todo id");
                *existing = item.clone();
            } else {
                next.push(item.clone());
            }
        }
        ensure!(
            next.len() <= 200 && next.iter().filter(|v| v["status"] == "in_progress").count() <= 1,
            "todo list requires at most 200 items and one in_progress"
        );
        for item in &next {
            let mut visited = std::collections::HashSet::new();
            let mut parent = item.get("parent");
            visited.insert(string(item, "id")?);
            while let Some(value) = parent {
                let id = value.as_str().context("parent must be an id string")?;
                ensure!(visited.insert(id), "todo parent cycle");
                let parent_item = next
                    .iter()
                    .find(|v| v["id"] == id)
                    .context("todo parent does not exist")?;
                parent = parent_item.get("parent");
            }
        }
        let body = serde_json::to_string(&next)?;
        let action = self.action(
            "todo_list",
            &json!({"scope":key,"old_sha256":hash(current.as_bytes()),"new_sha256":hash(body.as_bytes()),"item_count":next.len()}),
        );
        let mut grant = self
            .authorize(
                self.inner.cfg.write,
                context,
                &action,
                &format!(
                    "Update task list with {} items\n{}",
                    next.len(),
                    body.chars().take(4000).collect::<String>()
                ),
            )
            .await?;
        let inner = self.inner.clone();
        let context = context.clone();
        tokio::task::spawn_blocking(move||{let _fence=grant.verify(&context,&action)?;let mut db=inner.db.lock().unwrap();let tx=db.transaction()?;let actual=tx.query_row("SELECT body FROM local_todos WHERE scope=?1",[&key],|r|r.get::<_,String>(0)).optional()?.unwrap_or_else(||"[]".into());ensure!(actual==current,"todo list changed while awaiting approval");tx.execute("INSERT INTO local_todos(scope,body) VALUES(?1,?2) ON CONFLICT(scope) DO UPDATE SET body=excluded.body",params![key,body])?;tx.commit()?;Ok(json!({"todos":next}))}).await?
    }
    async fn terminal(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["command", "background", "timeout", "workdir"])?;
        scope(context)?;
        let words = split_command(string(&args, "command")?)?;
        ensure!(!words.is_empty(), "empty command");
        let (program, argv) = (words[0].clone(), words[1..].to_vec());
        let executable = self
            .inner
            .cfg
            .programs
            .iter()
            .find(|p| p.name == program)
            .context("program is not in the explicit host allowlist")?
            .executable
            .clone();
        let workdir = rel(args["workdir"].as_str().unwrap_or("."))?;
        self.inner.root.open_dir(&workdir)?;
        let timeout = number(
            &args,
            "timeout",
            self.inner.cfg.timeout.as_secs() as usize,
            self.inner.cfg.max_timeout.as_secs() as usize,
        )?;
        ensure!(timeout > 0, "timeout must be positive");
        let background = args
            .get("background")
            .map(|v| v.as_bool().context("background must be boolean"))
            .transpose()?
            .unwrap_or(false);
        let action=self.action("terminal",&json!({"program":program,"arguments":argv,"workdir":workdir,"timeout":timeout,"background":background,"workspace_access":if self.inner.cfg.write==Permission::Deny{"read_only"}else{"read_write"}}));
        let display = format!(
            "Run {} in /work/{} for at most {} seconds\n{}",
            program,
            workdir,
            timeout,
            argv.join(" ").chars().take(6000).collect::<String>()
        );
        let execution_permission = match (self.inner.cfg.execute, self.inner.cfg.write) {
            (Permission::Deny, _) => Permission::Deny,
            (_, Permission::Ask) => Permission::Ask,
            (permission, _) => permission,
        };
        let mut permit = self
            .authorize(execution_permission, context, &action, &display)
            .await?;
        let inner = self.inner.clone();
        let context = context.clone();
        let p=tokio::task::spawn_blocking(move||->Result<Arc<Process>>{
            let mut processes=inner.processes.lock().unwrap();processes.retain(|_,p|!p.done.load(Ordering::Acquire));ensure!(processes.len()<inner.cfg.max_processes,"maximum concurrent local processes reached");
            let slot=inner.execution_slots.clone().try_acquire_owned().context("maximum concurrent local processes reached")?;
            let mut command=sandbox_command(&inner,&executable,&argv,&workdir)?;
            let _fence = permit.verify(&context,&action)?;
            let id=format!("proc_{}",uuid::Uuid::new_v4());let initial=json!({"session_id":id,"status":"running","output":"","output_is_bounded_tail":true});
            inner.db.lock().unwrap().execute("INSERT INTO local_processes(id,conversation,session,result) VALUES(?1,?2,?3,?4)",params![id,context.conversation_id,context.session_id,initial.to_string()])?;
            let mut child=match command.spawn(){Ok(c)=>c,Err(_)=>{inner.db.lock().unwrap().execute("UPDATE local_processes SET result=?2 WHERE id=?1",params![id,json!({"session_id":id,"status":"failed","error":"configured sandbox process did not start"}).to_string()])?;bail!("configured sandbox process did not start; no unsandboxed fallback");}};
            if let Some(stdin)=child.stdin.as_ref(){let fd=stdin.as_raw_fd();let flags=unsafe{libc::fcntl(fd,libc::F_GETFL)};if flags<0 || unsafe{libc::fcntl(fd,libc::F_SETFL,flags|libc::O_NONBLOCK)}<0 {kill_owned_child(&mut child);let _=child.wait();bail!("process started but input setup failed; it was stopped, inspect workspace before retrying");}}
            let (Some(stdout),Some(stderr))=(child.stdout.take(),child.stderr.take())else{kill_owned_child(&mut child);let _=child.wait();bail!("process started but output setup failed; it was stopped, inspect workspace before retrying");};
            let process=Arc::new(Process{id:id.clone(),conversation:context.conversation_id,session:context.session_id,child:Mutex::new(Some(child)),output:Mutex::new(VecDeque::new()),done:AtomicBool::new(false),exit:Mutex::new(None),timed_out:AtomicBool::new(false),monitor_failed:AtomicBool::new(false),limit:inner.cfg.output_bytes,slot:Mutex::new(Some(slot))});
            processes.insert(id,process.clone());drop(processes);let p=process.clone();let service=inner.clone();
            let started=std::thread::Builder::new().name("local-tool-monitor".into()).spawn(move||supervise(service,p,stdout,stderr,Duration::from_secs(timeout as u64)));
            if started.is_err(){process.monitor_failed.store(true,Ordering::Release);process.stop();if let Some(mut child)=process.child.lock().unwrap().take(){let _=child.wait();}process.slot.lock().unwrap().take();process.done.store(true,Ordering::Release);inner.db.lock().unwrap().execute("UPDATE local_processes SET result=?2 WHERE id=?1",params![process.id,process.value().to_string()])?;bail!("process started but monitoring failed; it was stopped, inspect workspace before retrying");}
            Ok(process)
        }).await??;
        if !background {
            while !p.done.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
        Ok(p.value())
    }
    async fn process_manage(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(
            &args,
            &["action", "session_id", "data", "timeout", "offset", "limit"],
        )?;
        scope(context)?;
        let action_name = string(&args, "action")?;
        if action_name == "list" {
            let db = self.inner.db.lock().unwrap();
            let mut q=db.prepare("SELECT id,result FROM local_processes WHERE conversation=?1 AND session=?2 ORDER BY rowid DESC LIMIT 100")?;
            let records = q
                .query_map(params![context.conversation_id, context.session_id], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            drop(q);
            drop(db);
            let live = self.inner.processes.lock().unwrap();
            let results = records
                .into_iter()
                .map(|(id, raw)| {
                    live.get(&id)
                        .map(|p| Ok(p.value()))
                        .unwrap_or_else(|| serde_json::from_str(&raw))
                })
                .collect::<std::result::Result<Vec<Value>, _>>()?;
            return Ok(json!({"processes":results}));
        }
        let id = string(&args, "session_id")?;
        let p = self.inner.processes.lock().unwrap().get(id).cloned();
        if let Some(p) = p {
            ensure!(
                p.conversation == context.conversation_id && p.session == context.session_id,
                "process belongs to another conversation/session"
            );
            match action_name {
                "poll" | "log" => {}
                "wait" => {
                    let timeout = number(&args, "timeout", 30, 600)?;
                    let until = Instant::now() + Duration::from_secs(timeout as u64);
                    while !p.done.load(Ordering::Acquire) && Instant::now() < until {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                }
                "kill" | "write" | "submit" | "close" => {
                    let action = self.action("process_manage", &args);
                    let mut permit = self
                        .authorize(
                            match (self.inner.cfg.execute, self.inner.cfg.write) {
                                (Permission::Deny, _) => Permission::Deny,
                                (_, Permission::Ask) => Permission::Ask,
                                (permission, _) => permission,
                            },
                            context,
                            &action,
                            &format!(
                                "{} process {}\n{}",
                                action_name,
                                id,
                                args["data"]
                                    .as_str()
                                    .unwrap_or("")
                                    .chars()
                                    .take(4000)
                                    .collect::<String>()
                            ),
                        )
                        .await?;
                    let _fence = permit.verify(context, &action)?;
                    if action_name == "kill" {
                        p.stop();
                    } else {
                        let mut child = p.child.lock().unwrap();
                        let child = child.as_mut().context("process has already exited")?;
                        if action_name == "close" {
                            child.stdin.take();
                        } else {
                            let data = string(&args, "data")?;
                            ensure!(data.len() <= 8192, "stdin input exceeds 8 KiB");
                            let stdin = child.stdin.as_mut().context("process stdin is closed")?;
                            let mut bytes = data.as_bytes().to_vec();
                            if action_name == "submit" {
                                bytes.push(b'\n');
                            }
                            let written = match stdin.write(&bytes) {
                                Ok(n) => n,
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => 0,
                                Err(e) => return Err(e.into()),
                            };
                            let mut status = p.value();
                            status["stdin_bytes_written"] = json!(written);
                            status["stdin_complete"] = json!(written == bytes.len());
                            return Ok(status);
                        }
                    }
                }
                _ => bail!("unsupported process action"),
            }
            return page_log(p.value(), &args);
        }
        ensure!(
            ["poll", "log", "wait"].contains(&action_name),
            "process is not running in this host instance"
        );
        let raw = self
            .inner
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT result FROM local_processes WHERE id=?1 AND conversation=?2 AND session=?3",
                params![id, context.conversation_id, context.session_id],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .context("process not found in this conversation/session")?;
        page_log(serde_json::from_str(&raw)?, &args)
    }
}
impl ToolExecutor for LocalTools {
    fn execute_at_generation<'a>(
        &'a self, name: &'a str, arguments: Value, context: &'a TurnContext, generation: i64,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let execution = LocalExecution::new(context, generation, format!("local_{}", uuid::Uuid::new_v4()))?;
            self.execute_scoped(name, arguments, context, execution).await
        })
    }
    fn execute_call_at_generation<'a>(
        &'a self, name: &'a str, arguments: Value, context: &'a TurnContext,
        generation: i64, call_id: &'a str,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let execution = LocalExecution::new(context, generation, call_id.to_owned())?;
            self.execute_scoped(name, arguments, context, execution).await
        })
    }

    fn set_session_generation<'a>(
        &'a self,
        session: &'a str,
        generation: i64,
    ) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            ensure!(!session.is_empty() && generation >= 0, "invalid session generation");
            let advancing = self.inner.python.current_generation(session).is_ok_and(|current| generation > current);
            // Publish the monotone epoch before awaiting any effect cleanup.
            // Native commits already holding an effect lease are allowed to
            // finish; all pending/queued old approvals fail their epoch check.
            let advance = self.inner.python.set_generation(
                session, generation, self.inner.cfg.max_session_routes,
            );
            if advancing {
                let _effects = self.inner.effects.write().await;
            }
            advance?;
            if self
                .inner
                .python
                .check_generation(session, generation)
                .is_ok()
                && let Some(bridge) = &self.inner.python_bridge
            {
                bridge.set_generation(session, generation).await?;
            }
            Ok(())
        })
    }

    fn schemas(&self) -> Vec<Value> {
        let mut schemas = vec![
            schema(
                "read_file",
                "Read bounded text inside the configured root, including strict UTF-16 display rescue, with line numbers (offset/limit in lines, limit <=2000). For a returned python-output:// reference, recover sanitized output using one-based UTF-8 byte offset and limit 4..65536 (default8192); follow next_offset. Output references are read-only and session-generation scoped. UTF-8 BOM and CRLF/CR are normalized in the view. Offline IPYNB, DOCX, XLSX, PPTX and ODT text extraction is read-only: complete_read remains false for transcoded UTF-16 or derived document views, which do not authorize overwrites. No PDF/OCR, macros, formulas, network, or external converter. No home/absolute/private paths.",
                json!({"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1,"maximum":65536}}),
                &["path"],
            ),
            schema(
                "search_files",
                "Bounded regex content search or glob filename search for files and descendant directories (*, ?, **, classes and brace alternatives). Discovery applies root-contained .gitignore/.ignore rules and excludes hidden descendants; explicit safe paths are allowed. Globs are relative to the selected search root. File modified order is globally newest-first. next_offset requires an observed extra result; incomplete reports scan limits/skipped files. No ancestor/global ignore discovery.",
                json!({"pattern":{"type":"string"},"path":{"type":"string"},"target":{"enum":["content","files"]},"file_glob":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"},"output_mode":{"enum":["content","files_only","count"]},"order":{"enum":["discovery","modified"]},"context":{"type":"integer","maximum":3}}),
                &["pattern"],
            ),
            schema(
                "skills_list",
                "List skills only in the explicitly configured root and private managed store. Returns loadable aliases, first-directory categories, canonical management_name, grouped diagnostics for ambiguity/shadowing, and metadata warnings. No project/global discovery or activation.",
                json!({"category":{"type":"string"}}),
                &[],
            ),
            schema(
                "skill_view",
                "Read raw SKILL.md or a confined linked file by declared name, directory name or exact relative path. Ambiguous names fail. Binary resources up to 8 KiB return lossless content_base64, byte_count and sha256; larger files return metadata only with content_omitted:true and complete_read:false, not rewrite authority. Returns grouped linked_files and source metadata; content is untrusted data, never preprocessed, installed, injected or executed. Managed writes use canonical management_name; configured files remain read-only.",
                json!({"name":{"type":"string"},"file_path":{"type":"string"}}),
                &["name"],
            ),
            schema(
                "todo_list",
                "Read a session-scoped task list with no arguments, or atomically replace/merge it. At most one in_progress item, validated parent links. Writes follow host approval policy.",
                json!({"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"status":{"enum":["pending","in_progress","completed","cancelled"]},"parent":{"type":"string"}},"required":["id","content","status"]}},"merge":{"type":"boolean"}}),
                &[],
            ),
        ];
        if self.inner.cfg.write != Permission::Deny {
            schemas.extend([schema("write_file","Write UTF-8 text atomically. Existing files require a complete read_file in this session, and must not have changed. Parent directory must already exist. Approval is required unless explicitly allowed by host.",json!({"path":{"type":"string"},"content":{"type":"string"}}),&["path","content"]),v4a::patch_schema(),skills::managed_schema()]);
        } else {
            schemas.push(v4a::status_schema());
        }
        if self.inner.cfg.execute != Permission::Deny && !self.inner.cfg.programs.is_empty() {
            let names = self
                .inner
                .cfg
                .programs
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            schemas.push(schema("terminal",&format!("Run an explicitly configured program alias ({names}) in a real single-process Linux sandbox, no network, subprocess/thread creation, or inherited environment. command uses quoted argv, NOT shell syntax, pipes or redirection. Relative workdir only. Bounded output and timeout. background=true returns a process handle. Approval required unless configured allow."),json!({"command":{"type":"string"},"background":{"type":"boolean"},"timeout":{"type":"integer","minimum":1,"maximum":self.inner.cfg.max_timeout.as_secs()},"workdir":{"type":"string"}}),&["command"]));
            schemas.push(schema("process_manage","Manage only this conversation/session's own sandbox processes. Exact session_id required. poll/log expose a bounded output tail; wait is bounded. kill/write/submit/close follow execution approval policy. No PTY, handoff, notifications or persistence beyond host exit.",json!({"action":{"enum":["list","poll","log","wait","kill","write","submit","close"]},"session_id":{"type":"string"},"data":{"type":"string"},"timeout":{"type":"integer"},"offset":{"type":"integer"},"limit":{"type":"integer"}}),&["action"]));
            if self.inner.cfg.python_program.is_some() {
                schemas.push(schema("execute_code","Execute Python cells in a persistent session kernel inside the configured single-process sandbox. Variables/imports survive calls; reset=true discards state before this cell. Print results. No network, subprocesses, threads, or host private files. from hermes_tools import read_file, search_files, skills_list, skill_view, todo_list; write_file, patch, skill_manage follow write policy. Other tools are unavailable unless explicitly configured by the host. Every cell and callback retains exact approval policy. Timeout, cancellation, idle expiry, resource limits or service restart discard state; no automatic cell retry.",json!({"code":{"type":"string"},"reset":{"type":"boolean"}}),&["code"]));
            }
        }
        schemas
    }
    /// Legacy direct calls explicitly capture the current generation at entry;
    /// they never re-adopt a newer generation after approval or worker dispatch.
    fn execute<'a>(
        &'a self, name: &'a str, args: Value, context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let generation = self.inner.python.current_generation(&context.session_id)?;
            let execution = LocalExecution::new(context, generation, format!("direct_{}", uuid::Uuid::new_v4()))?;
            self.execute_scoped(name, args, context, execution).await
        })
    }
}
impl LocalTools {
    async fn execute_scoped(&self, name: &str, args: Value, context: &TurnContext, execution: LocalExecution) -> Result<Value> {
        let generation = execution.generation;
        let _retire = RetireExecution(execution.retired.clone());
        self.inner.python.check_generation(&context.session_id, generation)?;
        LOCAL_EXECUTION.scope(execution, async move {
            ensure!(
                args.to_string().len() <= 2 * 1024 * 1024,
                "local tool request exceeds limit"
            );
            scope(context)?;
            match name {
                "read_file" => self.read_file(args, context).await,
                "write_file" => self.write_file(args, context, false).await,
                "patch" if args.get("mode").and_then(Value::as_str) == Some("status") => self.patch_status(args, context).await,
                "patch" if args.get("patch").is_some() || args.get("mode").and_then(Value::as_str) == Some("patch") => self.patch_v4a(args, context).await,
                "patch" => self.write_file(args, context, true).await,
                "search_files" => self.search_files(args).await,
                "skills_list" => self.skills_list(args).await,
                "skill_view" => self.skill_view(args, context).await,
                "skill_manage" => self.skill_manage(args, context).await,
                "todo_list" => self.todo(args, context).await,
                "terminal" => self.terminal(args, context).await,
                "execute_code" => self.execute_python_at_generation(args, context, Some(generation)).await,
                "process_manage" => self.process_manage(args, context).await,
                _ => bail!("unknown local tool"),
            }
        }).await
    }
}

fn schema(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({"type":"function","function":{"name":name,"description":description,"parameters":{"type":"object","additionalProperties":false,"properties":properties,"required":required}}})
}
fn relative_exists(root: &ProtectedRoot, path: &str) -> Result<bool> {
    let (parent, name) = root.open_parent(path)?;
    let name = CString::new(name)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let code = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if code == 0 {
        Ok(true)
    } else {
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(err.into())
        }
    }
}
fn atomic_write(root: &ProtectedRoot, path: &str, bytes: &[u8]) -> Result<()> {
    let (parent, name) = root.open_parent(path)?;
    let name = CString::new(name)?;
    let temp = CString::new(format!(".local-write-{}", uuid::Uuid::new_v4()))?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            temp.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    ensure!(fd >= 0, "cannot create atomic replacement file");
    let mut file = unsafe { File::from_raw_fd(fd) };
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        ensure!(
            unsafe {
                libc::renameat(
                    parent.as_raw_fd(),
                    temp.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                )
            } == 0,
            "atomic rename failed"
        );
        parent.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        unsafe {
            libc::unlinkat(parent.as_raw_fd(), temp.as_ptr(), 0);
        }
    }
    result
}
struct PrivateSnapshot(PathBuf);
impl PrivateSnapshot {
    fn new(parent: &Path, bytes: &[u8]) -> Result<Self> {
        let path = parent.join(format!(".local-artifact-{}", uuid::Uuid::new_v4()));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        let owned = Self(path);
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(owned)
    }
}
impl Drop for PrivateSnapshot {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn bounded_utf8_tail(bytes: &[u8], limit: usize) -> String {
    let text = String::from_utf8_lossy(bytes);
    let mut start = text.len().saturating_sub(limit);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_owned()
}
fn page_log(mut result: Value, args: &Value) -> Result<Value> {
    if args["action"] == "log" {
        let offset = number(args, "offset", 0, 10000)?;
        let limit = number(args, "limit", 200, 2000)?;
        let output = result["output"]
            .as_str()
            .unwrap_or("")
            .lines()
            .skip(offset)
            .take(limit)
            .collect::<Vec<_>>()
            .join("\n");
        result["output"] = json!(output);
    }
    Ok(result)
}
fn kill_owned_child(child: &mut Child) {
    // try_wait caches an already reaped status. Never signal a numeric PID after
    // it has been reaped, since that PID/process group may now belong to others.
    if matches!(child.try_wait(), Ok(None)) {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        let _ = child.kill();
    }
}
fn read_output(
    mut reader: impl Read + Send + 'static,
    p: Arc<Process>,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("local-tool-output".into())
        .spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut out = p.output.lock().unwrap();
                out.extend(&buf[..n]);
                while out.len() > p.limit {
                    out.pop_front();
                }
            }
        })
}
fn supervise(
    service: Arc<Inner>,
    p: Arc<Process>,
    stdout: std::process::ChildStdout,
    stderr: std::process::ChildStderr,
    timeout: Duration,
) {
    let a = read_output(stdout, p.clone());
    let b = read_output(stderr, p.clone());
    if a.is_err() || b.is_err() {
        p.monitor_failed.store(true, Ordering::Release);
        p.stop();
    }
    let until = Instant::now() + timeout;
    loop {
        let status = {
            let mut slot = p.child.lock().unwrap();
            match slot.as_mut().map(Child::try_wait) {
                Some(Ok(Some(status))) => {
                    slot.take();
                    Ok(Some(status))
                }
                Some(Ok(None)) => Ok(None),
                Some(Err(error)) => {
                    slot.take();
                    Err(error)
                }
                None => Err(std::io::Error::other("process handle unavailable")),
            }
        };
        match status {
            Ok(Some(status)) => {
                *p.exit.lock().unwrap() = status.code();
                break;
            }
            Err(_) => {
                p.monitor_failed.store(true, Ordering::Release);
                break;
            }
            Ok(None) => {}
        }
        if Instant::now() >= until {
            p.timed_out.store(true, Ordering::Release);
            p.stop();
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if let Ok(a) = a {
        let _ = a.join();
    }
    if let Ok(b) = b {
        let _ = b.join();
    }
    let mut result = p.value();
    if !p.monitor_failed.load(Ordering::Acquire) {
        result["status"] = json!("exited");
    }
    if service
        .db
        .lock()
        .unwrap()
        .execute(
            "UPDATE local_processes SET result=?2 WHERE id=?1",
            params![p.id, result.to_string()],
        )
        .is_err()
    {
        p.monitor_failed.store(true, Ordering::Release);
    }
    p.slot.lock().unwrap().take();
    p.done.store(true, Ordering::Release);
}

fn split_command(command: &str) -> Result<Vec<String>> {
    ensure!(command.len() <= 128 * 1024, "command too long");
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut started = false;
    for c in command.chars() {
        if escaped {
            word.push(c);
            escaped = false;
            started = true;
            continue;
        }
        if c == '\\' && quote != Some('\'') {
            escaped = true;
            started = true;
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None
            } else {
                word.push(c)
            }
            started = true;
            continue;
        }
        match c {
            '\'' | '"' => {
                quote = Some(c);
                started = true
            }
            ' ' | '\t' => {
                if started {
                    words.push(std::mem::take(&mut word));
                    started = false
                }
            }
            ';' | '|' | '&' | '<' | '>' | '`' | '\n' | '\r' | '\0' => bail!(
                "terminal accepts argv, not shell operators; use a configured interpreter explicitly"
            ),
            _ => {
                word.push(c);
                started = true
            }
        }
    }
    ensure!(quote.is_none() && !escaped, "unclosed quote or escape");
    if started {
        words.push(word)
    }
    ensure!(words.len() <= 256, "too many command arguments");
    Ok(words)
}
#[cfg(target_os = "linux")]
fn sandbox_command(
    inner: &Inner,
    executable: &Path,
    argv: &[String],
    workdir: &str,
) -> Result<Command> {
    sandbox_command_with_status(inner, executable, argv, workdir, None)
}
#[cfg(target_os = "linux")]
fn sandbox_command_with_status(
    inner: &Inner,
    executable: &Path,
    argv: &[String],
    workdir: &str,
    status: Option<File>,
) -> Result<Command> {
    use std::io::{Seek, SeekFrom};
    ensure!(
        inner.cfg.sandbox.is_absolute() && inner.cfg.sandbox.is_file(),
        "bubblewrap sandbox is unavailable"
    );
    let roots = &inner.cfg.runtime_roots;
    ensure!(
        !roots.is_empty()
            && roots.iter().all(|p| [
                "/usr/bin",
                "/usr/lib",
                "/usr/lib64",
                "/usr/libexec",
                "/usr/sbin",
                "/usr/share",
                "/usr/local/bin",
                "/usr/local/lib",
                "/bin",
                "/sbin",
                "/lib",
                "/lib64"
            ]
            .iter()
            .any(|allowed| p == Path::new(allowed))),
        "runtime mounts are restricted to explicit system runtime directories"
    );
    ensure!(
        roots.iter().any(|r| executable.starts_with(r)),
        "configured executable is outside runtime mounts"
    );
    let mut masks = Vec::new();
    let mut visited = 0;
    check_process_tree(&inner.root, "", 0, &mut visited, &mut masks)?;
    let root = inner.root.open_dir("")?;
    let root_fd = root.as_raw_fd();
    let name = CString::new("local-tool-seccomp")?;
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    ensure!(fd >= 0, "cannot create sandbox filter");
    let mut filter = unsafe { File::from_raw_fd(fd) };
    let rules = network_filter()?;
    let bytes = unsafe {
        std::slice::from_raw_parts(
            rules.as_ptr().cast::<u8>(),
            std::mem::size_of_val(rules.as_slice()),
        )
    };
    filter.write_all(bytes)?;
    filter.seek(SeekFrom::Start(0))?;
    let filter_fd = filter.as_raw_fd();
    let mut command = Command::new(&inner.cfg.sandbox);
    command.args([
        "--unshare-user",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--die-with-parent",
        "--new-session",
        "--cap-drop",
        "ALL",
        "--clearenv",
    ]);
    // Network namespace setup itself needs NETLINK_ROUTE on some hosts. A
    // mandatory child seccomp filter instead denies every networking entry point,
    // including io_uring creation, with no weaker fallback on failure.
    for root in roots {
        ensure!(
            root.is_absolute() && root.is_dir(),
            "runtime mount is missing"
        );
        command.arg("--ro-bind").arg(root).arg(root);
    }
    command.args([
        if inner.cfg.write == Permission::Deny {
            "--ro-bind-fd"
        } else {
            "--bind-fd"
        },
        &root_fd.to_string(),
        "/work",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--size",
        "67108864",
        "--tmpfs",
        "/tmp",
        "--dir",
        "/home",
        "--dir",
        "/home/sandbox",
        "--setenv",
        "HOME",
        "/home/sandbox",
        "--setenv",
        "PATH",
        "/usr/bin:/bin",
        "--setenv",
        "LANG",
        "C.UTF-8",
    ]);
    for (path, directory) in masks {
        if directory {
            command.arg("--tmpfs").arg(format!("/work/{path}"));
        } else {
            command
                .args(["--ro-bind", "/dev/null"])
                .arg(format!("/work/{path}"));
        }
    }
    let status_fd = status.as_ref().map(AsRawFd::as_raw_fd);
    if let Some(fd) = status_fd {
        command.args(["--as-pid-1", "--info-fd", &fd.to_string()]);
    }
    command
        .args(["--seccomp", &filter_fd.to_string(), "--chdir"])
        .arg(if workdir.is_empty() {
            "/work".into()
        } else {
            format!("/work/{workdir}")
        })
        .arg("--")
        .arg(executable)
        .args(argv)
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let cpu = inner.cfg.max_timeout.as_secs() + 2;
    // The captured File values stay open until spawn's pre_exec has inherited
    // them. Bubblewrap consumes/closes bind-fd and seccomp descriptors before exec.
    unsafe {
        command.pre_exec(move || {
            let _keep = (&root, &filter, &status);
            if let Some(fd) = status_fd
                && libc::fcntl(fd, libc::F_SETFD, 0) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::fcntl(root_fd, libc::F_SETFD, 0) < 0
                || libc::fcntl(filter_fd, libc::F_SETFD, 0) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::setpgid(0, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            for (resource, value) in [
                (libc::RLIMIT_AS, 512 * 1024 * 1024),
                (libc::RLIMIT_FSIZE, 64 * 1024 * 1024),
                (libc::RLIMIT_CPU, cpu),
                (libc::RLIMIT_NOFILE, 256),
            ] {
                let limit = libc::rlimit {
                    rlim_cur: value,
                    rlim_max: value,
                };
                if libc::setrlimit(resource, &limit) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    Ok(command)
}
#[cfg(not(target_os = "linux"))]
fn sandbox_command(_: &Inner, _: &Path, _: &[String], _: &str) -> Result<Command> {
    bail!("local execution requires a verified Linux sandbox; no unsandboxed fallback")
}
#[cfg(target_os = "linux")]
fn network_filter() -> Result<Vec<libc::sock_filter>> {
    #[cfg(target_arch = "x86_64")]
    let arch = 0xc000003e;
    #[cfg(target_arch = "aarch64")]
    let arch = 0xc00000b7;
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    {
        bail!("sandbox syscall architecture not supported");
    }
    #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
    {
        let s = |code, jt, jf, k| libc::sock_filter { code, jt, jf, k };
        let mut rules = vec![
            s(0x20, 0, 0, 4),
            s(0x15, 1, 0, arch),
            s(0x06, 0, 0, 0x80000000),
            s(0x20, 0, 0, 0),
        ];
        // Also reject x32 ABI syscall numbers, which otherwise evade x86_64 matches.
        #[cfg(target_arch = "x86_64")]
        {
            rules.push(s(0x45, 0, 1, 0x40000000));
            rules.push(s(0x06, 0, 0, 0x80000000));
        }
        for syscall in [
            libc::SYS_clone,
            libc::SYS_clone3,
            libc::SYS_socket,
            libc::SYS_socketpair,
            libc::SYS_connect,
            libc::SYS_bind,
            libc::SYS_listen,
            libc::SYS_accept,
            libc::SYS_accept4,
            libc::SYS_sendto,
            libc::SYS_sendmsg,
            libc::SYS_sendmmsg,
            libc::SYS_recvfrom,
            libc::SYS_recvmsg,
            libc::SYS_recvmmsg,
            libc::SYS_ptrace,
            libc::SYS_mount,
            libc::SYS_umount2,
            libc::SYS_pivot_root,
            libc::SYS_unshare,
            libc::SYS_setns,
            libc::SYS_bpf,
            libc::SYS_perf_event_open,
            libc::SYS_userfaultfd,
            libc::SYS_open_by_handle_at,
            libc::SYS_io_uring_setup,
            libc::SYS_io_uring_enter,
            libc::SYS_io_uring_register,
        ] {
            rules.push(s(0x15, 0, 1, syscall as u32));
            rules.push(s(0x06, 0, 0, 0x00050000 | libc::EPERM as u32));
        }
        #[cfg(target_arch = "x86_64")]
        for syscall in [libc::SYS_fork, libc::SYS_vfork] {
            rules.push(s(0x15, 0, 1, syscall as u32));
            rules.push(s(0x06, 0, 0, 0x00050000 | libc::EPERM as u32));
        }
        rules.push(s(0x06, 0, 0, 0x7fff0000));
        Ok(rules)
    }
}
#[cfg(not(target_os = "linux"))]
fn check_process_tree(
    _: &ProtectedRoot,
    _: &str,
    _: usize,
    _: &mut usize,
    _: &mut Vec<(String, bool)>,
) -> Result<()> {
    bail!("process preflight requires verified Linux sandbox support")
}
#[cfg(target_os = "linux")]
fn check_process_tree(
    root: &ProtectedRoot,
    path: &str,
    depth: usize,
    visited: &mut usize,
    masks: &mut Vec<(String, bool)>,
) -> Result<()> {
    use std::{ffi::CStr, os::fd::IntoRawFd};
    ensure!(
        depth <= 16 && *visited <= 10000,
        "sandbox root preflight exceeds traversal limit"
    );
    // ProtectedRoot::list intentionally hides links/special files for browsing.
    // A security preflight must inspect EVERY entry before mounting the root.
    let directory = root.open_dir(path)?;
    let fd = directory.into_raw_fd();
    let raw = unsafe { libc::fdopendir(fd) };
    if raw.is_null() {
        unsafe {
            libc::close(fd);
        }
        bail!("cannot enumerate sandbox root");
    }
    struct Directory(*mut libc::DIR);
    impl Drop for Directory {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let directory = Directory(raw);
    let mut inspected = 0;
    loop {
        unsafe {
            *libc::__errno_location() = 0;
        }
        let entry = unsafe { libc::readdir(directory.0) };
        if entry.is_null() {
            ensure!(
                unsafe { *libc::__errno_location() } == 0,
                "sandbox directory enumeration failed"
            );
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        inspected += 1;
        *visited += 1;
        ensure!(
            inspected <= 1000 && *visited <= 10000,
            "sandbox root preflight exceeds traversal limit"
        );
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        ensure!(
            unsafe {
                libc::fstatat(
                    fd,
                    name.as_ptr(),
                    stat.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0,
            "sandbox entry changed or cannot be inspected"
        );
        let stat = unsafe { stat.assume_init() };
        let kind = stat.st_mode & libc::S_IFMT;
        ensure!(
            kind == libc::S_IFDIR || kind == libc::S_IFREG,
            "sandbox root contains unsupported link or special file"
        );
        ensure!(
            kind != libc::S_IFREG || stat.st_nlink == 1,
            "sandbox root contains a hard-linked file"
        );
        let name = name.to_str().context("sandbox entry name must be UTF-8")?;
        let child = if path.is_empty() {
            name.to_owned()
        } else {
            format!("{path}/{name}")
        };
        let is_directory = kind == libc::S_IFDIR;
        if rel(&child).is_err() {
            masks.push((child, is_directory));
        } else if is_directory {
            check_process_tree(root, &child, depth + 1, visited, masks)?;
        } else {
            let file = root
                .open_file(&child)
                .context("sandbox entry changed during preflight")?;
            let actual = file.metadata()?;
            ensure!(
                actual.ino() == stat.st_ino && actual.dev() == stat.st_dev && actual.nlink() == 1,
                "sandbox entry changed during preflight"
            );
        }
    }
    Ok(())
}
