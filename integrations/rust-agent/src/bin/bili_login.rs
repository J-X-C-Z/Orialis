//! Explicit foreground Bilibili WEB QR login. No default login or visitor activation.
//! `status`/`cancel` talk only to a same-user local socket, never to Bilibili.
use anyhow::{Context, Result, bail, ensure};
use clap::{Parser, Subcommand};
use hermes_rust_core::memory_video::{BiliLogin, CredentialStore, LoginSession, LoginState};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use std::os::{
    fd::AsRawFd,
    unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
};
use std::{
    fs::{self, File, OpenOptions},
    path::{Component, Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{Notify, watch},
};

#[derive(Parser)]
#[command(
    about = "Explicit private Bilibili QR authorization; no automatic login",
    long_about = "Explicit private Bilibili QR authorization. start contacts Bilibili and saves a dedicated ongoing account session after you scan and approve. status and cancel use local same-user IPC only. Cancel is not logout and never deletes an already saved session."
)]
struct Args {
    /// Explicit absolute credential destination. No default or environment lookup.
    #[arg(long)]
    credential_file: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Start a foreground flow. Open the private PNG and approve in the Bilibili app.
    Start {
        /// Explicit absolute private PNG path, different from credential-file.
        #[arg(long)]
        qr_file: PathBuf,
        #[arg(long, default_value_t = 180, value_parser = clap::value_parser!(u64).range(15..=300))]
        timeout: u64,
    },
    /// Inspect a running local flow; does not verify existing account cookies.
    Status,
    /// Cancel a running flow and wait for its outcome; not an account logout.
    Cancel,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum State {
    Inactive,
    Starting,
    AwaitingScan,
    AwaitingConfirmation,
    Authorized,
    Expired,
    Cancelled,
    Failed,
}
impl State {
    fn terminal(self) -> bool {
        matches!(
            self,
            Self::Inactive | Self::Authorized | Self::Expired | Self::Cancelled | Self::Failed
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    state: State,
    cancellation_requested: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_unix_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    qr_file: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    credential_fields: Vec<String>,
}
impl Snapshot {
    fn new(state: State) -> Self {
        Self {
            state,
            cancellation_requested: false,
            expires_unix_seconds: None,
            qr_file: None,
            credential_fields: vec![],
        }
    }
    fn from_session(s: &LoginSession, qr: &Path) -> Self {
        let (state, fields) = match s.state() {
            LoginState::AwaitingScan => (State::AwaitingScan, vec![]),
            LoginState::AwaitingConfirmation => (State::AwaitingConfirmation, vec![]),
            LoginState::Authorized { fields } => (State::Authorized, fields),
            LoginState::Expired => (State::Expired, vec![]),
            LoginState::Cancelled => (State::Cancelled, vec![]),
            LoginState::Failed => (State::Failed, vec![]),
        };
        let active = !state.terminal();
        Self {
            state,
            cancellation_requested: state == State::Cancelled,
            expires_unix_seconds: active
                .then(|| now_seconds().saturating_add(s.expires_in().as_secs())),
            qr_file: active.then(|| qr.to_owned()),
            credential_fields: fields,
        }
    }
}
#[derive(Default)]
struct Cancellation {
    requested: AtomicBool,
    wake: Notify,
}
impl Cancellation {
    fn cancel(&self) {
        self.requested.store(true, Ordering::SeqCst);
        self.wake.notify_waiters();
    }
    fn requested(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }
    async fn wait(&self) {
        loop {
            let notified = self.wake.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.requested() {
                return;
            }
            notified.await;
        }
    }
}
fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn print_snapshot(s: &Snapshot) -> Result<()> {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    writeln!(out, "{}", serde_json::to_string(s)?)?;
    out.flush()?;
    Ok(())
}

#[cfg(unix)]
struct Control {
    dir: PathBuf,
    socket: PathBuf,
}
#[cfg(unix)]
impl Control {
    fn new(credential: &Path) -> Result<Self> {
        // Validate lexically without reading any credential material.
        CredentialStore::new(credential)?;
        // Equivalent dot/repeated-separator spellings must share one lock.
        let credential: PathBuf = credential.components().collect();
        let digest = Sha256::digest(credential.as_os_str().as_encoded_bytes());
        let suffix: String = digest[..10].iter().map(|b| format!("{b:02x}")).collect();
        let dir = credential
            .parent()
            .context("credential directory missing")?
            .join(format!(".bili-login-{suffix}"));
        let socket = dir.join("control.sock");
        ensure!(
            socket.as_os_str().as_encoded_bytes().len() < 104,
            "credential path is too long for private login IPC; choose a shorter absolute path"
        );
        Ok(Self { dir, socket })
    }
    fn check(&self, create: bool) -> Result<bool> {
        check_ancestors(&self.dir)?;
        match fs::symlink_metadata(&self.dir) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && !create => return Ok(false),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                fs::DirBuilder::new().mode(0o700).create(&self.dir)?;
            }
            Err(e) => return Err(e.into()),
            Ok(_) => {}
        }
        let meta = fs::symlink_metadata(&self.dir)?;
        ensure!(
            meta.is_dir()
                && !meta.file_type().is_symlink()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o777 == 0o700,
            "login control directory must be an owner-private non-symlink directory"
        );
        Ok(true)
    }
    fn bind(&self) -> Result<ControlGuard> {
        self.check(true)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(self.dir.join("lock"))?;
        let meta = file.metadata()?;
        ensure!(
            meta.is_file()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.nlink() == 1
                && meta.mode() & 0o777 == 0o600,
            "unsafe login control lock"
        );
        ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "a login flow is already running for this credential destination"
        );
        match fs::symlink_metadata(&self.socket) {
            Ok(meta) => {
                ensure!(
                    meta.file_type().is_socket() && meta.uid() == unsafe { libc::geteuid() },
                    "unsafe stale login socket"
                );
                fs::remove_file(&self.socket)?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let listener = UnixListener::bind(&self.socket)?;
        fs::set_permissions(&self.socket, fs::Permissions::from_mode(0o600))?;
        let meta = fs::symlink_metadata(&self.socket)?;
        Ok(ControlGuard {
            listener,
            _lock: file,
            cleanup: Some(FileCleanup {
                path: self.socket.clone(),
                dev: meta.dev(),
                ino: meta.ino(),
            }),
        })
    }
    async fn request(&self, op: Operation) -> Result<Snapshot> {
        if !self.check(false)? {
            return Ok(Snapshot::new(State::Inactive));
        }
        if let Ok(meta) = fs::symlink_metadata(&self.socket) {
            ensure!(
                meta.file_type().is_socket()
                    && meta.uid() == unsafe { libc::geteuid() }
                    && meta.mode() & 0o777 == 0o600,
                "unsafe login socket"
            );
        }
        let stream = match UnixStream::connect(&self.socket).await {
            Ok(stream) => stream,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) =>
            {
                return Ok(Snapshot::new(State::Inactive));
            }
            Err(e) => return Err(e.into()),
        };
        request_stream(stream, op).await
    }
}
#[cfg(unix)]
async fn request_stream(mut stream: UnixStream, op: Operation) -> Result<Snapshot> {
    check_peer(&stream)?;
    let bytes = serde_json::to_vec(&Request { op })?;
    stream.write_all(&bytes).await?;
    stream.write_all(b"\n").await?;
    let result = tokio::time::timeout(Duration::from_secs(22), read_line(stream, 4096))
        .await
        .context("local login outcome is uncertain; inspect the foreground start process")??;
    serde_json::from_slice(&result).context("invalid local login response")
}
#[cfg(unix)]
fn check_ancestors(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute() && !path.components().any(|c| matches!(c, Component::ParentDir)),
        "absolute login path required"
    );
    for parent in path.parent().context("missing parent")?.ancestors() {
        let meta = match fs::symlink_metadata(parent) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e.into()),
        };
        let uid = unsafe { libc::geteuid() };
        ensure!(
            meta.is_dir()
                && !meta.file_type().is_symlink()
                && (meta.uid() == uid || meta.uid() == 0)
                && (meta.mode() & 0o022 == 0
                    || (meta.uid() == 0
                        && meta.mode() & 0o1000 != 0
                        && Some(parent) != path.parent())),
            "unsafe login control parent directory"
        );
    }
    Ok(())
}
#[cfg(unix)]
struct FileCleanup {
    path: PathBuf,
    dev: u64,
    ino: u64,
}
#[cfg(unix)]
impl FileCleanup {
    fn capture(path: &Path) -> Result<Self> {
        let meta = fs::symlink_metadata(path)?;
        ensure!(
            meta.is_file()
                && !meta.file_type().is_symlink()
                && meta.uid() == unsafe { libc::geteuid() },
            "unsafe QR file"
        );
        Ok(Self {
            path: path.to_owned(),
            dev: meta.dev(),
            ino: meta.ino(),
        })
    }
}
#[cfg(unix)]
impl Drop for FileCleanup {
    fn drop(&mut self) {
        if let Ok(meta) = fs::symlink_metadata(&self.path)
            && meta.dev() == self.dev
            && meta.ino() == self.ino
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}
#[cfg(unix)]
struct ControlGuard {
    listener: UnixListener,
    _lock: File,
    cleanup: Option<FileCleanup>,
}
#[cfg(unix)]
impl Drop for ControlGuard {
    fn drop(&mut self) {
        // Socket removed before releasing the exclusive lock; keep an empty lock
        // file so another invocation cannot race against a different lock inode.
        drop(self.cleanup.take());
    }
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation {
    Status,
    Cancel,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    op: Operation,
}
#[cfg(unix)]
fn check_peer(stream: &UnixStream) -> Result<()> {
    ensure!(
        stream.peer_cred()?.uid() == unsafe { libc::geteuid() },
        "login IPC peer is not the current user"
    );
    Ok(())
}
#[cfg(unix)]
async fn read_line(stream: UnixStream, max: usize) -> Result<Vec<u8>> {
    let mut reader = BufReader::new(stream);
    let mut line = vec![];
    loop {
        let buf = reader.fill_buf().await?;
        ensure!(!buf.is_empty(), "incomplete local login message");
        let length = buf
            .iter()
            .position(|b| *b == b'\n')
            .map(|i| i + 1)
            .unwrap_or(buf.len());
        ensure!(line.len() + length <= max, "local login message too large");
        let finished = buf[length - 1] == b'\n';
        line.extend_from_slice(&buf[..length]);
        reader.consume(length);
        if finished {
            return Ok(line);
        }
    }
}
#[cfg(unix)]
async fn handle(
    mut stream: UnixStream,
    mut states: watch::Receiver<Snapshot>,
    cancel: Arc<Cancellation>,
) -> Result<()> {
    check_peer(&stream)?;
    // Bounded read without taking ownership, so the same connection can reply.
    let request = {
        let mut reader = BufReader::new(&mut stream);
        let mut line = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let buf = reader.fill_buf().await?;
                ensure!(!buf.is_empty(), "incomplete login operation");
                let n = buf
                    .iter()
                    .position(|b| *b == b'\n')
                    .map(|i| i + 1)
                    .unwrap_or(buf.len());
                ensure!(line.len() + n <= 256, "login operation too large");
                let done = buf[n - 1] == b'\n';
                line.extend_from_slice(&buf[..n]);
                reader.consume(n);
                if done {
                    return serde_json::from_slice::<Request>(&line)
                        .context("invalid login operation");
                }
            }
        })
        .await
        .context("login operation timed out")??
    };
    if matches!(request.op, Operation::Cancel) && !states.borrow().state.terminal() {
        cancel.cancel();
        // Do not interrupt a credential write and then report a false cancellation.
        // If filesystem completion is unusually slow, report the current state
        // with cancellation_requested instead of inventing a terminal outcome.
        let _ = tokio::time::timeout(Duration::from_secs(18), async {
            while !states.borrow().state.terminal() {
                if states.changed().await.is_err() {
                    break;
                }
            }
        })
        .await;
    }
    let mut state = states.borrow().clone();
    state.cancellation_requested |= cancel.requested();
    let mut bytes = serde_json::to_vec(&state)?;
    bytes.push(b'\n');
    tokio::time::timeout(Duration::from_secs(2), stream.write_all(&bytes)).await??;
    Ok(())
}
#[cfg(unix)]
async fn run_login(
    login: BiliLogin,
    qr: PathBuf,
    timeout: Duration,
    states: watch::Sender<Snapshot>,
    cancel: Arc<Cancellation>,
) {
    let session = tokio::select! {
        biased;
        _ = cancel.wait() => { states.send_replace(Snapshot::new(State::Cancelled)); return; },
        result = login.begin(timeout) => result,
    };
    let mut session = match session {
        Ok(s) => s,
        Err(_) => {
            states.send_replace(Snapshot::new(State::Failed));
            return;
        }
    };
    let handle = session.cancellation();
    let cancellation_task = {
        let cancel = cancel.clone();
        tokio::spawn(async move {
            cancel.wait().await;
            handle.cancel();
        })
    };
    let result = async {
        session.write_qr(&qr).await?;
        let _cleanup = FileCleanup::capture(&qr)?;
        loop {
            if cancel.requested() {
                session.cancel();
            }
            let state = Snapshot::from_session(&session, &qr);
            let terminal = state.state.terminal();
            states.send_replace(state);
            if terminal {
                return Ok::<(), anyhow::Error>(());
            }
            session.poll().await?;
        }
    }
    .await;
    if result.is_err() {
        let mut state = Snapshot::from_session(&session, &qr);
        if !state.state.terminal() {
            state = Snapshot::new(State::Failed);
        }
        states.send_replace(state);
    }
    cancellation_task.abort();
}
#[cfg(unix)]
async fn start(store: CredentialStore, control: Control, qr: PathBuf, timeout: u64) -> Result<()> {
    start_with(store, control, qr, timeout, BiliLogin::new).await
}
#[cfg(unix)]
async fn start_with(
    store: CredentialStore,
    control: Control,
    qr: PathBuf,
    timeout: u64,
    create_login: impl FnOnce(CredentialStore) -> Result<BiliLogin>,
) -> Result<()> {
    // Validate both destinations and lock the flow before any network request.
    store.prepare_for_login().await?;
    CredentialStore::new(&qr)?.prepare_for_login().await?;
    let guard = control.bind().context(
        "Cannot start private login IPC. This host must allow named Unix sockets and have no conflicting login flow. No QR was requested and no credentials were saved"
    )?;
    let cancel = Arc::new(Cancellation::default());
    let (tx, mut states) = watch::channel(Snapshot::new(State::Starting));
    print_snapshot(&states.borrow().clone())?;
    let worker = tokio::spawn(run_login(
        create_login(store)?,
        qr,
        Duration::from_secs(timeout),
        tx,
        cancel.clone(),
    ));
    let mut handlers = tokio::task::JoinSet::new();
    let mut output_error = None;
    let signal = tokio::signal::ctrl_c();
    tokio::pin!(signal);
    let mut signal_seen = false;
    loop {
        tokio::select! {
            result = guard.listener.accept(), if handlers.len() < 16 => {
                match result {
                    Ok((stream, _)) => { handlers.spawn(handle(stream, states.clone(), cancel.clone())); }
                    Err(error) => { cancel.cancel(); output_error = Some(error.into()); break; }
                }
            }
            changed = states.changed() => {
                if changed.is_err() { break; }
                let state = states.borrow().clone();
                if let Err(error) = print_snapshot(&state) {
                    cancel.cancel(); output_error = Some(error); break;
                }
                if state.state.terminal() { break; }
            }
            _ = &mut signal, if !signal_seen => { signal_seen = true; cancel.cancel(); }
            Some(_) = handlers.join_next(), if !handlers.is_empty() => {}
        }
    }
    worker
        .await
        .context("login worker stopped; outcome is uncertain")?;
    // Deliver already accepted cancellation acknowledgments before closing IPC.
    let _ = tokio::time::timeout(Duration::from_secs(3), async {
        while handlers.join_next().await.is_some() {}
    })
    .await;
    if let Some(error) = output_error {
        return Err(error);
    }
    let result = states.borrow().state;
    if result == State::Failed {
        bail!(
            "Bilibili authorization was not confirmed; inspect file permissions or try a new explicit flow"
        );
    }
    Ok(())
}
#[tokio::main]
async fn main() {
    let args = Args::parse();
    if let Err(error) = execute(args).await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
#[cfg(unix)]
async fn execute(args: Args) -> Result<()> {
    let control = Control::new(&args.credential_file)?;
    match args.command {
        Command::Start { qr_file, timeout } => {
            ensure!(
                qr_file != args.credential_file,
                "QR file and credential file must differ"
            );
            start(
                CredentialStore::new(&args.credential_file)?,
                control,
                qr_file,
                timeout,
            )
            .await
        }
        Command::Status => print_snapshot(&control.request(Operation::Status).await?),
        Command::Cancel => print_snapshot(&control.request(Operation::Cancel).await?),
    }
}
#[cfg(not(unix))]
async fn execute(_: Args) -> Result<()> {
    bail!("private Bilibili QR CLI requires Unix permissions and local sockets")
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn explicit_paths_and_subcommand_required() {
        assert!(Args::try_parse_from(["bili_login"]).is_err());
        assert!(Args::try_parse_from(["bili_login", "status"]).is_err());
        assert!(Args::try_parse_from(["bili_login", "--credential-file", "/x", "start"]).is_err());
        assert!(
            Args::try_parse_from([
                "bili_login",
                "--credential-file",
                "/x",
                "start",
                "--qr-file",
                "/q",
                "--timeout",
                "301"
            ])
            .is_err()
        );
        assert!(Args::try_parse_from(["bili_login", "--credential-file", "/x", "status"]).is_ok());
        assert!(Control::new(Path::new("relative.json")).is_err());
        assert_eq!(
            Control::new(Path::new("/home/alice/a.json"))
                .unwrap()
                .socket,
            Control::new(Path::new("/home//alice/./a.json"))
                .unwrap()
                .socket
        );
    }
    #[tokio::test]
    async fn inactive_status_and_cancel_do_not_create_or_read_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let credential = dir.path().join("missing/new/account.json");
        let c = Control::new(&credential).unwrap();
        assert_eq!(
            c.request(Operation::Status).await.unwrap().state,
            State::Inactive
        );
        assert_eq!(
            c.request(Operation::Cancel).await.unwrap().state,
            State::Inactive
        );
        assert!(!dir.path().join("missing").exists());
    }
    #[tokio::test]
    #[ignore = "requires named Unix socket bind permission; sandbox returns EPERM"]
    async fn real_local_ipc_status_and_cancel_wait_for_worker() {
        let dir = tempfile::tempdir().unwrap();
        let c = Control::new(&dir.path().join("credentials.json")).unwrap();
        let guard = c.bind().unwrap();
        assert!(c.bind().is_err());
        let cancel = Arc::new(Cancellation::default());
        let (tx, rx) = watch::channel(Snapshot::new(State::AwaitingScan));
        let server_cancel = cancel.clone();
        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (stream, _) = guard.listener.accept().await.unwrap();
                handle(stream, rx.clone(), server_cancel.clone())
                    .await
                    .unwrap();
            }
        });
        assert_eq!(
            c.request(Operation::Status).await.unwrap().state,
            State::AwaitingScan
        );
        let worker = tokio::spawn(async move {
            cancel.wait().await;
            tokio::time::sleep(Duration::from_millis(50)).await;
            tx.send_replace(Snapshot::new(State::Cancelled));
        });
        let s = c.request(Operation::Cancel).await.unwrap();
        assert_eq!(s.state, State::Cancelled);
        assert!(s.cancellation_requested);
        worker.await.unwrap();
        server.await.unwrap();
        assert_eq!(
            c.request(Operation::Status).await.unwrap().state,
            State::Inactive
        );
    }
    #[tokio::test]
    #[ignore = "requires named Unix socket bind permission; sandbox returns EPERM"]
    async fn authorized_commit_wins_cancel_and_never_claims_logout() {
        let dir = tempfile::tempdir().unwrap();
        let c = Control::new(&dir.path().join("credentials.json")).unwrap();
        let guard = c.bind().unwrap();
        let (_tx, rx) = watch::channel(Snapshot {
            credential_fields: vec!["SESSDATA".into()],
            ..Snapshot::new(State::Authorized)
        });
        let cancel = Arc::new(Cancellation::default());
        let server_cancel = cancel.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = guard.listener.accept().await.unwrap();
            handle(stream, rx, server_cancel).await.unwrap();
        });
        let s = c.request(Operation::Cancel).await.unwrap();
        assert_eq!(s.state, State::Authorized);
        assert_eq!(s.credential_fields, vec!["SESSDATA"]);
        assert!(!cancel.requested());
        assert!(!serde_json::to_string(&s).unwrap().contains("Cookie"));
        server.await.unwrap();
    }
    #[tokio::test]
    #[ignore = "requires named Unix socket bind permission; sandbox returns EPERM"]
    async fn stale_socket_recovery_and_unsafe_paths_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let c = Control::new(&dir.path().join("credentials.json")).unwrap();
        c.check(true).unwrap();
        let old = UnixListener::bind(&c.socket).unwrap();
        fs::set_permissions(&c.socket, fs::Permissions::from_mode(0o600)).unwrap();
        drop(old);
        assert_eq!(
            c.request(Operation::Status).await.unwrap().state,
            State::Inactive
        );
        let new = c.bind().unwrap();
        drop(new);
        std::os::unix::fs::symlink(dir.path().join("not-a-socket"), &c.socket).unwrap();
        assert!(c.bind().is_err());
        assert!(c.request(Operation::Status).await.is_err());
        fs::remove_file(&c.socket).unwrap();
        fs::set_permissions(&c.dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(c.bind().is_err());
    }
    #[tokio::test]
    async fn bounded_ipc_rejects_unknown_operations_and_oversize() {
        for bytes in [b"{\"op\":\"start\"}\n".to_vec(), vec![b'x'; 257]] {
            let (mut a, b) = UnixStream::pair().unwrap();
            let (_tx, rx) = watch::channel(Snapshot::new(State::AwaitingScan));
            let cancel = Arc::new(Cancellation::default());
            let task = tokio::spawn(handle(b, rx, cancel.clone()));
            a.write_all(&bytes).await.unwrap();
            assert!(task.await.unwrap().is_err());
            assert!(!cancel.requested());
        }
    }
    #[test]
    fn cleanup_preserves_replaced_files() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("qr.png");
        fs::write(&p, b"synthetic-png").unwrap();
        let guard = FileCleanup::capture(&p).unwrap();
        let replacement = dir.path().join("new.png");
        fs::write(&replacement, b"replacement").unwrap();
        fs::rename(&replacement, &p).unwrap();
        drop(guard);
        assert_eq!(fs::read(&p).unwrap(), b"replacement");
        let guard = FileCleanup::capture(&p).unwrap();
        drop(guard);
        assert!(!p.exists());
    }
    #[tokio::test]
    async fn socketpair_executes_real_status_and_cancel_protocol() {
        let (tx, rx) = watch::channel(Snapshot::new(State::AwaitingConfirmation));
        let cancel = Arc::new(Cancellation::default());
        let (a, b) = UnixStream::pair().unwrap();
        let server = tokio::spawn(handle(b, rx.clone(), cancel.clone()));
        assert_eq!(
            request_stream(a, Operation::Status).await.unwrap().state,
            State::AwaitingConfirmation
        );
        server.await.unwrap().unwrap();
        let worker_cancel = cancel.clone();
        let worker = tokio::spawn(async move {
            worker_cancel.wait().await;
            tokio::time::sleep(Duration::from_millis(20)).await;
            tx.send_replace(Snapshot::new(State::Cancelled));
        });
        let (a, b) = UnixStream::pair().unwrap();
        let server = tokio::spawn(handle(b, rx, cancel));
        let response = request_stream(a, Operation::Cancel).await.unwrap();
        assert_eq!(response.state, State::Cancelled);
        assert!(response.cancellation_requested);
        server.await.unwrap().unwrap();
        worker.await.unwrap();
    }
    #[tokio::test]
    async fn socketpair_cancellation_race_reports_committed_authorized_truthfully() {
        let (tx, rx) = watch::channel(Snapshot::new(State::AwaitingConfirmation));
        let cancel = Arc::new(Cancellation::default());
        let worker_cancel = cancel.clone();
        let worker = tokio::spawn(async move {
            worker_cancel.wait().await;
            tx.send_replace(Snapshot {
                credential_fields: vec!["SESSDATA".into()],
                ..Snapshot::new(State::Authorized)
            });
        });
        let (a, b) = UnixStream::pair().unwrap();
        let server = tokio::spawn(handle(b, rx, cancel));
        let response = request_stream(a, Operation::Cancel).await.unwrap();
        assert_eq!(response.state, State::Authorized);
        assert!(response.cancellation_requested);
        assert_eq!(response.credential_fields, vec!["SESSDATA"]);
        server.await.unwrap().unwrap();
        worker.await.unwrap();
    }
    #[tokio::test]
    async fn startup_bind_failure_never_initializes_network_or_writes_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let credential = dir.path().join("credentials.json");
        fs::write(&credential, b"OLD_SYNTHETIC_SESSION").unwrap();
        fs::set_permissions(&credential, fs::Permissions::from_mode(0o600)).unwrap();
        let qr = dir.path().join("qr.png");
        let mut control = Control::new(&credential).unwrap();
        // Deterministically invalid socket address, even on a fully capable host.
        // This exercises the real bind failure, never an external login.
        control.socket = control.dir.join("s".repeat(200));
        let constructed = Arc::new(AtomicBool::new(false));
        let observed = constructed.clone();
        let error = start_with(
            CredentialStore::new(&credential).unwrap(),
            control,
            qr.clone(),
            15,
            move |_| {
                observed.store(true, Ordering::SeqCst);
                bail!("must never create login transport")
            },
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("No QR was requested"));
        assert!(!constructed.load(Ordering::SeqCst));
        assert_eq!(fs::read(&credential).unwrap(), b"OLD_SYNTHETIC_SESSION");
        assert!(!qr.exists());
    }
}
