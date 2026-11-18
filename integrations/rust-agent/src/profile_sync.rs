//! Portable profile synchronization compatible with Orialis' pinned Python hub.
//! This module synchronizes curated files, never databases, sessions or credentials.
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[cfg(not(unix))]
use std::fs::OpenOptions;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{BufRead, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use unicode_casefold::UnicodeCaseFold;

pub const MAX_REQUEST: usize = 128 * 1024 * 1024;
pub const MAX_FILES: usize = 100_000;
pub const MEMORY_PATHS: [&str; 2] = ["memories/MEMORY.md", "memories/USER.md"];
pub type Contents = BTreeMap<String, Vec<u8>>;
pub type Manifest = BTreeMap<String, String>;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Request {
    pub node: String,
    #[serde(default)]
    pub hub_id: Option<String>,
    pub base: Manifest,
    pub live: Manifest,
    #[serde(default)]
    pub payload: BTreeMap<String, String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Response {
    pub hub_id: String,
    pub revision: u64,
    pub files: Manifest,
    pub changes: BTreeMap<String, Option<String>>,
    pub conflicts: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SyncConfig {
    pub profile: PathBuf,
    pub state_dir: PathBuf,
    pub node: String,
    #[serde(default)]
    pub hub_store: Option<PathBuf>,
    /// Explicit argv, never passed to a shell. May be a local subprocess in tests.
    #[serde(default)]
    pub ssh: Vec<String>,
    #[serde(default)]
    pub force_payload: bool,
    /// Explicitly trusted external shared-skill libraries. Empty by default.
    #[serde(default)]
    pub allowed_skill_roots: Vec<PathBuf>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SyncOutcome {
    pub node: String,
    pub revision: u64,
    pub files: usize,
    pub applied: usize,
    pub conflicts: Vec<String>,
}
impl SyncOutcome {
    pub fn exit_code(&self) -> i32 {
        if self.conflicts.is_empty() { 0 } else { 2 }
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct ClientState {
    #[serde(default)]
    time: String,
    #[serde(default)]
    node: String,
    #[serde(default)]
    hub_id: Option<String>,
    #[serde(default)]
    revision: u64,
    #[serde(default)]
    base: Manifest,
    #[serde(default)]
    conflicts: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct HubState {
    hub_id: String,
    files: Manifest,
    revision: u64,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    memory_limits: BTreeMap<String, usize>,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}

pub fn digest(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
pub fn normalize(data: &[u8]) -> Vec<u8> {
    if !data.contains(&0) {
        let without_bom = data.strip_prefix(b"\xef\xbb\xbf").unwrap_or(data);
        if let Ok(text) = std::str::from_utf8(without_bom) {
            return text.replace("\r\n", "\n").replace('\r', "\n").into_bytes();
        }
    }
    data.to_vec()
}
pub fn allowed(path: &str) -> bool {
    if path.len() > 4096 {
        return false;
    }
    let parts: Vec<_> = path.split('/').collect();
    if path.contains(['\\', ':'])
        || path.chars().any(|c| c < ' ')
        || parts.iter().any(|p| p.is_empty() || p.starts_with('.'))
    {
        return false;
    }
    path == "SOUL.md"
        || MEMORY_PATHS.contains(&path)
        || (parts.len() > 1
            && parts[0] == "skills"
            && !parts
                .iter()
                .any(|p| ["node_modules", "__pycache__", "venv", "env"].contains(p))
            && ![".pyc", ".pyo", ".lock", ".bak", ".tmp"]
                .iter()
                .any(|suffix| path.ends_with(suffix)))
}
pub fn validate_paths<'a>(paths: impl IntoIterator<Item = &'a str>) -> Result<()> {
    let mut seen = BTreeMap::new();
    for path in paths {
        ensure!(allowed(path), "Outside sync scope: {path}");
        let folded: String = path.case_fold().collect();
        ensure!(
            seen.len() < MAX_FILES || seen.contains_key(&folded),
            "Too many sync paths"
        );
        if let Some(previous) = seen.insert(folded, path) {
            ensure!(
                previous == path,
                "Cross-platform filename collision: {path}"
            );
        }
    }
    for (folded, path) in &seen {
        for (index, _) in folded.match_indices('/') {
            ensure!(
                !seen.contains_key(&folded[..index]),
                "File/directory collision: {path}"
            );
        }
    }
    Ok(())
}
fn validate_hash(hash: &str) -> Result<()> {
    ensure!(
        hash.len() == 64
            && hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "Invalid content hash"
    );
    Ok(())
}
fn validate_node(node: &str) -> Result<()> {
    ensure!(
        !node.is_empty()
            && node.len() <= 200
            && node.chars().any(char::is_alphanumeric)
            && node
                .chars()
                .all(|c| c.is_alphanumeric() || c == '-' || c == '_'),
        "Invalid node name"
    );
    Ok(())
}
pub fn manifest(contents: &Contents) -> Manifest {
    contents
        .iter()
        .map(|(p, data)| (p.clone(), digest(data)))
        .collect()
}
fn stamp() -> String {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!(
        "{}.{:09}-{}",
        elapsed.as_secs(),
        elapsed.subsec_nanos(),
        uuid::Uuid::new_v4()
    )
}
fn linked(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|m| {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                m.file_attributes() & 0x400 != 0
            }
            #[cfg(not(windows))]
            {
                m.file_type().is_symlink()
            }
        })
        .unwrap_or(false)
}
/// State/hub files must not traverse links. The authorized root itself may have
/// canonical ancestors; caller-selected root is canonicalized after creation.
fn reject_links(path: &Path) -> Result<()> {
    let mut current = PathBuf::new();
    for part in path.components() {
        current.push(part);
        ensure!(
            !linked(&current),
            "Refusing linked state path: {}",
            current.display()
        );
    }
    Ok(())
}
fn private_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        unixfs::private_dir(path)
    }
    #[cfg(not(unix))]
    {
        reject_links(path)?;
        fs::create_dir_all(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
}
/// Locks a separate sibling file, so replacing its data file cannot invalidate
/// the lock. Unix uses flock, matching the original Hermes MemoryStore.
pub struct FileLock {
    _file: File,
}
impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = self._file.unlock();
    }
}
impl FileLock {
    pub fn acquire(path: &Path, blocking: bool) -> Result<Self> {
        reject_links(path)?;
        #[cfg(unix)]
        let file = unixfs::open_file(path, true)?;
        #[cfg(not(unix))]
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(path)?;
        if blocking {
            file.lock()?;
        } else {
            file.try_lock().map_err(|e| {
                anyhow::anyhow!("Lock busy or unavailable ({}): {e}", path.display())
            })?;
        }
        Ok(Self { _file: file })
    }
}
/// Atomic private-file replacement. Callers must hold the relevant writer lock.
pub fn atomic_write(path: &Path, data: &[u8], executable: bool) -> Result<()> {
    #[cfg(unix)]
    {
        unixfs::atomic(path, data, executable)
    }
    #[cfg(not(unix))]
    {
        reject_links(path)?;
        let parent = path.parent().context("File needs parent")?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".sync_{}", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut options = OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(if executable { 0o700 } else { 0o600 });
            }
            let mut file = options.open(&temporary)?;
            file.write_all(data)?;
            file.sync_all()?;
            fs::rename(&temporary, path)?;
            #[cfg(unix)]
            File::open(parent)?.sync_all()?;
            Ok(())
        })();
        let _ = fs::remove_file(&temporary);
        result
    }
}
fn json_write(path: &Path, value: &impl Serialize) -> Result<()> {
    atomic_write(path, &serde_json::to_vec(value)?, false)
}
fn read_bounded(path: &Path) -> Result<Vec<u8>> {
    #[cfg(unix)]
    let file = unixfs::open_file(path, false)?;
    #[cfg(not(unix))]
    let file = File::open(path)?;
    ensure!(
        file.metadata()?.is_file(),
        "Not a regular file: {}",
        path.display()
    );
    let mut data = Vec::new();
    file.take(MAX_REQUEST as u64 + 1).read_to_end(&mut data)?;
    ensure!(data.len() <= MAX_REQUEST, "Sync file exceeds size limit");
    Ok(data)
}
fn json_read<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Option<T>> {
    reject_links(path)?;
    match read_bounded(path) {
        Ok(data) => {
            Ok(Some(serde_json::from_slice(&data).with_context(|| {
                format!("Invalid JSON in {}", path.display())
            })?))
        }
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}
fn remove_if_exists(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        unixfs::remove(path)
    }
    #[cfg(not(unix))]
    {
        reject_links(path)?;
        match fs::remove_file(path) {
            Ok(()) => {
                #[cfg(unix)]
                File::open(path.parent().context("File needs parent")?)?.sync_all()?;
                Ok(())
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}
/// Scan only explicitly portable paths; link targets are read, never edited.
pub fn scan(profile: &Path) -> Result<Contents> {
    scan_with_skill_roots(profile, &[])
}
pub fn scan_with_skill_roots(profile: &Path, allowed_skill_roots: &[PathBuf]) -> Result<Contents> {
    ensure!(
        profile.is_dir(),
        "Missing Hermes profile: {}",
        profile.display()
    );
    let canonical_profile = fs::canonicalize(profile)?;
    let mut roots = vec![canonical_profile.join("skills")];
    for root in allowed_skill_roots {
        let root = fs::canonicalize(root).context("Missing allowed skill root")?;
        ensure!(root.is_dir(), "Allowed skill root is not a directory");
        roots.push(root);
    }
    let mut contents = Contents::new();
    let mut total = 0usize;
    fn visit(
        physical: &Path,
        rel: &str,
        ancestors: &BTreeSet<PathBuf>,
        roots: &[PathBuf],
        out: &mut Contents,
        total: &mut usize,
    ) -> Result<()> {
        ensure!(ancestors.len() <= 64, "Skill nesting exceeds sync limit");
        if rel != "skills" && !allowed(rel) {
            return Ok(());
        }
        let target = fs::canonicalize(physical)
            .with_context(|| format!("Unreadable or cyclic sync file/link: {rel}"))?;
        if rel == "skills" || rel.starts_with("skills/") {
            ensure!(
                roots.iter().any(|root| target.starts_with(root)),
                "Skill link outside allowed roots: {rel}"
            );
        } else {
            // Also verify the resolved identity leaf, closing the race between
            // the earlier link check and canonicalization.
            ensure!(
                target == roots[0].parent().context("Missing profile root")?.join(rel),
                "Refusing linked identity/memory file: {rel}"
            );
        }
        ensure!(!ancestors.contains(&target), "Cyclic skill link: {rel}");
        let meta = fs::metadata(&target)?;
        if meta.is_dir() {
            // The three selected identity/memory leaves may never expand scope.
            ensure!(
                rel == "skills" || rel.starts_with("skills/"),
                "Expected sync file: {rel}"
            );
            let mut next = ancestors.clone();
            next.insert(target.clone());
            #[cfg(unix)]
            let names = unixfs::names(&target, MAX_FILES)?;
            #[cfg(not(unix))]
            let names = {
                let mut names = fs::read_dir(&target)?
                    .map(|e| e.map(|e| e.file_name()))
                    .collect::<std::io::Result<Vec<_>>>()?;
                names.sort();
                names
            };
            for name in names {
                let name = name.to_str().context("Non-UTF-8 sync filename")?;
                visit(
                    &target.join(name),
                    &format!("{rel}/{name}"),
                    &next,
                    roots,
                    out,
                    total,
                )?;
            }
        } else {
            ensure!(meta.is_file(), "Not a regular sync file: {rel}");
            let bytes = normalize(&read_bounded(&target)?);
            *total = total
                .checked_add(bytes.len())
                .context("Snapshot size overflow")?;
            ensure!(
                *total <= MAX_REQUEST * 3 / 4,
                "Sync snapshot exceeds size limit"
            );
            ensure!(out.len() < MAX_FILES, "Too many sync files");
            out.insert(rel.to_owned(), bytes);
        }
        Ok(())
    }
    for rel in [
        "SOUL.md",
        "memories/MEMORY.md",
        "memories/USER.md",
        "skills",
    ] {
        let path = profile.join(rel);
        if path.exists() || linked(&path) {
            if rel != "skills" {
                ensure!(
                    !has_link(profile, rel),
                    "Refusing linked identity/memory file: {rel}"
                );
            }
            visit(
                &path,
                rel,
                &BTreeSet::new(),
                &roots,
                &mut contents,
                &mut total,
            )?;
        }
    }
    validate_paths(contents.keys().map(String::as_str))?;
    Ok(contents)
}
pub fn read_one(profile: &Path, rel: &str) -> Result<Option<Vec<u8>>> {
    read_one_with_skill_roots(profile, rel, &[])
}
pub fn read_one_with_skill_roots(
    profile: &Path,
    rel: &str,
    allowed_skill_roots: &[PathBuf],
) -> Result<Option<Vec<u8>>> {
    ensure!(allowed(rel), "Outside sync scope: {rel}");
    let mut source = profile.join(rel);
    if has_link(profile, rel) {
        ensure!(
            rel.starts_with("skills/"),
            "Refusing linked identity/memory file: {rel}"
        );
        // A remote addition can be absent beneath an existing skill link. Resolve
        // its deepest existing ancestor, then check the complete destination
        // against the approved roots before treating that absence as `None`.
        // Canonicalizing only the full leaf would reject valid new support files;
        // ignoring all NotFound errors would miss dangling or escaping links.
        let target = resolved_location(&source).context("Unreadable or cyclic skill link")?;
        let mut roots = vec![fs::canonicalize(profile)?.join("skills")];
        for root in allowed_skill_roots {
            roots.push(fs::canonicalize(root)?);
        }
        ensure!(
            roots.iter().any(|root| target.starts_with(root)),
            "Skill link outside allowed roots: {rel}"
        );
        source = target;
    }
    match read_bounded(&source) {
        Ok(data) => Ok(Some(normalize(&data))),
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            Ok(None)
        }
        Err(e) => Err(e),
    }
}
fn blob_path(store: &Path, sha: &str) -> Result<PathBuf> {
    validate_hash(sha)?;
    let path = store.join("objects").join(sha);
    reject_links(&path)?;
    Ok(path)
}
pub fn get_blob(store: &Path, sha: &str) -> Result<Vec<u8>> {
    let data = read_bounded(&blob_path(store, sha)?)?;
    ensure!(digest(&data) == sha, "Corrupt content object: {sha}");
    Ok(data)
}
fn put_blob(store: &Path, data: &[u8]) -> Result<String> {
    let sha = digest(data);
    let path = blob_path(store, &sha)?;
    if path.exists() {
        get_blob(store, &sha)?;
    } else {
        atomic_write(&path, data, false)?;
    }
    Ok(sha)
}
pub fn memory_merge(base: &[u8], ours: &[u8], theirs: &[u8]) -> Result<Vec<u8>> {
    fn entries(data: &[u8]) -> Result<Vec<String>> {
        let mut seen = BTreeSet::new();
        Ok(std::str::from_utf8(data)?
            .split("\n§\n")
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .filter(|s| seen.insert((*s).to_owned()))
            .map(str::to_owned)
            .collect())
    }
    let (b, o, t) = (entries(base)?, entries(ours)?, entries(theirs)?);
    let ours: BTreeSet<_> = o.iter().collect();
    let theirs: BTreeSet<_> = t.iter().collect();
    let removed: BTreeSet<_> = b
        .iter()
        .filter(|e| !ours.contains(e) || !theirs.contains(e))
        .collect();
    let mut seen = BTreeSet::new();
    let merged: Vec<_> = b
        .iter()
        .chain(&t)
        .chain(&o)
        .filter(|e| !removed.contains(e) && seen.insert(*e))
        .map(String::as_str)
        .collect();
    Ok(merged.join("\n§\n").into_bytes())
}
fn merge_content(
    store: &Path,
    path: &str,
    base: &[u8],
    ours: &[u8],
    theirs: &[u8],
) -> Result<Option<Vec<u8>>> {
    if MEMORY_PATHS.contains(&path) {
        return Ok(memory_merge(base, ours, theirs).ok());
    }
    if ours.contains(&0)
        || theirs.contains(&0)
        || std::str::from_utf8(ours).is_err()
        || std::str::from_utf8(theirs).is_err()
    {
        return Ok(None);
    }
    let temporary = store.join(format!(".merge_{}", uuid::Uuid::new_v4()));
    private_dir(&temporary)?;
    let result = (|| {
        for (name, data) in [("ours", ours), ("base", base), ("theirs", theirs)] {
            atomic_write(&temporary.join(name), data, false)?;
        }
        let argv = vec![
            "git".to_owned(),
            "merge-file".to_owned(),
            "-p".to_owned(),
            temporary.join("ours").to_string_lossy().into_owned(),
            temporary.join("base").to_string_lossy().into_owned(),
            temporary.join("theirs").to_string_lossy().into_owned(),
        ];
        match subprocess(&argv, &[], Duration::from_secs(15)) {
            Ok(output) if output.0 => Ok(Some(output.1)),
            _ => Ok(None),
        }
    })();
    let _ = fs::remove_dir_all(temporary);
    result
}
/// Reconcile one protocol request. State is serialized by hub.lock; old and new
/// blobs are retained even when reconciliation reports conflicts.
pub fn exchange(store: &Path, request: &Request) -> Result<Response> {
    validate_node(&request.node)?;
    ensure!(
        crate::json_encoded_len(request)?.saturating_add(1) <= MAX_REQUEST,
        "Sync request exceeds size limit"
    );
    private_dir(store)?;
    let _lock = FileLock::acquire(&store.join("hub.lock"), true)?;
    let mut state: HubState = json_read(&store.join("hub.json"))?.unwrap_or_else(|| HubState {
        hub_id: uuid::Uuid::new_v4().to_string(),
        files: Manifest::new(),
        revision: 0,
        memory_limits: BTreeMap::new(),
        extra: BTreeMap::new(),
    });
    if let Some(hub_id) = &request.hub_id {
        ensure!(
            hub_id == &state.hub_id,
            "Hub identity changed; refusing to replace local files"
        );
    }
    validate_paths(
        request
            .base
            .keys()
            .chain(request.live.keys())
            .chain(state.files.keys())
            .map(String::as_str),
    )?;
    for hash in request
        .base
        .values()
        .chain(request.live.values())
        .chain(state.files.values())
    {
        validate_hash(hash)?;
    }
    // Validate the complete incoming payload before persisting any object.
    let mut decoded = Contents::new();
    for (path, encoded) in &request.payload {
        let wanted = request.live.get(path).context("Unrequested payload")?;
        let data = STANDARD.decode(encoded).context("Invalid base64 payload")?;
        ensure!(&digest(&data) == wanted, "Content hash mismatch: {path}");
        decoded.insert(path.clone(), data);
    }
    for data in decoded.values() {
        put_blob(store, data)?;
    }
    drop(decoded);
    for hash in request.live.values().collect::<BTreeSet<_>>() {
        get_blob(store, hash).context("Missing or corrupt content object; resnapshot required")?;
    }
    let mut result = state.files.clone();
    let mut conflicts = Vec::new();
    let paths: BTreeSet<_> = request
        .base
        .keys()
        .chain(request.live.keys())
        .chain(result.keys())
        .cloned()
        .collect();
    for path in paths {
        let (base, ours, theirs) = (
            request.base.get(&path),
            request.live.get(&path),
            result.get(&path),
        );
        if ours == base {
            continue;
        }
        let chosen = if theirs == base || ours == theirs {
            ours.cloned()
        } else if let (Some(ours), Some(theirs)) = (ours, theirs) {
            let base = base
                .map(|sha| get_blob(store, sha))
                .transpose()?
                .unwrap_or_default();
            if let Some(merged) = merge_content(
                store,
                &path,
                &base,
                &get_blob(store, ours)?,
                &get_blob(store, theirs)?,
            )? {
                Some(put_blob(store, &merged)?)
            } else {
                conflicts.push(path);
                continue;
            }
        } else {
            conflicts.push(path);
            continue;
        };
        if let (Some(hash), Some(limit)) =
            (&chosen, state.memory_limits.get(&path).filter(|n| **n > 0))
        {
            let bytes = get_blob(store, hash)?;
            if std::str::from_utf8(&bytes)
                .map(|s| s.chars().count() > *limit)
                .unwrap_or(true)
            {
                conflicts.push(path);
                continue;
            }
        }
        if let Some(hash) = chosen {
            result.insert(path, hash);
        } else {
            result.remove(&path);
        }
    }
    validate_paths(result.keys().map(String::as_str))?;
    if result != state.files {
        json_write(
            &store.join("history").join(format!("{}.json", stamp())),
            &state,
        )?;
        state.files = result.clone();
        state.revision = state
            .revision
            .checked_add(1)
            .context("Hub revision overflow")?;
    }
    json_write(&store.join("hub.json"), &state)?;
    let conflict_path = store
        .join("conflicts")
        .join(format!("{}.json", request.node));
    if conflicts.is_empty() {
        remove_if_exists(&conflict_path)?;
    } else {
        json_write(
            &conflict_path,
            &json!({"time": stamp(), "base": request.base, "local": request.live, "hub": result, "paths": conflicts}),
        )?;
    }
    let mut changes = BTreeMap::new();
    let mut encoded_bytes = 0usize;
    for path in request
        .live
        .keys()
        .chain(result.keys())
        .collect::<BTreeSet<_>>()
    {
        if request.live.get(path) != result.get(path) && !conflicts.contains(path) {
            let encoded = if let Some(sha) = result.get(path) {
                let bytes = get_blob(store, sha)?;
                encoded_bytes = encoded_bytes
                    .checked_add(bytes.len().div_ceil(3) * 4)
                    .context("Response size overflow")?;
                ensure!(
                    encoded_bytes <= MAX_REQUEST,
                    "Sync response exceeds size limit"
                );
                Some(STANDARD.encode(bytes))
            } else {
                None
            };
            changes.insert(path.clone(), encoded);
        }
    }
    json_write(
        &store.join("nodes").join(format!("{}.json", request.node)),
        &json!({"time": stamp(), "revision": state.revision, "live": request.live, "conflicts": conflicts}),
    )?;
    let response = Response {
        hub_id: state.hub_id,
        revision: state.revision,
        files: result,
        changes,
        conflicts,
    };
    ensure!(
        crate::json_encoded_len(&response)?.saturating_add(1) <= MAX_REQUEST,
        "Sync response exceeds size limit"
    );
    Ok(response)
}

/// Read exactly one newline JSON frame; does not wait for stdin/SSH EOF.
pub fn read_request(reader: &mut impl BufRead) -> Result<Request> {
    let mut raw = Vec::new();
    reader
        .take(MAX_REQUEST as u64 + 1)
        .read_until(b'\n', &mut raw)?;
    ensure!(raw.len() <= MAX_REQUEST, "Sync request exceeds size limit");
    let request: Request = serde_json::from_slice(&raw).context("Invalid sync request JSON")?;
    validate_node(&request.node)?;
    Ok(request)
}
pub fn serve_hub(store: &Path, reader: &mut impl BufRead, writer: &mut impl Write) -> Result<()> {
    let response = exchange(store, &read_request(reader)?)?;
    serde_json::to_writer(&mut *writer, &response)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

/// Bounded argv transport used by SSH and optional git merge-file. No shell,
/// credentials, SSH connection, or scheduler is configured by this function.
fn subprocess(
    argv: &[String],
    input: &[u8],
    timeout: Duration,
) -> Result<(bool, Vec<u8>, Vec<u8>)> {
    ensure!(!argv.is_empty(), "Missing transport argv");
    let mut command = Command::new(&argv[0]);
    command
        .args(&argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().context("Start sync subprocess")?;
    let pid = child.id();
    let mut stdin = child.stdin.take().context("Missing subprocess stdin")?;
    let input = input.to_vec();
    let writer = thread::spawn(move || -> std::io::Result<()> { stdin.write_all(&input) });
    let stdout = child.stdout.take().context("Missing subprocess stdout")?;
    let stderr = child.stderr.take().context("Missing subprocess stderr")?;
    let overflow = Arc::new(AtomicBool::new(false));
    fn read_pipe(
        mut pipe: impl Read,
        maximum: usize,
        overflow: Arc<AtomicBool>,
    ) -> std::io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        (&mut pipe)
            .take(maximum as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > maximum {
            overflow.store(true, Ordering::Release);
        }
        Ok(bytes)
    }
    let out_overflow = Arc::clone(&overflow);
    let err_overflow = Arc::clone(&overflow);
    let out = thread::spawn(move || read_pipe(stdout, MAX_REQUEST, out_overflow));
    let err = thread::spawn(move || read_pipe(stderr, 1024 * 1024, err_overflow));
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Ok(status);
        }
        if Instant::now() >= deadline {
            break Err(anyhow::anyhow!("Sync subprocess timed out"));
        }
        if overflow.load(Ordering::Acquire) {
            break Err(anyhow::anyhow!("Sync subprocess output exceeds size limit"));
        }
        thread::sleep(Duration::from_millis(5));
    };
    if let Err(error) = status {
        #[cfg(unix)]
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
        let _ = child.kill();
        let _ = child.wait();
        // Reader/writer handles are detached on a platform whose subprocess
        // retains inherited handles; do not block the caller beyond deadline.
        return Err(error);
    }
    // A spawned descendant must not keep pipes open after the command exits.
    while !(out.is_finished() && err.is_finished() && writer.is_finished()) {
        if Instant::now() >= deadline {
            #[cfg(unix)]
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
            bail!("Sync subprocess pipes did not close before deadline");
        }
        thread::sleep(Duration::from_millis(2));
    }
    writer
        .join()
        .map_err(|_| anyhow::anyhow!("Transport writer panicked"))??;
    let stdout = out
        .join()
        .map_err(|_| anyhow::anyhow!("Transport reader panicked"))??;
    let stderr = err
        .join()
        .map_err(|_| anyhow::anyhow!("Transport reader panicked"))??;
    ensure!(
        !overflow.load(Ordering::Acquire),
        "Sync subprocess output exceeds size limit"
    );
    Ok((status?.success(), stdout, stderr))
}
pub fn exchange_command(argv: &[String], request: &Request, timeout: Duration) -> Result<Response> {
    let mut bytes = serde_json::to_vec(request)?;
    bytes.push(b'\n');
    ensure!(
        bytes.len() <= MAX_REQUEST,
        "Sync request exceeds size limit"
    );
    let (success, stdout, stderr) = subprocess(argv, &bytes, timeout)?;
    ensure!(
        success,
        "Sync exchange failed: {}",
        String::from_utf8_lossy(&stderr[stderr.len().saturating_sub(700)..])
    );
    let value: Value = serde_json::from_slice(&stdout).context("Invalid sync response JSON")?;
    if let Some(error) = value.get("error") {
        bail!("Hub rejected exchange: {error}");
    }
    serde_json::from_value(value).context("Invalid sync response schema")
}

fn has_link(profile: &Path, rel: &str) -> bool {
    let mut current = profile.to_path_buf();
    for part in rel.split('/') {
        current.push(part);
        if linked(&current) {
            return true;
        }
    }
    false
}
fn materialize(
    profile: &Path,
    rel: &str,
    contents: &Contents,
    backup: &Path,
    marker: &Path,
) -> Result<()> {
    let mut current = profile.to_path_buf();
    let mut prefix = Vec::new();
    for part in rel.split('/') {
        current.push(part);
        prefix.push(part);
        if !linked(&current) {
            continue;
        }
        ensure!(
            prefix[0] == "skills",
            "Refusing to replace linked identity/memory file: {rel}"
        );
        let virtual_path = prefix.join("/");
        let destination = backup.join("links").join(&virtual_path);
        let link_meta = destination.with_file_name(format!(
            "{}.link.json",
            destination
                .file_name()
                .context("Link name")?
                .to_string_lossy()
        ));
        json_write(
            &link_meta,
            &json!({"target": guarded_read_link(&current)?.to_string_lossy()}),
        )?;
        // Tie the durable marker to the actual link move, not an earlier
        // has_link check that can race a concurrent editor.
        json_write(
            marker,
            &json!({"profile": profile, "path": rel, "backup": backup, "live": manifest(contents)}),
        )?;
        guarded_rename(&current, &destination)?;
        if !contents.contains_key(&virtual_path) {
            private_dir(&current)?;
        }
        for (path, bytes) in contents {
            if path == &virtual_path || path.starts_with(&format!("{virtual_path}/")) {
                atomic_write(&profile.join(path), bytes, bytes.starts_with(b"#!"))?;
            }
        }
    }
    Ok(())
}
fn validate_response(
    previous: &ClientState,
    request: &Request,
    response: &Response,
) -> Result<BTreeMap<String, Option<Vec<u8>>>> {
    ensure!(
        crate::json_encoded_len(response)?.saturating_add(1) <= MAX_REQUEST,
        "Sync response exceeds size limit"
    );
    ensure!(!response.hub_id.is_empty(), "Missing hub identity");
    if let Some(hub_id) = &previous.hub_id {
        ensure!(
            hub_id == &response.hub_id,
            "Hub identity changed; refusing to replace local files"
        );
        ensure!(
            response.revision >= previous.revision,
            "Hub revision rolled back"
        );
    }
    validate_paths(
        response
            .files
            .keys()
            .chain(response.changes.keys())
            .chain(response.conflicts.iter())
            .chain(request.live.keys())
            .chain(request.base.keys())
            .map(String::as_str),
    )?;
    for hash in response.files.values() {
        validate_hash(hash)?;
    }
    let conflicts: BTreeSet<_> = response.conflicts.iter().collect();
    ensure!(
        conflicts.len() == response.conflicts.len(),
        "Duplicate response conflict"
    );
    for conflict in &response.conflicts {
        ensure!(
            request.base.contains_key(conflict)
                || request.live.contains_key(conflict)
                || response.files.contains_key(conflict),
            "Unrequested conflict"
        );
        ensure!(
            !response.changes.contains_key(conflict),
            "Response changes conflicting path"
        );
    }
    let mut decoded = BTreeMap::new();
    for (path, data) in &response.changes {
        ensure!(
            request.live.get(path) != response.files.get(path),
            "Unexpected response change: {path}"
        );
        let bytes = data
            .as_ref()
            .map(|encoded| STANDARD.decode(encoded))
            .transpose()
            .context("Invalid response base64")?;
        ensure!(
            bytes.as_ref().map(|b| digest(b)).as_ref() == response.files.get(path),
            "Invalid hub response for {path}"
        );
        decoded.insert(path.clone(), bytes);
    }
    for path in request.live.keys().chain(response.files.keys()) {
        if request.live.get(path) != response.files.get(path) && !conflicts.contains(path) {
            ensure!(decoded.contains_key(path), "Missing hub change for {path}");
        }
    }
    Ok(decoded)
}
// Resolve a not-yet-created private store without allowing lexical traversal
// through a missing component. Existing symlink aliases resolve to their real
// location for overlap checks; actual state I/O still rejects every link.
fn resolved_location(path: &Path) -> Result<PathBuf> {
    ensure!(
        !path
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir)),
        "Parent traversal is not permitted in sync configuration"
    );
    let mut existing = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut missing = Vec::new();
    loop {
        match fs::symlink_metadata(&existing) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(
                    existing
                        .file_name()
                        .context("Missing configuration ancestor")?
                        .to_os_string(),
                );
                ensure!(existing.pop(), "Missing configuration ancestor");
            }
            Err(error) => return Err(error.into()),
        }
    }
    let mut resolved = fs::canonicalize(&existing)?;
    for component in missing.into_iter().rev() {
        resolved.push(component);
    }
    Ok(resolved)
}
fn validate_config_locations(config: &SyncConfig) -> Result<PathBuf> {
    ensure!(config.profile.is_dir(), "Missing Hermes profile");
    let profile = resolved_location(&config.profile)?;
    let skills = profile.join("skills");
    let mut private = vec![resolved_location(&config.state_dir)?];
    if let Some(hub) = &config.hub_store {
        private.push(resolved_location(hub)?);
    }
    for path in &private {
        ensure!(
            !path.starts_with(&skills),
            "Private state/hub directory overlaps portable skills scope"
        );
    }
    for allowed in &config.allowed_skill_roots {
        let allowed = resolved_location(allowed)?;
        ensure!(
            !profile.starts_with(&allowed)
                && (!allowed.starts_with(&profile) || allowed.starts_with(&skills)),
            "Skill root overlaps excluded profile files"
        );
        for path in &private {
            ensure!(
                !allowed.starts_with(path) && !path.starts_with(&allowed),
                "Private state/hub directory overlaps an allowed skill root"
            );
        }
    }
    Ok(profile)
}

/// Exchange and apply with an injected transport, useful for in-process hubs,
/// testing, and embedding. The client run lock spans snapshot through state save;
/// the memory writer locks are held only around per-file recheck and replacement.
pub fn run_sync_with_transport<F>(config: &SyncConfig, transport: F) -> Result<SyncOutcome>
where
    F: FnOnce(&Request) -> Result<Response>,
{
    validate_node(&config.node)?;
    // This must precede every metadata write, including run.lock/status.json.
    let profile = validate_config_locations(config)?;
    private_dir(&config.state_dir)?;
    let _run = FileLock::acquire(&config.state_dir.join("run.lock"), false)?;
    let previous: ClientState =
        json_read(&config.state_dir.join("client.json"))?.unwrap_or_default();
    validate_paths(previous.base.keys().map(String::as_str))?;
    for hash in previous.base.values() {
        validate_hash(hash)?;
    }
    ensure!(
        previous.node.is_empty() || previous.node == config.node,
        "Client state belongs to a different node"
    );
    let binding = json!({"profile": profile, "node": config.node});
    if let Some(saved) = json_read::<Value>(&config.state_dir.join("binding.json"))? {
        ensure!(
            saved == binding,
            "Client state belongs to a different profile or node"
        );
    } else {
        json_write(&config.state_dir.join("binding.json"), &binding)?;
    }
    // Always acquire this shared gate, including before the bridge has created
    // its first readiness marker. Never hold the SQLite connection over sync.
    let _bridge_lock = FileLock::acquire(&profile.join(".native-bridge.lock"), false)?;
    crate::profile_bridge::check_sync_ready(&profile)?;
    ensure!(
        read_plain(
            &config.state_dir.join("materialization-incomplete.json"),
            MAX_REQUEST
        )?
        .is_none(),
        "Interrupted skill materialization: restore the preserved link/files and review materialization-incomplete.json before syncing"
    );
    let mut contents = scan_with_skill_roots(&profile, &config.allowed_skill_roots)?;
    crate::profile_bridge::validate_sync_contents(&contents)?;
    let live = manifest(&contents);
    let payload = contents
        .iter()
        .filter(|(p, _)| config.force_payload || live.get(*p) != previous.base.get(*p))
        .map(|(p, bytes)| (p.clone(), STANDARD.encode(bytes)))
        .collect();
    let request = Request {
        node: config.node.clone(),
        hub_id: previous.hub_id.clone(),
        base: previous.base.clone(),
        live: live.clone(),
        payload,
    };
    ensure!(
        crate::json_encoded_len(&request)?.saturating_add(1) <= MAX_REQUEST,
        "Sync request exceeds size limit"
    );
    let response = transport(&request)?;
    let decoded = validate_response(&previous, &request, &response)?;
    for (path, bytes) in &decoded {
        crate::profile_bridge::validate_sync_file(path, bytes.as_deref())?;
    }
    let backup = config.state_dir.join("backups").join(stamp());
    let mut conflicts: BTreeSet<String> = response.conflicts.iter().cloned().collect();
    let mut applied = 0;
    let mut next_base = previous.base;
    // This recovery record does not replace the last acknowledged base. A crash
    // can safely retry with that old base; object identity makes it idempotent.
    json_write(
        &config.state_dir.join("pending.json"),
        &json!({"time": stamp(), "live": live, "response": response, "backup": backup}),
    )?;
    for path in live
        .keys()
        .chain(response.files.keys())
        .chain(next_base.keys())
        .cloned()
        .collect::<BTreeSet<_>>()
    {
        if conflicts.contains(&path) {
            continue;
        }
        let desired = response.files.get(&path);
        if let Some(bytes) = decoded.get(&path) {
            let target = profile.join(&path);
            // Check before creating a sibling lock: a linked memory parent must
            // not cause a lock file to be created in an external directory.
            if !path.starts_with("skills/") && has_link(&profile, &path) {
                conflicts.insert(path.clone());
                continue;
            }
            let _memory_lock = if MEMORY_PATHS.contains(&path.as_str()) {
                Some(FileLock::acquire(&target.with_extension("md.lock"), true)?)
            } else {
                None
            };
            let current = read_one_with_skill_roots(&profile, &path, &config.allowed_skill_roots)?;
            if current.as_ref().map(|bytes| digest(bytes)).as_ref() != live.get(&path) {
                conflicts.insert(path.clone());
                continue;
            }
            if let Some(current) = &current {
                atomic_write(&backup.join("files").join(&path), current, false)?;
            }
            if has_link(&profile, &path) {
                contents = scan_with_skill_roots(&profile, &config.allowed_skill_roots)?;
            }
            let marker = config.state_dir.join("materialization-incomplete.json");
            materialize(&profile, &path, &contents, &backup, &marker)?;
            remove_if_exists(&marker)?;
            if let Some(bytes) = bytes {
                let mut executable = bytes.starts_with(b"#!");
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    executable |= unixfs::open_file(&target, false)
                        .and_then(|file| Ok(file.metadata()?))
                        .is_ok_and(|m| m.permissions().mode() & 0o111 != 0);
                }
                atomic_write(&target, bytes, executable)?;
            } else {
                remove_if_exists(&target)?;
            }
            applied += 1;
        }
        if let Some(hash) = desired {
            next_base.insert(path, hash.clone());
        } else {
            next_base.remove(&path);
        }
    }
    let conflicts: Vec<_> = conflicts.into_iter().collect();
    let state = ClientState {
        time: stamp(),
        node: config.node.clone(),
        hub_id: Some(response.hub_id.clone()),
        revision: response.revision,
        base: next_base,
        conflicts: conflicts.clone(),
    };
    json_write(&config.state_dir.join("client.json"), &state)?;
    json_write(
        &config.state_dir.join("status.json"),
        &json!({"time": state.time, "node": state.node, "hub_id": state.hub_id, "revision": state.revision, "conflicts": conflicts}),
    )?;
    if conflicts.is_empty() {
        remove_if_exists(&config.state_dir.join("conflicts.json"))?;
    } else {
        json_write(
            &config.state_dir.join("conflicts.json"),
            &json!({"time": stamp(), "paths": conflicts, "local": live, "hub": response.files}),
        )?;
    }
    remove_if_exists(&config.state_dir.join("pending.json"))?;
    Ok(SyncOutcome {
        node: config.node.clone(),
        revision: state.revision,
        files: state.base.len(),
        applied,
        conflicts,
    })
}
pub fn run_sync(config: &SyncConfig) -> Result<SyncOutcome> {
    let result = run_sync_with_transport(config, |request| {
        if let Some(store) = &config.hub_store {
            exchange(store, request)
        } else {
            exchange_command(&config.ssh, request, Duration::from_secs(600))
        }
    });
    if let Err(error) = &result
        && validate_config_locations(config).is_ok()
    {
        // An invalid overlap must not create error status inside sync scope.
        // Never follow an attacker-supplied link to write error status.
        let _ = json_write(
            &config.state_dir.join("status.json"),
            &json!({"time": stamp(), "error": error.to_string()}),
        );
    }
    result
}

// Descriptor-relative Unix I/O: never follow an ancestor/leaf symlink between
// validation and use. The descriptor stays anchored even when a concurrent
// writer renames a directory or swaps its former path for an external link.
#[cfg(unix)]
mod unixfs {
    use super::*;
    use std::{
        ffi::{CStr, CString, OsString},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::ffi::{OsStrExt, OsStringExt},
        },
    };
    fn c_name(name: &std::ffi::OsStr) -> Result<CString> {
        CString::new(name.as_bytes()).context("NUL in filename")
    }
    fn checked_fd(fd: i32) -> Result<File> {
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: a successful open/openat returns a newly owned descriptor.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    pub(super) fn directory(path: &Path, create: bool) -> Result<File> {
        let absolute = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let mut directory = checked_fd(unsafe {
            libc::open(
                c"/".as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        })?;
        for component in absolute.components() {
            match component {
                std::path::Component::RootDir | std::path::Component::CurDir => continue,
                std::path::Component::Normal(name) => {
                    let name = c_name(name)?;
                    let mut fd = unsafe {
                        libc::openat(
                            directory.as_raw_fd(),
                            name.as_ptr(),
                            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                        )
                    };
                    if fd < 0
                        && create
                        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
                    {
                        let made =
                            unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
                        if made < 0
                            && std::io::Error::last_os_error().kind()
                                != std::io::ErrorKind::AlreadyExists
                        {
                            return Err(std::io::Error::last_os_error().into());
                        }
                        fd = unsafe {
                            libc::openat(
                                directory.as_raw_fd(),
                                name.as_ptr(),
                                libc::O_RDONLY
                                    | libc::O_DIRECTORY
                                    | libc::O_CLOEXEC
                                    | libc::O_NOFOLLOW,
                            )
                        };
                    }
                    directory = checked_fd(fd).with_context(|| {
                        format!("Open directory without links: {}", path.display())
                    })?;
                }
                _ => bail!("Parent traversal is not permitted in sync I/O"),
            }
        }
        Ok(directory)
    }
    fn parent(path: &Path, create: bool) -> Result<(File, CString)> {
        Ok((
            directory(path.parent().context("File needs parent")?, create)?,
            c_name(path.file_name().context("File needs name")?)?,
        ))
    }
    fn is_link_at(parent: &File, name: &CStr) -> Result<bool> {
        let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                status.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } < 0
        {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                return Ok(false);
            }
            return Err(error.into());
        }
        Ok(unsafe { status.assume_init() }.st_mode & libc::S_IFMT == libc::S_IFLNK)
    }
    pub(super) fn open_file(path: &Path, write_create: bool) -> Result<File> {
        let (parent, name) = parent(path, write_create)?;
        let flags = if write_create {
            libc::O_RDWR | libc::O_CREAT
        } else {
            libc::O_RDONLY
        };
        let file = checked_fd(unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                0o600,
            )
        })?;
        ensure!(
            file.metadata()?.is_file(),
            "Not a regular sync file: {}",
            path.display()
        );
        Ok(file)
    }
    pub(super) fn private_dir(path: &Path) -> Result<()> {
        let directory = directory(path, true)?;
        ensure!(
            unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) } == 0,
            "Set private directory permissions: {}",
            std::io::Error::last_os_error()
        );
        Ok(())
    }
    pub(super) fn atomic(path: &Path, bytes: &[u8], executable: bool) -> Result<()> {
        let (parent, name) = parent(path, true)?;
        ensure!(
            !is_link_at(&parent, &name)?,
            "Refusing linked destination: {}",
            path.display()
        );
        let temporary = CString::new(format!(".sync_{}", uuid::Uuid::new_v4()))?;
        let result = (|| {
            let mut file = checked_fd(unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    temporary.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    if executable { 0o700 } else { 0o600 },
                )
            })?;
            file.write_all(bytes)?;
            file.sync_all()?;
            if unsafe {
                libc::renameat(
                    parent.as_raw_fd(),
                    temporary.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                )
            } < 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            parent.sync_all()?;
            Ok(())
        })();
        unsafe {
            libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0);
        }
        result
    }
    pub(super) fn remove(path: &Path) -> Result<()> {
        let (parent, name) = match parent(path, false) {
            Ok(value) => value,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        ensure!(
            !is_link_at(&parent, &name)?,
            "Refusing linked destination: {}",
            path.display()
        );
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(error.into());
            }
        }
        parent.sync_all()?;
        Ok(())
    }
    pub(super) fn names(path: &Path, max_entries: usize) -> Result<Vec<OsString>> {
        let directory = directory(path, false)?;
        let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        ensure!(
            fd >= 0,
            "Duplicate directory descriptor: {}",
            std::io::Error::last_os_error()
        );
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            unsafe {
                libc::close(fd);
            }
            return Err(std::io::Error::last_os_error().into());
        }
        struct Directory(*mut libc::DIR);
        impl Drop for Directory {
            fn drop(&mut self) {
                unsafe {
                    libc::closedir(self.0);
                }
            }
        }
        let stream = Directory(stream);
        let mut names = Vec::new();
        loop {
            // readdir null means EOF or error. Reset errno using the supported
            // platform accessor so a failed enumeration cannot look complete.
            #[cfg(any(target_os = "linux", target_os = "android"))]
            unsafe {
                *libc::__errno_location() = 0;
            }
            #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
            unsafe {
                *libc::__error() = 0;
            }
            let entry = unsafe { libc::readdir(stream.0) };
            if entry.is_null() {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error().unwrap_or(0) != 0 {
                    return Err(error.into());
                }
                break;
            }
            let bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
            if bytes != b"." && bytes != b".." {
                ensure!(names.len() < max_entries, "Too many directory entries");
                names.push(OsString::from_vec(bytes.to_vec()));
            }
        }
        names.sort();
        Ok(names)
    }
    pub(super) fn read_link(path: &Path) -> Result<PathBuf> {
        let (parent, name) = parent(path, false)?;
        let mut bytes = vec![0; 65536];
        let count = unsafe {
            libc::readlinkat(
                parent.as_raw_fd(),
                name.as_ptr(),
                bytes.as_mut_ptr().cast(),
                bytes.len(),
            )
        };
        if count < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        ensure!((count as usize) < bytes.len(), "Link target is too long");
        bytes.truncate(count as usize);
        Ok(PathBuf::from(OsString::from_vec(bytes)))
    }
    pub(super) fn rename(source: &Path, destination: &Path) -> Result<()> {
        let (src_parent, src_name) = parent(source, false)?;
        let (dst_parent, dst_name) = parent(destination, true)?;
        ensure!(
            !is_link_at(&dst_parent, &dst_name)?,
            "Refusing linked backup destination"
        );
        if unsafe {
            libc::renameat(
                src_parent.as_raw_fd(),
                src_name.as_ptr(),
                dst_parent.as_raw_fd(),
                dst_name.as_ptr(),
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        src_parent.sync_all()?;
        dst_parent.sync_all()?;
        Ok(())
    }
}

fn guarded_read_link(path: &Path) -> Result<PathBuf> {
    #[cfg(unix)]
    {
        unixfs::read_link(path)
    }
    #[cfg(not(unix))]
    {
        Ok(fs::read_link(path)?)
    }
}
fn guarded_rename(source: &Path, destination: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        unixfs::rename(source, destination)
    }
    #[cfg(not(unix))]
    {
        Ok(fs::rename(source, destination)?)
    }
}

/// Bounded strict no-follow read for the native profile bridge. Missing files
/// return None; a linked ancestor/leaf, special file or oversized file is error.
pub fn read_plain(path: &Path, max_bytes: usize) -> Result<Option<Vec<u8>>> {
    let opened: Result<File> = {
        #[cfg(unix)]
        {
            unixfs::open_file(path, false)
        }
        #[cfg(not(unix))]
        {
            reject_links(path).and_then(|_| Ok(File::open(path)?))
        }
    };
    let file = match opened {
        Ok(file) => file,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    ensure!(file.metadata()?.is_file(), "Not a regular sync file");
    let mut bytes = Vec::new();
    file.take((max_bytes as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= max_bytes, "Sync file exceeds size limit");
    Ok(Some(bytes))
}
pub fn remove_plain(path: &Path) -> Result<()> {
    remove_if_exists(path)
}
pub fn ensure_private_dir(path: &Path) -> Result<()> {
    private_dir(path)
}

/// Enumerate names from a no-follow directory descriptor, bounded in count.
pub fn list_plain(path: &Path, max_entries: usize) -> Result<Vec<std::ffi::OsString>> {
    #[cfg(unix)]
    {
        unixfs::names(path, max_entries)
    }
    #[cfg(not(unix))]
    {
        reject_links(path)?;
        let mut names = fs::read_dir(path)?
            .take(max_entries.saturating_add(1))
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<std::io::Result<Vec<_>>>()?;
        ensure!(names.len() <= max_entries, "Too many directory entries");
        names.sort();
        Ok(names)
    }
}
