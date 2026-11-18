//! Bounded incoming document text extraction. Never executes document macros,
//! formulas, links or embedded objects; extracted text remains untrusted data.
use anyhow::{Context, Result, bail, ensure};
use quick_xml::{Reader, events::Event};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize)]
pub struct DocumentConfig {
    /// Explicit trusted absolute Poppler executable. None disables PDF parsing.
    pub pdf_program: Option<PathBuf>,
    pub timeout: Duration,
    pub max_output_bytes: usize,
    pub max_entries: usize,
    pub max_xml_part_bytes: usize,
    pub max_total_xml_bytes: usize,
    pub max_sections: usize,
    pub max_xml_depth: usize,
    pub pdf_memory_bytes: u64,
    pub pdf_cpu_seconds: u64,
}
impl Default for DocumentConfig {
    fn default() -> Self {
        Self {
            pdf_program: None,
            timeout: Duration::from_secs(5),
            max_output_bytes: 100_000,
            max_entries: 4096,
            max_xml_part_bytes: 4 * 1024 * 1024,
            max_total_xml_bytes: 32 * 1024 * 1024,
            max_sections: 2048,
            max_xml_depth: 64,
            pdf_memory_bytes: 512 * 1024 * 1024,
            pdf_cpu_seconds: 4,
        }
    }
}
#[derive(Clone, Debug)]
pub struct DocumentExtractor {
    config: Arc<DocumentConfig>,
    gate: Arc<tokio::sync::Semaphore>,
    cache: Arc<DocumentCache>,
}
/// Process-local derived text only. Zero bytes or entries disables storage.
#[derive(Clone, Debug)]
pub struct DocumentCacheConfig {
    pub max_bytes: usize,
    pub max_entries: usize,
    pub ttl: Duration,
}
impl Default for DocumentCacheConfig {
    fn default() -> Self {
        Self {
            max_bytes: 16 * 1024 * 1024,
            max_entries: 256,
            ttl: Duration::from_secs(15 * 60),
        }
    }
}
/// Construct only from trusted transport identity and original conversation.
/// Neither component is taken from model arguments. Debug never exposes either.
#[derive(Clone, Debug)]
pub struct DocumentCacheScope([u8; 32]);
impl DocumentCacheScope {
    pub fn new(
        verified_owner_scope: &str,
        owner_namespace: &str,
        conversation_id: &str,
    ) -> Result<Self> {
        ensure!(
            !verified_owner_scope.is_empty()
                && verified_owner_scope.len() <= 4096
                && !owner_namespace.is_empty()
                && owner_namespace.len() <= 4096
                && !conversation_id.is_empty()
                && conversation_id.len() <= 4096,
            "document cache requires trusted owner and conversation scope"
        );
        Ok(Self(
            Sha256::digest(serde_json::to_vec(&(
                verified_owner_scope,
                owner_namespace,
                conversation_id,
            ))?)
            .into(),
        ))
    }
}
#[derive(Clone, Copy, Debug, Default)]
pub struct DocumentCacheStats {
    pub entries: usize,
    pub bytes: usize,
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
}
struct CacheEntry {
    document: ExtractedDocument,
    bytes: usize,
    created: Instant,
    used: u64,
}
#[derive(Default)]
struct CacheState {
    entries: HashMap<[u8; 32], CacheEntry>,
    inflight: HashSet<[u8; 32]>,
    bytes: usize,
    tick: u64,
    hits: u64,
    misses: u64,
    evictions: u64,
}
struct DocumentCache {
    config: DocumentCacheConfig,
    state: Mutex<CacheState>,
    changed: Condvar,
}
impl std::fmt::Debug for DocumentCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DocumentCache")
            .field("limits", &self.config)
            .finish_non_exhaustive()
    }
}
enum CacheAccess {
    Hit(ExtractedDocument),
    Reserved(CacheReservation),
    Disabled,
}
struct CacheReservation {
    cache: Arc<DocumentCache>,
    key: [u8; 32],
}
impl Drop for CacheReservation {
    fn drop(&mut self) {
        if let Ok(mut state) = self.cache.state.lock() {
            state.inflight.remove(&self.key);
            self.cache.changed.notify_all();
        }
    }
}
impl DocumentCache {
    fn new(config: DocumentCacheConfig) -> Result<Arc<Self>> {
        ensure!(
            config.max_bytes <= 256 * 1024 * 1024
                && config.max_entries <= 4096
                && config.ttl > Duration::ZERO
                && config.ttl <= Duration::from_secs(86400),
            "invalid derived document cache limits"
        );
        Ok(Arc::new(Self {
            config,
            state: Mutex::new(CacheState::default()),
            changed: Condvar::new(),
        }))
    }
    fn access(self: &Arc<Self>, key: [u8; 32], context: &ExtractionContext) -> Result<CacheAccess> {
        if self.config.max_bytes == 0 || self.config.max_entries == 0 {
            return Ok(CacheAccess::Disabled);
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("document cache unavailable"))?;
        loop {
            context.check()?;
            let expired = state
                .entries
                .iter()
                .filter(|(_, v)| v.created.elapsed() >= self.config.ttl)
                .map(|(k, _)| *k)
                .collect::<Vec<_>>();
            for key in expired {
                if let Some(entry) = state.entries.remove(&key) {
                    state.bytes -= entry.bytes;
                    state.evictions += 1;
                }
            }
            state.tick = state.tick.wrapping_add(1);
            let tick = state.tick;
            if let Some(entry) = state.entries.get_mut(&key) {
                entry.used = tick;
                let doc = entry.document.clone();
                state.hits += 1;
                return Ok(CacheAccess::Hit(doc));
            }
            if !state.inflight.contains(&key) {
                state.inflight.insert(key);
                state.misses += 1;
                return Ok(CacheAccess::Reserved(CacheReservation {
                    cache: self.clone(),
                    key,
                }));
            }
            state = self
                .changed
                .wait_timeout(state, Duration::from_millis(10))
                .map_err(|_| anyhow::anyhow!("document cache unavailable"))?
                .0;
        }
    }
}
impl CacheReservation {
    fn store(&self, document: &ExtractedDocument) -> Result<()> {
        // JSON size bounds all source/text/warning data, including escaped bytes.
        // Include a fixed allocation allowance per entry and section.
        let bytes = serde_json::to_vec(document)?
            .len()
            .saturating_add(256)
            .saturating_add(document.sections.len() * 96);
        if bytes > self.cache.config.max_bytes {
            return Ok(());
        }
        let mut state = self
            .cache
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("document cache unavailable"))?;
        while state.entries.len() >= self.cache.config.max_entries
            || state.bytes.saturating_add(bytes) > self.cache.config.max_bytes
        {
            let oldest = state
                .entries
                .iter()
                .min_by_key(|(_, v)| v.used)
                .map(|(k, _)| *k);
            let Some(oldest) = oldest else { break };
            let old = state.entries.remove(&oldest).unwrap();
            state.bytes -= old.bytes;
            state.evictions += 1;
        }
        state.tick = state.tick.wrapping_add(1);
        let used = state.tick;
        if let Some(old) = state.entries.remove(&self.key) {
            state.bytes -= old.bytes;
        }
        state.entries.insert(
            self.key,
            CacheEntry {
                document: document.clone(),
                bytes,
                created: Instant::now(),
                used,
            },
        );
        state.bytes += bytes;
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct DocumentSection {
    pub source: String,
    pub text: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct ExtractedDocument {
    pub format: String,
    pub sections: Vec<DocumentSection>,
    pub truncated: bool,
    pub warnings: Vec<String>,
}
impl ExtractedDocument {
    pub fn text_bytes(&self) -> usize {
        self.sections
            .iter()
            .map(|s| s.source.len() + s.text.len())
            .sum()
    }
}
struct CancelGuard(Arc<AtomicBool>);
impl Drop for CancelGuard {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Pdf,
    Docx,
    Xlsx,
    Pptx,
    Odt,
    Legacy,
    Unsupported,
}
fn kind(mime: &str, name: &str) -> Kind {
    let mime = mime
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if mime == "application/pdf" {
        return Kind::Pdf;
    }
    let extension = Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match extension.as_str() {
        "pdf" => Kind::Pdf,
        "docx" => Kind::Docx,
        "xlsx" => Kind::Xlsx,
        "pptx" => Kind::Pptx,
        "odt" => Kind::Odt,
        "doc" | "xls" | "ppt" | "rtf" | "docm" | "xlsm" | "pptm" | "ods" | "odp" => Kind::Legacy,
        _ => Kind::Unsupported,
    }
}
pub fn recognizes(mime: &str, name: &str) -> bool {
    kind(mime, name) != Kind::Unsupported
}
impl DocumentExtractor {
    pub fn new(mut config: DocumentConfig) -> Result<Self> {
        ensure!(
            config.timeout > Duration::ZERO && config.timeout <= Duration::from_secs(30),
            "document timeout must be 1ns–30s"
        );
        ensure!(
            config.max_output_bytes > 0
                && config.max_output_bytes <= 256 * 1024
                && config.max_entries > 0
                && config.max_entries <= 8192
                && config.max_xml_part_bytes > 0
                && config.max_xml_part_bytes <= 16 * 1024 * 1024
                && config.max_total_xml_bytes >= config.max_xml_part_bytes
                && config.max_total_xml_bytes <= 128 * 1024 * 1024
                && config.max_sections > 0
                && config.max_sections <= 4096
                && config.max_xml_depth > 0
                && config.max_xml_depth <= 256,
            "invalid document extraction limits"
        );
        ensure!(
            (64 * 1024 * 1024..=2 * 1024 * 1024 * 1024).contains(&config.pdf_memory_bytes)
                && (1..=30).contains(&config.pdf_cpu_seconds),
            "invalid PDF process limits"
        );
        if let Some(program) = &config.pdf_program {
            ensure!(
                program.is_absolute() && program.is_file(),
                "PDF extractor must be an explicitly configured absolute executable"
            );
            config.pdf_program = Some(fs::canonicalize(program)?);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                ensure!(
                    fs::metadata(config.pdf_program.as_ref().unwrap())?
                        .permissions()
                        .mode()
                        & 0o111
                        != 0,
                    "PDF extractor is not executable"
                );
            }
        }
        Ok(Self {
            config: Arc::new(config),
            gate: Arc::new(tokio::sync::Semaphore::new(2)),
            cache: DocumentCache::new(DocumentCacheConfig::default())?,
        })
    }
    /// Replace this handle's cache with an empty cache under explicit limits.
    /// Existing clones retain their previous cache; no process-wide shared cache exists.
    pub fn with_cache_config(mut self, config: DocumentCacheConfig) -> Result<Self> {
        self.cache = DocumentCache::new(config)?;
        Ok(self)
    }
    pub fn cache_stats(&self) -> DocumentCacheStats {
        self.cache
            .state
            .lock()
            .map(|s| DocumentCacheStats {
                entries: s.entries.len(),
                bytes: s.bytes,
                hits: s.hits,
                misses: s.misses,
                evictions: s.evictions,
            })
            .unwrap_or_default()
    }
    /// Legacy/direct extraction remains uncached, preserving its prior semantics.
    pub async fn extract(
        &self,
        path: &Path,
        mime: &str,
        name: &str,
        remaining_text_bytes: usize,
    ) -> Result<ExtractedDocument> {
        self.extract_inner(path, mime, name, remaining_text_bytes, None)
            .await
    }
    /// `scope` must come from trusted transport identity and source conversation.
    /// A cache hit still opens, validates and hashes the actual private input file.
    pub async fn extract_scoped(
        &self,
        path: &Path,
        mime: &str,
        name: &str,
        remaining_text_bytes: usize,
        scope: &DocumentCacheScope,
    ) -> Result<ExtractedDocument> {
        self.extract_inner(path, mime, name, remaining_text_bytes, Some(scope.clone()))
            .await
    }
    async fn extract_inner(
        &self,
        path: &Path,
        mime: &str,
        name: &str,
        remaining_text_bytes: usize,
        scope: Option<DocumentCacheScope>,
    ) -> Result<ExtractedDocument> {
        ensure!(
            remaining_text_bytes > 0,
            "document text budget is exhausted"
        );
        let kind = kind(mime, name);
        ensure!(kind != Kind::Unsupported, "unsupported document format");
        ensure!(
            kind != Kind::Legacy,
            "legacy, macro-enabled and unsupported Office formats require a separate extractor; no text was read"
        );
        let permit = self.gate.clone().acquire_owned().await?;
        let config = self.config.clone();
        let cache = self.cache.clone();
        let path = path.to_owned();
        let mime = mime.to_owned();
        let name = name.to_owned();
        let cancelled = Arc::new(AtomicBool::new(false));
        let _guard = CancelGuard(cancelled.clone());
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let context = ExtractionContext {
                deadline: Instant::now() + config.timeout,
                cancelled,
                config,
                limit: remaining_text_bytes,
            };
            context.check()?;
            let mut file = open_input(&path)?;
            ensure!(
                (1..=20 * 1024 * 1024).contains(&file.metadata()?.len()),
                "document must be between 1 byte and 20 MiB"
            );
            let version = file_version(&file.metadata()?);
            let mut access = CacheAccess::Disabled;
            let mut sha = None;
            let mut program = None;
            if let Some(scope) = &scope {
                check_private_input(&path, &file)?;
                let actual = hash_open_file(&mut file, &context, 20 * 1024 * 1024)?;
                verify_input(&path, &file, &version, true)?;
                let program_identity = program_identity(&context, kind)?;
                let key = Sha256::digest(serde_json::to_vec(&(
                    "orialis-document-extract-v2",
                    scope.0,
                    actual,
                    format!("{kind:?}"),
                    &mime,
                    &name,
                    remaining_text_bytes,
                    &*context.config,
                    &program_identity,
                ))?)
                .into();
                access = cache.access(key, &context)?;
                // The file may have changed while waiting on a same-key producer.
                verify_input(&path, &file, &version, true)?;
                if let CacheAccess::Hit(document) = access {
                    context.check()?;
                    return Ok(document);
                }
                sha = Some(actual);
                program = Some(program_identity);
            }
            let mut signature = [0u8; 5];
            let read = file.read(&mut signature)?;
            file.rewind()?;
            let mut verification = file.try_clone()?;
            let output = if kind == Kind::Pdf {
                ensure!(
                    read == 5 && &signature == b"%PDF-",
                    "PDF bytes do not match the declared document format"
                );
                pdf(file, &context)?
            } else {
                ensure!(
                    read >= 4 && &signature[..4] == b"PK\x03\x04",
                    "Office document is not a supported ZIP container"
                );
                office(file, kind, &context)?
            };
            context.check()?;
            verify_input(&path, &verification, &version, scope.is_some())?;
            if let Some(expected) = sha {
                ensure!(
                    hash_open_file(&mut verification, &context, 20 * 1024 * 1024)? == expected,
                    "document bytes changed during extraction"
                );
                verify_input(&path, &verification, &version, true)?;
                ensure!(
                    program.as_ref() == Some(&program_identity(&context, kind)?),
                    "PDF extractor changed during extraction"
                );
                context.check()?;
                if let CacheAccess::Reserved(reservation) = &access {
                    reservation.store(&output)?;
                }
            }
            Ok(output)
        })
        .await
        .context("document extractor stopped")?
    }
}

/// Extract an already confined, immutable byte snapshot. Unlike the attachment
/// path, this entry point cannot open paths, invoke a PDF program, or use a cache.
/// The caller owns input admission; archive/XML/output limits are still enforced.
pub(crate) fn extract_office_bytes(bytes: &[u8], name: &str) -> Result<ExtractedDocument> {
    let kind = kind("", name);
    ensure!(matches!(kind, Kind::Docx | Kind::Xlsx | Kind::Pptx | Kind::Odt),
        "only DOCX, XLSX, PPTX and ODT have an in-process document extractor");
    ensure!((1..=20 * 1024 * 1024).contains(&bytes.len()),
        "document must be between 1 byte and 20 MiB");
    ensure!(bytes.starts_with(b"PK\x03\x04"),
        "Office document is not a supported ZIP container");
    let config = DocumentConfig { max_output_bytes: 256 * 1024, ..DocumentConfig::default() };
    let context = ExtractionContext {
        deadline: Instant::now() + config.timeout,
        cancelled: Arc::new(AtomicBool::new(false)),
        limit: config.max_output_bytes,
        config: Arc::new(config),
    };
    let output = office(std::io::Cursor::new(bytes), kind, &context)?;
    context.check()?;
    Ok(output)
}

#[cfg(unix)]
fn file_version(meta: &fs::Metadata) -> Vec<u64> {
    use std::os::unix::fs::MetadataExt;
    vec![
        meta.dev(),
        meta.ino(),
        meta.len(),
        meta.mtime() as u64,
        meta.mtime_nsec() as u64,
        meta.ctime() as u64,
        meta.ctime_nsec() as u64,
        meta.nlink(),
        meta.mode() as u64,
        meta.uid() as u64,
    ]
}
#[cfg(not(unix))]
fn file_version(meta: &fs::Metadata) -> Vec<u64> {
    vec![meta.len()]
}
fn verify_input(path: &Path, file: &File, version: &[u64], private: bool) -> Result<()> {
    ensure!(
        file_version(&file.metadata()?) == version,
        "document changed during extraction"
    );
    let reopened = open_input(path)?;
    ensure!(
        file_version(&reopened.metadata()?) == version,
        "document cache path was replaced during extraction"
    );
    if private {
        check_private_input(path, &reopened)?;
    }
    Ok(())
}
#[cfg(unix)]
fn check_private_input(path: &Path, file: &File) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let file = file.metadata()?;
    let parent = fs::symlink_metadata(path.parent().context("missing document parent")?)?;
    ensure!(
        file.is_file()
            && file.nlink() == 1
            && file.uid() == unsafe { libc::geteuid() }
            && file.mode() & 0o777 == 0o600
            && parent.is_dir()
            && !parent.file_type().is_symlink()
            && parent.uid() == unsafe { libc::geteuid() }
            && parent.mode() & 0o777 == 0o700,
        "derived cache requires a private single-linked input and private parent"
    );
    Ok(())
}
#[cfg(not(unix))]
fn check_private_input(_: &Path, _: &File) -> Result<()> {
    bail!("private document cache requires Unix")
}
fn hash_open_file(file: &mut File, context: &ExtractionContext, max: u64) -> Result<[u8; 32]> {
    file.rewind()?;
    let mut sha = Sha256::new();
    let mut bytes = 0u64;
    let mut buffer = [0u8; 65536];
    loop {
        context.check()?;
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        ensure!(bytes <= max, "document/extractor exceeds hash size limit");
        sha.update(&buffer[..n]);
    }
    file.rewind()?;
    Ok(sha.finalize().into())
}
fn program_identity(
    context: &ExtractionContext,
    kind: Kind,
) -> Result<Option<([u8; 32], Vec<u64>)>> {
    if kind != Kind::Pdf {
        return Ok(None);
    }
    let path = context.config.pdf_program.as_ref().context(
        "PDF extraction is not configured; set an explicit Poppler pdftotext executable",
    )?;
    let mut file = open_input(path)?;
    let version = file_version(&file.metadata()?);
    let sha = hash_open_file(&mut file, context, 128 * 1024 * 1024)?;
    verify_input(path, &file, &version, false)?;
    Ok(Some((sha, version)))
}

struct ExtractionContext {
    config: Arc<DocumentConfig>,
    deadline: Instant,
    cancelled: Arc<AtomicBool>,
    limit: usize,
}
impl ExtractionContext {
    fn check(&self) -> Result<()> {
        ensure!(
            !self.cancelled.load(Ordering::Acquire),
            "document extraction cancelled"
        );
        ensure!(
            Instant::now() < self.deadline,
            "document extraction timed out"
        );
        Ok(())
    }
    fn budget(&self) -> usize {
        self.limit.min(self.config.max_output_bytes)
    }
}
struct Builder {
    output: ExtractedDocument,
    remaining: usize,
    max_sections: usize,
}
impl Builder {
    fn new(format: &str, context: &ExtractionContext) -> Self {
        Self {
            output: ExtractedDocument {
                format: format.into(),
                sections: Vec::new(),
                truncated: false,
                warnings: Vec::new(),
            },
            remaining: context.budget(),
            max_sections: context.config.max_sections,
        }
    }
    fn section(&mut self, source: impl Into<String>, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let mut source = source.into();
        if source.len() > 256 {
            let mut end = 256;
            while !source.is_char_boundary(end) {
                end -= 1;
            }
            source.truncate(end);
        }
        if self.output.sections.len() >= self.max_sections || self.remaining <= source.len() {
            self.output.truncated = true;
            return;
        }
        self.remaining -= source.len();
        let mut end = text.len().min(self.remaining);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        if end < text.len() {
            self.output.truncated = true;
        }
        self.remaining -= end;
        self.output.sections.push(DocumentSection {
            source,
            text: text[..end].into(),
        });
    }
    fn finish(mut self) -> Result<ExtractedDocument> {
        ensure!(
            !self.output.sections.is_empty() || !self.output.truncated,
            "document text limit is too small; no content was analyzed"
        );
        ensure!(
            !self.output.sections.is_empty(),
            "document contains no extractable text; scanned/image-only documents require OCR, which is not implemented"
        );
        if self.output.truncated {
            self.output.warnings.push("Document text was truncated by the configured text or section limit; omitted content was not analyzed.".into());
        }
        Ok(self.output)
    }
}
#[cfg(unix)]
fn open_input(path: &Path) -> Result<File> {
    use std::{
        ffi::CString,
        os::fd::{AsRawFd, FromRawFd},
        os::unix::fs::OpenOptionsExt,
    };
    ensure!(path.is_absolute(), "document cache path must be absolute");
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/")?;
    let components = path.components().collect::<Vec<_>>();
    for (index, part) in components.iter().enumerate().skip(1) {
        let std::path::Component::Normal(part) = part else {
            bail!("document cache path contains traversal");
        };
        use std::os::unix::ffi::OsStrExt;
        let name = CString::new(part.as_bytes())?;
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | libc::O_NONBLOCK
            | if index + 1 < components.len() {
                libc::O_DIRECTORY
            } else {
                0
            };
        let fd = unsafe { libc::openat(file.as_raw_fd(), name.as_ptr(), flags) };
        ensure!(
            fd >= 0,
            "document cache path is unavailable or contains links"
        );
        file = unsafe { File::from_raw_fd(fd) };
    }
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.nlink() == 1,
        "document input must be a single-linked regular file"
    );
    Ok(file)
}
#[cfg(not(unix))]
fn open_input(_: &Path) -> Result<File> {
    bail!("document cache descriptor protection requires Unix")
}

#[cfg(target_os = "linux")]
fn pdf(file: File, context: &ExtractionContext) -> Result<ExtractedDocument> {
    use std::{
        os::{fd::AsRawFd, unix::process::CommandExt},
        process::{Child, Command, Stdio},
    };
    let program = context.config.pdf_program.as_ref().context(
        "PDF extraction is not configured; set an explicit Poppler pdftotext executable",
    )?;
    let input_fd = file.as_raw_fd();
    let input = format!("/proc/self/fd/{input_fd}");
    let memory = context.config.pdf_memory_bytes;
    let cpu = context.config.pdf_cpu_seconds;
    let mut command = Command::new(program);
    command
        .args([
            "-q",
            "-layout",
            "-enc",
            "UTF-8",
            "-eol",
            "unix",
            "-f",
            "1",
            "-l",
            &(context.config.max_sections + 1).to_string(),
            &input,
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env_clear()
        .env("LANG", "C.UTF-8")
        .current_dir("/");
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(input_fd, libc::F_GETFD);
            if flags < 0
                || libc::fcntl(input_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                || libc::setpgid(0, 0) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            for (resource, soft, hard) in [
                (libc::RLIMIT_CPU, cpu, cpu + 1),
                (libc::RLIMIT_AS, memory, memory),
                (libc::RLIMIT_FSIZE, 0, 0),
                (libc::RLIMIT_CORE, 0, 0),
                (libc::RLIMIT_NOFILE, 64, 64),
            ] {
                let limit = libc::rlimit {
                    rlim_cur: soft as libc::rlim_t,
                    rlim_max: hard as libc::rlim_t,
                };
                if libc::setrlimit(resource, &limit) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
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
        child: command
            .spawn()
            .map_err(|_| anyhow::anyhow!("configured PDF extractor could not start"))?,
        complete: false,
    };
    let mut stdout = process
        .child
        .stdout
        .take()
        .context("PDF extractor stdout unavailable")?;
    let fd = stdout.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
        "PDF extraction output could not be bounded"
    );
    let cap = context
        .budget()
        .saturating_add(context.config.max_sections * 2)
        .min(512 * 1024);
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    let mut eof = false;
    let mut status = None;
    let mut truncated = false;
    loop {
        context.check()?;
        match stdout.read(&mut buffer) {
            Ok(0) => eof = true,
            Ok(n) => {
                let take = n.min(cap.saturating_sub(bytes.len()));
                bytes.extend_from_slice(&buffer[..take]);
                if take < n || bytes.len() == cap {
                    truncated = true;
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => bail!("PDF extractor output failed"),
        }
        if status.is_none() {
            status = process.child.try_wait()?;
        }
        if eof && status.is_some() {
            process.complete = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    if !truncated {
        ensure!(
            status.is_some_and(|s| s.success()),
            "PDF extraction failed; malformed, encrypted, resource-limited or unsupported PDF"
        );
    }
    while std::str::from_utf8(&bytes).is_err()
        && truncated
        && !bytes.is_empty()
        && bytes.len() > cap.saturating_sub(4)
    {
        bytes.pop();
    }
    let text = std::str::from_utf8(&bytes).context("PDF extractor did not return UTF-8 text")?;
    let mut output = Builder::new("pdf", context);
    output.output.truncated = truncated;
    for (index, page) in text.split('\x0c').enumerate() {
        output.section(format!("page {}", index + 1), page);
    }
    output.output.warnings.push("PDF text extraction does not analyze embedded images, layout semantics, annotations or OCR-only content.".into());
    output.finish()
}
#[cfg(not(target_os = "linux"))]
fn pdf(_: File, _: &ExtractionContext) -> Result<ExtractedDocument> {
    bail!("protected PDF subprocess extraction requires Linux")
}

struct Package<'a, R: Read + Seek> {
    zip: zip::ZipArchive<R>,
    names: HashSet<String>,
    read_bytes: usize,
    context: &'a ExtractionContext,
}
impl<'a, R: Read + Seek> Package<'a, R> {
    fn open(mut file: R, context: &'a ExtractionContext) -> Result<Self> {
        // Bound central-directory allocation before asking the ZIP parser to
        // allocate its index. ZIP64/multidisk are explicitly unsupported.
        let size = file.seek(SeekFrom::End(0))?;
        let tail_size = size.min(65557) as usize;
        file.seek(SeekFrom::End(-(tail_size as i64)))?;
        let mut tail = vec![0; tail_size];
        file.read_exact(&mut tail)?;
        file.rewind()?;
        let position = (0..tail.len().saturating_sub(21))
            .rev()
            .find(|&p| {
                tail[p..].starts_with(b"PK\x05\x06")
                    && p + 22 + u16::from_le_bytes([tail[p + 20], tail[p + 21]]) as usize
                        == tail.len()
            })
            .context("invalid ZIP end directory")?;
        let e = &tail[position..];
        let u16at = |p| u16::from_le_bytes([e[p], e[p + 1]]);
        let u32at = |p| u32::from_le_bytes([e[p], e[p + 1], e[p + 2], e[p + 3]]);
        ensure!(
            u16at(4) == 0
                && u16at(6) == 0
                && u16at(8) == u16at(10)
                && u16at(10) != u16::MAX
                && u32at(12) != u32::MAX
                && u32at(16) != u32::MAX,
            "ZIP64 or multi-disk Office containers are unsupported"
        );
        ensure!(
            (u16at(10) as usize) <= context.config.max_entries
                && u32at(12) <= 8 * 1024 * 1024
                && u32at(16) as u64 + u32at(12) as u64 <= size,
            "Office archive directory exceeds configured bounds"
        );
        let zip = zip::ZipArchive::new(file).context("invalid Office ZIP container")?;
        ensure!(
            zip.len() <= context.config.max_entries,
            "too many Office archive entries"
        );
        let mut names = HashSet::new();
        for i in 0..zip.len() {
            context.check()?;
            let entry = zip.by_index_data(i)?;
            let name = entry.name()?.into_owned();
            ensure!(
                !name.is_empty()
                    && name.len() <= 1024
                    && !name.starts_with('/')
                    && !name.contains(['\\', ':', '\0'])
                    && !name.split('/').any(|p| p == ".." || p == "."),
                "unsafe Office archive member"
            );
            ensure!(names.insert(name), "duplicate Office archive member");
            ensure!(
                !entry.encrypted() && entry.unix_mode().is_none_or(|m| m & 0o170000 != 0o120000),
                "encrypted or symlink Office members are unsupported"
            );
        }
        Ok(Self {
            zip,
            names,
            read_bytes: 0,
            context,
        })
    }
    fn xml(&mut self, name: &str) -> Result<String> {
        self.context.check()?;
        let mut entry = self
            .zip
            .by_name(name)
            .context("required Office XML part is missing")?;
        ensure!(
            entry.size() <= self.context.config.max_xml_part_bytes as u64,
            "Office XML part exceeds decompression limit"
        );
        let available = self
            .context
            .config
            .max_total_xml_bytes
            .saturating_sub(self.read_bytes)
            .min(self.context.config.max_xml_part_bytes);
        ensure!(
            entry.size() <= available as u64,
            "Office XML total decompression limit exceeded"
        );
        let mut bytes = Vec::with_capacity((entry.size() as usize).min(65536));
        let mut buffer = [0u8; 8192];
        loop {
            self.context.check()?;
            let n = entry
                .read(&mut buffer)
                .context("Office XML decompression/CRC failed")?;
            if n == 0 {
                break;
            }
            ensure!(
                bytes.len().saturating_add(n) <= available,
                "Office XML actual decompressed bytes exceed limit"
            );
            bytes.extend_from_slice(&buffer[..n]);
        }
        ensure!(
            bytes.len() as u64 == entry.size(),
            "Office XML decompressed size mismatch"
        );
        self.read_bytes += bytes.len();
        String::from_utf8(bytes).context("Office XML must use supported UTF-8 encoding")
    }
}
#[derive(Debug)]
enum XmlEvent {
    Start(String, HashMap<String, String>),
    End(String),
    Text(String),
}
fn xml_walk(
    xml: &str,
    context: &ExtractionContext,
    mut action: impl FnMut(XmlEvent) -> Result<()>,
) -> Result<()> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().expand_empty_elements = true;
    reader.config_mut().check_end_names = true;
    let mut depth = 0usize;
    let mut roots = 0usize;
    loop {
        context.check()?;
        match reader.read_event().context("invalid Office XML")? {
            Event::Start(e) => {
                if depth == 0 {
                    roots += 1;
                }
                depth += 1;
                ensure!(
                    depth <= context.config.max_xml_depth,
                    "Office XML nesting limit exceeded"
                );
                let mut attrs = HashMap::new();
                for attr in e.attributes() {
                    let attr = attr.context("invalid Office XML attribute")?;
                    let value = attr
                        .normalized_value(quick_xml::XmlVersion::Implicit1_0)
                        .context("unsupported Office XML entity")?
                        .into_owned();
                    ensure!(value.len() <= 8192, "Office XML attribute exceeds limit");
                    attrs.insert(attr.key.as_ref().to_owned(), value);
                }
                action(XmlEvent::Start(e.local_name().as_ref().into(), attrs))?;
            }
            Event::End(e) => {
                ensure!(depth > 0, "invalid Office XML depth");
                depth -= 1;
                action(XmlEvent::End(e.local_name().as_ref().into()))?;
            }
            Event::Text(e) => {
                let text = e.xml10_content();
                ensure!(
                    depth > 0 || text.trim().is_empty(),
                    "Office XML has content outside its root"
                );
                action(XmlEvent::Text(text.into_owned()))?;
            }
            Event::CData(e) => {
                ensure!(depth > 0, "Office XML CDATA outside root");
                action(XmlEvent::Text(e.xml10_content().into_owned()))?;
            }
            Event::GeneralRef(e) => {
                ensure!(depth > 0, "Office XML entity outside root");
                let value = if let Some(ch) = e
                    .resolve_char_ref()
                    .context("invalid XML character reference")?
                {
                    ch.to_string()
                } else {
                    match e.as_ref() {
                        "amp" => "&",
                        "lt" => "<",
                        "gt" => ">",
                        "quot" => "\"",
                        "apos" => "'",
                        _ => bail!("external or custom XML entities are unsupported"),
                    }
                    .into()
                };
                action(XmlEvent::Text(value))?;
            }
            Event::DocType(_) => bail!("Office XML DTD/entity declarations are forbidden"),
            Event::Decl(e) => {
                if let Some(encoding) = e.encoding() {
                    ensure!(
                        encoding?.eq_ignore_ascii_case("UTF-8"),
                        "Office XML encoding is unsupported"
                    );
                }
            }
            Event::PI(_) => bail!("Office XML processing instructions are unsupported"),
            Event::Eof => break,
            Event::Comment(_) => {}
            Event::Empty(_) => unreachable!("empty elements expanded"),
        }
    }
    ensure!(
        depth == 0 && roots == 1,
        "Office XML must contain one complete root element"
    );
    Ok(())
}
fn text_part(xml: &str, root: &str, odt: bool, context: &ExtractionContext) -> Result<String> {
    let mut text = String::new();
    let mut first = true;
    let mut capture = 0usize;
    let mut stack = Vec::new();
    xml_walk(xml, context, |event| {
        match event {
            XmlEvent::Start(name, attrs) => {
                if first {
                    ensure!(name == root, "Office part has an unexpected XML root");
                    first = false;
                }
                let selected = if odt {
                    matches!(name.as_str(), "p" | "h")
                } else {
                    name == "t"
                };
                stack.push(selected);
                if selected {
                    capture += 1;
                }
                if matches!(name.as_str(), "tab" | "tab-stop") {
                    text.push('\t');
                }
                if matches!(name.as_str(), "br" | "line-break") {
                    text.push('\n');
                }
                if odt && name == "s" && capture > 0 {
                    let count = attribute_local(&attrs, "c")
                        .map(|s| s.parse::<usize>())
                        .transpose()?
                        .unwrap_or(1);
                    ensure!(count <= 4096, "ODF space repetition limit exceeded");
                    text.extend(std::iter::repeat_n(' ', count));
                }
            }
            XmlEvent::End(name) => {
                if stack.pop().unwrap_or(false) {
                    capture -= 1;
                }
                if matches!(name.as_str(), "p" | "h" | "tr") {
                    text.push('\n');
                }
                if name == "tc" {
                    text.push('\t');
                }
            }
            XmlEvent::Text(value) => {
                if capture > 0 {
                    text.push_str(&value)
                }
            }
        }
        ensure!(
            text.len() <= context.config.max_xml_part_bytes,
            "expanded Office text exceeds part limit"
        );
        Ok(())
    })?;
    Ok(text)
}
fn attribute_local<'a>(attrs: &'a HashMap<String, String>, local: &str) -> Option<&'a String> {
    attrs.get(local).or_else(|| {
        attrs
            .iter()
            .find(|(key, _)| key.rsplit(':').next() == Some(local))
            .map(|(_, value)| value)
    })
}
fn relationship_id(attrs: &HashMap<String, String>) -> Option<&String> {
    attrs
        .iter()
        .find(|(key, _)| key.ends_with(":id"))
        .map(|(_, value)| value)
}

fn relations(
    xml: &str,
    prefix: &str,
    context: &ExtractionContext,
) -> Result<HashMap<String, String>> {
    let mut map = HashMap::new();
    xml_walk(xml, context, |event| {
        if let XmlEvent::Start(name, attrs) = event
            && name == "Relationship"
            && attrs.get("TargetMode").is_none_or(|v| v != "External")
        {
            let id = attrs.get("Id").context("Office relationship has no ID")?;
            let target = attrs
                .get("Target")
                .context("Office relationship has no target")?;
            ensure!(
                !target.contains(['\\', ':', '\0'])
                    && !target.split('/').any(|p| p == ".." || p == "."),
                "unsupported Office relationship path"
            );
            let target = if target.starts_with('/') {
                target.trim_start_matches('/').into()
            } else {
                format!("{prefix}/{target}")
            };
            ensure!(
                map.insert(id.clone(), target).is_none(),
                "duplicate Office relationship ID"
            );
        }
        Ok(())
    })?;
    Ok(map)
}
fn office<R: Read + Seek>(file: R, kind: Kind, context: &ExtractionContext) -> Result<ExtractedDocument> {
    let mut package = Package::open(file, context)?;
    let mut output = Builder::new(
        match kind {
            Kind::Docx => "docx",
            Kind::Xlsx => "xlsx",
            Kind::Pptx => "pptx",
            Kind::Odt => "odt",
            _ => unreachable!(),
        },
        context,
    );
    match kind {
        Kind::Docx => {
            let mut parts = package
                .names
                .iter()
                .filter(|n| {
                    *n == "word/document.xml"
                        || *n == "word/footnotes.xml"
                        || *n == "word/endnotes.xml"
                        || (n.starts_with("word/header") || n.starts_with("word/footer"))
                            && n.ends_with(".xml")
                })
                .cloned()
                .collect::<Vec<_>>();
            parts.sort();
            ensure!(
                parts.iter().any(|s| s == "word/document.xml"),
                "Word document part is missing"
            );
            parts.sort_by_key(|s| if s == "word/document.xml" { 0 } else { 1 });
            for part in parts {
                let root = if part == "word/document.xml" {
                    "document"
                } else if part.starts_with("word/header") {
                    "hdr"
                } else if part.starts_with("word/footer") {
                    "ftr"
                } else if part == "word/footnotes.xml" {
                    "footnotes"
                } else {
                    "endnotes"
                };
                let xml = package.xml(&part)?;
                output.section(part, text_part(&xml, root, false, context)?.as_str());
            }
            output.output.warnings.push("Word sections are XML part sources, not rendered page numbers. Images, layout, embedded objects and tracked-change interpretation are not analyzed.".into());
        }
        Kind::Odt => {
            let xml = package.xml("content.xml")?;
            output.section(
                "content.xml",
                &text_part(&xml, "document-content", true, context)?,
            );
            output.output.warnings.push("OpenDocument text only; visual layout, images and embedded objects are not analyzed.".into());
        }
        Kind::Pptx => {
            let rels = relations(
                &package.xml("ppt/_rels/presentation.xml.rels")?,
                "ppt",
                context,
            )?;
            let mut slides = Vec::new();
            xml_walk(&package.xml("ppt/presentation.xml")?, context, |event| {
                if let XmlEvent::Start(name, attrs) = event
                    && name == "sldId"
                {
                    slides.push(
                        relationship_id(&attrs)
                            .context("slide relationship missing")?
                            .clone(),
                    );
                }
                Ok(())
            })?;
            ensure!(
                slides.len() <= context.config.max_entries,
                "too many presentation slides"
            );
            for (index, id) in slides.iter().enumerate() {
                let part = rels
                    .get(id)
                    .context("slide relationship is missing or external")?;
                ensure!(
                    part.starts_with("ppt/slides/") && part.ends_with(".xml"),
                    "unsupported slide part path"
                );
                let xml = package.xml(part)?;
                output.section(
                    format!("slide {} ({part})", index + 1),
                    &text_part(&xml, "sld", false, context)?,
                );
            }
            output.output.warnings.push(
                "Slide text only; charts, images, notes, layout and animations are not analyzed."
                    .into(),
            );
        }
        Kind::Xlsx => spreadsheet(&mut package, &mut output, context)?,
        _ => unreachable!(),
    }
    output.finish()
}
fn spreadsheet<R: Read + Seek>(
    package: &mut Package<'_, R>,
    output: &mut Builder,
    context: &ExtractionContext,
) -> Result<()> {
    let mut shared = Vec::new();
    if package.names.contains("xl/sharedStrings.xml") {
        let mut current = String::new();
        let mut inside = false;
        let mut text = false;
        xml_walk(&package.xml("xl/sharedStrings.xml")?, context, |event| {
            match event {
                XmlEvent::Start(name, _) => {
                    if name == "si" {
                        inside = true;
                        current.clear();
                    }
                    if name == "t" {
                        text = true;
                    }
                }
                XmlEvent::End(name) => {
                    if name == "t" {
                        text = false;
                    }
                    if name == "si" {
                        ensure!(shared.len() < 100_000, "too many shared strings");
                        shared.push(std::mem::take(&mut current));
                        inside = false;
                    }
                }
                XmlEvent::Text(value) => {
                    if inside && text {
                        current.push_str(&value)
                    }
                }
            }
            Ok(())
        })?;
    }
    let rels = relations(&package.xml("xl/_rels/workbook.xml.rels")?, "xl", context)?;
    let mut sheets = Vec::new();
    xml_walk(&package.xml("xl/workbook.xml")?, context, |event| {
        if let XmlEvent::Start(name, attrs) = event
            && name == "sheet"
        {
            sheets.push((
                attrs.get("name").context("worksheet name missing")?.clone(),
                relationship_id(&attrs)
                    .context("worksheet relationship missing")?
                    .clone(),
            ));
        }
        Ok(())
    })?;
    for (sheet, id) in sheets {
        let part = rels
            .get(&id)
            .context("worksheet relationship is missing or external")?;
        ensure!(
            part.starts_with("xl/worksheets/") && part.ends_with(".xml"),
            "unsupported worksheet part path"
        );
        let mut cell = String::new();
        let mut cell_type = String::new();
        let mut content = String::new();
        let mut value_tag = false;
        let mut formula = false;
        let mut rows = String::new();
        let mut cell_count = 0usize;
        xml_walk(&package.xml(part)?, context, |event| {
            match event {
                XmlEvent::Start(name, attrs) => {
                    if name == "c" {
                        cell = attrs
                            .get("r")
                            .context("worksheet cell reference missing")?
                            .clone();
                        ensure!(
                            cell.len() <= 16
                                && cell
                                    .bytes()
                                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()),
                            "invalid worksheet cell reference"
                        );
                        cell_type = attrs.get("t").cloned().unwrap_or_default();
                        content.clear();
                        formula = false;
                    }
                    if name == "f" {
                        formula = true;
                    }
                    if name == "v" || name == "t" {
                        value_tag = true;
                    }
                }
                XmlEvent::End(name) => {
                    if name == "v" || name == "t" {
                        value_tag = false;
                    }
                    if name == "c" {
                        cell_count += 1;
                        ensure!(cell_count <= 100_000, "worksheet cell limit exceeded");
                        let value = if cell_type == "s" {
                            shared
                                .get(
                                    content
                                        .trim()
                                        .parse::<usize>()
                                        .context("invalid shared-string index")?,
                                )
                                .context("shared-string index outside table")?
                                .clone()
                        } else if cell_type == "b" {
                            match content.as_str() {
                                "1" => "true".into(),
                                "0" => "false".into(),
                                _ => bail!("invalid boolean cell"),
                            }
                        } else {
                            content.clone()
                        };
                        if !value.is_empty() {
                            if rows.len() < context.budget() {
                                rows.push_str(&format!(
                                    "{cell}: {value}{}\n",
                                    if formula {
                                        " [cached formula value]"
                                    } else {
                                        ""
                                    }
                                ));
                            } else {
                                output.output.truncated = true;
                            }
                        } else if formula {
                            if rows.len() < context.budget() {
                                rows.push_str(&format!(
                                    "{cell}: [formula has no cached value; not evaluated]\n"
                                ));
                            } else {
                                output.output.truncated = true;
                            }
                        }
                    }
                }
                XmlEvent::Text(value) => {
                    if value_tag {
                        content.push_str(&value)
                    }
                }
            }
            Ok(())
        })?;
        output.section(format!("sheet {sheet} ({part})"), &rows);
    }
    output.output.warnings.push("Spreadsheet values retain sheet names and cell references. Formulas are not executed; only cached values are read. Dates/styles, charts, macros, external links and visual layout are not evaluated.".into());
    Ok(())
}
