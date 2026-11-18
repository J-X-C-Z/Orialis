//! Native search with explicit work limits and one-match lookahead. Every path
//! returned to the model is reopened through the pinned root and link-checked.
use super::*;
#[path = "file_ignore.rs"]
mod file_ignore;

const SCAN_BYTES: usize = 32 * 1024 * 1024;
const RESULT_BYTES: usize = 128 * 1024;
const MAX_ENTRIES: usize = 1000;

struct Candidate {
    path: String,
    modified: (i64, i64),
    directory: bool,
}
struct SearchPage {
    matches: Vec<Value>,
    seen: usize,
    offset: usize,
    limit: usize,
    bytes: usize,
    more: bool,
}
impl SearchPage {
    /// False means the current match proves another page exists.
    fn push(&mut self, value: Value) -> Result<bool> {
        self.seen += 1;
        if self.seen <= self.offset {
            return Ok(true);
        }
        if self.matches.len() >= self.limit {
            self.more = true;
            return Ok(false);
        }
        let bytes = serde_json::to_vec(&value)?.len() + 1;
        ensure!(
            bytes <= RESULT_BYTES,
            "single search result exceeds output byte bound; narrow the search"
        );
        if self.bytes + bytes > RESULT_BYTES {
            self.more = true;
            return Ok(false);
        }
        self.bytes += bytes;
        self.matches.push(value);
        Ok(true)
    }
}

pub(super) async fn search(tools: &LocalTools, args: Value) -> Result<Value> {
    known(
        &args,
        &[
            "pattern",
            "target",
            "path",
            "file_glob",
            "limit",
            "offset",
            "output_mode",
            "context",
            "order",
        ],
    )?;
    let pattern = string(&args, "pattern")?.to_owned();
    ensure!(pattern.len() <= 1024, "pattern too long");
    let path = rel(args["path"].as_str().unwrap_or("."))?;
    let target = args["target"].as_str().unwrap_or("content").to_owned();
    ensure!(
        ["files", "content"].contains(&target.as_str()),
        "invalid search target"
    );
    let mode = args["output_mode"].as_str().unwrap_or("content").to_owned();
    ensure!(
        ["content", "files_only", "count"].contains(&mode.as_str()),
        "invalid output_mode"
    );
    let order = args
        .get("order")
        .map(|v| v.as_str().context("order must be text"))
        .transpose()?
        .unwrap_or("discovery")
        .to_owned();
    ensure!(
        ["discovery", "modified"].contains(&order.as_str()),
        "invalid search order"
    );
    ensure!(
        target == "files" || order == "discovery",
        "modified order applies only to filename search"
    );
    let limit = number(&args, "limit", 50, 200)?;
    ensure!(limit > 0, "limit must be positive");
    let offset = number(&args, "offset", 0, 10000)?;
    let context = number(&args, "context", 0, 3)?;
    let filter = args["file_glob"].as_str().map(glob).transpose()?;
    let expression = if target == "files" {
        // Pinned ripgrep branch treats a bare name as a suffix glob.
        glob(&if !pattern.contains('/') && !pattern.starts_with('*') {
            format!("*{pattern}")
        } else {
            pattern.clone()
        })?
    } else {
        regex::RegexBuilder::new(&pattern)
            .size_limit(1024 * 1024)
            .dfa_size_limit(1024 * 1024)
            .build()?
    };
    let inner = tools.inner.clone();
    tokio::task::spawn_blocking(move || {
        let mut files = Vec::new();
        let mut rules = file_ignore::Rules::default();
        if inner.root.open_file(&path).is_ok() {
            // Explicit single-file targets are not discovery: hidden and ignore
            // rules do not suppress them, but private/link validation still does.
            files.push(candidate(&inner.root, &path, false)?);
        } else {
            // Read ancestors only inside the configured capability root. An
            // explicitly selected directory is itself exempt from ignore rules.
            let mut ancestor = String::new();
            for component in path.split('/').filter(|s| !s.is_empty()) {
                rules.load(&inner.root, &ancestor, inner.cfg.file_bytes)?;
                if !ancestor.is_empty() { ancestor.push('/'); }
                ancestor.push_str(component);
            }
            collect(&inner.root, &path, 0, &mut files, &mut 0, &mut rules, inner.cfg.file_bytes)?;
        }
        if order == "modified" {
            files.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.path.cmp(&b.path)));
        }
        let mut page = SearchPage { matches: vec![], seen: 0, offset, limit, bytes: 0, more: false };
        let mut scanned = 0usize;
        let mut skipped = 0usize;
        let mut incomplete_reason = None;
        for file in files {
            if target == "files" {
                let relative = if path.is_empty() { file.path.as_str() }
                    else { file.path.strip_prefix(&path).and_then(|p| p.strip_prefix('/')).unwrap_or(&file.path) };
                if expression.is_match(relative) && !page.push(json!({"path":file.path,"is_directory":file.directory}))? { break; }
                continue;
            }
            if file.directory { continue; }
            let relative = if path.is_empty() { file.path.as_str() }
                else { file.path.strip_prefix(&path).and_then(|p| p.strip_prefix('/')).unwrap_or(&file.path) };
            if filter.as_ref().is_some_and(|f| !f.is_match(relative)) { continue; }
            let Ok((bytes, _)) = snapshot(&inner.root, &file.path, inner.cfg.file_bytes) else {
                skipped += 1;
                continue;
            };
            if bytes.len() > SCAN_BYTES - scanned { incomplete_reason = Some("scan_bytes"); break; }
            scanned += bytes.len();
            let Ok((text, _)) = file_read::decode_text(&bytes, &file.path) else { continue; };
            let lines = text.lines().collect::<Vec<_>>();
            let mut count = 0;
            for (i, line) in lines.iter().enumerate() {
                if !expression.is_match(line) { continue; }
                count += 1;
                if mode == "files_only" { break; }
                if mode == "content" {
                    let start = i.saturating_sub(context);
                    let end = (i + context + 1).min(lines.len());
                    let result = json!({"path":file.path,"line":i+1,"content":preview(line),
                        "context":lines[start..end].iter().map(|s|preview(s)).collect::<Vec<_>>(),
                        "content_truncated":line.len()>2000 || lines[start..end].iter().any(|s|s.len()>2000)});
                    if !page.push(result)? { break; }
                }
            }
            if page.more { break; }
            if count > 0 && mode != "content" {
                let result = if mode == "count" { json!({"path":file.path,"count":count}) }
                    else { json!({"path":file.path}) };
                if !page.push(result)? { break; }
            }
        }
        if skipped > 0 && incomplete_reason.is_none() { incomplete_reason = Some("unreadable_or_oversized_files"); }
        let next = page.more.then_some(offset + page.matches.len());
        Ok(json!({"matches":page.matches,"bounded":page.more || incomplete_reason.is_some(),
            "truncated":page.more,"incomplete":incomplete_reason.is_some(),
            "incomplete_reason":incomplete_reason,"skipped_files":skipped,
            "scanned_bytes":scanned,"next_offset":next,"order":order,
            "ignore_rules_applied":true,"ignore_scope":"configured_root_only",
            "ignore_files":rules.files,"hidden_descendants_excluded":true}))
    }).await?
}

fn preview(text: &str) -> &str {
    let mut end = text.len().min(2000);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}
fn candidate(root: &ProtectedRoot, path: &str, directory: bool) -> Result<Candidate> {
    let file = if directory {
        root.open_dir(path)?
    } else {
        root.open_file(path)?
    };
    let meta = file.metadata()?;
    ensure!(
        if directory {
            meta.is_dir()
        } else {
            meta.is_file() && meta.nlink() == 1
        },
        "candidate must be a safe directory or a regular non-hard-linked file"
    );
    Ok(Candidate {
        path: path.into(),
        modified: (meta.mtime(), meta.mtime_nsec()),
        directory,
    })
}
fn collect(
    root: &ProtectedRoot,
    path: &str,
    depth: usize,
    files: &mut Vec<Candidate>,
    visited: &mut usize,
    rules: &mut file_ignore::Rules,
    file_bytes: usize,
) -> Result<()> {
    ensure!(
        depth <= 16,
        "search traversal depth bound reached; narrow the root"
    );
    let checkpoint = rules.checkpoint();
    rules.load(root, path, file_bytes)?;
    for entry in root.list(path)? {
        *visited += 1;
        ensure!(
            *visited <= MAX_ENTRIES,
            "search traversal entry bound reached; narrow the root"
        );
        let Ok(path) = rel(&entry.path) else {
            continue;
        };
        if entry.name.starts_with('.') || rules.ignored(&path, entry.is_directory) {
            continue;
        }
        if entry.is_directory {
            files.push(candidate(root, &path, true)?);
            collect(root, &path, depth + 1, files, visited, rules, file_bytes)?;
        } else if let Ok(file) = candidate(root, &path, false) {
            files.push(file);
        }
    }
    rules.restore(checkpoint);
    Ok(())
}

/// A bounded shell-style pathname glob, not a shell command. '*'/'?' never cross
/// separators; a full '**' component can. Brace alternatives and classes are
/// supported, but malformed escapes/classes/braces fail instead of broadening.
fn glob(pattern: &str) -> Result<regex::Regex> {
    ensure!(
        pattern.len() <= 1024 && !pattern.contains('\0'),
        "invalid glob pattern"
    );
    let mut out = if pattern.contains('/') {
        String::from("^")
    } else {
        String::from("(?:^|/)")
    };
    let chars = pattern.trim_start_matches('/').chars().collect::<Vec<_>>();
    let mut index = 0;
    let mut braces = 0;
    while index < chars.len() {
        let c = chars[index];
        match c {
            '*' => {
                let start = index;
                while index + 1 < chars.len() && chars[index + 1] == '*' {
                    index += 1;
                }
                let component_start = start == 0 || chars[start - 1] == '/';
                let component_end = index + 1 == chars.len() || chars[index + 1] == '/';
                if index > start && component_start && component_end {
                    if index + 1 < chars.len() {
                        out.push_str("(?:[^/]+/)*");
                        index += 1;
                    } else {
                        out.push_str(".*");
                    }
                } else {
                    out.push_str("[^/]*");
                }
            }
            '?' => out.push_str("[^/]"),
            '[' => {
                out.push('[');
                index += 1;
                if chars.get(index).is_some_and(|v| matches!(v, '!' | '^')) {
                    out.push_str("^/");
                    index += 1;
                }
                let start = index;
                while index < chars.len() && chars[index] != ']' {
                    ensure!(
                        chars[index] != '/' && chars[index] != '[',
                        "unsupported glob class"
                    );
                    if chars[index] == '\\' {
                        index += 1;
                        let escaped = chars.get(index).context("unterminated glob escape")?;
                        ensure!(*escaped != '/', "glob class cannot match a path separator");
                        out.push_str(&regex::escape(&escaped.to_string()));
                    } else if chars[index] == '-' {
                        out.push('-');
                    } else {
                        out.push_str(&regex::escape(&chars[index].to_string()));
                    }
                    index += 1;
                }
                ensure!(
                    index < chars.len() && index > start,
                    "unterminated or empty glob class"
                );
                out.push(']');
            }
            '{' => {
                ensure!(braces == 0, "nested glob alternatives are unsupported");
                braces += 1;
                out.push_str("(?:");
            }
            '}' => {
                ensure!(braces == 1, "unmatched glob alternative");
                braces -= 1;
                out.push(')');
            }
            ',' if braces > 0 => out.push('|'),
            '\\' => {
                index += 1;
                let escaped = chars.get(index).context("unterminated glob escape")?;
                out.push_str(&regex::escape(&escaped.to_string()));
            }
            _ => out.push_str(&regex::escape(&c.to_string())),
        }
        index += 1;
    }
    ensure!(braces == 0, "unterminated glob alternative");
    out.push('$');
    Ok(regex::RegexBuilder::new(&out)
        .size_limit(1024 * 1024)
        .dfa_size_limit(1024 * 1024)
        .build()?)
}
