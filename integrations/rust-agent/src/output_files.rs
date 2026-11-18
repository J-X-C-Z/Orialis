//! Durable, explicitly authorized outbound artifacts. Model-authored MEDIA paths
//! are data, not permission to read a host file. Only configured export roots or
//! a trusted host tool's per-turn registration can supply bytes.
use crate::attachments::{
    AttachmentMetadata, AttachmentTransport, MAX_ATTACHMENT_BYTES, MAX_ATTACHMENTS, safe_filename,
};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutputScope {
    pub conversation_id: String,
    pub input_id: String,
}
impl OutputScope {
    fn validate(&self) -> Result<()> {
        for id in [&self.conversation_id, &self.input_id] {
            ensure!(
                !id.trim().is_empty() && id.len() <= 4096 && !id.chars().any(char::is_control),
                "invalid artifact scope"
            );
        }
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct OutputConfig {
    pub database: PathBuf,
    pub spool: PathBuf,
    pub artifact_roots: Vec<PathBuf>,
    pub max_spool_bytes: u64,
    pub max_records: usize,
}
impl OutputConfig {
    pub fn new(database: PathBuf, spool: PathBuf) -> Self {
        Self {
            database,
            spool,
            artifact_roots: Vec::new(),
            max_spool_bytes: 512 * 1024 * 1024,
            max_records: 4096,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ArtifactHandle {
    pub artifact_id: String,
    pub name: String,
    pub mime_type: String,
    pub size: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum UploadOutcome {
    Uploaded {
        artifact: ArtifactHandle,
        attachment: AttachmentMetadata,
    },
    OutcomeUnknown {
        artifact: ArtifactHandle,
        message: String,
    },
    Failed {
        artifact: ArtifactHandle,
        message: String,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputEvent {
    pub id: i64,
    pub scope: OutputScope,
    pub artifact_id: String,
    pub payload: Value,
}
#[derive(Clone, Debug)]
pub struct FinalMedia {
    /// Markers are removed only after every selected file has a durable uploaded
    /// result. On any unknown/failure the caller must retain the original body.
    pub text: String,
    pub attachments: Vec<AttachmentMetadata>,
    pub artifacts: Vec<ArtifactHandle>,
}
#[derive(Clone)]
pub struct OutputFiles {
    inner: Arc<Inner>,
}
struct Inner {
    db: Mutex<Connection>,
    _journal_lock: File,
    _spool_lock: File,
    transport: AttachmentTransport,
    identity: String,
    journal_epoch: String,
    spool: PathBuf,
    roots: Vec<ExportRoot>,
    max_bytes: u64,
    max_records: usize,
    gate: tokio::sync::Semaphore,
    changed: tokio::sync::Notify,
}
struct ExportRoot {
    path: PathBuf,
    directory: File,
}
#[derive(Clone, Debug)]
struct Record {
    scope: OutputScope,
    handle: ArtifactHandle,
    source: String,
    operation: String,
    state: String,
    upload_key: String,
    metadata: Option<AttachmentMetadata>,
    error: Option<String>,
}

impl OutputFiles {
    /// One service instance per database. The database is identity-bound and
    /// refuses a changed origin/device/credential instead of crossing owners.
    pub async fn open(config: OutputConfig, transport: AttachmentTransport) -> Result<Self> {
        ensure!(
            config.max_spool_bytes >= MAX_ATTACHMENT_BYTES && config.max_records > 0,
            "invalid artifact storage limits"
        );
        ensure!(config.artifact_roots.len() <= 32, "too many artifact roots");
        let identity = transport.identity_fingerprint();
        let setup=tokio::task::spawn_blocking(move||->Result<_>{
            let spool=private_directory(&config.spool)?;
            let spool_lock=lock_journal(&spool.join(".service.lock"))?;
            let mut roots=Vec::new();
            for root in config.artifact_roots {
                ensure!(root.is_absolute()&&root.is_dir(),"artifact root must be an existing absolute directory");
                let root=fs::canonicalize(root)?;let directory=open_directory(&root)?;roots.push(ExportRoot{path:root,directory});
            }
            let mut db=crate::private_db::open_private(&config.database)?;
            let journal_lock=lock_journal(&config.database.with_extension("artifacts.lock"))?;
            db.busy_timeout(Duration::from_secs(5))?;
            db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS output_identity(id INTEGER PRIMARY KEY CHECK(id=1),fingerprint TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS output_journal_epoch(id INTEGER PRIMARY KEY CHECK(id=1),epoch TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS output_files(
                    id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,input_id TEXT NOT NULL,operation_id TEXT NOT NULL,
                    source TEXT NOT NULL,name TEXT NOT NULL,mime TEXT NOT NULL,size INTEGER NOT NULL,sha256 TEXT NOT NULL,
                    state TEXT NOT NULL,upload_key TEXT NOT NULL,metadata TEXT,error TEXT,created_at INTEGER NOT NULL,delivered_at INTEGER,
                    UNIQUE(conversation_id,input_id,operation_id));
                CREATE INDEX IF NOT EXISTS output_files_turn ON output_files(conversation_id,input_id);
                CREATE TABLE IF NOT EXISTS output_events(id INTEGER PRIMARY KEY AUTOINCREMENT,artifact_id TEXT NOT NULL REFERENCES output_files(id),payload TEXT NOT NULL,accepted INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS output_events_pending ON output_events(accepted,id);
                CREATE TABLE IF NOT EXISTS output_final_messages(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,input_id TEXT NOT NULL,artifact_ids TEXT NOT NULL,created_at INTEGER NOT NULL,acked_at INTEGER);
                CREATE TABLE IF NOT EXISTS output_final_files(final_id TEXT NOT NULL REFERENCES output_final_messages(id) ON DELETE CASCADE,artifact_id TEXT NOT NULL REFERENCES output_files(id) ON DELETE CASCADE,PRIMARY KEY(final_id,artifact_id));")?;
            let tx=db.transaction()?;
            let existing:Option<String>=tx.query_row("SELECT fingerprint FROM output_identity WHERE id=1",[],|r|r.get(0)).optional()?;
            if let Some(existing)=existing{ensure!(existing==identity,"artifact journal belongs to a different server/device/credential");}
            else{tx.execute("INSERT INTO output_identity(id,fingerprint) VALUES(1,?1)",[&identity])?;}
            tx.execute("INSERT OR IGNORE INTO output_journal_epoch(id,epoch) VALUES(1,?1)",[uuid::Uuid::new_v4().to_string()])?;
            let journal_epoch:String=tx.query_row("SELECT epoch FROM output_journal_epoch WHERE id=1",[],|r|r.get(0))?;
            // No implicit reupload after an interrupted remote operation. A
            // recovery failure event keeps the observable lifecycle truthful.
            let interrupted={let mut q=tx.prepare("SELECT id FROM output_files WHERE state='uploading'")?;q.query_map([],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?};
            for id in interrupted {
                let record=lookup(&tx,&id)?.context("interrupted artifact missing")?;
                let message="Upload was interrupted; remote outcome is unknown";
                tx.execute("UPDATE output_files SET state='outcome_unknown',error=?2 WHERE id=?1",params![id,message])?;
                event(&tx,&record,json!({"type":"artifact.failed","conversation_id":record.scope.conversation_id,"artifact_id":id,"code":"UPLOAD_OUTCOME_UNKNOWN","message":message,"metadata":{"outcomeUnknown":true,"input_id":record.scope.input_id}}))?;
            }
            tx.commit()?;
            Ok((db,identity,spool,roots,config.max_spool_bytes,config.max_records,journal_lock,journal_epoch,spool_lock))
        }).await??;
        Ok(Self {
            inner: Arc::new(Inner {
                db: Mutex::new(setup.0),
                _journal_lock: setup.6,
                _spool_lock: setup.8,
                transport,
                identity: setup.1,
                journal_epoch: setup.7,
                spool: setup.2,
                roots: setup.3,
                max_bytes: setup.4,
                max_records: setup.5,
                gate: tokio::sync::Semaphore::new(1),
                changed: tokio::sync::Notify::new(),
            }),
        })
    }
    async fn database<T, F>(&self, operation: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let mut db = inner
                .db
                .lock()
                .map_err(|_| anyhow::anyhow!("artifact journal unavailable"))?;
            operation(&mut db)
        })
        .await?
    }
    fn artifact_id(&self, scope: &OutputScope, operation: &str) -> Result<String> {
        scope.validate()?;
        ensure!(
            !operation.trim().is_empty() && operation.len() <= 4096,
            "invalid artifact operation ID"
        );
        Ok(format!(
            "artifact_{}",
            &digest(&serde_json::to_vec(&(
                &self.inner.identity,
                &self.inner.journal_epoch,
                scope,
                operation
            ))?)[..32]
        ))
    }
    /// Trusted host-tool API only. Calling this with a model-supplied path would
    /// bypass the intended authorization boundary. Registration does no upload.
    pub async fn register_tool_artifact(
        &self,
        scope: &OutputScope,
        operation_id: &str,
        path: &Path,
        name: Option<&str>,
        mime: &str,
    ) -> Result<ArtifactHandle> {
        self.register(scope, operation_id, path, name, mime, false)
            .await
    }
    /// Automatic MEDIA selection is limited to configured export roots. A tool's
    /// already-registered path can also be selected only in its original turn.
    pub async fn resolve_media(
        &self,
        scope: &OutputScope,
        reference: &str,
    ) -> Result<ArtifactHandle> {
        scope.validate()?;
        ensure!(
            !reference.is_empty() && reference.len() <= 8192,
            "invalid MEDIA reference"
        );
        if let Some(id) = reference.strip_prefix("artifact://") {
            return Ok(self.record(scope, id).await?.handle);
        }
        let path = normalized_absolute(Path::new(reference))?;
        let source = path.to_string_lossy().into_owned();
        let query_source = source.clone();
        let query_scope = scope.clone();
        if let Some(record) = self
            .database(move |db| find_source(db, &query_scope, &query_source))
            .await?
        {
            return Ok(record.handle);
        }
        ensure!(
            self.inner
                .roots
                .iter()
                .any(|root| path.starts_with(&root.path)),
            "MEDIA path is not registered in this turn or inside a configured artifact root"
        );
        let operation = format!("media:{}", digest(source.as_bytes()));
        self.register(scope, &operation, &path, None, &guess_mime(&path), true)
            .await
    }
    async fn register(
        &self,
        scope: &OutputScope,
        operation: &str,
        path: &Path,
        name: Option<&str>,
        mime: &str,
        configured_only: bool,
    ) -> Result<ArtifactHandle> {
        let id = self.artifact_id(scope, operation)?;
        let path = normalized_absolute(path)?;
        let source = path.to_string_lossy().into_owned();
        let name = safe_filename(
            name.or_else(|| path.file_name().and_then(|s| s.to_str()))
                .unwrap_or("attachment"),
        );
        let mime = normalize_mime(mime);
        // Reuse the same allowlist as the actual attachment transport.
        AttachmentMetadata {
            id: "validation".into(),
            name: name.clone(),
            mime_type: mime.clone(),
            size: Some(1),
            download_url: "http://validation.invalid/api/v1/attachments/validation/download".into(),
        }
        .validate()?;
        let _permit = self.inner.gate.acquire().await?;
        let query_scope = scope.clone();
        let query_operation = operation.to_owned();
        if let Some(record) = self.database(move |db| {
            let id:Option<String>=db.query_row("SELECT id FROM output_files WHERE conversation_id=?1 AND input_id=?2 AND operation_id=?3",params![query_scope.conversation_id,query_scope.input_id,query_operation],|r|r.get(0)).optional()?;
            id.map(|id|lookup(db,&id)).transpose().map(Option::flatten)
        }).await? {
            ensure!(
                record.scope == *scope
                    && record.source == source
                    && record.handle.name == name
                    && record.handle.mime_type == mime
                    && record.operation == operation,
                "artifact operation ID was reused for a different file"
            );
            return Ok(record.handle);
        }
        let inner = self.inner.clone();
        let scope = scope.clone();
        let operation = operation.to_owned();
        tokio::task::spawn_blocking(move||{
            let mut db=inner.db.lock().map_err(|_|anyhow::anyhow!("artifact journal unavailable"))?;
            let count:i64=db.query_row("SELECT COUNT(*) FROM output_files",[],|r|r.get(0))?;
            // Count crash leftovers too; never unlink an unknown potentially active partial.
            let used=spool_usage(&inner.spool,inner.max_records.saturating_add(128))?;
            ensure!((count as usize)<inner.max_records,"artifact journal is full; delivered records must be pruned explicitly");
            let source_file=if configured_only {open_from_roots(&inner.roots,&path)?}else{open_trusted_source(&path)?};
            let before=source_file.metadata()?;
            ensure!(before.is_file()&&(1..=MAX_ATTACHMENT_BYTES).contains(&before.len()),"artifact must be a regular file between 1 byte and 20 MiB");
            ensure!(used.saturating_add(before.len())<=inner.max_bytes,"artifact spool quota exceeded");
            let final_path=inner.spool.join(format!("{id}.bin"));
            let temporary=inner.spool.join(format!(".part-{}",uuid::Uuid::new_v4().simple()));
            let pending=PendingFile(temporary.clone());
            let mut target=private_create(&temporary)?;let mut source_file=source_file;
            let mut hasher=Sha256::new();let mut copied=0u64;let mut buffer=[0u8;65536];
            loop {let n=source_file.read(&mut buffer)?;if n==0{break;}copied+=n as u64;ensure!(copied<=before.len()&&copied<=MAX_ATTACHMENT_BYTES,"artifact source changed while snapshotting");hasher.update(&buffer[..n]);target.write_all(&buffer[..n])?;}
            ensure!(copied==before.len()&&same_file_version(&before,&source_file.metadata()?),"artifact source changed while snapshotting");
            target.flush()?;target.sync_all()?;drop(target);
            let sha=format!("{:x}",hasher.finalize());
            // Existing spool targets are never overwritten, including orphaned
            // snapshots after a crash before the journal transaction committed.
            if fs::symlink_metadata(&final_path).is_ok(){
                ensure!(hash_private_snapshot(&final_path,copied)?==sha,"orphan artifact snapshot conflicts with this operation");
            }else{fs::rename(&temporary,&final_path)?;File::open(&inner.spool)?.sync_all()?;}
            drop(pending);
            let handle=ArtifactHandle{artifact_id:id.clone(),name,mime_type:mime,size:copied,sha256:sha};
            let upload_key=format!("upload_{}",digest(&serde_json::to_vec(&(&inner.identity,&scope,&handle.artifact_id,&handle.sha256))?));
            let tx=db.transaction()?;
            tx.execute("INSERT INTO output_files(id,conversation_id,input_id,operation_id,source,name,mime,size,sha256,state,upload_key,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'prepared',?10,?11)",params![id,scope.conversation_id,scope.input_id,operation,source,handle.name,handle.mime_type,handle.size,handle.sha256,upload_key,now()])?;
            tx.commit()?;
            Ok(handle)
        }).await?
    }
    async fn record(&self, scope: &OutputScope, id: &str) -> Result<Record> {
        scope.validate()?;
        let id = id.to_owned();
        let scope = scope.clone();
        self.database(move |db| {
            let record = lookup(db, &id)?.context("artifact is not registered")?;
            ensure!(
                record.scope == scope,
                "artifact belongs to another conversation or turn"
            );
            Ok(record)
        })
        .await
    }
    pub async fn outcome(&self, scope: &OutputScope, id: &str) -> Result<Option<UploadOutcome>> {
        let record = self.record(scope, id).await?;
        outcome(&record)
    }
    /// Does not retry an interrupted/uncertain upload. Completed results are
    /// replayed from SQLite without reading source paths or making HTTP calls.
    pub async fn upload(&self, scope: &OutputScope, id: &str) -> Result<UploadOutcome> {
        self.perform_upload(scope, id, false).await
    }
    /// Explicit recovery only: reuse the same immutable snapshot and exact
    /// Idempotency-Key. Orialis returns the original committed metadata if present.
    pub async fn reconcile_upload(&self, scope: &OutputScope, id: &str) -> Result<UploadOutcome> {
        self.perform_upload(scope, id, true).await
    }
    async fn perform_upload(
        &self,
        scope: &OutputScope,
        id: &str,
        reconcile: bool,
    ) -> Result<UploadOutcome> {
        let _permit = self.inner.gate.acquire().await?;
        let record = self.record(scope, id).await?;
        if record.state == "uploaded" || record.state == "failed" {
            return outcome(&record)?.context("artifact state is missing its result");
        }
        if matches!(record.state.as_str(), "uploading" | "outcome_unknown") && !reconcile {
            return Ok(UploadOutcome::OutcomeUnknown {
                artifact: record.handle,
                message: record.error.unwrap_or_else(|| {
                    "Upload may already have completed. Explicit reconciliation is required.".into()
                }),
            });
        }
        ensure!(
            matches!(
                record.state.as_str(),
                "prepared" | "uploading" | "outcome_unknown"
            ),
            "invalid artifact state"
        );
        let path = self
            .inner
            .spool
            .join(format!("{}.bin", record.handle.artifact_id));
        let expected = record.handle.sha256.clone();
        let size = record.handle.size;
        let verify_path = path.clone();
        let verified = tokio::task::spawn_blocking(move || {
            hash_private_snapshot(&verify_path, size).is_ok_and(|sha| sha == expected)
        })
        .await?;
        if !verified {
            let failed = record.clone();
            // A lost snapshot cannot establish that a previous remote attempt
            // failed. Preserve uncertainty instead of converting it to a false
            // definitive failure during explicit reconciliation.
            let unknown = record.state != "prepared";
            let message = if unknown {
                "Artifact snapshot changed or is unavailable; previous remote upload outcome remains unknown"
            } else {
                "Artifact snapshot changed or is unavailable"
            };
            self.database(move |db| finish_failure(db, &failed, message, unknown))
                .await?;
            self.inner.changed.notify_one();
            return Ok(if unknown {
                UploadOutcome::OutcomeUnknown {
                    artifact: record.handle,
                    message: message.into(),
                }
            } else {
                UploadOutcome::Failed {
                    artifact: record.handle,
                    message: message.into(),
                }
            });
        }
        let started = record.clone();
        self.database(move|db|{
            let tx=db.transaction()?;
            tx.execute("UPDATE output_files SET state='uploading',error=NULL WHERE id=?1",[&started.handle.artifact_id])?;
            let count:i64=tx.query_row("SELECT COUNT(*) FROM output_events WHERE artifact_id=?1",[&started.handle.artifact_id],|r|r.get(0))?;
            ensure!(count <= 124, "artifact reconciliation/event limit reached; retain the result for manual recovery");
            if count==0 {
                event(&tx,&started,json!({"type":"artifact.started","conversation_id":started.scope.conversation_id,"artifact":{"id":started.handle.artifact_id,"kind":"document","name":started.handle.name,"mime_type":started.handle.mime_type,"size":started.handle.size,"metadata":{"input_id":started.scope.input_id,"phase":"upload"}}}))?;
                event(&tx,&started,json!({"type":"artifact.progress","conversation_id":started.scope.conversation_id,"artifact_id":started.handle.artifact_id,"progress":{"phase":"snapshot_ready","bytes":started.handle.size,"total_bytes":started.handle.size}}))?;
            }
            event(&tx,&started,json!({"type":"artifact.progress","conversation_id":started.scope.conversation_id,"artifact_id":started.handle.artifact_id,"progress":{"phase":"uploading"}}))?;
            tx.commit()?;Ok(())
        }).await?;
        self.inner.changed.notify_one();
        let uploaded = self
            .inner
            .transport
            .upload_verified_file(
                &record.scope.conversation_id,
                &path,
                Some(&record.handle.name),
                &record.handle.mime_type,
                &record.upload_key,
                &record.handle.sha256,
            )
            .await;
        match uploaded {
            Ok(metadata) => {
                let committed = record.clone();
                let result = metadata.clone();
                let saved=self.database(move|db|{
                    let tx=db.transaction()?;
                    tx.execute("UPDATE output_files SET state='uploaded',metadata=?2,error=NULL WHERE id=?1",params![committed.handle.artifact_id,serde_json::to_string(&result)?])?;
                    event(&tx,&committed,json!({"type":"artifact.completed","conversation_id":committed.scope.conversation_id,"artifact":{"id":committed.handle.artifact_id,"kind":"document","name":committed.handle.name,"mime_type":committed.handle.mime_type,"size":committed.handle.size,"uri":result.download_url,"metadata":{"attachment_id":result.id,"input_id":committed.scope.input_id,"sha256":committed.handle.sha256}}}))?;
                    tx.commit()?;Ok(())
                }).await;
                self.inner.changed.notify_one();
                if saved.is_err() {
                    return Ok(UploadOutcome::OutcomeUnknown{artifact:record.handle,message:"Server accepted the upload, but its result could not be saved. Reconcile with the same operation ID.".into()});
                }
                Ok(UploadOutcome::Uploaded {
                    artifact: record.handle,
                    attachment: metadata,
                })
            }
            Err(_) => {
                let unknown = record.clone();
                let message = "Upload response was not confirmed. Remote outcome is unknown; explicit same-key reconciliation is required.";
                // Even HTTP/error-response parsing failures may follow a commit.
                self.database(move |db| finish_failure(db, &unknown, message, true))
                    .await
                    .context("upload outcome is unknown and could not be recorded")?;
                self.inner.changed.notify_one();
                Ok(UploadOutcome::OutcomeUnknown {
                    artifact: record.handle,
                    message: message.into(),
                })
            }
        }
    }
    /// Wake the single lifecycle outbox writer. Drain pending_events_all before
    /// waiting; this notification is only a wakeup, never the authoritative data.
    pub async fn notified(&self) {
        self.inner.changed.notified().await;
    }
    pub async fn pending_events(&self, scope: &OutputScope) -> Result<Vec<OutputEvent>> {
        scope.validate()?;
        let scope = scope.clone();
        self.database(move |db| pending_events(db, Some(&scope)))
            .await
    }
    /// Device-wide batches allow artifact.started/progress to reach the durable
    /// Gateway outbox while the HTTP operation is still running.
    pub async fn pending_events_all(&self) -> Result<Vec<OutputEvent>> {
        self.database(move |db| pending_events(db, None)).await
    }
    /// Acknowledge only after the parent's durable sequenced event outbox has
    /// accepted this exact event. Socket send acceptance alone is not delivery.
    pub async fn acknowledge_event(&self, scope: &OutputScope, event_id: i64) -> Result<()> {
        let scope = scope.clone();
        self.database(move|db|{let changed=db.execute("UPDATE output_events SET accepted=1 WHERE id=?1 AND artifact_id IN (SELECT id FROM output_files WHERE conversation_id=?2 AND input_id=?3)",params![event_id,scope.conversation_id,scope.input_id])?;ensure!(changed==1,"unknown or out-of-scope artifact event");Ok(())}).await
    }
    /// Persist the exact uploaded artifacts selected for an already-prepared
    /// final reply. Call before admitting that reply to its durable outbox. This
    /// is only a correlation binding; it does not claim delivery or consume ACKs.
    pub async fn bind_final(
        &self,
        message_id: &str,
        scope: &OutputScope,
        artifact_ids: &[String],
    ) -> Result<()> {
        scope.validate()?;
        ensure!(
            !message_id.trim().is_empty()
                && message_id.len() <= 4096
                && !message_id.chars().any(char::is_control),
            "invalid final reply ID"
        );
        ensure!(
            artifact_ids.len() <= MAX_ATTACHMENTS,
            "too many final artifacts"
        );
        let mut ids = artifact_ids.to_vec();
        ids.sort();
        ids.dedup();
        ensure!(
            ids.len() == artifact_ids.len(),
            "duplicate final artifact ID"
        );
        let message_id = message_id.to_owned();
        let scope = scope.clone();
        let limit = self.inner.max_records;
        self.database(move|db|{
            let tx=db.transaction()?;
            let stored:Option<(String,String,String)>=tx.query_row("SELECT conversation_id,input_id,artifact_ids FROM output_final_messages WHERE id=?1",[&message_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
            let serialized=serde_json::to_string(&ids)?;
            if let Some((conversation,input,artifacts))=stored {
                ensure!(conversation==scope.conversation_id&&input==scope.input_id&&artifacts==serialized,"final reply ID was reused for different scope or artifacts");
                return Ok(());
            }
            let count:i64=tx.query_row("SELECT COUNT(*) FROM output_final_messages",[],|r|r.get(0))?;
            ensure!((count as usize)<limit,"final artifact bindings are full; prune delivered records explicitly");
            for id in &ids {
                let record=lookup(&tx,id)?.context("final artifact is not registered")?;
                ensure!(record.scope==scope&&record.state=="uploaded","final artifact must be uploaded and belong to the exact turn");
            }
            tx.execute("INSERT INTO output_final_messages(id,conversation_id,input_id,artifact_ids,created_at) VALUES(?1,?2,?3,?4,?5)",params![message_id,scope.conversation_id,scope.input_id,serialized,now()])?;
            for id in ids{tx.execute("INSERT INTO output_final_files(final_id,artifact_id) VALUES(?1,?2)",params![message_id,id])?;}
            tx.commit()?;Ok(())
        }).await
    }
    /// Startup reconciliation pages. Advance the cursor to the last returned
    /// ID even if some replies are not delivered. The host must check its own
    /// durable successful receipt before calling ack_final for any returned ID.
    pub async fn pending_final_bindings(
        &self,
        after_message_id: Option<&str>,
    ) -> Result<Vec<String>> {
        let after = after_message_id.map(str::to_owned);
        self.database(move|db|{
            let mut q=db.prepare_cached("SELECT id FROM output_final_messages WHERE acked_at IS NULL AND (?1 IS NULL OR id>?1) ORDER BY id LIMIT 256")?;
            Ok(q.query_map([after],|r|r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?)
        }).await
    }
    /// Consume an authoritative successful final-reply ACK. The durable mapping
    /// works after restart without retaining a scope in memory. Unrelated ACKs
    /// return false; duplicate matching ACKs are harmless.
    pub async fn ack_final(&self, message_id: &str) -> Result<bool> {
        let message_id = message_id.to_owned();
        self.database(move|db|{
            let tx=db.transaction()?;
            let changed=tx.execute("UPDATE output_final_messages SET acked_at=COALESCE(acked_at,?2) WHERE id=?1",params![message_id,now()])?;
            if changed==0{return Ok(false);}
            tx.execute("UPDATE output_files SET delivered_at=COALESCE(delivered_at,?2) WHERE state='uploaded' AND id IN (SELECT artifact_id FROM output_final_files WHERE final_id=?1)",params![message_id,now()])?;
            tx.commit()?;Ok(true)
        }).await
    }
    /// Call only after an authoritative final-reply delivery ACK. Uploaded state
    /// is retained even when local snapshot cleanup later becomes eligible.
    pub async fn mark_delivered(&self, scope: &OutputScope, id: &str) -> Result<()> {
        let record = self.record(scope, id).await?;
        ensure!(
            record.state == "uploaded",
            "only uploaded artifacts can be marked delivered"
        );
        let id = id.to_owned();
        self.database(move |db| {
            db.execute(
                "UPDATE output_files SET delivered_at=COALESCE(delivered_at,?2) WHERE id=?1",
                params![id, now()],
            )?;
            Ok(())
        })
        .await
    }
    /// Explicit bounded retention maintenance. Never prunes pending/unknown data
    /// or events not yet admitted to the parent's durable event outbox.
    pub async fn prune_delivered_before(&self, before_unix_seconds: i64) -> Result<usize> {
        let _permit = self.inner.gate.acquire().await?;
        let inner = self.inner.clone();
        self.database(move|db|{
            let tx=db.transaction()?;let ids={let mut q=tx.prepare("SELECT id FROM output_files f WHERE state='uploaded' AND delivered_at IS NOT NULL AND delivered_at<?1 AND NOT EXISTS(SELECT 1 FROM output_events e WHERE e.artifact_id=f.id AND accepted=0)")?;q.query_map([before_unix_seconds],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?};
            for id in &ids {let path=inner.spool.join(format!("{id}.bin"));if path.exists(){validate_private_file(&path)?;fs::remove_file(path)?;}tx.execute("DELETE FROM output_events WHERE artifact_id=?1",[id])?;tx.execute("DELETE FROM output_files WHERE id=?1",[id])?;}
            tx.execute("DELETE FROM output_final_messages WHERE acked_at IS NOT NULL AND acked_at<?1 AND NOT EXISTS(SELECT 1 FROM output_final_files f WHERE f.final_id=output_final_messages.id)",[before_unix_seconds])?;
            tx.commit()?;Ok(ids.len())
        }).await
    }
    /// Run only on the final assistant body, never streaming deltas/initial or
    /// progress messages. Any failure retains the caller's original text.
    pub async fn finalize_media(&self, scope: &OutputScope, body: &str) -> Result<FinalMedia> {
        ensure!(body.len() <= 256 * 1024, "final text too large");
        let markers = parse_media_markers(body);
        if markers.is_empty() {
            return Ok(FinalMedia {
                text: body.to_owned(),
                attachments: Vec::new(),
                artifacts: Vec::new(),
            });
        }
        ensure!(
            markers.len() <= MAX_ATTACHMENTS,
            "too many outbound attachments"
        );
        let mut attachments = Vec::new();
        let mut artifacts = Vec::new();
        let mut spans = Vec::new();
        // Resolve every permission and snapshot before performing any remote
        // upload, so a later unauthorized marker cannot cause a partial send.
        let mut selected = Vec::with_capacity(markers.len());
        for marker in markers {
            let handle = self.resolve_media(scope, &marker.reference).await?;
            selected.push((marker, handle));
        }
        for (marker, handle) in selected {
            match self.upload(scope, &handle.artifact_id).await? {
                UploadOutcome::Uploaded {
                    artifact,
                    attachment,
                } => {
                    if !artifacts
                        .iter()
                        .any(|a: &ArtifactHandle| a.artifact_id == artifact.artifact_id)
                    {
                        artifacts.push(artifact);
                        attachments.push(attachment);
                    }
                    spans.push((marker.start, marker.end));
                }
                UploadOutcome::OutcomeUnknown { .. } => bail!(
                    "outbound artifact outcome is unknown; retain the final body and reconcile the registered artifact"
                ),
                UploadOutcome::Failed { .. } => bail!(
                    "outbound artifact failed; retain the final body and report the artifact failure"
                ),
            }
        }
        let mut text = body.to_owned();
        for (start, end) in spans.into_iter().rev() {
            text.replace_range(start..end, "");
        }
        Ok(FinalMedia {
            text: text.trim().to_owned(),
            attachments,
            artifacts,
        })
    }
}

fn pending_events(db: &Connection, scope: Option<&OutputScope>) -> Result<Vec<OutputEvent>> {
    let mut q=db.prepare_cached("SELECT e.id,e.artifact_id,e.payload,f.conversation_id,f.input_id FROM output_events e JOIN output_files f ON f.id=e.artifact_id WHERE e.accepted=0 AND (?1 IS NULL OR (f.conversation_id=?1 AND f.input_id=?2)) ORDER BY e.id LIMIT 256")?;
    let rows = q
        .query_map(
            params![
                scope.map(|s| &s.conversation_id),
                scope.map(|s| &s.input_id)
            ],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            },
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter()
        .map(|(id, artifact_id, payload, conversation_id, input_id)| {
            Ok(OutputEvent {
                id,
                artifact_id,
                scope: OutputScope {
                    conversation_id,
                    input_id,
                },
                payload: serde_json::from_str(&payload)?,
            })
        })
        .collect()
}

fn outcome(record: &Record) -> Result<Option<UploadOutcome>> {
    Ok(match record.state.as_str() {
        "uploaded" => Some(UploadOutcome::Uploaded {
            artifact: record.handle.clone(),
            attachment: record
                .metadata
                .clone()
                .context("uploaded artifact metadata missing")?,
        }),
        "uploading" | "outcome_unknown" => Some(UploadOutcome::OutcomeUnknown {
            artifact: record.handle.clone(),
            message: record.error.clone().unwrap_or_else(|| {
                "Upload outcome is unknown; explicit reconciliation is required".into()
            }),
        }),
        "failed" => Some(UploadOutcome::Failed {
            artifact: record.handle.clone(),
            message: record
                .error
                .clone()
                .unwrap_or_else(|| "Artifact failed".into()),
        }),
        "prepared" => None,
        _ => bail!("invalid artifact journal state"),
    })
}
type RawRecord = (
    String,
    String,
    String,
    String,
    String,
    String,
    i64,
    String,
    String,
    String,
    Option<String>,
    Option<String>,
);
fn lookup(db: &Connection, id: &str) -> Result<Option<Record>> {
    let raw:Option<RawRecord>=db.query_row("SELECT conversation_id,input_id,operation_id,source,name,mime,size,sha256,state,upload_key,metadata,error FROM output_files WHERE id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?,r.get(9)?,r.get(10)?,r.get(11)?))).optional()?;
    raw.map(|r| {
        Ok(Record {
            scope: OutputScope {
                conversation_id: r.0,
                input_id: r.1,
            },
            operation: r.2,
            source: r.3,
            handle: ArtifactHandle {
                artifact_id: id.into(),
                name: r.4,
                mime_type: r.5,
                size: r.6 as u64,
                sha256: r.7,
            },
            state: r.8,
            upload_key: r.9,
            metadata: r.10.map(|s| serde_json::from_str(&s)).transpose()?,
            error: r.11,
        })
    })
    .transpose()
}
fn find_source(db: &Connection, scope: &OutputScope, source: &str) -> Result<Option<Record>> {
    let id:Option<String>=db.query_row("SELECT id FROM output_files WHERE conversation_id=?1 AND input_id=?2 AND source=?3 ORDER BY rowid DESC LIMIT 1",params![scope.conversation_id,scope.input_id,source],|r|r.get(0)).optional()?;
    id.map(|id| lookup(db, &id))
        .transpose()
        .map(Option::flatten)
}
fn event(tx: &Transaction<'_>, record: &Record, payload: Value) -> Result<()> {
    let count: i64 = tx.query_row(
        "SELECT COUNT(*) FROM output_events WHERE artifact_id=?1",
        [&record.handle.artifact_id],
        |r| r.get(0),
    )?;
    ensure!(count < 128, "artifact event retention limit reached");
    tx.execute(
        "INSERT INTO output_events(artifact_id,payload) VALUES(?1,?2)",
        params![record.handle.artifact_id, serde_json::to_string(&payload)?],
    )?;
    Ok(())
}
fn finish_failure(
    db: &mut Connection,
    record: &Record,
    message: &str,
    unknown: bool,
) -> Result<()> {
    let tx = db.transaction()?;
    let state = if unknown { "outcome_unknown" } else { "failed" };
    tx.execute(
        "UPDATE output_files SET state=?2,error=?3 WHERE id=?1",
        params![record.handle.artifact_id, state, message],
    )?;
    event(
        &tx,
        record,
        json!({"type":"artifact.failed","conversation_id":record.scope.conversation_id,"artifact_id":record.handle.artifact_id,"code":if unknown{"UPLOAD_OUTCOME_UNKNOWN"}else{"ARTIFACT_UNAVAILABLE"},"message":message,"metadata":{"outcomeUnknown":unknown,"input_id":record.scope.input_id}}),
    )?;
    tx.commit()?;
    Ok(())
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn normalize_mime(mime: &str) -> String {
    mime.split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase()
}
fn guess_mime(path: &Path) -> String {
    match path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "json" => "application/json",
        "xml" => "application/xml",
        "zip" => "application/zip",
        "html" | "htm" => "text/html",
        "csv" => "text/csv",
        "md" | "txt" | "yaml" | "yml" | "toml" | "py" | "rs" | "js" | "ts" | "log" => "text/plain",
        "mp3" | "wav" | "ogg" | "mp4" | "mov" | "webm" => "unsupported/media",
        _ => "application/octet-stream",
    }
    .into()
}
fn normalized_absolute(path: &Path) -> Result<PathBuf> {
    ensure!(
        path.is_absolute()
            && !path.components().any(|p| matches!(p, Component::ParentDir))
            && !path.as_os_str().is_empty(),
        "artifact paths must be absolute without parent traversal"
    );
    let value = path.to_str().context("artifact path must be UTF-8")?;
    ensure!(
        value.len() <= 8192 && !value.contains(['\0', '\\']),
        "invalid artifact path"
    );
    Ok(path.components().collect())
}
struct PendingFile(PathBuf);
impl Drop for PendingFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaMarker {
    pub start: usize,
    pub end: usize,
    pub reference: String,
}
/// Conservative final-message grammar. Code blocks, inline-code examples and
/// blockquotes are never deliverable. Quoting supports paths containing spaces.
pub fn parse_media_markers(body: &str) -> Vec<MediaMarker> {
    let mut result = Vec::new();
    let mut offset = 0usize;
    let mut fence: Option<(char, usize)> = None;
    for line in body.split_inclusive('\n') {
        let trimmed = line.trim_start();
        let fence_char = trimmed.chars().next().filter(|c| matches!(c, '`' | '~'));
        let fence_run = fence_char
            .map(|c| trimmed.chars().take_while(|x| *x == c).count())
            .unwrap_or(0);
        if fence_run >= 3 {
            let token = (fence_char.unwrap(), fence_run);
            if let Some((kind, len)) = fence {
                if token.0 == kind && token.1 >= len && trimmed[token.1..].trim().is_empty() {
                    fence = None;
                }
            } else {
                fence = Some(token);
            }
            offset += line.len();
            continue;
        }
        if fence.is_some()
            || trimmed.starts_with('>')
            || line.starts_with("    ")
            || line.starts_with('\t')
        {
            offset += line.len();
            continue;
        }
        let mut i = 0usize;
        let mut inline: Option<usize> = None;
        while i < line.len() {
            let ch = line[i..].chars().next().unwrap();
            if ch == '`' {
                let count = line[i..].bytes().take_while(|b| *b == b'`').count();
                if inline == Some(count) {
                    inline = None;
                } else if inline.is_none() {
                    inline = Some(count);
                }
                i += count;
                continue;
            }
            if inline.is_none()
                && !line[..i]
                    .chars()
                    .next_back()
                    .is_some_and(|c| c.is_alphanumeric() || c == '\\')
                && line[i..]
                    .get(..6)
                    .is_some_and(|s| s.eq_ignore_ascii_case("MEDIA:"))
            {
                let mut start = i;
                let mut p = i + 6;
                while p < line.len()
                    && line[p..]
                        .chars()
                        .next()
                        .is_some_and(|c| c == ' ' || c == '\t')
                {
                    p += 1;
                }
                let mut end = p;
                let mut span_end = p;
                if let Some(quote) = line[p..]
                    .chars()
                    .next()
                    .filter(|c| matches!(c, '"' | '\'' | '`'))
                {
                    p += quote.len_utf8();
                    if let Some(relative) = line[p..].find(quote) {
                        end = p + relative;
                        span_end = end + quote.len_utf8();
                    }
                } else {
                    let rest = &line[p..];
                    for (pos, c) in rest.char_indices() {
                        if pos > 0
                            && (rest[pos..].starts_with("MEDIA:")
                                || c.is_whitespace()
                                || (c == '_'
                                    && line[..start].ends_with('_')
                                    && rest[pos..].chars().all(|x| x == '_' || x.is_whitespace()))
                                || "\"'`*）〉》：，。；！？、【】".contains(c))
                        {
                            break;
                        }
                        end = p + pos + c.len_utf8();
                    }
                    while end > p
                        && line[..end]
                            .chars()
                            .next_back()
                            .is_some_and(|c| ".,;:)]}".contains(c))
                    {
                        end -= line[..end].chars().next_back().unwrap().len_utf8();
                    }
                    span_end = end;
                }
                if end > p {
                    let reference = &line[p..end];
                    if reference.starts_with('/') || reference.starts_with("artifact://") {
                        // Include balanced Markdown emphasis around the whole
                        // directive, never leave an empty **/** wrapper behind.
                        for wrapper in ["***", "**", "*", "___", "__", "_"] {
                            if line[..start].ends_with(wrapper)
                                && line[span_end..].starts_with(wrapper)
                            {
                                start -= wrapper.len();
                                span_end += wrapper.len();
                                break;
                            }
                        }
                        result.push(MediaMarker {
                            start: offset + start,
                            end: offset + span_end,
                            reference: reference.to_owned(),
                        });
                        i = span_end;
                        continue;
                    }
                }
            }
            i += ch.len_utf8();
        }
        offset += line.len();
    }
    result
}

#[cfg(unix)]
fn lock_journal(path: &Path) -> Result<File> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    validate_private_file(path)?;
    ensure!(
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "artifact journal is already in use by another service"
    );
    Ok(file)
}
#[cfg(not(unix))]
fn lock_journal(_: &Path) -> Result<File> {
    bail!("artifact journal locking requires Unix")
}

#[cfg(unix)]
fn open_directory(path: &Path) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    Ok(OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?)
}
#[cfg(not(unix))]
fn open_directory(_: &Path) -> Result<File> {
    bail!("outbound artifacts require Unix descriptor protection")
}
#[cfg(unix)]
fn open_relative(root: &File, parts: &[&str]) -> Result<File> {
    use std::{
        ffi::CString,
        os::fd::{AsRawFd, FromRawFd},
    };
    let mut file = root.try_clone()?;
    for (index, part) in parts.iter().enumerate() {
        ensure!(
            !part.is_empty() && *part != ".." && !part.contains(['\0', ':']),
            "invalid artifact-relative path"
        );
        let name = CString::new(*part)?;
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if index + 1 < parts.len() {
                libc::O_DIRECTORY
            } else {
                0
            };
        let fd = unsafe { libc::openat(file.as_raw_fd(), name.as_ptr(), flags) };
        ensure!(
            fd >= 0,
            "artifact path is unavailable or contains a symbolic link"
        );
        file = unsafe { File::from_raw_fd(fd) };
    }
    ensure!(
        file.metadata()?.is_file(),
        "artifact must be a regular file"
    );
    Ok(file)
}
#[cfg(not(unix))]
fn open_relative(_: &File, _: &[&str]) -> Result<File> {
    bail!("outbound artifacts require Unix descriptor protection")
}
fn open_from_roots(roots: &[ExportRoot], path: &Path) -> Result<File> {
    for root in roots {
        if let Ok(relative) = path.strip_prefix(&root.path) {
            let parts = relative
                .iter()
                .map(|p| p.to_str().context("artifact path must be UTF-8"))
                .collect::<Result<Vec<_>>>()?;
            ensure!(!parts.is_empty(), "artifact path must select a file");
            ensure!(
                !parts.iter().any(|p| matches!(
                    *p,
                    ".ssh" | ".aws" | ".git" | ".hermes" | ".env" | "id_rsa" | "id_ed25519"
                ) || p.starts_with(".env.")),
                "automatic MEDIA export of credential/configuration paths is not allowed"
            );
            let file = open_relative(&root.directory, &parts)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                ensure!(
                    file.metadata()?.nlink() == 1,
                    "automatic MEDIA export of hard-linked files is not allowed"
                );
            }
            return Ok(file);
        }
    }
    bail!("artifact path is outside configured roots")
}
fn open_trusted_source(path: &Path) -> Result<File> {
    let root = open_directory(Path::new("/"))?;
    let parts = path
        .iter()
        .filter(|p| *p != std::ffi::OsStr::new("/"))
        .map(|p| p.to_str().context("artifact path must be UTF-8"))
        .collect::<Result<Vec<_>>>()?;
    open_relative(&root, &parts)
}
#[cfg(unix)]
fn private_directory(path: &Path) -> Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let path = if path.is_absolute() {
        path.into()
    } else {
        std::env::current_dir()?.join(path)
    };
    ensure!(
        !path.components().any(|c| matches!(c, Component::ParentDir)),
        "artifact spool cannot contain parent traversal"
    );
    let uid = unsafe { libc::geteuid() };
    let mut current = PathBuf::new();
    for part in path.components() {
        current.push(part);
        if !current.exists() {
            fs::DirBuilder::new().mode(0o700).create(&current)?;
        }
        let m = fs::symlink_metadata(&current)?;
        ensure!(
            m.is_dir() && !m.file_type().is_symlink() && (m.uid() == uid || m.uid() == 0),
            "untrusted artifact spool ancestor"
        );
        let sticky = current != path && m.uid() == 0 && m.mode() & 0o1000 != 0;
        ensure!(
            m.mode() & 0o022 == 0 || sticky,
            "artifact spool ancestor is writable by others"
        );
    }
    let m = fs::metadata(&path)?;
    ensure!(
        m.uid() == uid && m.mode() & 0o777 == 0o700,
        "artifact spool must be private mode 0700"
    );
    Ok(path)
}
#[cfg(not(unix))]
fn private_directory(_: &Path) -> Result<PathBuf> {
    bail!("private artifact spool requires Unix")
}
#[cfg(unix)]
fn private_create(path: &Path) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    Ok(OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?)
}
#[cfg(not(unix))]
fn private_create(_: &Path) -> Result<File> {
    bail!("private artifact spool requires Unix")
}
#[cfg(unix)]
fn validate_private_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let m = fs::symlink_metadata(path)?;
    ensure!(
        m.is_file()
            && !m.file_type().is_symlink()
            && m.uid() == unsafe { libc::geteuid() }
            && m.mode() & 0o777 == 0o600
            && m.nlink() == 1,
        "artifact snapshot is not a private single-linked file"
    );
    Ok(())
}
#[cfg(not(unix))]
fn validate_private_file(_: &Path) -> Result<()> {
    bail!("private artifact spool requires Unix")
}
fn spool_usage(path: &Path, max_entries: usize) -> Result<u64> {
    private_directory(path)?;
    let mut bytes = 0u64;
    for (count, entry) in fs::read_dir(path)?.enumerate() {
        ensure!(
            count < max_entries,
            "artifact spool contains too many files; explicit maintenance required"
        );
        let entry = entry?;
        validate_private_file(&entry.path())?;
        bytes = bytes.saturating_add(entry.metadata()?.len());
    }
    Ok(bytes)
}
fn hash_private_snapshot(path: &Path, size: u64) -> Result<String> {
    validate_private_file(path)?;
    let mut file = open_trusted_source(path)?;
    ensure!(
        file.metadata()?.len() == size,
        "artifact snapshot size changed"
    );
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        ensure!(
            bytes <= size && bytes <= MAX_ATTACHMENT_BYTES,
            "artifact snapshot changed"
        );
        hash.update(&buffer[..n]);
    }
    ensure!(bytes == size, "artifact snapshot truncated");
    Ok(format!("{:x}", hash.finalize()))
}
#[cfg(unix)]
fn same_file_version(before: &fs::Metadata, after: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}
#[cfg(not(unix))]
fn same_file_version(before: &fs::Metadata, after: &fs::Metadata) -> bool {
    before.len() == after.len() && before.modified().ok() == after.modified().ok()
}
