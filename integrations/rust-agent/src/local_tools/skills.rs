//! Managed skill storage and source-derived atomic operation contracts.
use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::collections::BTreeSet;
#[path = "skills_catalog.rs"]
mod catalog;
#[path = "skills_frontmatter.rs"]
mod frontmatter;
const INLINE_BINARY_BYTES: usize = 8 * 1024;

impl LocalTools {
    pub(super) async fn skills_list(&self, args: Value) -> Result<Value> {
        known(&args, &["category"])?;
        let category = args["category"].as_str().map(str::to_owned);
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            Ok(catalog::Catalog::load(&inner)?.list(category.as_deref()))
        })
        .await?
    }
    pub(super) async fn skill_view(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["name", "file_path"])?;
        let name = catalog::lookup_name(string(&args, "name")?)?;
        let file = skill_file_path(args["file_path"].as_str().unwrap_or("SKILL.md"))?;
        let owner = self.read_scope(context)?;
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let catalog = catalog::Catalog::load(&inner)?;
            let doc = catalog.resolve(&name)?;
            let managed = doc.source == "managed_store";
            let bytes = if file == "SKILL.md" {
                doc.body.as_bytes().to_vec()
            } else if managed {
                inner.db.lock().unwrap().query_row("SELECT CAST(body AS BLOB) FROM local_skills WHERE name=?1 AND path=?2", params![doc.key,file], |r| r.get::<_,Vec<u8>>(0)).optional()?.context("managed file does not exist; stale exported files are not a fallback")?
            } else {
                let base = inner.cfg.skills_root.as_ref().context("no configured skills root")?;
                let path = rel(&format!("{base}/{}/{file}", doc.key))?;
                let (bytes, _) = snapshot(&inner.root, &path, inner.cfg.file_bytes)?;
                bytes
            };
            ensure!(bytes.len() <= inner.cfg.file_bytes, "skill file exceeds configured byte limit");
            let body = std::str::from_utf8(&bytes).ok().filter(|body| !body.contains('\0'));
            ensure!(file != "SKILL.md" || body.is_some(), "SKILL.md must be UTF-8 text without NUL");
            let complete = body.is_some() || bytes.len() <= INLINE_BINARY_BYTES;
            let linked = catalog::linked_files(&inner, doc)?;
            if managed && complete {
                inner.reads.lock().unwrap().insert((owner,format!("skill:{}:{file}", doc.key)),Snapshot{hash:hash(&bytes),inode:0,device:0});
            }
            let mut result = json!({"success":true,"name":doc.declared,"requested_name":name,"relative_path":doc.key,"management_name":if managed {Some(&doc.key)}else{None},"file_path":file,"path":format!("{}/{file}",doc.key),"content":body,"linked_files":linked,"source":doc.source,"read_only":!managed,"content_trust":"untrusted_skill_data","activation":"disabled","readiness_status":"not_evaluated","shadowed":catalog.shadowed,"catalog_warnings":catalog.warnings});
            if body.is_none() {
                result["is_binary"] = json!(true);
                result["complete_read"] = json!(complete);
                result["content_omitted"] = json!(!complete);
                result["byte_count"] = json!(bytes.len());
                result["sha256"] = json!(hash(&bytes));
                if complete {
                    result["content_encoding"] = json!("base64");
                    result["content_base64"] = json!(STANDARD.encode(&bytes));
                } else {
                    result["content_encoding"] = Value::Null;
                    result["content_base64"] = Value::Null;
                    result["binary_notice"] = json!("Resource bytes remain in the selected storage. Inline binary view is limited to 8 KiB; this metadata-only view does not authorize replacing the resource.");
                }
            }
            if file == "SKILL.md" {
                result["description"] = json!(doc.description);
                result["category"] = json!(doc.category());
                let hermes = doc.fields.get("metadata").and_then(|v| v.get("hermes"));
                for field in ["tags", "related_skills"] {
                    let nested = hermes.and_then(|v| v.get(field));
                    let tags = frontmatter::tags(nested);
                    result[field] = json!(if tags.is_empty() {frontmatter::tags(doc.fields.get(field))}else{tags});
                }
                if let Some(metadata) = doc.fields.get("metadata").filter(|v| v.is_object()) { result["metadata"] = metadata.clone(); }
                if let Some(compatibility) = doc.fields.get("compatibility") { result["compatibility"] = compatibility.clone(); }
            } else {
                result["file"] = json!(file);
                result["file_type"] = json!(Path::new(&file).extension().and_then(|s| s.to_str()).map(|s| format!(".{s}")).unwrap_or_default());
            }
            if let Some(warning) = &doc.warning { result["metadata_warning"] = json!(warning); }
            Ok(result)
        }).await?
    }
    pub(super) async fn skill_manage(&self, args: Value, context: &TurnContext) -> Result<Value> {
        known(&args, &["operations"])?;
        let ops = args["operations"]
            .as_array()
            .context("operations array required")?;
        ensure!(
            !ops.is_empty() && ops.len() <= 20 && args.to_string().len() <= 200 * 1024,
            "skill batch exceeds bound"
        );
        let owner = self.read_scope(context)?;
        let current = managed_skills(&self.inner.db.lock().unwrap())?;
        let mut next = current.clone();
        let mut touched = BTreeSet::new();
        let mut deleted_names = BTreeSet::new();
        let mut created_names = BTreeSet::new();
        // Upstream reserves whole-skill deletion for a sole operation. Enforce
        // the same rule before approval and before any database effects.
        ensure!(
            ops.len() == 1 || !ops.iter().any(|op| op["action"] == "delete"),
            "delete must be the sole operation"
        );
        for op in ops {
            let operation = string(op, "action")?;
            let mut name = skill_name(string(op, "name")?)?;
            if operation == "create"
                && let Some(category) = op.get("category")
            {
                let category = category.as_str().context("category must be text")?.trim();
                if !category.is_empty() {
                    let category = skill_name(category)?;
                    ensure!(
                        !category.contains('/') && !name.contains('/'),
                        "create category requires a bare skill name and one category directory"
                    );
                    name = skill_name(&format!("{category}/{name}"))?;
                }
            }
            let target = match operation {
                "create" | "delete" => "SKILL.md".to_owned(),
                _ => skill_file_path(op["file_path"].as_str().unwrap_or("SKILL.md"))?,
            };
            let destructive = matches!(operation, "create" | "write_file" | "remove_file")
                || (operation == "patch" && op.get("content").is_some());
            ensure!(
                !destructive || !touched.contains(&(name.clone(), target.clone())),
                "destructive skill operation would discard an earlier operation on the same file"
            );
            touched.insert((name.clone(), target));
            match operation {
                "create" => {
                    known(op, &["name", "action", "content", "category"])?;
                    ensure!(
                        !next.keys().any(|(n, _)| n == &name),
                        "managed skill already exists"
                    );
                    if let Some(base) = &self.inner.cfg.skills_root {
                        ensure!(
                            !relative_exists(&self.inner.root, &format!("{base}/{name}/SKILL.md"))
                                .unwrap_or(false),
                            "configured filesystem skill already exists and is read-only"
                        );
                    }
                    catalog::validate_create_layout(&name, &next, &self.inner)?;
                    let content = string(op, "content")?;
                    validate_skill(content, None)?;
                    created_names.insert(name.clone());
                    next.insert((name, "SKILL.md".into()), content.as_bytes().to_vec());
                }
                "write_file" => {
                    known(op, &["name", "action", "file_path", "file_content"])?;
                    ensure!(
                        next.contains_key(&(name.clone(), "SKILL.md".into())),
                        "managed skill does not exist"
                    );
                    let path = supporting_path(string(op, "file_path")?)?;
                    ensure!(
                        !path.is_empty() && path != "SKILL.md",
                        "use patch for main SKILL.md"
                    );
                    let content = string(op, "file_content")?;
                    ensure!(
                        content.len() <= 128 * 1024 && !content.contains('\0'),
                        "skill file too large or contains NUL"
                    );
                    if let Some(old) = next.get(&(name.clone(), path.clone()))
                        && (old.contains(&0) || std::str::from_utf8(old).is_err())
                    {
                        let snapshot = self
                            .inner
                            .reads
                            .lock()
                            .unwrap()
                            .get(&(owner.clone(), format!("skill:{name}:{path}")))
                            .cloned()
                            .context("read skill_view before replacing a binary resource")?;
                        ensure!(snapshot.hash == hash(old), "skill changed since read");
                    }
                    next.insert((name, path), content.as_bytes().to_vec());
                }
                "patch" => {
                    known(
                        op,
                        &[
                            "name",
                            "action",
                            "file_path",
                            "old_string",
                            "new_string",
                            "replace_all",
                            "content",
                        ],
                    )?;
                    let path = skill_file_path(op["file_path"].as_str().unwrap_or("SKILL.md"))?;
                    if path != "SKILL.md" {
                        supporting_path(&path)?;
                    }
                    let key = (name.clone(), path.clone());
                    let old=next.get(&key).context("managed skill file not found; configured filesystem skills are read-only")?.clone();
                    let body = if let Some(content) = op.get("content") {
                        ensure!(
                            op.get("old_string").is_none() && op.get("new_string").is_none(),
                            "choose full rewrite or literal patch"
                        );
                        let snapshot = self
                            .inner
                            .reads
                            .lock()
                            .unwrap()
                            .get(&(owner.clone(), format!("skill:{name}:{path}")))
                            .cloned()
                            .context("read skill_view before full rewrite")?;
                        ensure!(snapshot.hash == hash(&old), "skill changed since read");
                        content.as_str().context("content must be text")?.to_owned()
                    } else {
                        let old = std::str::from_utf8(&old)
                            .context("literal skill patch requires UTF-8 text; read then explicitly rewrite binary resources")?;
                        ensure!(
                            !old.contains('\0'),
                            "literal skill patch requires text without NUL"
                        );
                        let from = string(op, "old_string")?;
                        let to = string(op, "new_string")?;
                        ensure!(!from.is_empty() && from != to, "invalid skill patch span");
                        let count = old.match_indices(from).count();
                        ensure!(
                            count > 0 && (count == 1 || op["replace_all"] == true),
                            "skill span missing or ambiguous"
                        );
                        old.replace(from, to)
                    };
                    ensure!(
                        body.len() <= 128 * 1024 && !body.contains('\0'),
                        "skill file too large or contains NUL"
                    );
                    if path == "SKILL.md" {
                        validate_skill(&body, Some(std::str::from_utf8(&old)?))?;
                    }
                    next.insert(key, body.into_bytes());
                }
                "remove_file" => {
                    known(op, &["name", "action", "file_path"])?;
                    ensure!(
                        next.contains_key(&(name.clone(), "SKILL.md".into())),
                        "managed skill does not exist; configured filesystem skills are read-only"
                    );
                    let path = supporting_path(string(op, "file_path")?)?;
                    ensure!(
                        !path.is_empty() && path != "SKILL.md",
                        "remove_file requires a supporting file; use delete for the whole skill"
                    );
                    ensure!(
                        next.remove(&(name, path)).is_some(),
                        "managed skill file not found"
                    );
                }
                "delete" => {
                    known(op, &["name", "action", "absorbed_into"])?;
                    ensure!(
                        next.contains_key(&(name.clone(), "SKILL.md".into())),
                        "managed skill does not exist; configured filesystem skills are read-only"
                    );
                    if let Some(target) = op.get("absorbed_into") {
                        let target = target
                            .as_str()
                            .context("absorbed_into must be text")?
                            .trim();
                        if !target.is_empty() {
                            let target = skill_name(target)?;
                            ensure!(target != name, "absorbed_into cannot be the deleted skill");
                            let tombstoned = self.inner.db.lock().unwrap().query_row(
                                "SELECT EXISTS(SELECT 1 FROM local_skill_tombstones WHERE name=?1)",
                                [&target],
                                |row| row.get::<_, bool>(0),
                            )?;
                            let configured = !tombstoned
                                && self.inner.cfg.skills_root.as_ref().is_some_and(|base| {
                                    relative_exists(
                                        &self.inner.root,
                                        &format!("{base}/{target}/SKILL.md"),
                                    )
                                    .unwrap_or(false)
                                });
                            ensure!(
                                next.contains_key(&(target, "SKILL.md".into())) || configured,
                                "absorbed_into skill does not exist"
                            );
                        }
                    }
                    next.retain(|(n, _), _| n != &name);
                    deleted_names.insert(name);
                }
                _ => {
                    bail!(
                        "unsupported managed skill action; supported: create, patch, write_file, remove_file, delete"
                    )
                }
            }
        }
        ensure!(
            next.len() <= 1000 && next.values().map(Vec::len).sum::<usize>() <= 8 * 1024 * 1024,
            "managed skill storage limit exceeded"
        );
        let action = self.action("skill_manage", &args);
        let mut permit = self
            .authorize(
                self.inner.cfg.write,
                context,
                &action,
                &format!(
                    "Apply {} managed-skill edits atomically\n{}",
                    ops.len(),
                    args.to_string().chars().take(4000).collect::<String>()
                ),
            )
            .await?;
        let inner = self.inner.clone();
        let ctx = context.clone();
        tokio::task::spawn_blocking(move || {
            let _fence = permit.verify(&ctx, &action)?;
            let mut db = inner.db.lock().unwrap();
            let tx = db.transaction()?;
            ensure!(
                managed_skills(&tx)? == current,
                "skills changed while awaiting approval"
            );
            for name in &created_names {
                tx.execute("DELETE FROM local_skill_tombstones WHERE name=?1", [name])?;
            }
            for name in &deleted_names {
                let (exists, count): (bool, usize) = tx.query_row("SELECT EXISTS(SELECT 1 FROM local_skill_tombstones WHERE name=?1), (SELECT count(*) FROM local_skill_tombstones)", [name], |row| Ok((row.get(0)?, row.get(1)?)))?;
                ensure!(exists || count < 10000, "managed deletion-marker capacity exhausted; explicit maintenance required");
                tx.execute("INSERT OR IGNORE INTO local_skill_tombstones(name) VALUES(?1)", [name])?;
            }
            apply_delta(&tx, &current, &next)?;
            tx.commit()?;
            Ok(json!({"success":true,"storage":"managed_store","atomic":true}))
        })
        .await?
    }
}

fn supporting_path(raw: &str) -> Result<String> {
    let path = skill_file_path(raw)?;
    let (directory, file) = path
        .split_once('/')
        .context("supporting file must be inside references, templates, scripts or assets")?;
    ensure!(
        ["references", "templates", "scripts", "assets"].contains(&directory) && !file.is_empty(),
        "supporting file must be inside references, templates, scripts or assets"
    );
    Ok(path)
}
fn skill_name(name: &str) -> Result<String> {
    let name = rel(name)?;
    ensure!(
        !name.is_empty()
            && name.len() <= 128
            && name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"-_/".contains(&b)),
        "skill name must be a lowercase relative name"
    );
    Ok(name)
}
fn skill_file_path(raw: &str) -> Result<String> {
    ensure!(
        !raw.contains(['\\', ':']) && !raw.chars().any(char::is_control),
        "invalid skill file path"
    );
    let path = rel(raw)?;
    ensure!(!path.is_empty(), "skill file required");
    Ok(path)
}
fn validate_skill(body: &str, before: Option<&str>) -> Result<()> {
    // Keep profile_bridge's existing export/import envelope until that separate
    // boundary supports more encodings. Read-only configured documents are wider.
    ensure!(
        body.len() <= 128 * 1024
            && !body.contains('\0')
            && body.starts_with("---\n")
            && !body.contains('\r'),
        "managed SKILL.md requires bounded LF-only YAML frontmatter; BOM/CRLF is supported only for configured read-only skills"
    );
    let (header, markdown) = frontmatter::split(body)
        .context("skill frontmatter must close before its Markdown body")?;
    ensure!(
        body.get(4 + header.len()..)
            .is_some_and(|tail| tail.starts_with("---\n")),
        "managed frontmatter closing fence must be an exact LF line"
    );
    let fields = frontmatter::parse(header)?;
    for key in ["name", "description"] {
        ensure!(
            fields
                .get(key)
                .and_then(Value::as_str)
                .is_some_and(|s| !s.trim().is_empty()),
            "skill frontmatter requires nonempty text name and description"
        );
    }
    ensure!(
        !markdown.trim().is_empty(),
        "SKILL.md requires a nonempty Markdown body"
    );
    let description = fields["description"].as_str().unwrap().trim();
    ensure!(
        description.chars().count() <= 1024,
        "skill description exceeds 1024 characters"
    );
    let unchanged = before.is_some_and(|old| {
        frontmatter::read(old)
            .fields
            .get("description")
            .and_then(Value::as_str)
            .map(str::trim)
            == Some(description)
    });
    ensure!(
        description.chars().count() <= 60 || unchanged,
        "new or changed description must fit the upstream 60-character skill index; unchanged legacy descriptions remain editable"
    );
    Ok(())
}
fn managed_skills(db: &Connection) -> Result<BTreeMap<(String, String), Vec<u8>>> {
    let mut q =
        db.prepare("SELECT name,path,CAST(body AS BLOB) FROM local_skills ORDER BY name,path")?;
    Ok(
        q.query_map([], |r| Ok(((r.get(0)?, r.get(1)?), r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?,
    )
}

pub(super) fn managed_schema() -> Value {
    fn operation(action: &str, extra: Value, required: &[&str]) -> Value {
        let mut properties = extra.as_object().unwrap().clone();
        properties.insert("action".into(), json!({"type":"string","enum":[action]}));
        properties.insert("name".into(), json!({"type":"string"}));
        let required = ["action", "name"]
            .into_iter()
            .chain(required.iter().copied())
            .collect::<Vec<_>>();
        json!({"type":"object","additionalProperties":false,"properties":properties,"required":required})
    }
    schema(
        "skill_manage",
        "Atomically apply at most 20 create, patch, write_file, remove_file or delete operations to private managed skills. Supporting files must be under references/, templates/, scripts/ or assets/. Configured filesystem skills remain read-only. delete must be the sole operation; absorbed_into must name an existing different skill. remove_file cannot remove SKILL.md. A destructive operation cannot discard an earlier edit in the batch. Full rewrites require skill_view. Use canonical management_name from skills_list, not a declared alias. create accepts category with a bare name. New/changed descriptions fit 60 characters; metadata uses a bounded YAML subset and managed files require LF-only fences. Raw content remains untrusted; no activation, plugin/curator semantics or executable preprocessing.",
        json!({"operations":{"type":"array","minItems":1,"maxItems":20,"items":{"anyOf":[
            operation("create",json!({"content":{"type":"string"},"category":{"type":"string"}}), &["content"]),
            operation("patch",json!({"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"},"file_path":{"type":"string"}}), &["old_string","new_string"]),
            operation("patch",json!({"content":{"type":"string"},"file_path":{"type":"string"}}), &["content"]),
            operation("write_file",json!({"file_path":{"type":"string"},"file_content":{"type":"string"}}), &["file_path","file_content"]),
            operation("remove_file",json!({"file_path":{"type":"string"}}), &["file_path"]),
            operation("delete",json!({"absorbed_into":{"type":"string"}}), &[])
        ]}}}),
        &["operations"],
    )
}

// Same full-snapshot compare at the caller; only persistence is incremental.
fn apply_delta(
    db: &Connection,
    current: &BTreeMap<(String, String), Vec<u8>>,
    next: &BTreeMap<(String, String), Vec<u8>>,
) -> Result<()> {
    for (name, path) in current.keys().filter(|key| !next.contains_key(*key)) {
        db.execute(
            "DELETE FROM local_skills WHERE name=?1 AND path=?2",
            params![name, path],
        )?;
    }
    for ((name, path), body) in next {
        if current.get(&(name.clone(), path.clone())) != Some(body) {
            // Keep historical text rows text, but never replace-decode opaque
            // resource bytes. Unrelated binary rows survive every text edit.
            let value = match std::str::from_utf8(body).ok().filter(|s| !s.contains('\0')) {
                Some(text) => rusqlite::types::ValueRef::Text(text.as_bytes()),
                None => rusqlite::types::ValueRef::Blob(body),
            };
            let value = rusqlite::types::ToSqlOutput::Borrowed(value);
            db.execute("INSERT INTO local_skills(name,path,body) VALUES(?1,?2,?3) ON CONFLICT(name,path) DO UPDATE SET body=excluded.body", params![name, path, value])?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod persistence_benchmark {
    use super::*;
    fn cpu_us() -> i64 {
        unsafe {
            let mut r: libc::rusage = std::mem::zeroed();
            assert_eq!(libc::getrusage(libc::RUSAGE_SELF, &mut r), 0);
            (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1_000_000
                + r.ru_utime.tv_usec
                + r.ru_stime.tv_usec
        }
    }
    #[test]
    #[ignore = "release-only deterministic persistence A/B; writes JSON to HERMES_SKILL_BENCH_OUTPUT"]
    #[allow(
        clippy::assertions_on_constants,
        reason = "Benchmark must refuse a debug build"
    )]
    fn skill_persistence_ab() -> Result<()> {
        assert!(!cfg!(debug_assertions));
        let output = std::env::var("HERMES_SKILL_BENCH_OUTPUT").context("output path required")?;
        let mut results = vec![];
        for files in [10usize, 1000] {
            for trial in 0..4 {
                let order = if trial % 2 == 0 {
                    ["rewrite_all", "delta"]
                } else {
                    ["delta", "rewrite_all"]
                };
                for implementation in order {
                    let temp = tempfile::tempdir()?;
                    let mut db =
                        crate::private_db::open_private(&temp.path().join("state.sqlite"))?;
                    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE local_skills(name TEXT NOT NULL,path TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(name,path));")?;
                    let mut expected = BTreeMap::new();
                    for i in 0..files {
                        expected.insert(
                            ("demo".into(), format!("references/{i:04}.txt")),
                            "x".repeat(4096).into_bytes(),
                        );
                    }
                    let tx = db.transaction()?;
                    apply_delta(&tx, &BTreeMap::new(), &expected)?;
                    tx.commit()?;
                    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
                    let mut samples = vec![];
                    let cpu = cpu_us();
                    for turn in 0..40 {
                        let start = Instant::now();
                        let current = managed_skills(&db)?;
                        let mut next = current.clone();
                        next.insert(
                            ("demo".into(), "references/0000.txt".into()),
                            format!("{turn:04}{}", "x".repeat(4092)).into_bytes(),
                        );
                        let tx = db.transaction()?;
                        ensure!(managed_skills(&tx)? == current, "CAS mismatch");
                        if implementation == "delta" {
                            apply_delta(&tx, &current, &next)?;
                        } else {
                            // Previous b53e5b implementation, verbatim persistence algorithm.
                            tx.execute("DELETE FROM local_skills", [])?;
                            for ((name, path), body) in &next {
                                tx.execute(
                                    "INSERT INTO local_skills(name,path,body) VALUES(?1,?2,?3)",
                                    params![name, path, std::str::from_utf8(body)?],
                                )?;
                            }
                        }
                        tx.commit()?;
                        samples.push(start.elapsed().as_secs_f64() * 1000.);
                        expected = next;
                    }
                    let cpu = cpu_us() - cpu;
                    ensure!(managed_skills(&db)? == expected, "final contents differ");
                    let changes = db.total_changes();
                    results.push(json!({"files":files,"bytes_per_file":4096,"trial":trial,"order":order,"implementation":implementation,"elapsed_ms":samples,"cpu_us_total":cpu,"total_row_changes_including_seed":changes,"final_digest":hash(serde_json::to_string(&expected.iter().collect::<Vec<_>>())?.as_bytes())}));
                }
            }
        }
        fs::write(
            output,
            serde_json::to_vec_pretty(
                &json!({"method":"same process, same WAL/FULL, full read+clone+CAS each transaction, prior SQL vs incremental SQL, warm OS cache, temporary independent databases; not whole Agent or historical binary comparison","samples":results}),
            )?,
        )?;
        Ok(())
    }
}
