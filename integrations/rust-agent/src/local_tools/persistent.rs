//! Ephemeral Python state with a host-enforced stopped interval between cells.
//! Pipes carry untrusted messages, never authority. No socket or host fallback.
use super::python_clean;
use super::python_output::{Capture, append_warning};
use super::*;
use std::sync::atomic::AtomicU64;

const LOCAL_NAMES: &[(&str, &[&str])] = &[
    ("read_file", &["path", "offset", "limit"]),
    ("write_file", &["path", "content"]),
    (
        "patch",
        &["path", "old_string", "new_string", "replace_all"],
    ),
    (
        "search_files",
        &[
            "pattern",
            "target",
            "path",
            "file_glob",
            "limit",
            "offset",
            "output_mode",
            "context",
        ],
    ),
    ("skills_list", &["category"]),
    ("skill_view", &["name", "file_path"]),
    ("skill_manage", &["operations"]),
    ("todo_list", &["todos", "merge"]),
];
const FRAME_LIMIT: usize = 2 * 1024 * 1024;
const LIFETIME: Duration = Duration::from_secs(3600);

/// Host-only, explicit callback allowlist. The dispatcher must enforce its own
/// permissions using the supplied TurnContext. It must not alias a denied tool.
/// There is no generic model-selectable dispatch or automatic registration.
#[derive(Clone)]
pub struct PythonBridge {
    executor: Arc<dyn ToolExecutor>,
    names: Vec<String>,
}
impl PythonBridge {
    pub(super) async fn set_generation(&self, session: &str, generation: i64) -> Result<()> {
        self.executor
            .set_session_generation(session, generation)
            .await
    }
    pub fn new(executor: Arc<dyn ToolExecutor>, names: Vec<String>) -> Result<Self> {
        ensure!(
            !names.is_empty() && names.len() <= 128,
            "invalid bridge allowlist"
        );
        let schemas = executor.schemas();
        let mut seen = std::collections::HashSet::new();
        for name in &names {
            ensure!(
                !name.is_empty()
                    && name.len() <= 64
                    && name.as_bytes()[0].is_ascii_alphabetic()
                    && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                    && !LOCAL_NAMES.iter().any(|(local, _)| local == name)
                    && ![
                        "execute_code",
                        "terminal",
                        "process_manage",
                        "delegate_task",
                        "json_parse",
                        "shell_quote",
                        "retry"
                    ]
                    .contains(&name.as_str())
                    && seen.insert(name.clone())
                    && schemas
                        .iter()
                        .any(|s| s["type"] == "function" && s["function"]["name"] == *name),
                "bridge name must be registered, unique and nonrecursive"
            );
        }
        Ok(Self { executor, names })
    }
}

pub(super) struct Kernels {
    entries: Mutex<HashMap<String, Arc<Kernel>>>,
    closed: AtomicBool,
    generations: Mutex<GenerationFences>,
    retirement: Arc<Retirement>,
}
#[derive(Default)]
struct GenerationFences {
    // Only resets need a permanent tombstone. Ordinary generation-zero turns
    // must not consume a slot, even when they never use Python.
    positive: HashMap<String, i64>,
    // A failed reset cannot forget its fence and then admit generation zero.
    // One sticky flag bounds this failure state without evicting old tombstones
    // or allocating an unbounded list of rejected routes.
    untracked_blocked: bool,
}
impl GenerationFences {
    fn current(&self, session: &str) -> Result<i64> {
        match self.positive.get(session) {
            Some(generation) => Ok(*generation),
            None => {
                ensure!(
                    !self.untracked_blocked,
                    "local session generation capacity reached; untracked sessions disabled until reopen"
                );
                Ok(0)
            }
        }
    }
}
struct Kernel {
    conversation: String,
    session: String,
    generation: i64,
    gate: Arc<tokio::sync::Mutex<()>>,
    process: Mutex<Option<OwnedKernel>>,
    pipes: Mutex<Option<Pipes>>,
    retired: Arc<AtomicBool>,
    last_used: Mutex<Instant>,
    born: Instant,
    execution_count: AtomicU64,
    masks: Mutex<Vec<(String, bool)>>,
    id: String,
    sentinel: String,
    retirement: Arc<Retirement>,
}
struct OwnedKernel {
    child: Child,
    #[cfg(target_os = "linux")]
    pidfd: File,
    #[cfg(target_os = "linux")]
    pid: i32,
    _slot: tokio::sync::OwnedSemaphorePermit,
}
struct Retiring {
    child: Child,
    slot: Option<tokio::sync::OwnedSemaphorePermit>,
    finished: Arc<AtomicBool>,
}
struct Retirement {
    sender: std::sync::mpsc::Sender<Retiring>,
    receiver: Mutex<Option<std::sync::mpsc::Receiver<Retiring>>>,
    pending: Arc<std::sync::atomic::AtomicUsize>,
}
impl Default for Kernels {
    fn default() -> Self {
        let (sender, receiver) = std::sync::mpsc::channel();
        Self {
            entries: Mutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
            generations: Mutex::new(GenerationFences::default()),
            retirement: Arc::new(Retirement {
                sender,
                receiver: Mutex::new(Some(receiver)),
                pending: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            }),
        }
    }
}
impl Retirement {
    fn enqueue(
        &self,
        mut child: Child,
        slot: tokio::sync::OwnedSemaphorePermit,
    ) -> Arc<AtomicBool> {
        // Signal and queue only. Waiting/reaping never runs on a Tokio worker or
        // under the session registry lock. Slots remain held until actual reap.
        kill_owned_child(&mut child);
        let finished = Arc::new(AtomicBool::new(false));
        self.pending.fetch_add(1, Ordering::AcqRel);
        let _ = self.sender.send(Retiring {
            child,
            slot: Some(slot),
            finished: finished.clone(),
        });
        finished
    }
}
enum Framing {
    Raw,
    Header,
    Body(usize),
}
struct Pipes {
    input: std::process::ChildStdin,
    protocol: std::process::ChildStdout,
    output: std::process::ChildStderr,
    buffer: Vec<u8>,
    framing: Framing,
    sentinel: Vec<u8>,
}
impl Kernels {
    fn acquire(
        &self,
        key: String,
        conversation: &str,
        session: &str,
        expected: Option<i64>,
        limit: usize,
    ) -> Result<Arc<Kernel>> {
        let mut entries = self.entries.lock().unwrap();
        ensure!(
            !self.closed.load(Ordering::Acquire),
            "local Python service is shut down"
        );
        let generation = self.generations.lock().unwrap().current(session)?;
        ensure!(
            expected.is_none_or(|expected| expected == generation),
            "stale session generation; no cell executed"
        );
        entries.retain(|_, k| !k.retired.load(Ordering::Acquire));
        if let Some(kernel) = entries.get(&key) {
            return Ok(kernel.clone());
        }
        ensure!(
            entries.len() < limit,
            "maximum persistent Python sessions reached"
        );
        let kernel = Arc::new(Kernel {
            conversation: conversation.to_owned(),
            session: session.to_owned(),
            generation,
            gate: Arc::new(tokio::sync::Mutex::new(())),
            process: Mutex::new(None),
            pipes: Mutex::new(None),
            retired: Arc::new(AtomicBool::new(false)),
            last_used: Mutex::new(Instant::now()),
            born: Instant::now(),
            execution_count: AtomicU64::new(0),
            masks: Mutex::new(Vec::new()),
            id: format!("kernel_{}", uuid::Uuid::new_v4()),
            sentinel: format!("\u{001e}HERMES-{}\u{001f}", uuid::Uuid::new_v4()),
            retirement: self.retirement.clone(),
        });
        entries.insert(key, kernel.clone());
        Ok(kernel)
    }
    pub(super) fn check_generation(&self, session: &str, expected: i64) -> Result<()> {
        ensure!(
            self.generations.lock().unwrap().current(session)? == expected,
            "stale session generation"
        );
        Ok(())
    }
    pub(super) fn current_generation(&self, session: &str) -> Result<i64> {
        self.generations.lock().unwrap().current(session)
    }
    pub(super) fn set_generation(
        &self,
        session: &str,
        generation: i64,
        capacity: usize,
    ) -> Result<()> {
        ensure!(generation >= 0, "invalid session generation");
        let entries = self.entries.lock().unwrap();
        let mut generations = self.generations.lock().unwrap();
        let current = generations.current(session)?;
        if generation <= current {
            return Ok(());
        }
        if !generations.positive.contains_key(session) && generations.positive.len() >= capacity {
            generations.untracked_blocked = true;
            // Mark every now-blocked kernel before releasing the fence lock.
            // A callback approved after this point cannot commit via its old
            // cell-bound grant, and queued cells cannot adopt a fresh kernel.
            let blocked = entries
                .values()
                .filter(|kernel| !generations.positive.contains_key(&kernel.session))
                .collect::<Vec<_>>();
            for kernel in &blocked {
                kernel.retired.store(true, Ordering::Release);
            }
            drop(generations);
            for kernel in blocked {
                kernel.stop();
            }
            bail!(
                "local session generation capacity reached; no tombstone eviction; untracked sessions disabled until reopen"
            );
        }
        generations.positive.insert(session.to_owned(), generation);
        // Invalidate before waiting for process teardown. Late approved/queued
        // cells reference this retired object and cannot adopt the new epoch.
        for kernel in entries
            .values()
            .filter(|k| k.session == session && k.generation < generation)
        {
            kernel.retired.store(true, Ordering::Release);
        }
        drop(generations);
        for kernel in entries
            .values()
            .filter(|k| k.session == session && k.generation < generation)
        {
            kernel.stop();
        }
        Ok(())
    }
    pub(super) fn cancel(&self, conversation: Option<&str>) {
        let entries = self.entries.lock().unwrap();
        for kernel in entries
            .values()
            .filter(|k| conversation.is_none_or(|c| c == k.conversation))
        {
            kernel.stop();
        }
    }
    pub(super) fn is_reaped(&self) -> bool {
        self.retirement.pending.load(Ordering::Acquire) == 0
    }
    pub(super) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.cancel(None);
    }
}
impl Drop for Kernels {
    fn drop(&mut self) {
        self.close();
    }
}
impl Kernel {
    fn dispose_process(&self) -> Option<Arc<AtomicBool>> {
        let owned = self.process.lock().unwrap().take()?;
        #[cfg(target_os = "linux")]
        let _ = pid_signal(&owned.pidfd, libc::SIGKILL);
        Some(self.retirement.enqueue(owned.child, owned._slot))
    }
    fn stop(&self) {
        self.retired.store(true, Ordering::Release);
        self.dispose_process();
    }
    fn alive(&self) -> Result<()> {
        ensure!(
            !self.retired.load(Ordering::Acquire),
            "kernel was cancelled or retired; state was lost"
        );
        let mut process = self.process.lock().unwrap();
        ensure!(
            process
                .as_mut()
                .context("kernel is not running")?
                .child
                .try_wait()?
                .is_none(),
            "kernel exited; state was lost"
        );
        Ok(())
    }
    #[cfg(target_os = "linux")]
    fn pause(&self) -> Result<()> {
        // pidfd addresses the exact owned sandbox process even after PID reuse.
        let (pidfd, pid) = {
            let process = self.process.lock().unwrap();
            let process = process.as_ref().context("kernel is not running")?;
            (process.pidfd.try_clone()?, process.pid)
        };
        pid_signal(&pidfd, libc::SIGSTOP)?;
        let until = Instant::now() + Duration::from_secs(1);
        loop {
            ensure!(
                !self.retired.load(Ordering::Acquire),
                "kernel retired while stopping"
            );
            let status = fs::read_to_string(format!("/proc/{pid}/status"))?;
            if status
                .lines()
                .any(|line| line.starts_with("State:\tT") || line.starts_with("State:\tt"))
            {
                return Ok(());
            }
            ensure!(
                Instant::now() < until,
                "cannot confirm stopped kernel; refusing continued execution"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    #[cfg(not(target_os = "linux"))]
    fn pause(&self) -> Result<()> {
        bail!("persistent Python requires Linux pidfd supervision")
    }
    #[cfg(target_os = "linux")]
    fn resume(&self) -> Result<()> {
        let process = self.process.lock().unwrap();
        ensure!(!self.retired.load(Ordering::Acquire), "kernel was retired");
        pid_signal(
            &process.as_ref().context("kernel is not running")?.pidfd,
            libc::SIGCONT,
        )
    }
    #[cfg(not(target_os = "linux"))]
    fn resume(&self) -> Result<()> {
        bail!("persistent Python requires Linux pidfd supervision")
    }
}

pub(super) fn start_reaper(inner: &Arc<Inner>) -> Result<()> {
    let weak = Arc::downgrade(inner);
    let receiver = inner
        .python
        .retirement
        .receiver
        .lock()
        .unwrap()
        .take()
        .context("kernel reaper already started")?;
    let pending = inner.python.retirement.pending.clone();
    std::thread::Builder::new()
        .name("python-kernel-reaper".into())
        .spawn(move || {
            let mut retiring = Vec::<Retiring>::new();
            let mut disconnected = false;
            loop {
                match receiver.recv_timeout(if retiring.is_empty() {
                    Duration::from_millis(100)
                } else {
                    Duration::from_millis(1)
                }) {
                    Ok(child) => retiring.push(child),
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => disconnected = true,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                }
                retiring.retain_mut(|process| {
                    // Uncertain wait errors do not release a resource slot or claim
                    // completion. A stuck OS process cannot create unlimited slots.
                    if matches!(process.child.try_wait(), Ok(Some(_))) {
                        process.slot.take();
                        process.finished.store(true, Ordering::Release);
                        pending.fetch_sub(1, Ordering::AcqRel);
                        false
                    } else {
                        true
                    }
                });
                if let Some(inner) = weak.upgrade() {
                    let mut entries = inner.python.entries.lock().unwrap();
                    entries.retain(|_, kernel| {
                        if let Ok(_gate) = kernel.gate.try_lock()
                            && (kernel.last_used.lock().unwrap().elapsed()
                                >= inner.cfg.python_idle_timeout
                                || kernel.born.elapsed() >= LIFETIME)
                        {
                            kernel.stop();
                        }
                        !kernel.retired.load(Ordering::Acquire)
                    });
                }
                if disconnected && retiring.is_empty() {
                    break;
                }
                if disconnected {
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        })?;
    Ok(())
}

struct CancelOnDrop {
    kernel: Arc<Kernel>,
    armed: bool,
}
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self.armed {
            self.kernel.stop();
        }
    }
}

impl LocalTools {
    pub(super) async fn execute_python_at_generation(
        &self,
        args: Value,
        context: &TurnContext,
        expected: Option<i64>,
    ) -> Result<Value> {
        known(&args, &["code", "reset"])?;
        let code = string(&args, "code")?.to_owned();
        ensure!(code.len() <= 128 * 1024, "code exceeds 128 KiB");
        let reset = args["reset"].as_bool().unwrap_or(false);
        let key = scope(context)?;
        let kernel = self.inner.python.acquire(
            key,
            &context.conversation_id,
            &context.session_id,
            expected,
            self.inner.cfg.max_processes,
        )?;
        let gate = kernel.gate.clone().lock_owned().await;
        ensure!(
            !kernel.retired.load(Ordering::Acquire),
            "queued cell was cancelled; no execution occurred"
        );
        let action = self.action("execute_code", &json!({
            "code": code, "reset": reset, "kernel":kernel.id,
            "execution_count":kernel.execution_count.load(Ordering::Acquire),
            "timeout_ms":self.inner.cfg.timeout.as_millis(),
            "workspace_access":if self.inner.cfg.write == Permission::Deny {"read_only"} else {"read_write"},
        }));
        let permission = match (self.inner.cfg.execute, self.inner.cfg.write) {
            (Permission::Deny, _) => Permission::Deny,
            (_, Permission::Ask) => Permission::Ask,
            (p, _) => p,
        };
        let permit = self
            .authorize(
                permission,
                context,
                &action,
                &format!(
                    "Run Python cell{} in this session for at most {:?}\n{}",
                    if reset { " after discarding state" } else { "" },
                    self.inner.cfg.timeout,
                    code.chars().take(6000).collect::<String>()
                ),
            )
            .await?;
        let tools = self.clone();
        let context = context.clone();
        let worker_kernel = kernel.clone();
        let runtime = tokio::runtime::Handle::current();
        let mut cancellation = CancelOnDrop {
            kernel,
            armed: true,
        };
        let value = tokio::task::spawn_blocking(move || {
            let _gate = gate;
            run_cell(
                &tools,
                &worker_kernel,
                code,
                reset,
                context,
                permit,
                action,
                &runtime,
            )
        })
        .await?;
        cancellation.armed = false;
        value
    }
    fn python_specs(&self) -> Value {
        let enabled = self.schemas();
        let mut specs = serde_json::Map::new();
        for (name, positional) in LOCAL_NAMES {
            if enabled.iter().any(|s| s["function"]["name"] == *name) {
                specs.insert((*name).to_owned(), json!(positional));
            }
        }
        if let Some(extension) = &self.inner.python_bridge {
            for name in &extension.names {
                specs.insert(name.clone(), json!([]));
            }
        }
        Value::Object(specs)
    }
    async fn python_callback(
        &self,
        name: &str,
        arguments: Value,
        context: &TurnContext,
        generation: i64,
    ) -> Result<Value> {
        self.inner
            .python
            .check_generation(&context.session_id, generation)?;
        ensure!(
            arguments.is_object(),
            "callback arguments must be an object"
        );
        if LOCAL_NAMES.iter().any(|(local, _)| *local == name) {
            ensure!(
                self.schemas().iter().any(|s| s["function"]["name"] == name),
                "callback disabled by host policy"
            );
            return self
                .execute_at_generation(name, arguments, context, generation)
                .await;
        }
        let extension = self
            .inner
            .python_bridge
            .as_ref()
            .context("unknown or disabled Python callback")?;
        ensure!(
            extension.names.iter().any(|allowed| allowed == name),
            "unknown or disabled Python callback"
        );
        extension
            .executor
            .execute_at_generation(name, arguments, context, generation)
            .await
    }
}

#[cfg(target_os = "linux")]
fn pid_signal(pidfd: &File, signal: i32) -> Result<()> {
    ensure!(
        unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                pidfd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        } == 0,
        "cannot signal owned kernel: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}
fn nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
        "cannot configure kernel pipe"
    );
    Ok(())
}
#[cfg(target_os = "linux")]
fn launch(tools: &LocalTools, kernel: &Arc<Kernel>, deadline: Instant) -> Result<()> {
    let inner = &tools.inner;
    let slot = loop {
        match inner.execution_slots.clone().try_acquire_owned() {
            Ok(slot) => break slot,
            Err(_) if !inner.python.is_reaped() => {
                ensure!(
                    Instant::now() < deadline && !kernel.retired.load(Ordering::Acquire),
                    "prior kernel cleanup exceeded deadline or was cancelled"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(error) => return Err(error).context("maximum concurrent local processes reached"),
        }
    };
    let name = inner
        .cfg
        .python_program
        .as_ref()
        .context("Python runtime is not configured")?;
    let executable = &inner
        .cfg
        .programs
        .iter()
        .find(|p| &p.name == name)
        .context("Python program is not configured")?
        .executable;
    let mut fds = [-1; 2];
    ensure!(
        unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } == 0,
        "cannot create kernel status pipe"
    );
    let mut status = unsafe { File::from_raw_fd(fds[0]) };
    let status_write = unsafe { File::from_raw_fd(fds[1]) };
    nonblocking(status.as_raw_fd())?;
    let args = vec![
        "-I".to_owned(),
        "-u".to_owned(),
        "-c".to_owned(),
        include_str!("kernel_runner.py").to_owned(),
        tools.python_specs().to_string(),
        kernel.sentinel.clone(),
    ];
    let mut command =
        sandbox_command_with_status(inner, executable, &args, "", Some(status_write))?;
    let mut child = command
        .spawn()
        .context("kernel sandbox did not start; no unsandboxed fallback")?;
    drop(command);
    let setup = (|| -> Result<(i32, File, Pipes)> {
        let input = child.stdin.take().context("kernel input unavailable")?;
        let protocol = child.stdout.take().context("kernel output unavailable")?;
        let output = child.stderr.take().context("kernel stderr unavailable")?;
        for fd in [input.as_raw_fd(), protocol.as_raw_fd(), output.as_raw_fd()] {
            nonblocking(fd)?;
        }
        let mut bytes = Vec::new();
        let pid = loop {
            let mut chunk = [0; 1024];
            match status.read(&mut chunk) {
                Ok(n) if n > 0 => {
                    bytes.extend_from_slice(&chunk[..n]);
                    ensure!(bytes.len() <= 4096, "invalid sandbox status");
                    if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                        let pid = value["child-pid"]
                            .as_i64()
                            .context("sandbox status lacks child PID")?;
                        ensure!(
                            pid > 0 && pid <= i32::MAX as i64,
                            "invalid sandbox child PID"
                        );
                        break pid as i32;
                    }
                }
                Ok(_) => bail!("sandbox closed before trusted process identity; no host fallback"),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
            ensure!(
                Instant::now() < deadline && !kernel.retired.load(Ordering::Acquire),
                "kernel startup cancelled or timed out"
            );
            ensure!(child.try_wait()?.is_none(), "sandbox exited during startup");
            std::thread::sleep(Duration::from_millis(1));
        };
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        ensure!(
            fd >= 0,
            "cannot obtain owned kernel pidfd; no weaker supervision fallback"
        );
        Ok((
            pid,
            unsafe { File::from_raw_fd(fd as i32) },
            Pipes {
                input,
                protocol,
                output,
                buffer: Vec::new(),
                framing: Framing::Raw,
                sentinel: kernel.sentinel.as_bytes().to_vec(),
            },
        ))
    })();
    let (pid, pidfd, pipes) = match setup {
        Ok(parts) => parts,
        Err(error) => {
            inner.python.retirement.enqueue(child, slot);
            return Err(error);
        }
    };
    let mut process = kernel.process.lock().unwrap();
    if kernel.retired.load(Ordering::Acquire) {
        let _ = pid_signal(&pidfd, libc::SIGKILL);
        inner.python.retirement.enqueue(child, slot);
        bail!("kernel startup was cancelled");
    }
    *process = Some(OwnedKernel {
        child,
        pidfd,
        pid,
        _slot: slot,
    });
    drop(process);
    *kernel.pipes.lock().unwrap() = Some(pipes);
    Ok(())
}
#[cfg(not(target_os = "linux"))]
fn launch(_: &LocalTools, _: &Arc<Kernel>, _: Instant) -> Result<()> {
    bail!("persistent Python requires verified Linux sandbox and pidfd supervision")
}

fn output_drain(pipes: &mut Pipes, output: &mut Capture) -> Result<()> {
    let mut buf = [0; 8192];
    for _ in 0..16 {
        match pipes.output.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => output.push(&buf[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
fn take_frame(pipes: &mut Pipes, output: &mut Capture) -> Result<Option<Value>> {
    loop {
        match pipes.framing {
            Framing::Raw => {
                if let Some(at) = pipes
                    .buffer
                    .windows(pipes.sentinel.len())
                    .position(|part| part == pipes.sentinel)
                {
                    output.push(&pipes.buffer[..at]);
                    pipes.buffer.drain(..at + pipes.sentinel.len());
                    pipes.framing = Framing::Header;
                } else {
                    let keep = (1..pipes.sentinel.len().min(pipes.buffer.len() + 1))
                        .rev()
                        .find(|n| pipes.buffer.ends_with(&pipes.sentinel[..*n]))
                        .unwrap_or(0);
                    let count = pipes.buffer.len() - keep;
                    output.push(&pipes.buffer[..count]);
                    pipes.buffer.drain(..count);
                    return Ok(None);
                }
            }
            Framing::Header => {
                if let Some(end) = pipes.buffer.iter().position(|b| *b == b'\n') {
                    ensure!(end > 0 && end <= 20, "invalid kernel frame header");
                    let length = std::str::from_utf8(&pipes.buffer[..end])?.parse::<usize>()?;
                    ensure!(length <= FRAME_LIMIT, "kernel frame exceeds bound");
                    pipes.buffer.drain(..=end);
                    pipes.framing = Framing::Body(length);
                } else {
                    ensure!(
                        pipes.buffer.len() <= 20,
                        "kernel frame header exceeds bound"
                    );
                    return Ok(None);
                }
            }
            Framing::Body(length) => {
                if pipes.buffer.len() < length {
                    return Ok(None);
                }
                let value = serde_json::from_slice(&pipes.buffer[..length])
                    .context("invalid kernel frame; cell outcome is uncertain")?;
                pipes.buffer.drain(..length);
                pipes.framing = Framing::Raw;
                return Ok(Some(value));
            }
        }
    }
}
fn frame(pipes: &mut Pipes, output: &mut Capture) -> Result<Option<Value>> {
    if let Some(frame) = take_frame(pipes, output)? {
        return Ok(Some(frame));
    }
    let mut buf = [0; 8192];
    match pipes.protocol.read(&mut buf) {
        Ok(0) => {
            if matches!(pipes.framing, Framing::Raw) {
                output.push(&pipes.buffer);
                pipes.buffer.clear();
            }
            bail!("kernel protocol closed; cell may have had effects, never automatically retry");
        }
        Ok(n) => {
            ensure!(
                pipes.buffer.len() + n <= FRAME_LIMIT + 8192,
                "kernel frame exceeds bound"
            );
            pipes.buffer.extend_from_slice(&buf[..n]);
        }
        Err(error)
            if error.kind() == std::io::ErrorKind::WouldBlock
                || error.kind() == std::io::ErrorKind::Interrupted => {}
        Err(error) => return Err(error.into()),
    }
    take_frame(pipes, output)
}
fn pipe_write(pipes: &mut Pipes, bytes: &[u8], kernel: &Kernel, deadline: Instant) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        check_running(kernel, deadline)?;
        match pipes.input.write(&bytes[offset..]) {
            Ok(0) => bail!("kernel input closed after a partial request; no automatic retry"),
            Ok(n) => offset += n,
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::Interrupted =>
            {
                std::thread::sleep(Duration::from_millis(1))
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
fn check_running(kernel: &Kernel, deadline: Instant) -> Result<()> {
    ensure!(Instant::now() < deadline, "cell deadline exceeded");
    kernel.alive()
}

fn encode_capped(value: &Value, limit: usize) -> (Vec<u8>, bool) {
    struct Capped {
        bytes: Vec<u8>,
        limit: usize,
    }
    impl Write for Capped {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            let count = bytes.len().min(self.limit - self.bytes.len());
            self.bytes.extend_from_slice(&bytes[..count]);
            if count < bytes.len() {
                return Err(std::io::Error::other("encoded response exceeds bound"));
            }
            Ok(count)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut writer = Capped {
        bytes: Vec::new(),
        limit,
    };
    let complete = serde_json::to_writer(&mut writer, value).is_ok();
    (writer.bytes, complete)
}
fn returned_error(value: &Value) -> Option<String> {
    let error = value.as_object()?.get("error")?;
    let truthy = match error {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(value) => value.as_f64().is_none_or(|value| value != 0.0),
        Value::String(value) => !value.is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
    };
    if !truthy {
        return None;
    }
    Some(match error.as_str() {
        Some(error) => python_clean::clean(error).chars().take(300).collect(),
        None => String::from_utf8_lossy(&encode_capped(error, 1200).0)
            .chars()
            .take(300)
            .collect(),
    })
}

struct Cell<'a> {
    tools: &'a LocalTools,
    kernel: &'a Arc<Kernel>,
    context: &'a TurnContext,
    runtime: &'a tokio::runtime::Handle,
    id: String,
    deadline: Instant,
    stdout: Capture,
    stderr: Capture,
    calls: usize,
    errors: Vec<Value>,
}
impl Cell<'_> {
    fn callback(&mut self, request: Value, pipes: &mut Pipes) -> Result<()> {
        ensure!(
            request["sequence"].as_u64() == Some(self.calls as u64 + 1),
            "callback sequence mismatch; no dispatch"
        );
        ensure!(
            self.calls < self.tools.inner.cfg.python_max_tool_calls,
            "cell callback budget exceeded"
        );
        let name = string(&request, "name")?;
        let args = request["arguments"].clone();
        self.kernel.pause()?;
        self.calls += 1;
        let result = self.runtime.block_on(async {
            tokio::select! {
                value = PYTHON_CELL_RETIRED.scope(self.kernel.retired.clone(), self.tools.python_callback(name, args, self.context, self.kernel.generation)) => value,
                _ = async {
                    loop {
                        if self.kernel.retired.load(Ordering::Acquire) || Instant::now() >= self.deadline { break; }
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                } => bail!("callback interrupted or deadline exceeded; effects may be uncertain, do not retry"),
            }
        });
        check_running(self.kernel, self.deadline)?;
        let result = match result {
            Ok(value) => value,
            Err(error) => {
                let message = format!("{error:#}").chars().take(2048).collect::<String>();
                json!({"error":message,"success":false})
            }
        };
        let response_value = json!({"id":self.id,"sequence":self.calls,"result":result});
        let (mut response, complete) =
            encode_capped(&response_value, self.tools.inner.cfg.output_bytes);
        let error = if complete {
            returned_error(&response_value["result"])
        } else {
            let error = "Callback result exceeds configured byte limit; the tool may have completed, do not retry effects";
            response = serde_json::to_vec(
                &json!({"id":self.id,"sequence":self.calls,"result":{"error":error,"success":false}}),
            )?;
            Some(error.to_owned())
        };
        // Match the upstream intent: ignored handler-returned error objects are
        // still visible to the model. Keep only the first five, 300 chars each.
        if let Some(error) = error
            && self.errors.len() < 5
        {
            self.errors
                .push(json!({"tool":name,"error":error.chars().take(300).collect::<String>()}));
        }
        response.push(b'\n');
        self.kernel.resume()?;
        pipe_write(pipes, &response, self.kernel, self.deadline)
    }
    fn drain(&mut self, pipes: &mut Pipes) -> Result<()> {
        output_drain(pipes, &mut self.stderr)
    }
    fn drain_completed_stdout(&mut self, pipes: &mut Pipes) -> Result<()> {
        for _ in 0..32 {
            ensure!(
                frame(pipes, &mut self.stdout)?.is_none(),
                "unsolicited frame after cell completion"
            );
            let mut descriptor = libc::pollfd {
                fd: pipes.protocol.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut descriptor, 1, 0) } == 0 {
                ensure!(
                    matches!(pipes.framing, Framing::Raw),
                    "partial control frame after cell completion"
                );
                self.stdout.push(&pipes.buffer);
                pipes.buffer.clear();
                return Ok(());
            }
        }
        bail!("kernel output did not settle after verified stop")
    }
    fn await_ready(&mut self, pipes: &mut Pipes) -> Result<()> {
        loop {
            check_running(self.kernel, self.deadline)?;
            self.drain(pipes)?;
            if let Some(frame) = frame(pipes, &mut self.stdout)? {
                ensure!(
                    frame == json!({"kind":"ready"}),
                    "invalid kernel startup handshake"
                );
                self.kernel.pause()?;
                return Ok(());
            }
            poll_pipes(pipes, self.deadline)?;
        }
    }
    fn execute(&mut self, pipes: &mut Pipes, code: &str) -> Result<Value> {
        // No frame or raw output left over from a retired cell can acquire the
        // next input's authority, even when user code forges its own frames.
        ensure!(
            pipes.buffer.is_empty(),
            "unsolicited kernel frame between cells"
        );
        let mut byte = [0; 1];
        match pipes.protocol.read(&mut byte) {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            _ => bail!("unsolicited or closed kernel protocol before cell"),
        }
        let mut request = serde_json::to_vec(&json!({"id":self.id,"code":code}))?;
        request.push(b'\n');
        self.kernel.resume()?;
        pipe_write(pipes, &request, self.kernel, self.deadline)?;
        loop {
            check_running(self.kernel, self.deadline)?;
            self.drain(pipes)?;
            if let Some(request) = frame(pipes, &mut self.stdout)? {
                ensure!(
                    request["id"].as_str() == Some(&self.id),
                    "stale or invalid cell frame; no callback dispatch"
                );
                match request["kind"].as_str() {
                    Some("call") => self.callback(request, pipes)?,
                    Some("complete") => {
                        self.kernel.pause()?;
                        self.drain(pipes)?;
                        self.drain_completed_stdout(pipes)?;
                        ensure!(
                            ["ok", "error", "exit"]
                                .iter()
                                .any(|s| request["status"] == *s),
                            "invalid cell completion"
                        );
                        return Ok(request);
                    }
                    _ => bail!("unknown kernel frame; no callback dispatch"),
                }
            } else {
                poll_pipes(pipes, self.deadline)?;
            }
        }
    }
}
fn poll_pipes(pipes: &Pipes, deadline: Instant) -> Result<()> {
    let mut fds = [
        libc::pollfd {
            fd: pipes.protocol.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: pipes.output.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    let millis = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(10) as i32;
    let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, millis) };
    ensure!(
        n >= 0 || std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted,
        "kernel polling failed"
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn run_cell(
    tools: &LocalTools,
    kernel: &Arc<Kernel>,
    code: String,
    reset: bool,
    context: TurnContext,
    mut permit: Grant,
    action: Value,
    runtime: &tokio::runtime::Handle,
) -> Result<Value> {
    let started = Instant::now();
    let deadline = started + tools.inner.cfg.timeout;
    let mut stop_on_error = CancelOnDrop {
        kernel: kernel.clone(),
        armed: true,
    };
    let reused = kernel.process.lock().unwrap().is_some() && !reset;
    let mut masks = Vec::new();
    check_process_tree(&tools.inner.root, "", 0, &mut 0, &mut masks)?;
    masks.sort();
    if reused {
        ensure!(
            *kernel.masks.lock().unwrap() == masks,
            "workspace private-path masks changed; kernel retired, run a new cell explicitly"
        );
        ensure!(
            kernel.execution_count.load(Ordering::Acquire)
                < tools.inner.cfg.python_max_cells as u64,
            "kernel cell limit reached; state discarded, run a new cell explicitly"
        );
        ensure!(
            kernel.born.elapsed() < LIFETIME,
            "kernel lifetime reached; state discarded"
        );
    }
    ensure!(
        !kernel.retired.load(Ordering::Acquire),
        "cell cancelled before execution"
    );
    // Python owns a separate retired-kernel fence for its long-lived execution
    // and callbacks; never retain the native-effect mutex across a callback.
    drop(permit.verify(&context, &action)?);
    if reset {
        // Serialized and approved: resetting can never kill another active cell.
        if let Some(finished) = kernel.dispose_process() {
            while !finished.load(Ordering::Acquire) {
                ensure!(
                    !kernel.retired.load(Ordering::Acquire) && Instant::now() < deadline,
                    "reset cleanup did not finish before cancellation/deadline; no new cell started"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        kernel.pipes.lock().unwrap().take();
        kernel.execution_count.store(0, Ordering::Release);
    }
    *kernel.masks.lock().unwrap() = masks;
    let mut cell = Cell {
        tools,
        kernel,
        context: &context,
        runtime,
        id: uuid::Uuid::new_v4().to_string(),
        deadline,
        stdout: Capture::new(tools.inner.cfg.output_bytes),
        stderr: Capture::new(tools.inner.cfg.output_bytes),
        calls: 0,
        errors: Vec::new(),
    };
    let result = (|| {
        if !reused {
            launch(tools, kernel, deadline)?;
        }
        let mut pipes_guard = kernel.pipes.lock().unwrap();
        let pipes = pipes_guard.as_mut().context("kernel pipes unavailable")?;
        if !reused {
            cell.await_ready(pipes)?;
        }
        cell.execute(pipes, &code)
    })();
    let count = kernel.execution_count.fetch_add(1, Ordering::AcqRel) + 1;
    let mut trace = String::new();
    let mut notice = String::new();
    let mut value = json!({"status":"ok","output":"","exit_code":0,"tool_calls_made":cell.calls,
        "duration_seconds":started.elapsed().as_secs_f64(),
        "kernel":{"mode":"session","id":kernel.id,"reused":reused,"execution_count":count,"state_reset":reset,"ephemeral":true}});
    match result {
        Ok(response) => {
            if response["status"] == "exit" {
                kernel.stop();
                value["kernel"]["ended"] = json!(true);
            } else if response["status"] == "error" {
                value["status"] = json!("error");
                value["exit_code"] = json!(1);
                trace = python_clean::clean(
                    &response["error"]
                        .as_str()
                        .unwrap_or("Cell raised an exception")
                        .chars()
                        .take(8192)
                        .collect::<String>(),
                );
                value["error"] = json!(trace);
                let enabled = tools
                    .python_specs()
                    .as_object()
                    .unwrap()
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>();
                if let Some(hint) = python_clean::failure_hint(&trace, &enabled) {
                    value["hint"] = json!(hint);
                }
            }
            if let Some(warning) = python_clean::stale_warning(&response["stale_modules"]) {
                append_warning(&mut value, &warning);
            }
            stop_on_error.armed = false;
            *kernel.last_used.lock().unwrap() = Instant::now();
        }
        Err(error) => {
            let status = if Instant::now() >= deadline {
                "timeout"
            } else if kernel.retired.load(Ordering::Acquire) {
                "interrupted"
            } else {
                "error"
            };
            kernel.stop();
            if let Some(pipes) = kernel.pipes.lock().unwrap().as_mut() {
                let _ = cell.drain(pipes);
                for _ in 0..16 {
                    if frame(pipes, &mut cell.stdout).is_err() {
                        break;
                    }
                }
            }
            value["status"] = json!(status);
            value["exit_code"] = json!(-1);
            value["timed_out"] = json!(status == "timeout");
            notice = python_clean::clean(&format!(
                "{}: {error:#}; kernel state was lost. Effects may have occurred; never automatically retry this cell.",
                if status == "timeout" {
                    "Cell timed out"
                } else if status == "interrupted" {
                    "[execution interrupted]"
                } else {
                    "Kernel failed"
                }
            ));
            value["error"] = json!(notice);
            value["kernel"]["ended"] = json!(true);
            value["kernel"]["state_lost"] = json!(true);
        }
    }
    tools.finish_python_output(
        &context,
        kernel.generation,
        python_output::CellOutput {
            stdout: &cell.stdout,
            stderr: &cell.stderr,
            trace: &trace,
            notice: &notice,
        },
        &mut value,
    );
    value["duration_seconds"] = json!(started.elapsed().as_secs_f64());
    if !cell.errors.is_empty() {
        value["tool_errors"] = json!(cell.errors);
    }
    Ok(value)
}

#[cfg(test)]
mod generation_and_reaper_tests {
    use super::*;

    #[tokio::test]
    async fn reaper_runs_only_when_python_is_configured() -> Result<()> {
        for configured in [false, true] {
            let dir = tempfile::tempdir()?;
            let root = dir.path().join("root");
            std::fs::create_dir(&root)?;
            let mut config = LocalToolsConfig::new(
                "synthetic-owner".into(),
                root,
                dir.path().join("local.sqlite"),
            );
            if configured {
                // Resolve an existing executable but never execute it here.
                config.python_program = Some("python".into());
                config.programs.push(Program {
                    name: "python".into(),
                    executable: "/usr/bin/python3".into(),
                });
            }
            config.execute = Permission::Deny;
            let tools = LocalTools::open(config, None, None).await?;
            let running = tools
                .inner
                .python
                .retirement
                .receiver
                .lock()
                .unwrap()
                .is_none();
            assert_eq!(running, configured);
            assert!(tools.inner.python.is_reaped());
            assert!(tools.inner.python.entries.lock().unwrap().is_empty());
            tools.shutdown().await;
        }
        Ok(())
    }

    #[test]
    fn zero_generations_are_implicit_and_positive_tombstones_remain_bounded() -> Result<()> {
        let kernels = Kernels::default();
        for i in 0..10_000 {
            let session = format!("zero-{i}");
            kernels.set_generation(&session, 0, 1)?;
            kernels.check_generation(&session, 0)?;
        }
        assert!(kernels.generations.lock().unwrap().positive.is_empty());
        kernels.set_generation("known", 7, 1)?;
        kernels.set_generation("still-zero", 0, 1)?;
        assert!(kernels.set_generation("overflow", 1, 1).is_err());
        assert!(kernels.current_generation("overflow").is_err());
        assert!(kernels.check_generation("still-zero", 0).is_err());
        for i in 0..10_000 {
            assert!(
                kernels
                    .set_generation(&format!("rejected-{i}"), 1, 1)
                    .is_err()
            );
        }
        let generations = kernels.generations.lock().unwrap();
        assert_eq!(generations.positive.len(), 1);
        assert_eq!(generations.positive["known"], 7);
        drop(generations);
        kernels.set_generation("known", 8, 1)?;
        kernels.set_generation("known", 0, 1)?;
        kernels.check_generation("known", 8)?;
        assert!(kernels.check_generation("known", 7).is_err());
        Ok(())
    }

    #[test]
    fn overflowing_reset_retires_all_untracked_kernels_but_not_positive_routes() -> Result<()> {
        let kernels = Kernels::default();
        kernels.set_generation("known", 1, 1)?;
        let known = kernels.acquire("known-key".into(), "c", "known", Some(1), 4)?;
        let zero = kernels.acquire("zero-key".into(), "c", "zero", Some(0), 4)?;
        let other = kernels.acquire("other-key".into(), "c", "other", Some(0), 4)?;
        assert!(kernels.set_generation("zero", 1, 1).is_err());
        assert!(zero.retired.load(Ordering::Acquire));
        assert!(other.retired.load(Ordering::Acquire));
        assert!(!known.retired.load(Ordering::Acquire));
        assert!(
            kernels
                .acquire("new-key".into(), "c", "new", None, 4)
                .is_err()
        );
        kernels.acquire("known-key".into(), "c", "known", Some(1), 4)?;
        assert!(kernels.current_generation("zero").is_err());
        assert!(kernels.check_generation("zero", 0).is_err());
        kernels.check_generation("known", 1)?;
        Ok(())
    }

    #[test]
    fn concurrent_resets_do_not_exceed_capacity_or_reopen_zero_routes() -> Result<()> {
        let kernels = Arc::new(Kernels::default());
        kernels.set_generation("known", 1, 1)?;
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let workers = (0..8)
            .map(|i| {
                let kernels = kernels.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    assert!(kernels.set_generation(&format!("zero-{i}"), 1, 1).is_err());
                    assert!(kernels.check_generation(&format!("zero-{i}"), 0).is_err());
                    kernels.set_generation("known", i + 2, 1).unwrap();
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }
        assert_eq!(kernels.current_generation("known")?, 9);
        assert_eq!(kernels.generations.lock().unwrap().positive.len(), 1);
        Ok(())
    }
}
