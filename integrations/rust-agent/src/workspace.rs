//! Explicit host workspaces and optional Unix PTYs. This is a direct authenticated
//! transport, never an LLM tool. A terminal's workspace is its initial cwd, NOT an
//! OS sandbox. The caller must verify conversation ownership and route binding.
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};

pub const FILE_LIMIT: usize = 1024 * 1024;
pub const TEXT_LIMIT: usize = 256 * 1024;
pub const OUTPUT_LIMIT: usize = 256 * 1024;
pub const TERMINAL_IDLE_SECONDS: u64 = 120;
pub const MAX_TERMINALS: usize = 4;
pub const MAX_ENTRIES: usize = 1000;
const REQUEST_LIMIT: usize = 1_500_000;

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceConfig {
    pub path: PathBuf,
    pub name: Option<String>,
    #[serde(default)]
    pub terminal: bool,
}
/// A reusable filesystem capability for explicitly configured host file tools.
/// Only descriptor-relative filesystem access is exposed. No terminal/process
/// authority is implied; this is not isolation from hostile same-UID code.
#[derive(Clone)]
pub struct ProtectedRoot {
    directory: Arc<File>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProtectedEntry {
    pub name: String,
    pub path: String,
    #[serde(rename = "isDirectory")]
    pub is_directory: bool,
    pub size: u64,
}
impl ProtectedRoot {
    pub fn new(explicit_absolute_root: &Path) -> Result<Self> {
        ensure!(
            explicit_absolute_root.is_absolute() && explicit_absolute_root.is_dir(),
            "protected root must be an explicitly configured existing absolute directory"
        );
        let canonical = fs::canonicalize(explicit_absolute_root)?;
        #[cfg(unix)]
        {
            Ok(Self {
                directory: Arc::new(unix::open_directory(&canonical)?),
            })
        }
        #[cfg(not(unix))]
        {
            let _ = canonical;
            anyhow::bail!("protected file roots require Unix descriptor support")
        }
    }
    pub fn open_file(&self, relative: &str) -> Result<File> {
        let parts = protected_parts(relative)?;
        #[cfg(unix)]
        {
            let file =
                unix::open_relative(&self.directory, &parts, false).map_err(protected_error)?;
            ensure!(
                file.metadata()?.is_file(),
                "protected path must select a regular file"
            );
            Ok(file)
        }
        #[cfg(not(unix))]
        {
            let _ = parts;
            anyhow::bail!("protected file roots require Unix descriptor support")
        }
    }
    pub fn open_dir(&self, relative: &str) -> Result<File> {
        let parts = protected_parts(relative)?;
        #[cfg(unix)]
        {
            unix::open_relative(&self.directory, &parts, true).map_err(protected_error)
        }
        #[cfg(not(unix))]
        {
            let _ = parts;
            anyhow::bail!("protected file roots require Unix descriptor support")
        }
    }
    /// Existing parents only. The returned leaf is one validated component;
    /// create/replace through this FD, never reconstruct an absolute host path.
    pub fn open_parent(&self, relative: &str) -> Result<(File, String)> {
        let parts = protected_parts(relative)?;
        let (leaf, parent) = parts.split_last().context("protected file path is empty")?;
        #[cfg(unix)]
        {
            Ok((
                unix::open_relative(&self.directory, parent, true).map_err(protected_error)?,
                leaf.clone(),
            ))
        }
        #[cfg(not(unix))]
        {
            let _ = (leaf, parent);
            anyhow::bail!("protected file roots require Unix descriptor support")
        }
    }
    /// At most 1,000 inspected entries, excluding symlinks and special files.
    /// Paths are relative to this root. Each call has an independent cursor.
    pub fn list(&self, relative: &str) -> Result<Vec<ProtectedEntry>> {
        let parts = protected_parts(relative)?;
        #[cfg(unix)]
        {
            let mut value = unix::list(&self.directory, &parts).map_err(protected_error)?;
            Ok(serde_json::from_value(value["entries"].take())?)
        }
        #[cfg(not(unix))]
        {
            let _ = parts;
            anyhow::bail!("protected file roots require Unix descriptor support")
        }
    }
}
fn protected_parts(relative: &str) -> Result<Vec<String>> {
    path_parts(relative).map_err(protected_error)
}
fn protected_error(error: WorkspaceError) -> anyhow::Error {
    anyhow::anyhow!("{}: {}", error.code, error.message)
}

#[derive(Clone)]
struct Root {
    path: PathBuf,
    name: String,
    terminal: bool,
    directory: Arc<File>,
}

#[derive(Debug)]
struct WorkspaceError {
    code: &'static str,
    message: &'static str,
}
type WorkspaceResult<T> = std::result::Result<T, WorkspaceError>;
impl WorkspaceError {
    fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
    fn failed() -> Self {
        Self::new("operation_failed", "Workspace operation failed")
    }
    fn value(self) -> Value {
        json!({"ok":false,"error":{"code":self.code,"message":self.message}})
    }
}
impl From<std::io::Error> for WorkspaceError {
    fn from(_: std::io::Error) -> Self {
        Self::failed()
    }
}

#[derive(Clone)]
pub struct WorkspaceService {
    inner: Arc<Inner>,
}
type PendingOpens = HashMap<String, Vec<Weak<std::sync::atomic::AtomicBool>>>;
struct Inner {
    roots: Vec<Root>,
    shell: PathBuf,
    files: Arc<tokio::sync::Semaphore>,
    generation: std::sync::atomic::AtomicU64,
    pending_opens: Mutex<PendingOpens>,
    #[cfg(unix)]
    terminals: Mutex<HashMap<String, Arc<Terminal>>>,
}
struct OperationGuard {
    inner: Weak<Inner>,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
    terminal_id: Arc<Mutex<Option<String>>>,
    armed: bool,
}
impl OperationGuard {
    fn new(inner: &Arc<Inner>) -> Self {
        Self {
            inner: Arc::downgrade(inner),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            terminal_id: Arc::new(Mutex::new(None)),
            armed: true,
        }
    }
    fn disarm(&mut self) {
        self.armed = false;
    }
}
impl Drop for OperationGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.cancelled
            .store(true, std::sync::atomic::Ordering::Release);
        #[cfg(unix)]
        if let Some(inner) = self.inner.upgrade() {
            let key = self.terminal_id.lock().ok().and_then(|key| key.clone());
            if let Some(key) = key {
                let terminal = inner
                    .terminals
                    .lock()
                    .ok()
                    .and_then(|mut map| map.remove(&key));
                if let Some(terminal) = terminal {
                    terminal.close_now();
                }
            }
        }
    }
}
impl WorkspaceService {
    /// Empty configuration exposes no directories and cannot open a shell.
    pub fn from_json(config: &str) -> Result<Self> {
        let roots: Vec<WorkspaceConfig> = if config.trim().is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(config).context("invalid workspace configuration")?
        };
        Self::new(roots)
    }
    pub fn new(config: Vec<WorkspaceConfig>) -> Result<Self> {
        let shell = std::env::var_os("SHELL")
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "/bin/sh".into());
        Self::new_with_shell(config, PathBuf::from(shell))
    }
    /// Trusted host-only override, useful for a deliberately isolated shell.
    pub fn new_with_shell(config: Vec<WorkspaceConfig>, shell: PathBuf) -> Result<Self> {
        ensure!(
            shell.is_absolute(),
            "terminal shell must be an absolute host path"
        );
        ensure!(
            config.len() <= 32,
            "workspaces must contain at most 32 directories"
        );
        let mut roots = Vec::with_capacity(config.len());
        for item in config {
            let path = expand_home(item.path)?;
            ensure!(
                path.is_absolute() && path.is_dir(),
                "workspace path must be an existing absolute directory"
            );
            let canonical = fs::canonicalize(&path)?;
            #[cfg(unix)]
            let directory =
                unix::open_directory(&canonical).context("could not pin workspace directory")?;
            #[cfg(not(unix))]
            let directory = {
                let _ = canonical;
                anyhow::bail!(
                    "workspace file operations require Unix; Windows handle protection is not implemented"
                )
            };
            let name = item.name.filter(|v| !v.is_empty()).unwrap_or_else(|| {
                canonical
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned()
            });
            roots.push(Root {
                path: canonical,
                name,
                terminal: item.terminal,
                directory: Arc::new(directory),
            });
        }
        Ok(Self {
            inner: Arc::new(Inner {
                roots,
                shell,
                files: Arc::new(tokio::sync::Semaphore::new(1)),
                generation: std::sync::atomic::AtomicU64::new(0),
                pending_opens: Mutex::new(HashMap::new()),
                #[cfg(unix)]
                terminals: Mutex::new(HashMap::new()),
            }),
        })
    }
    /// `trusted_socket_id` MUST come from the authenticated server routing layer,
    /// independently of this payload. A payload's `_clientId` is never consulted.
    pub async fn handle(
        &self,
        conversation_id: &str,
        trusted_socket_id: &str,
        payload: &Value,
    ) -> Value {
        let result = match tokio::time::timeout(
            Duration::from_secs(15),
            self.execute(conversation_id, trusted_socket_id, payload),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(WorkspaceError::new(
                "operation_timeout",
                "Workspace operation timed out; an upload may already have completed. Read the target before retrying.",
            )),
        };
        match result {
            Ok(data) => {
                let response = json!({"ok":true,"data":data});
                if serde_json::to_vec(&response)
                    .map(|v| v.len() > REQUEST_LIMIT)
                    .unwrap_or(true)
                {
                    WorkspaceError::new("response_too_large", "Encoded workspace response exceeds the transport limit; use file download instead of preview").value()
                } else {
                    response
                }
            }
            Err(error) => error.value(),
        }
    }
    async fn execute(
        &self,
        conversation: &str,
        client: &str,
        payload: &Value,
    ) -> WorkspaceResult<Value> {
        if conversation.trim().is_empty()
            || conversation.chars().count() > 160
            || client.trim().is_empty()
            || client.len() > 4096
            || !payload.is_object()
        {
            return Err(WorkspaceError::new(
                "invalid_request",
                "A conversation and trusted mobile connection identity are required",
            ));
        }
        if serde_json::to_vec(payload)
            .map_err(|_| WorkspaceError::failed())?
            .len()
            > REQUEST_LIMIT
        {
            return Err(WorkspaceError::new(
                "invalid_request",
                "Workspace payload exceeds the request limit",
            ));
        }
        let op = payload["op"].as_str().ok_or_else(|| {
            WorkspaceError::new(
                "unsupported_operation",
                "Workspace operation is not supported",
            )
        })?;
        if op == "capabilities" {
            return Ok(self.capabilities());
        }
        // Socket cleanup is a host API, never a client-controlled operation.
        if op == "terminal.close_client" {
            return Err(WorkspaceError::new(
                "unsupported_operation",
                "Socket cleanup is reserved for the trusted host",
            ));
        }
        if matches!(
            op,
            "terminal.read" | "terminal.write" | "terminal.resize" | "terminal.close"
        ) {
            #[cfg(unix)]
            {
                return self.terminal_operation(conversation, client, payload).await;
            }
            #[cfg(not(unix))]
            {
                return Err(WorkspaceError::new(
                    "terminal_unavailable",
                    "Windows PTY and Job Object cleanup are not implemented",
                ));
            }
        }
        let root = self.root(payload["workspaceId"].as_str())?;
        let relative = payload
            .get("path")
            .map(|v| v.as_str().ok_or_else(invalid_path))
            .transpose()?
            .unwrap_or("");
        let parts = path_parts(relative)?;
        if op == "terminal.open" {
            if !root.terminal {
                return Err(WorkspaceError::new(
                    "terminal_unavailable",
                    "Explicit terminal permission and a host PTY are required",
                ));
            }
            let (columns, rows) = dimensions(payload)?;
            #[cfg(unix)]
            {
                let cwd = unix::open_relative(&root.directory, &parts, true)?;
                let inner = self.inner.clone();
                let service = self.clone();
                let generation = inner.generation.load(std::sync::atomic::Ordering::Acquire);
                let conversation = conversation.to_owned();
                let client = client.to_owned();
                let mut cancellation = OperationGuard::new(&self.inner);
                let cancelled = cancellation.cancelled.clone();
                let published = cancellation.terminal_id.clone();
                {
                    let mut pending = inner
                        .pending_opens
                        .lock()
                        .map_err(|_| WorkspaceError::failed())?;
                    pending.retain(|_, flags| {
                        flags.retain(|flag| flag.strong_count() > 0);
                        !flags.is_empty()
                    });
                    pending
                        .entry(client.clone())
                        .or_default()
                        .push(Arc::downgrade(&cancelled));
                }
                let terminal = tokio::task::spawn_blocking(move || {
                    let mut terminals = inner
                        .terminals
                        .lock()
                        .map_err(|_| WorkspaceError::failed())?;
                    if cancelled.load(std::sync::atomic::Ordering::Acquire)
                        || inner.generation.load(std::sync::atomic::Ordering::Acquire) != generation
                    {
                        return Err(WorkspaceError::new(
                            "terminal_closed",
                            "Connection closed while opening terminal",
                        ));
                    }
                    if terminals.len() >= MAX_TERMINALS {
                        return Err(WorkspaceError::new(
                            "terminal_limit",
                            "Close an existing terminal first",
                        ));
                    }
                    let terminal =
                        Terminal::spawn(conversation, client, cwd, columns, rows, &inner.shell)?;
                    let key = uuid::Uuid::new_v4().simple().to_string();
                    if cancelled.load(std::sync::atomic::Ordering::Acquire)
                        || inner.generation.load(std::sync::atomic::Ordering::Acquire) != generation
                    {
                        terminal.close_now();
                        return Err(WorkspaceError::new(
                            "terminal_closed",
                            "Connection closed while opening terminal",
                        ));
                    }
                    terminals.insert(key.clone(), terminal.clone());
                    drop(terminals);
                    service.start_terminal_tasks(&key, &terminal);
                    *published.lock().map_err(|_| WorkspaceError::failed())? = Some(key.clone());
                    if cancelled.load(std::sync::atomic::Ordering::Acquire) {
                        if let Ok(mut map) = inner.terminals.lock() {
                            map.remove(&key);
                        }
                        terminal.close_now();
                        return Err(WorkspaceError::new(
                            "terminal_closed",
                            "Terminal request was cancelled",
                        ));
                    }
                    Ok(key)
                })
                .await
                .map_err(|_| WorkspaceError::failed())??;
                cancellation.disarm();
                return Ok(json!({"terminalId":terminal}));
            }
            #[cfg(not(unix))]
            {
                let _ = (parts, columns, rows);
                return Err(WorkspaceError::new(
                    "terminal_unavailable",
                    "Windows PTY and Job Object cleanup are not implemented",
                ));
            }
        }
        let root = root.clone();
        let payload = payload.clone();
        let op = op.to_owned();
        let relative = relative.to_owned();
        let permit = self
            .inner
            .files
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| WorkspaceError::failed())?;
        let mut cancellation = OperationGuard::new(&self.inner);
        let cancelled = cancellation.cancelled.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if cancelled.load(std::sync::atomic::Ordering::Acquire) {
                return Err(WorkspaceError::new(
                    "operation_cancelled",
                    "Workspace operation was cancelled",
                ));
            }
            file_operation(&root, &op, &relative, &parts, &payload)
        })
        .await
        .map_err(|_| WorkspaceError::failed())?;
        cancellation.disarm();
        result
    }
    fn root(&self, id: Option<&str>) -> WorkspaceResult<&Root> {
        let index = id
            .and_then(|s| s.strip_prefix('w'))
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse::<usize>().ok());
        index.and_then(|i| self.inner.roots.get(i)).ok_or_else(|| {
            WorkspaceError::new("workspace_not_found", "Select a configured workspace")
        })
    }
    fn capabilities(&self) -> Value {
        json!({"operations":["list","read","download","upload","diff"],"maxFileBytes":FILE_LIMIT,"maxTextBytes":TEXT_LIMIT,
            "workspaces":self.inner.roots.iter().enumerate().map(|(i,r)| {
                let enabled = r.terminal && cfg!(unix);
                json!({"id":format!("w{i}"),"name":r.name,"terminalEnabled":enabled,"terminalUnavailableReason":if enabled {Value::Null} else if !r.terminal {json!("Terminal is not explicitly enabled")} else {json!("Windows PTY and Job Object cleanup are not implemented")}})
            }).collect::<Vec<_>>()})
    }
    /// Call only for a trusted socket-disconnect notification, not from payload.
    pub async fn close_client(&self, trusted_socket_id: &str) {
        if let Ok(mut pending) = self.inner.pending_opens.lock() {
            for flag in pending.remove(trusted_socket_id).unwrap_or_default() {
                if let Some(flag) = flag.upgrade() {
                    flag.store(true, std::sync::atomic::Ordering::Release);
                }
            }
        }
        #[cfg(unix)]
        {
            let terminals = {
                let Ok(mut map) = self.inner.terminals.lock() else {
                    return;
                };
                let keys = map
                    .iter()
                    .filter(|(_, t)| t.client == trusted_socket_id)
                    .map(|(id, _)| id.clone())
                    .collect::<Vec<_>>();
                keys.into_iter()
                    .filter_map(|id| map.remove(&id))
                    .collect::<Vec<_>>()
            };
            if terminals.is_empty() {
                return;
            }
            let _ = tokio::task::spawn_blocking(move || {
                for terminal in terminals {
                    terminal.close_now();
                }
            })
            .await;
        }
        #[cfg(not(unix))]
        {
            let _ = trusted_socket_id;
        }
    }
    /// Call on plugin/server disconnect, including during shutdown. Drop is a
    /// synchronous fallback; explicit close is preferred so cleanup is observed.
    pub async fn close(&self) {
        self.inner
            .generation
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        #[cfg(unix)]
        {
            let terminals = match self.inner.terminals.lock() {
                Ok(mut map) => map.drain().map(|(_, t)| t).collect::<Vec<_>>(),
                Err(_) => return,
            };
            if terminals.is_empty() {
                return;
            }
            let _ = tokio::task::spawn_blocking(move || {
                for terminal in terminals {
                    terminal.close_now();
                }
            })
            .await;
        }
    }
    /// Gateway envelope: never route file/terminal data as assistant chat history.
    pub fn response_frame(request_id: &str, conversation_id: &str, result: Value) -> Value {
        json!({"version":1,"type":"workspace.response","request_id":request_id,"conversation_id":conversation_id,"payload":result})
    }
}
impl Drop for Inner {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Ok(map) = self.terminals.get_mut() {
            for (_, terminal) in map.drain() {
                terminal.close_now();
            }
        }
    }
}
fn expand_home(path: PathBuf) -> Result<PathBuf> {
    let value = path.to_str().context("workspace path must be UTF-8")?;
    if value == "~" || value.starts_with("~/") {
        let home = std::env::var_os("HOME").context("HOME is required to expand workspace path")?;
        Ok(PathBuf::from(home).join(value.strip_prefix("~/").unwrap_or("")))
    } else {
        Ok(path)
    }
}
fn invalid_path() -> WorkspaceError {
    WorkspaceError::new(
        "invalid_path",
        "Use a workspace-relative path without links or parent traversal",
    )
}
fn path_parts(path: &str) -> WorkspaceResult<Vec<String>> {
    if path.chars().count() > 1024 || path.starts_with('/') || path.contains(['\\', ':', '\0']) {
        return Err(invalid_path());
    }
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => return Err(invalid_path()),
            _ => parts.push(part.to_owned()),
        }
    }
    Ok(parts)
}
fn dimensions(payload: &Value) -> WorkspaceResult<(u16, u16)> {
    let columns = payload
        .get("columns")
        .map(|v| v.as_u64())
        .unwrap_or(Some(80));
    let rows = payload.get("rows").map(|v| v.as_u64()).unwrap_or(Some(24));
    match (columns, rows) {
        (Some(c), Some(r)) if (20..=300).contains(&c) && (5..=120).contains(&r) => {
            Ok((c as u16, r as u16))
        }
        _ => Err(WorkspaceError::new(
            "invalid_dimensions",
            "Terminal dimensions must be 20–300 columns and 5–120 rows",
        )),
    }
}
fn file_operation(
    root: &Root,
    op: &str,
    relative: &str,
    parts: &[String],
    payload: &Value,
) -> WorkspaceResult<Value> {
    #[cfg(unix)]
    {
        match op {
            "list" => unix::list(&root.directory, parts),
            "read" | "download" => {
                let mut file = unix::open_relative(&root.directory, parts, false)?;
                if !file.metadata()?.is_file() {
                    return Err(WorkspaceError::new(
                        "unsupported_file",
                        "Only regular files can be opened",
                    ));
                }
                let limit = if op == "read" { TEXT_LIMIT } else { FILE_LIMIT };
                let mut bytes = Vec::new();
                Read::by_ref(&mut file)
                    .take(limit as u64 + 1)
                    .read_to_end(&mut bytes)?;
                if bytes.len() > limit {
                    return Err(WorkspaceError::new(
                        "file_too_large",
                        "File exceeds the operation byte limit",
                    ));
                }
                if op == "read" {
                    let text = String::from_utf8(bytes).map_err(|_| {
                        WorkspaceError::new("binary_file", "This file is not UTF-8 text")
                    })?;
                    if text.contains('\0') {
                        return Err(WorkspaceError::new(
                            "binary_file",
                            "Binary files cannot be previewed",
                        ));
                    }
                    Ok(json!({"path":relative,"text":text,"truncated":false}))
                } else {
                    Ok(
                        json!({"path":relative,"name":parts.last().map(String::as_str).unwrap_or(""),"base64":STANDARD.encode(&bytes),"size":bytes.len()}),
                    )
                }
            }
            "upload" => {
                let encoded = payload["base64"]
                    .as_str()
                    .ok_or_else(|| WorkspaceError::new("file_too_large", "Upload exceeds 1 MiB"))?;
                if encoded.len() > FILE_LIMIT.div_ceil(3) * 4 {
                    return Err(WorkspaceError::new(
                        "file_too_large",
                        "Upload exceeds 1 MiB",
                    ));
                }
                let bytes = STANDARD
                    .decode(encoded)
                    .map_err(|_| WorkspaceError::failed())?;
                if bytes.len() > FILE_LIMIT {
                    return Err(WorkspaceError::new(
                        "file_too_large",
                        "Upload exceeds 1 MiB",
                    ));
                }
                unix::upload(&root.directory, parts, &bytes)?;
                Ok(json!({"path":relative,"size":bytes.len()}))
            }
            "diff" => {
                if !parts.is_empty() {
                    return Err(WorkspaceError::new(
                        "invalid_path",
                        "Diff operates on the workspace root",
                    ));
                }
                unix::git_diff(&root.directory, &root.path)
            }
            _ => Err(WorkspaceError::new(
                "unsupported_operation",
                "Workspace operation is not supported",
            )),
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (root, op, relative, parts, payload);
        Err(WorkspaceError::new(
            "unsupported_platform",
            "Windows protected file operations are not implemented",
        ))
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::{
        ffi::{CStr, CString},
        os::{
            fd::{AsRawFd, FromRawFd, RawFd},
            unix::{
                fs::OpenOptionsExt,
                process::{CommandExt, ExitStatusExt},
            },
        },
    };
    pub(super) fn open_directory(path: &Path) -> std::io::Result<File> {
        fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    }
    fn openat(parent: RawFd, name: &str, flags: i32, mode: libc::mode_t) -> WorkspaceResult<File> {
        let name = CString::new(name).map_err(|_| invalid_path())?;
        let fd = unsafe {
            libc::openat(
                parent,
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                mode,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return Err(
                if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
                    invalid_path()
                } else {
                    WorkspaceError::failed()
                },
            );
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    pub(super) fn open_relative(
        root: &File,
        parts: &[String],
        directory: bool,
    ) -> WorkspaceResult<File> {
        // A new open file description avoids sharing readdir offsets across
        // repeated or concurrent root listings (dup/try_clone would share them).
        let mut current = openat(root.as_raw_fd(), ".", libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        for (i, part) in parts.iter().enumerate() {
            let flags = libc::O_RDONLY
                | if directory || i + 1 < parts.len() {
                    libc::O_DIRECTORY
                } else {
                    0
                };
            current = openat(current.as_raw_fd(), part, flags, 0)?;
        }
        if directory && !current.metadata()?.is_dir() {
            return Err(invalid_path());
        }
        Ok(current)
    }
    pub(super) fn upload(root: &File, parts: &[String], bytes: &[u8]) -> WorkspaceResult<()> {
        let (last, parent) = parts.split_last().ok_or_else(invalid_path)?;
        let parent = open_relative(root, parent, true)?;
        let mut file = openat(
            parent.as_raw_fd(),
            last,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )?;
        file.write_all(bytes)?;
        file.sync_all()?;
        parent.sync_all()?;
        Ok(())
    }
    pub(super) fn list(root: &File, parts: &[String]) -> WorkspaceResult<Value> {
        let directory = open_relative(root, parts, true)?;
        let duplicate = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        if duplicate < 0 {
            return Err(WorkspaceError::failed());
        }
        let raw = unsafe { libc::fdopendir(duplicate) };
        if raw.is_null() {
            unsafe { libc::close(duplicate) };
            return Err(WorkspaceError::failed());
        }
        struct Directory(*mut libc::DIR);
        impl Drop for Directory {
            fn drop(&mut self) {
                unsafe { libc::closedir(self.0) };
            }
        }
        let guard = Directory(raw);
        let mut entries = Vec::new();
        let mut inspected = 0usize;
        loop {
            let entry = unsafe { libc::readdir(guard.0) };
            if entry.is_null() {
                break;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
            let bytes = name.to_bytes();
            if matches!(bytes, b"." | b"..") {
                continue;
            }
            inspected += 1;
            if inspected > MAX_ENTRIES {
                return Err(WorkspaceError::new(
                    "too_many_entries",
                    "Directory exceeds 1000 entries",
                ));
            }
            let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    metadata.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } < 0
            {
                return Err(WorkspaceError::failed());
            }
            let metadata = unsafe { metadata.assume_init() };
            let kind = metadata.st_mode & libc::S_IFMT;
            if kind != libc::S_IFDIR && kind != libc::S_IFREG {
                continue;
            }
            let name = name
                .to_str()
                .map_err(|_| {
                    WorkspaceError::new("invalid_path", "Directory contains a non-UTF-8 filename")
                })?
                .to_owned();
            let path = if parts.is_empty() {
                name.clone()
            } else {
                format!("{}/{}", parts.join("/"), name)
            };
            entries.push(json!({"name":name,"path":path,"isDirectory":kind==libc::S_IFDIR,"size":metadata.st_size}));
        }
        entries.sort_by_cached_key(|v| {
            (
                !v["isDirectory"].as_bool().unwrap_or(false),
                v["name"].as_str().unwrap_or("").to_lowercase(),
            )
        });
        Ok(json!({"entries":entries}))
    }
    pub(super) struct GitScope {
        worktree: PathBuf,
        git_dir: PathBuf,
        common_dir: PathBuf,
        descriptors: Vec<File>,
    }
    fn read_git_pointer(path: &Path) -> WorkspaceResult<String> {
        let mut file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)?;
        if !file.metadata()?.is_file() {
            return Err(invalid_path());
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file).take(4097).read_to_end(&mut bytes)?;
        if bytes.len() > 4096 {
            return Err(invalid_path());
        }
        String::from_utf8(bytes).map_err(|_| invalid_path())
    }
    fn git_scope(root: &File, path: &Path) -> WorkspaceResult<GitScope> {
        use std::os::unix::fs::MetadataExt;
        let held = root.metadata()?;
        let current = fs::symlink_metadata(path)?;
        if !current.is_dir()
            || current.file_type().is_symlink()
            || held.dev() != current.dev()
            || held.ino() != current.ino()
        {
            return Err(invalid_path());
        }
        for ancestor in path.ancestors() {
            let marker = ancestor.join(".git");
            let metadata = match fs::symlink_metadata(&marker) {
                Ok(m) => m,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            };
            if metadata.file_type().is_symlink() {
                return Err(invalid_path());
            }
            let (git_dir, common_dir) = if metadata.is_dir() {
                if fs::symlink_metadata(marker.join("commondir")).is_ok() {
                    return Err(invalid_path());
                }
                (marker.clone(), marker)
            } else if metadata.is_file() {
                let pointer = read_git_pointer(&marker)?;
                let target = pointer
                    .trim()
                    .strip_prefix("gitdir: ")
                    .filter(|s| !s.is_empty())
                    .ok_or_else(invalid_path)?;
                let target = fs::canonicalize(ancestor.join(target))?;
                // A standard linked worktree has a backlink to this exact .git
                // file. Do not follow arbitrary gitdir files into another repo.
                let backlink = read_git_pointer(&target.join("gitdir"))?;
                if fs::canonicalize(target.join(backlink.trim()))? != fs::canonicalize(&marker)? {
                    return Err(invalid_path());
                }
                if !target.is_dir() {
                    return Err(invalid_path());
                }
                let common = fs::canonicalize(
                    target.join(read_git_pointer(&target.join("commondir"))?.trim()),
                )?;
                if target.parent().and_then(Path::parent) != Some(common.as_path()) {
                    return Err(invalid_path());
                }
                (target, common)
            } else {
                return Err(invalid_path());
            };
            for file in [
                "HEAD",
                "config",
                "config.worktree",
                "objects",
                "objects/info",
                "objects/pack",
                "refs",
                "packed-refs",
            ] {
                if fs::symlink_metadata(common_dir.join(file))
                    .is_ok_and(|m| m.file_type().is_symlink())
                {
                    return Err(invalid_path());
                }
            }
            for file in ["objects/info/alternates", "objects/info/http-alternates"] {
                if fs::symlink_metadata(common_dir.join(file)).is_ok() {
                    return Err(WorkspaceError::new(
                        "git_unavailable",
                        "Protected diff does not allow alternate object databases",
                    ));
                }
            }
            return Ok(GitScope {
                worktree: ancestor.to_path_buf(),
                git_dir,
                common_dir,
                descriptors: Vec::new(),
            });
        }
        Err(WorkspaceError::new(
            "git_unavailable",
            "Workspace must be a Git repository with a HEAD commit",
        ))
    }
    fn format_diff(mut bytes: Vec<u8>) -> Value {
        let truncated = bytes.len() > TEXT_LIMIT;
        bytes.truncate(TEXT_LIMIT);
        json!({"text":String::from_utf8_lossy(&bytes),"truncated":truncated})
    }
    struct PrivateGitView {
        scope: GitScope,
    }
    impl Drop for PrivateGitView {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.scope.git_dir);
        }
    }
    fn hash_text(value: &str) -> WorkspaceResult<String> {
        let value = value.trim();
        if !matches!(value.len(), 40 | 64) || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(WorkspaceError::new(
                "git_unavailable",
                "Workspace must have a valid HEAD commit",
            ));
        }
        Ok(value.to_ascii_lowercase())
    }
    fn resolve_head(scope: &GitScope, deadline: Instant) -> WorkspaceResult<String> {
        use std::io::{BufRead, BufReader};
        let root = open_directory(&scope.git_dir)?;
        let common = open_directory(&scope.common_dir)?;
        let mut value = read_small_at(&root, &["HEAD".to_owned()])?;
        for _ in 0..8 {
            if Instant::now() >= deadline {
                return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
            }
            let Some(reference) = value.trim().strip_prefix("ref: ") else {
                return hash_text(&value);
            };
            let parts = path_parts(reference)?;
            if !reference.starts_with("refs/") || parts.iter().any(|p| p.is_empty()) {
                return Err(invalid_path());
            }
            match open_relative(&common, &parts, false) {
                Ok(mut file) => {
                    if !file.metadata()?.is_file() {
                        return Err(invalid_path());
                    }
                    let mut bytes = Vec::new();
                    Read::by_ref(&mut file).take(4097).read_to_end(&mut bytes)?;
                    if bytes.len() > 4096 {
                        return Err(invalid_path());
                    }
                    value = String::from_utf8(bytes).map_err(|_| invalid_path())?;
                }
                Err(_) => {
                    let file = open_relative(&common, &["packed-refs".into()], false)?;
                    if !file.metadata()?.is_file() {
                        return Err(invalid_path());
                    }
                    let mut reader = BufReader::new(file);
                    let mut found = None;
                    loop {
                        if Instant::now() >= deadline {
                            return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
                        }
                        let mut line = Vec::new();
                        let n = Read::by_ref(&mut reader)
                            .take(4097)
                            .read_until(b'\n', &mut line)?;
                        if n == 0 {
                            break;
                        }
                        if n > 4096 {
                            return Err(invalid_path());
                        }
                        let line = std::str::from_utf8(&line).map_err(|_| invalid_path())?;
                        if let Some((hash, name)) = line.trim_end().split_once(' ')
                            && name == reference
                        {
                            found = Some(hash_text(hash)?);
                            break;
                        }
                    }
                    return found.ok_or_else(|| {
                        WorkspaceError::new(
                            "git_unavailable",
                            "Workspace must have a valid HEAD commit",
                        )
                    });
                }
            }
        }
        Err(invalid_path())
    }
    fn read_small_at(root: &File, parts: &[String]) -> WorkspaceResult<String> {
        let mut file = open_relative(root, parts, false)?;
        if !file.metadata()?.is_file() {
            return Err(invalid_path());
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file).take(4097).read_to_end(&mut bytes)?;
        if bytes.len() > 4096 {
            return Err(invalid_path());
        }
        String::from_utf8(bytes).map_err(|_| invalid_path())
    }
    fn private_write(path: &Path, bytes: &[u8]) -> WorkspaceResult<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        file.write_all(bytes)?;
        Ok(())
    }
    #[cfg(target_os = "linux")]
    fn private_view(
        scope: GitScope,
        head: &str,
        deadline: Instant,
    ) -> WorkspaceResult<PrivateGitView> {
        use std::os::unix::fs::{DirBuilderExt, symlink};
        let path = std::env::temp_dir().join(format!(
            "orialis-git-view-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        let mut view = PrivateGitView {
            scope: GitScope {
                worktree: scope.worktree.clone(),
                git_dir: path,
                common_dir: PathBuf::new(),
                descriptors: Vec::new(),
            },
        };
        let worktree = open_directory(&scope.worktree)?;
        view.scope.worktree = PathBuf::from(format!("/proc/self/fd/{}", worktree.as_raw_fd()));
        view.scope.descriptors.push(worktree);
        for directory in ["objects", "objects/pack", "refs"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(view.scope.git_dir.join(directory))?;
        }
        let config = if head.len() == 64 {
            "[core]\nrepositoryformatversion = 1\nbare = false\n[extensions]\nobjectFormat = sha256\n"
        } else {
            "[core]\nrepositoryformatversion = 0\nbare = false\n"
        };
        private_write(&view.scope.git_dir.join("config"), config.as_bytes())?;
        private_write(
            &view.scope.git_dir.join("HEAD"),
            format!("{head}\n").as_bytes(),
        )?;
        let common = open_directory(&scope.common_dir)?;
        let objects = open_relative(&common, &["objects".into()], true)?;
        // Deliberately do not expose objects/info: no alternates, replacement
        // config, lazy fetch, hooks, attributes drivers, or external commands.
        for prefix in 0..=255 {
            if Instant::now() >= deadline {
                return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
            }
            let name = format!("{prefix:02x}");
            if fs::symlink_metadata(scope.common_dir.join("objects").join(&name)).is_err() {
                continue;
            }
            let directory = open_relative(&objects, std::slice::from_ref(&name), true)?;
            for entry in fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))? {
                if Instant::now() >= deadline {
                    return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
                }
                let entry = entry?;
                let leaf = entry.file_name();
                let leaf = leaf.to_str().ok_or_else(invalid_path)?;
                if matches!(leaf.len(), 38 | 62) && leaf.bytes().all(|b| b.is_ascii_hexdigit()) {
                    let metadata = fs::symlink_metadata(entry.path())?;
                    if !metadata.is_file() || metadata.file_type().is_symlink() {
                        return Err(invalid_path());
                    }
                }
            }
            symlink(
                format!("/proc/self/fd/{}", directory.as_raw_fd()),
                view.scope.git_dir.join("objects").join(&name),
            )?;
            view.scope.descriptors.push(directory);
        }
        let pack_path = scope.common_dir.join("objects/pack");
        if pack_path.exists() {
            let pack = open_relative(&objects, &["pack".into()], true)?;
            let mut count = 0usize;
            for entry in fs::read_dir(format!("/proc/self/fd/{}", pack.as_raw_fd()))? {
                let entry = entry?;
                count += 1;
                if count > 4096 {
                    return Err(WorkspaceError::new(
                        "git_unavailable",
                        "Git pack count exceeds the protected diff limit",
                    ));
                }
                let name = entry
                    .file_name()
                    .to_str()
                    .ok_or_else(invalid_path)?
                    .to_owned();
                let Some((hash, extension)) =
                    name.strip_prefix("pack-").and_then(|s| s.rsplit_once('.'))
                else {
                    continue;
                };
                if !matches!(extension, "idx" | "pack" | "rev")
                    || !matches!(hash.len(), 40 | 64)
                    || !hash.bytes().all(|b| b.is_ascii_hexdigit())
                {
                    continue;
                }
                let file = open_relative(&pack, std::slice::from_ref(&name), false)?;
                if !file.metadata()?.is_file() {
                    return Err(invalid_path());
                }
                symlink(
                    format!("/proc/self/fd/{}", file.as_raw_fd()),
                    view.scope.git_dir.join("objects/pack").join(&name),
                )?;
                view.scope.descriptors.push(file);
            }
        }
        // Preserve staged changes without reading any executable repository
        // configuration. Split indexes need their matching shared index files.
        let git_dir = open_directory(&scope.git_dir)?;
        let mut copied = 0u64;
        for entry in fs::read_dir(format!("/proc/self/fd/{}", git_dir.as_raw_fd()))? {
            let entry = entry?;
            let name = entry
                .file_name()
                .to_str()
                .ok_or_else(invalid_path)?
                .to_owned();
            if name != "index"
                && !name.strip_prefix("sharedindex.").is_some_and(|s| {
                    matches!(s.len(), 40 | 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
                })
            {
                continue;
            }
            let mut source = open_relative(&git_dir, std::slice::from_ref(&name), false)?;
            if !source.metadata()?.is_file() {
                return Err(invalid_path());
            }
            let mut target = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(view.scope.git_dir.join(name))?;
            let mut buffer = [0u8; 65536];
            loop {
                if Instant::now() >= deadline {
                    return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
                }
                let n = source.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                copied += n as u64;
                if copied > 128 * 1024 * 1024 {
                    return Err(WorkspaceError::new(
                        "git_unavailable",
                        "Git index exceeds the protected diff limit",
                    ));
                }
                target.write_all(&buffer[..n])?;
            }
        }
        Ok(view)
    }
    #[cfg(not(target_os = "linux"))]
    fn private_view(
        _scope: GitScope,
        _head: &str,
        _deadline: Instant,
    ) -> WorkspaceResult<PrivateGitView> {
        Err(WorkspaceError::new(
            "git_unavailable",
            "Protected Git diff requires Linux descriptor-backed object paths",
        ))
    }
    pub(super) fn git_diff(root: &File, path: &Path) -> WorkspaceResult<Value> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let scope = git_scope(root, path)?;
        let head = resolve_head(&scope, deadline)?;
        let view = private_view(scope, &head, deadline)?;
        Ok(format_diff(git_output(
            root,
            std::ffi::OsStr::new("git"),
            Some(&view.scope),
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--ignore-submodules=all",
                "HEAD",
                "--",
                ".",
            ],
            deadline,
        )?))
    }
    #[cfg(test)]
    pub(super) fn git_diff_command(
        root: &File,
        program: &std::ffi::OsStr,
        scope: Option<&GitScope>,
    ) -> WorkspaceResult<Value> {
        Ok(format_diff(git_output(
            root,
            program,
            scope,
            &["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", "."],
            Instant::now() + Duration::from_secs(5),
        )?))
    }
    fn git_output(
        root: &File,
        program: &std::ffi::OsStr,
        scope: Option<&GitScope>,
        arguments: &[&str],
        deadline: Instant,
    ) -> WorkspaceResult<Vec<u8>> {
        let cwd = root.try_clone()?;
        let fd = cwd.as_raw_fd();
        let inherited = scope
            .map(|s| {
                s.descriptors
                    .iter()
                    .map(AsRawFd::as_raw_fd)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let mut command = Command::new(program);
        if let Some(scope) = scope {
            command
                .arg("--git-dir")
                .arg(&scope.git_dir)
                .arg("--work-tree")
                .arg(&scope.worktree);
        }
        command
            .args([
                "--no-pager",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "diff.submodule=short",
            ])
            .args(arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_NO_LAZY_FETCH", "1")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_ATTR_NOSYSTEM", "1")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env_remove("GIT_CONFIG_COUNT")
            .env_remove("GIT_CONFIG_PARAMETERS")
            .env_remove("GIT_CONFIG")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_EXTERNAL_DIFF")
            .env_remove("GIT_DIFF_OPTS")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_OBJECT_DIRECTORY")
            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES");
        unsafe {
            command.pre_exec(move || {
                for inherited_fd in &inherited {
                    let flags = libc::fcntl(*inherited_fd, libc::F_GETFD);
                    if flags < 0
                        || libc::fcntl(*inherited_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                    {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                if libc::setpgid(0, 0) < 0 || libc::fchdir(fd) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().map_err(|_| {
            WorkspaceError::new(
                "git_unavailable",
                "Workspace must be a Git repository with a HEAD commit",
            )
        })?;
        struct Process {
            child: Child,
            complete: bool,
        }
        impl Drop for Process {
            fn drop(&mut self) {
                if !self.complete {
                    unsafe { libc::kill(-(self.child.id() as i32), libc::SIGKILL) };
                }
                let _ = self.child.wait();
            }
        }
        let mut process = Process {
            child,
            complete: false,
        };
        let mut output = process
            .child
            .stdout
            .take()
            .ok_or_else(WorkspaceError::failed)?;
        nonblocking(output.as_raw_fd())?;
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 16384];
        let mut eof = false;
        let mut status = None;
        loop {
            if Instant::now() >= deadline {
                return Err(WorkspaceError::new("diff_timeout", "Git diff timed out"));
            }
            let mut had_output = false;
            match output.read(&mut buffer) {
                Ok(0) => eof = true,
                Ok(n) => {
                    had_output = true;
                    let keep = n.min((TEXT_LIMIT + 1).saturating_sub(bytes.len()));
                    bytes.extend_from_slice(&buffer[..keep]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => return Err(WorkspaceError::failed()),
            }
            if status.is_none() {
                status = process.child.try_wait()?;
            }
            if eof && status.is_some() {
                break;
            }
            if !had_output {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
        process.complete = true;
        if !status.unwrap().success() {
            return Err(WorkspaceError::new(
                "git_unavailable",
                "Workspace must be a Git repository with a HEAD commit",
            ));
        }
        Ok(bytes)
    }
    pub(super) fn nonblocking(fd: RawFd) -> std::io::Result<()> {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
    pub(super) fn exit_code(status: std::process::ExitStatus) -> i32 {
        status
            .code()
            .unwrap_or_else(|| -status.signal().unwrap_or(1))
    }
    /// Interactive shells create separate job process groups. On Linux, include
    /// every group still in our own PTY session, not unrelated host processes.
    pub(super) fn kill_session(pid: u32) {
        #[cfg(target_os = "linux")]
        if let Ok(entries) = fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let Some(id) = entry
                    .file_name()
                    .to_str()
                    .and_then(|v| v.parse::<i32>().ok())
                else {
                    continue;
                };
                let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else {
                    continue;
                };
                let Some((_, tail)) = stat.rsplit_once(") ") else {
                    continue;
                };
                let fields = tail.split_whitespace().take(4).collect::<Vec<_>>();
                if fields.len() == 4 && fields[3].parse::<u32>().ok() == Some(pid) {
                    unsafe { libc::kill(id, libc::SIGKILL) };
                    if let Ok(group) = fields[2].parse::<i32>()
                        && group > 0
                    {
                        unsafe { libc::kill(-group, libc::SIGKILL) };
                    }
                }
            }
        }
        unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
    }
}

#[cfg(unix)]
struct Terminal {
    conversation: String,
    client: String,
    master: Arc<tokio::io::unix::AsyncFd<File>>,
    child: Mutex<Child>,
    state: Mutex<TerminalState>,
    reader: Mutex<Option<tokio::task::JoinHandle<()>>>,
}
#[cfg(unix)]
struct TerminalState {
    output: VecDeque<u8>,
    pending: Vec<u8>,
    truncated: bool,
    closed: bool,
    last_active: Instant,
}
#[cfg(unix)]
impl TerminalState {
    fn append(&mut self, bytes: &[u8], eof: bool) {
        let mut data = std::mem::take(&mut self.pending);
        data.extend_from_slice(bytes);
        let mut offset = 0;
        while offset < data.len() {
            match std::str::from_utf8(&data[offset..]) {
                Ok(text) => {
                    self.output.extend(text.as_bytes());
                    break;
                }
                Err(error) => {
                    self.output
                        .extend(&data[offset..offset + error.valid_up_to()]);
                    offset += error.valid_up_to();
                    match error.error_len() {
                        Some(n) => {
                            self.output.extend("�".as_bytes());
                            offset += n;
                        }
                        None => {
                            if eof {
                                self.output.extend("�".as_bytes());
                            } else {
                                self.pending.extend_from_slice(&data[offset..]);
                            }
                            break;
                        }
                    }
                }
            }
        }
        while self.output.len() > OUTPUT_LIMIT {
            self.output.pop_front();
            self.truncated = true;
        }
        while self.output.front().is_some_and(|b| b & 0xc0 == 0x80) {
            self.output.pop_front();
            self.truncated = true;
        }
    }
}
#[cfg(unix)]
fn take_terminal_output(state: &mut TerminalState) -> WorkspaceResult<String> {
    let text = String::from_utf8(state.output.drain(..).collect())
        .map_err(|_| WorkspaceError::failed())?;
    let mut encoded = 0usize;
    let mut split = text.len();
    for (index, ch) in text.char_indices() {
        let cost = match ch {
            '"' | '\\' | '\n' | '\r' | '\t' | '\u{8}' | '\u{c}' => 2,
            ch if ch <= '\u{1f}' => 6,
            ch => ch.len_utf8(),
        };
        if encoded + cost > REQUEST_LIMIT - 1024 {
            split = index;
            break;
        }
        encoded += cost;
    }
    // Escape-heavy terminal output must still fit the Gateway's JSON envelope.
    // Preserve the tail for the next read rather than silently dropping it.
    state.output.extend(&text.as_bytes()[split..]);
    Ok(text[..split].to_owned())
}

#[cfg(unix)]
impl Terminal {
    fn spawn(
        conversation: String,
        client: String,
        cwd: File,
        columns: u16,
        rows: u16,
        shell: &Path,
    ) -> WorkspaceResult<Arc<Self>> {
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::process::CommandExt,
        };
        let mut master = -1;
        let mut slave = -1;
        let winsize = libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null(),
                &winsize,
            )
        } < 0
        {
            return Err(WorkspaceError::new(
                "terminal_unavailable",
                "The host could not allocate a Unix PTY",
            ));
        }
        let master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        for fd in [master.as_raw_fd(), slave.as_raw_fd()] {
            if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err(WorkspaceError::failed());
            }
        }
        unix::nonblocking(master.as_raw_fd())?;
        let cwd_fd = cwd.as_raw_fd();
        let mut command = Command::new(shell);
        command
            .arg("-i")
            .env("TERM", "xterm-256color")
            .env("COLORTERM", "truecolor")
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() < 0
                    || libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY, 0) < 0
                    || libc::fchdir(cwd_fd) < 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                for signal in [
                    libc::SIGINT,
                    libc::SIGQUIT,
                    libc::SIGTSTP,
                    libc::SIGTTIN,
                    libc::SIGTTOU,
                ] {
                    libc::signal(signal, libc::SIG_DFL);
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        // SAFETY: AsyncFd exclusively owns this File. Its descriptor stays open,
        // fixed, and refers to the same PTY until AsyncFd drops it.
        let master = match unsafe { tokio::io::unix::AsyncFd::register(master) } {
            Ok(fd) => fd,
            Err(error) => {
                let mut child = child;
                unix::kill_session(child.id());
                let _ = child.wait();
                let (_, error) = error.into_parts();
                return Err(error.into());
            }
        };
        Ok(Arc::new(Self {
            conversation,
            client,
            master: Arc::new(master),
            child: Mutex::new(child),
            state: Mutex::new(TerminalState {
                output: VecDeque::new(),
                pending: Vec::new(),
                truncated: false,
                closed: false,
                last_active: Instant::now(),
            }),
            reader: Mutex::new(None),
        }))
    }
    fn poll(&self) -> WorkspaceResult<Option<i32>> {
        self.child
            .lock()
            .map_err(|_| WorkspaceError::failed())?
            .try_wait()
            .map(|s| s.map(unix::exit_code))
            .map_err(Into::into)
    }
    fn refresh(&self) -> WorkspaceResult<()> {
        let mut state = self.state.lock().map_err(|_| WorkspaceError::failed())?;
        if state.closed {
            return Err(WorkspaceError::new(
                "terminal_closed",
                "Terminal has exited",
            ));
        }
        state.last_active = Instant::now();
        Ok(())
    }
    fn read(&self) -> WorkspaceResult<Value> {
        let exit = self.poll()?;
        let mut state = self.state.lock().map_err(|_| WorkspaceError::failed())?;
        let output = take_terminal_output(&mut state)?;
        let truncated = std::mem::take(&mut state.truncated);
        Ok(json!({"output":output,"exited":exit.is_some(),"exitCode":exit,"truncated":truncated}))
    }
    async fn write(&self, input: &str) -> WorkspaceResult<()> {
        use std::os::fd::AsRawFd;
        if input.len() > 8192 {
            return Err(WorkspaceError::new(
                "invalid_input",
                "Terminal input exceeds 8192 bytes",
            ));
        }
        if self.poll()?.is_some() {
            return Err(WorkspaceError::new(
                "terminal_closed",
                "Terminal has exited",
            ));
        }
        let write = async {
            let mut remaining = input.as_bytes();
            while !remaining.is_empty() {
                if self
                    .state
                    .lock()
                    .map_err(|_| WorkspaceError::failed())?
                    .closed
                {
                    return Err(WorkspaceError::new(
                        "terminal_closed",
                        "Terminal has exited",
                    ));
                }
                let mut ready = self.master.writable().await?;
                match ready.try_io(|fd| {
                    let n = unsafe {
                        libc::write(
                            fd.get_ref().as_raw_fd(),
                            remaining.as_ptr().cast(),
                            remaining.len(),
                        )
                    };
                    if n < 0 {
                        Err(std::io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                }) {
                    Ok(Ok(0)) => return Err(WorkspaceError::failed()),
                    Ok(Ok(n)) => remaining = &remaining[n..],
                    Ok(Err(e)) => return Err(e.into()),
                    Err(_) => {}
                }
            }
            Ok(())
        };
        tokio::time::timeout(Duration::from_secs(5), write)
            .await
            .map_err(|_| {
                WorkspaceError::new(
                    "terminal_busy",
                    "Terminal input timed out; some input may already have been written",
                )
            })?
    }
    fn resize(&self, columns: u16, rows: u16) -> WorkspaceResult<()> {
        use std::os::fd::AsRawFd;
        let size = libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe { libc::ioctl(self.master.get_ref().as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0 {
            return Err(WorkspaceError::failed());
        }
        Ok(())
    }
    fn close_now(&self) {
        if let Ok(mut state) = self.state.lock() {
            if state.closed {
                return;
            }
            state.closed = true;
        }
        if let Ok(mut reader) = self.reader.lock()
            && let Some(reader) = reader.take()
        {
            reader.abort();
        }
        if let Ok(mut child) = self.child.lock() {
            unix::kill_session(child.id());
            let _ = child.wait();
        }
    }
}
#[cfg(unix)]
impl Drop for Terminal {
    fn drop(&mut self) {
        self.close_now();
    }
}

#[cfg(unix)]
impl WorkspaceService {
    async fn terminal_operation(
        &self,
        conversation: &str,
        client: &str,
        payload: &Value,
    ) -> WorkspaceResult<Value> {
        let key = payload["terminalId"].as_str().unwrap_or("");
        let terminal = self
            .inner
            .terminals
            .lock()
            .map_err(|_| WorkspaceError::failed())?
            .get(key)
            .cloned()
            .filter(|t| t.conversation == conversation && t.client == client)
            .ok_or_else(|| {
                WorkspaceError::new(
                    "terminal_not_found",
                    "Terminal is closed or belongs to another conversation",
                )
            })?;
        terminal.refresh()?;
        match payload["op"].as_str().unwrap_or("") {
            "terminal.read" => terminal.read(),
            "terminal.write" => {
                let input = payload["input"].as_str().ok_or_else(|| {
                    WorkspaceError::new("invalid_input", "Terminal input must be a string")
                })?;
                terminal.write(input).await?;
                Ok(json!({}))
            }
            "terminal.resize" => {
                let (c, r) = dimensions(payload)?;
                terminal.resize(c, r)?;
                Ok(json!({}))
            }
            "terminal.close" => {
                self.inner
                    .terminals
                    .lock()
                    .map_err(|_| WorkspaceError::failed())?
                    .remove(key);
                tokio::task::spawn_blocking(move || terminal.close_now())
                    .await
                    .map_err(|_| WorkspaceError::failed())?;
                Ok(json!({}))
            }
            _ => Err(WorkspaceError::failed()),
        }
    }
    fn start_terminal_tasks(&self, key: &str, terminal: &Arc<Terminal>) {
        use std::os::fd::AsRawFd;
        let weak = Arc::downgrade(terminal);
        let reader = tokio::spawn(async move {
            let mut buffer = [0u8; 4096];
            loop {
                let Some(terminal) = weak.upgrade() else {
                    break;
                };
                let Ok(mut ready) = terminal.master.readable().await else {
                    break;
                };
                match ready.try_io(|fd| {
                    let n = unsafe {
                        libc::read(
                            fd.get_ref().as_raw_fd(),
                            buffer.as_mut_ptr().cast(),
                            buffer.len(),
                        )
                    };
                    if n < 0 {
                        Err(std::io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                }) {
                    Ok(Ok(0)) | Ok(Err(_)) => {
                        if let Ok(mut state) = terminal.state.lock() {
                            state.append(&[], true);
                        }
                        break;
                    }
                    Ok(Ok(n)) => {
                        if let Ok(mut state) = terminal.state.lock() {
                            state.append(&buffer[..n], false);
                        }
                    }
                    Err(_) => {}
                }
            }
        });
        if let Ok(mut slot) = terminal.reader.lock() {
            *slot = Some(reader);
        } else {
            reader.abort();
        }
        let weak = Arc::downgrade(terminal);
        let inner = Arc::downgrade(&self.inner);
        let key = key.to_owned();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let (Some(terminal), Some(inner)) = (weak.upgrade(), inner.upgrade()) else {
                    break;
                };
                let expired = terminal
                    .state
                    .lock()
                    .map(|s| {
                        s.closed
                            || s.last_active.elapsed() > Duration::from_secs(TERMINAL_IDLE_SECONDS)
                    })
                    .unwrap_or(true);
                if expired {
                    if let Ok(mut map) = inner.terminals.lock() {
                        map.remove(&key);
                    }
                    let _ = tokio::task::spawn_blocking(move || terminal.close_now()).await;
                    break;
                }
            }
        });
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn utf8_decoder_preserves_partial_sequences_and_bounds_output() {
        let mut state = TerminalState {
            output: VecDeque::new(),
            pending: Vec::new(),
            truncated: false,
            closed: false,
            last_active: Instant::now(),
        };
        let bytes = "中文".as_bytes();
        state.append(&bytes[..2], false);
        assert!(state.output.is_empty());
        state.append(&bytes[2..], false);
        assert_eq!(
            String::from_utf8(state.output.drain(..).collect()).unwrap(),
            "中文"
        );
        state.append(&[0xff], false);
        assert_eq!(
            String::from_utf8(state.output.drain(..).collect()).unwrap(),
            "�"
        );
        state.append("界".repeat(OUTPUT_LIMIT).as_bytes(), false);
        assert!(state.output.len() <= OUTPUT_LIMIT);
        assert!(state.truncated);
        assert!(String::from_utf8(state.output.drain(..).collect()).is_ok());
    }
    #[tokio::test]
    async fn inactivity_lease_expires_without_client_requests() {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(TERMINAL_IDLE_SECONDS, 120);
        let dir = tempfile::tempdir().unwrap();
        let shell = dir.path().join("fixture-shell");
        fs::write(
            &shell,
            format!(
                "#!/bin/sh\nexec env -i PATH=/usr/bin:/bin HOME='{}' ENV=/dev/null /bin/sh -i\n",
                dir.path().display()
            ),
        )
        .unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        let service = WorkspaceService::new_with_shell(
            vec![WorkspaceConfig {
                path: dir.path().into(),
                name: None,
                terminal: true,
            }],
            shell,
        )
        .unwrap();
        let response = service
            .handle(
                "c",
                "socket",
                &json!({"op":"terminal.open","workspaceId":"w0"}),
            )
            .await;
        assert_eq!(response["ok"], true, "{response}");
        let id = response["data"]["terminalId"].as_str().unwrap();
        let terminal = service.inner.terminals.lock().unwrap()[id].clone();
        terminal.state.lock().unwrap().last_active = Instant::now() - Duration::from_secs(121);
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert!(!service.inner.terminals.lock().unwrap().contains_key(id));
        assert!(terminal.poll().unwrap().is_some());
        service.close().await;
    }
}

#[cfg(all(test, target_os = "linux"))]
mod process_tests {
    use super::*;
    #[test]
    fn git_timeout_kills_real_subprocess_group() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("fixture-git");
        fs::write(
            &program,
            "#!/bin/sh\nsleep 60 &\nprintf '%s\\n' $! > child.pid\nwait\n",
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        let root = unix::open_directory(dir.path()).unwrap();
        let started = Instant::now();
        let result = unix::git_diff_command(&root, program.as_os_str(), None);
        assert_eq!(result.unwrap_err().code, "diff_timeout");
        assert!(started.elapsed() >= Duration::from_secs(5));
        assert!(started.elapsed() < Duration::from_secs(7));
        let child = fs::read_to_string(dir.path().join("child.pid"))
            .unwrap()
            .trim()
            .parse::<i32>()
            .unwrap();
        let mut stopped = false;
        for _ in 0..100 {
            let stat = fs::read_to_string(format!("/proc/{child}/stat"));
            if stat.is_err()
                || stat
                    .unwrap()
                    .rsplit_once(") ")
                    .is_some_and(|(_, tail)| tail.starts_with('Z'))
            {
                stopped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(stopped, "git timeout left a running descendant");
    }
}

#[cfg(all(test, unix))]
mod cancellation_tests {
    use super::*;
    #[test]
    fn queued_open_cancellation_and_socket_disconnect_do_not_leak_or_cross_clients() {
        use std::os::unix::fs::PermissionsExt;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .unwrap();
        runtime.block_on(async {
            let dir=tempfile::tempdir().unwrap();let shell=dir.path().join("fixture-shell");
            fs::write(&shell,format!("#!/bin/sh\nexec env -i PATH=/usr/bin:/bin HOME='{}' ENV=/dev/null /bin/sh -i\n",dir.path().display())).unwrap();fs::set_permissions(&shell,fs::Permissions::from_mode(0o700)).unwrap();
            let service=WorkspaceService::new_with_shell(vec![WorkspaceConfig{path:dir.path().into(),name:None,terminal:true}],shell).unwrap();
            let(start_tx,start_rx)=tokio::sync::oneshot::channel();let(release_tx,release_rx)=std::sync::mpsc::channel();
            let blocker=tokio::task::spawn_blocking(move||{let _=start_tx.send(());release_rx.recv().unwrap();});start_rx.await.unwrap();
            let cloned=service.clone();let cancelled=tokio::spawn(async move{cloned.handle("c","cancelled",&json!({"op":"terminal.open","workspaceId":"w0"})).await});
            while !service.inner.pending_opens.lock().unwrap().contains_key("cancelled"){tokio::task::yield_now().await;}
            cancelled.abort();let _=cancelled.await;
            let cloned=service.clone();let disconnected=tokio::spawn(async move{cloned.handle("c","socket-a",&json!({"op":"terminal.open","workspaceId":"w0"})).await});
            let cloned=service.clone();let unaffected=tokio::spawn(async move{cloned.handle("c","socket-b",&json!({"op":"terminal.open","workspaceId":"w0"})).await});
            loop{let ready={let map=service.inner.pending_opens.lock().unwrap();map.contains_key("socket-a")&&map.contains_key("socket-b")};if ready{break;}tokio::task::yield_now().await;}
            service.close_client("socket-a").await;release_tx.send(()).unwrap();blocker.await.unwrap();
            assert_eq!(disconnected.await.unwrap()["ok"],false);assert_eq!(unaffected.await.unwrap()["ok"],true);
            { let terminals=service.inner.terminals.lock().unwrap();assert_eq!(terminals.len(),1);assert!(terminals.values().all(|t|t.client=="socket-b")); } service.close().await;
        });
    }
    #[test]
    fn escape_heavy_terminal_output_retains_tail_within_wire_limit() {
        let mut state = TerminalState {
            output: VecDeque::new(),
            pending: Vec::new(),
            truncated: false,
            closed: false,
            last_active: Instant::now(),
        };
        state.append(&vec![0x1b; OUTPUT_LIMIT], false);
        let first = take_terminal_output(&mut state).unwrap();
        assert!(!state.output.is_empty());
        assert!(serde_json::to_vec(&json!({"output":first})).unwrap().len() < REQUEST_LIMIT);
        let second = take_terminal_output(&mut state).unwrap();
        assert_eq!(first.len() + second.len(), OUTPUT_LIMIT);
        assert!(state.output.is_empty());
        assert!(!state.truncated);
    }
}
