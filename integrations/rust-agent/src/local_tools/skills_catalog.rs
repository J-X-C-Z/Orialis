//! One explicit-root catalog; filesystem locations never become capabilities.
use super::*;

const EXCLUDED: &[&str] = &[
    ".git",
    ".github",
    ".hub",
    ".archive",
    ".curator_backups",
    ".locks",
    ".hermes-dist",
    ".venv",
    "venv",
    "node_modules",
    "site-packages",
    "__pycache__",
    ".tox",
    ".nox",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
];
const SUPPORT: &[&str] = &["references", "templates", "assets", "scripts"];
const CATALOG_BYTES: usize = 8 * 1024 * 1024;

pub(super) struct Document {
    pub key: String,
    pub body: String,
    pub source: &'static str,
    pub declared: String,
    pub description: String,
    pub fields: serde_json::Map<String, Value>,
    pub warning: Option<String>,
}
impl Document {
    fn new(key: String, body: String, source: &'static str) -> Self {
        let metadata = frontmatter::read(&body);
        let declared = metadata
            .fields
            .get("name")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| key.rsplit('/').next().unwrap())
            .to_owned();
        let description = metadata
            .fields
            .get("description")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| {
                metadata
                    .body
                    .lines()
                    .map(str::trim)
                    .find(|s| !s.is_empty() && !s.starts_with('#'))
                    .unwrap_or("")
            })
            .to_owned();
        let fields = metadata.fields;
        let warning = metadata.warning;
        Self {
            key,
            body,
            source,
            declared,
            description,
            fields,
            warning,
        }
    }
    pub fn category(&self) -> Option<&str> {
        self.key.split_once('/').map(|(category, _)| category)
    }
    fn aliases(&self) -> BTreeSet<&str> {
        [
            &*self.key,
            &*self.declared,
            self.key.rsplit('/').next().unwrap(),
        ]
        .into_iter()
        .collect()
    }
    fn brief(&self) -> Value {
        json!({"relative_path": self.key, "declared_name": self.declared, "source": self.source})
    }
}
pub(super) struct Catalog {
    pub docs: Vec<Document>,
    pub shadowed: Vec<Value>,
    pub warnings: Vec<Value>,
    pub tombstones: BTreeSet<String>,
    aliases: BTreeMap<String, Vec<usize>>,
    winners: BTreeMap<String, Option<usize>>,
}
impl Catalog {
    pub fn load(inner: &Inner) -> Result<Self> {
        let (managed, tombstones) = {
            let db = inner.db.lock().unwrap();
            let mut q = db.prepare(
                "SELECT name,body FROM local_skills WHERE path='SKILL.md' ORDER BY name",
            )?;
            let rows = q
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                .collect::<rusqlite::Result<BTreeMap<_, _>>>()?;
            let mut q = db.prepare("SELECT name FROM local_skill_tombstones")?;
            let tombstones = q
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<BTreeSet<_>>>()?;
            (rows, tombstones)
        };
        let mut docs = BTreeMap::new();
        let mut bytes = 0;
        let mut warnings = vec![];
        let mut shadowed = vec![];
        if let Some(base) = &inner.cfg.skills_root {
            let base = rel(base)?;
            let mut paths = vec![];
            scan(&inner.root, &base, &base, 0, &mut 0, &mut paths)?;
            for (key, path) in paths {
                if tombstones.contains(&key) && !managed.contains_key(&key) {
                    continue;
                }
                match snapshot(&inner.root, &path, inner.cfg.file_bytes.min(128 * 1024)).and_then(|(bytes, _)| Ok(String::from_utf8(bytes)?)) {
                    Ok(body) => {
                        bytes += body.len();
                        ensure!(bytes <= CATALOG_BYTES, "skill catalog exceeds 8 MiB");
                        docs.insert(key.clone(), Document::new(key, body, "configured_files"));
                    }
                    Err(_) => warnings.push(json!({"relative_path":key,"reason":"configured skill unreadable, linked, invalid UTF-8, changing, or over byte limit"})),
                }
            }
        }
        for (key, body) in managed {
            ensure!(
                lookup_name(&key).is_ok(),
                "invalid stored managed skill name"
            );
            if let Some(configured) = docs.remove(&key)
                && configured.body != body
            {
                shadowed.push(json!({"relative_path":key,"source":"configured_files","selected_source":"managed_store","reason":"managed content differs from configured file; reconcile profile before sync"}));
            }
            bytes += body.len();
            ensure!(
                bytes <= CATALOG_BYTES && docs.len() < 1000,
                "skill catalog bound reached"
            );
            docs.insert(key.clone(), Document::new(key, body, "managed_store"));
        }
        let docs = docs.into_values().collect::<Vec<_>>();
        ensure!(docs.len() <= 1000, "skill catalog exceeds 1000 documents");
        let mut aliases = BTreeMap::<String, Vec<usize>>::new();
        for (i, doc) in docs.iter().enumerate() {
            for alias in doc.aliases() {
                if lookup_name(alias).is_ok_and(|name| name == alias) {
                    aliases.entry(alias.into()).or_default().push(i);
                }
            }
        }
        // Resolve each alias once. Re-resolving one shared declared name for
        // every row would compare whole bodies quadratically under collisions.
        let winners = aliases
            .iter()
            .map(|(name, ids)| (name.clone(), Self::winner(&docs, ids)))
            .collect();
        Ok(Self {
            docs,
            shadowed,
            warnings,
            tombstones,
            aliases,
            winners,
        })
    }
    fn winner(docs: &[Document], candidates: &[usize]) -> Option<usize> {
        if candidates.len() == 1 {
            return candidates.first().copied();
        }
        let first = &docs[*candidates.first()?];
        if candidates
            .iter()
            .all(|i| docs[*i].source == first.source && docs[*i].body == first.body)
        {
            let depth = |i: usize| docs[i].key.split('/').count();
            let mut ranked = candidates.to_vec();
            ranked.sort_by_key(|i| depth(*i));
            if depth(ranked[0]) < depth(ranked[1]) {
                return Some(ranked[0]);
            }
        }
        None
    }
    fn alias_winner(&self, name: &str) -> Option<usize> {
        self.winners.get(name).copied().flatten()
    }
    pub fn resolve(&self, name: &str) -> Result<&Document> {
        ensure!(
            !self.tombstones.contains(name)
                || self
                    .docs
                    .iter()
                    .any(|d| d.key == name && d.source == "managed_store"),
            "managed skill was deleted; stale exported files are not a fallback"
        );
        let ids = self
            .aliases
            .get(name)
            .context("skill not found; use skills_list")?;
        if let Some(i) = self.alias_winner(name) {
            return Ok(&self.docs[i]);
        }
        let names = ids
            .iter()
            .map(|i| self.docs[*i].key.as_str())
            .collect::<Vec<_>>();
        bail!(
            "ambiguous skill name '{name}'; refusing to guess; candidate relative paths: {}",
            names.join(", ")
        )
    }
    pub fn list(&self, category: Option<&str>) -> Value {
        let mut rows = vec![];
        let mut shadowed = self.shadowed.clone();
        let mut unresolved = vec![];
        for (i, doc) in self.docs.iter().enumerate() {
            if category.is_some_and(|c| !c.is_empty() && doc.category() != Some(c)) {
                continue;
            }
            let name = match self.alias_winner(&doc.declared) {
                Some(winner) if winner == i => &doc.declared,
                Some(_) => {
                    let mut summary = doc.brief();
                    summary["reason"] =
                        json!("identical same-source copy has a shallower unambiguous name");
                    shadowed.push(summary);
                    continue;
                }
                None if self.alias_winner(&doc.key) == Some(i) => &doc.key,
                _ => {
                    unresolved.push(doc.brief());
                    continue;
                }
            };
            let description = clip(&doc.description, 1024);
            let mut row = json!({"name":name,"declared_name":doc.declared,"relative_path":doc.key,"description":description,"category":doc.category(),"source":doc.source,"read_only":doc.source == "configured_files","management_name":if doc.source == "managed_store" {Some(&doc.key)}else{None}});
            if let Some(warning) = &doc.warning {
                row["metadata_warning"] = json!(warning);
            }
            rows.push(row);
        }
        rows.sort_by(|a, b| {
            (a["category"].as_str().unwrap_or(""), a["name"].as_str())
                .cmp(&(b["category"].as_str().unwrap_or(""), b["name"].as_str()))
        });
        let categories = rows
            .iter()
            .filter_map(|r| r["category"].as_str())
            .collect::<BTreeSet<_>>();
        json!({"success":true,"count":rows.len(),"skills":rows,"categories":categories,"shadowed":shadowed,"unresolved":unresolved,"warnings":self.warnings,"content_trust":"untrusted_skill_data","activation":"disabled","hint":"Use skill_view(name) for raw content and linked files. Use management_name for managed edits. No skill content is executed or promoted to host instructions."})
    }
}
fn clip(value: &str, count: usize) -> String {
    if value.chars().count() <= count {
        value.into()
    } else {
        format!("{}...", value.chars().take(count - 3).collect::<String>())
    }
}
pub(super) fn lookup_name(raw: &str) -> Result<String> {
    ensure!(
        !raw.is_empty()
            && raw.len() <= 256
            && !raw.contains(['\\', ':'])
            && !raw.chars().any(char::is_control),
        "invalid skill lookup name"
    );
    let name = rel(raw)?;
    ensure!(!name.is_empty(), "skill lookup name is empty");
    Ok(name)
}
fn scan(
    root: &ProtectedRoot,
    base: &str,
    path: &str,
    depth: usize,
    visited: &mut usize,
    found: &mut Vec<(String, String)>,
) -> Result<()> {
    ensure!(depth <= 16, "skill catalog depth exceeds 16");
    let entries = root.list(path)?;
    *visited += entries.len();
    ensure!(
        *visited <= 10000,
        "skill catalog exceeds 10000 inspected entries"
    );
    let main = entries
        .iter()
        .find(|e| !e.is_directory && e.name == "SKILL.md");
    let has_main = main.is_some();
    if let Some(main) = main
        && path != base
    {
        let key = if base.is_empty() {
            path
        } else {
            path.strip_prefix(&format!("{base}/"))
                .context("skill escaped configured root")?
        };
        found.push((key.into(), main.path.clone()));
        ensure!(found.len() <= 1000, "skill catalog exceeds 1000 documents");
    }
    for entry in entries {
        if !entry.is_directory
            || EXCLUDED.contains(&entry.name.as_str())
            || (has_main && SUPPORT.contains(&entry.name.as_str()))
        {
            continue;
        }
        let Ok(path) = rel(&entry.path) else { continue };
        scan(root, base, &path, depth + 1, visited, found)?;
    }
    Ok(())
}

fn linked_group(path: &str) -> Option<&str> {
    let (group, tail) = path.split_once('/')?;
    if !SUPPORT.contains(&group) || rel(path).is_err() {
        return None;
    }
    if tail.split('/').any(|p| EXCLUDED.contains(&p)) {
        return None;
    }
    let extension = Path::new(tail)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let selected = match group {
        "references" => !tail.contains('/') && extension == "md",
        "templates" => ["md", "py", "yaml", "yml", "json", "tex", "sh"].contains(&extension),
        "assets" => true,
        "scripts" => {
            !tail.contains('/') && ["py", "sh", "bash", "js", "ts", "rb"].contains(&extension)
        }
        _ => false,
    };
    selected.then_some(group)
}
pub(super) fn linked_files(inner: &Inner, doc: &Document) -> Result<Value> {
    let paths = if doc.source == "managed_store" {
        let db = inner.db.lock().unwrap();
        let mut q = db.prepare("SELECT path FROM local_skills WHERE name=?1 ORDER BY path")?;
        q.query_map([&doc.key], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    } else {
        let base = inner
            .cfg
            .skills_root
            .as_ref()
            .context("no configured skills root")?;
        let base = rel(&format!("{base}/{}", doc.key))?;
        let mut files = vec![];
        let mut visited = 0;
        for entry in inner.root.list(&base)? {
            if entry.is_directory && SUPPORT.contains(&entry.name.as_str()) {
                linked_walk(
                    &inner.root,
                    &base,
                    &entry.path,
                    0,
                    matches!(entry.name.as_str(), "templates" | "assets"),
                    &mut visited,
                    &mut files,
                )?;
            }
        }
        files
    };
    let mut groups = BTreeMap::<&str, Vec<&str>>::new();
    for path in &paths {
        if let Some(group) = linked_group(path) {
            groups.entry(group).or_default().push(path);
        }
    }
    for values in groups.values_mut() {
        values.sort();
        values.dedup();
    }
    Ok(if groups.is_empty() {
        Value::Null
    } else {
        json!(groups)
    })
}
fn linked_walk(
    root: &ProtectedRoot,
    base: &str,
    path: &str,
    depth: usize,
    recursive: bool,
    visited: &mut usize,
    files: &mut Vec<String>,
) -> Result<()> {
    ensure!(depth <= 16, "linked skill files exceed depth limit");
    for entry in root.list(path)? {
        *visited += 1;
        ensure!(
            *visited <= 1000,
            "linked skill files exceed 1000 inspected entries"
        );
        if EXCLUDED.contains(&entry.name.as_str()) {
            continue;
        }
        let Ok(path) = rel(&entry.path) else { continue };
        if entry.is_directory {
            if recursive {
                linked_walk(root, base, &path, depth + 1, recursive, visited, files)?;
            }
        } else {
            let file = root.open_file(&path)?;
            if file.metadata()?.nlink() == 1 {
                files.push(
                    path.strip_prefix(&format!("{base}/"))
                        .context("linked file escaped skill")?
                        .into(),
                );
            }
        }
    }
    Ok(())
}

// Reject new storage layouts that would change meaning after profile export.
// Existing imported/private rows stay addressable and are never silently erased.
pub(super) fn validate_create_layout(
    name: &str,
    skills: &BTreeMap<(String, String), Vec<u8>>,
    inner: &Inner,
) -> Result<()> {
    ensure!(
        !name.split('/').any(|p| EXCLUDED.contains(&p)),
        "managed skill name uses an excluded catalog directory"
    );
    let parts = name.split('/').collect::<Vec<_>>();
    for i in 1..parts.len() {
        if SUPPORT.contains(&parts[i]) {
            let parent = parts[..i].join("/");
            let configured = inner.cfg.skills_root.as_ref().is_some_and(|base| {
                relative_exists(&inner.root, &format!("{base}/{parent}/SKILL.md")).unwrap_or(false)
            });
            ensure!(
                !configured && !skills.contains_key(&(parent, "SKILL.md".into())),
                "managed skill cannot be created inside another skill's support directory"
            );
        }
    }
    let prefix = format!("{name}/");
    ensure!(
        !skills.keys().any(|(key, file)| file == "SKILL.md"
            && key
                .strip_prefix(&prefix)
                .and_then(|rest| rest.split('/').next())
                .is_some_and(|part| SUPPORT.contains(&part))),
        "creating this skill would hide an existing managed skill inside its support directory"
    );
    Ok(())
}
