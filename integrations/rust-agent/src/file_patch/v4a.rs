use super::{Budget, PatchErrorKind as E, PatchLimits, PatchResult, check_text, err, fuzzy, trim};
use std::collections::{BTreeMap, BTreeSet};

type FileState = BTreeMap<String, Option<String>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationKind {
    Add,
    Update,
    Delete,
    Move,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HunkLine {
    pub prefix: char,
    pub content: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub context_hint: Option<String>,
    pub lines: Vec<HunkLine>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Operation {
    pub kind: OperationKind,
    pub path: String,
    pub new_path: Option<String>,
    pub hunks: Vec<Hunk>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileChange {
    pub path: String,
    pub before: Option<String>,
    pub after: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PatchPlan {
    pub changes: Vec<FileChange>,
    pub operations: Vec<Operation>,
    pub notes: Vec<String>,
    pub work_used: usize,
}

/// Canonical lexical identity only. The caller MUST also use a descriptor-confined
/// filesystem implementation; a valid spelling does not rule out symlinks or races.
pub fn relative_patch_path(path: &str) -> PatchResult<String> {
    let p = trim(path);
    if p.is_empty()
        || p.starts_with('/')
        || p.contains(['\\', '\0', '\r', '\n'])
        || p.ends_with('/')
        || p.ends_with("/.")
        || p.bytes().any(|b| b < 0x20)
        || p.as_bytes().get(1) == Some(&b':')
    {
        return Err(err(
            E::InvalidPath,
            "patch paths must be root-relative regular-file paths",
        ));
    }
    let mut parts = Vec::new();
    for part in p.split('/') {
        match part {
            ".." => {
                return Err(err(
                    E::InvalidPath,
                    "parent traversal is not allowed in patch paths",
                ));
            }
            "" | "." => {}
            _ => parts.push(part),
        }
    }
    if parts.is_empty() {
        return Err(err(E::InvalidPath, "patch path is empty"));
    }
    Ok(parts.join("/"))
}
fn marker(line: &str, first: &str) -> bool {
    let Some(s) = line.strip_prefix("***") else {
        return false;
    };
    let words: Vec<_> = s.split_whitespace().collect();
    words == [first, "Patch"]
}
fn parse_header(line: &str) -> Option<(OperationKind, &str)> {
    let rest = line.strip_prefix("***")?.trim_start();
    for (word, kind) in [
        ("Update", OperationKind::Update),
        ("Add", OperationKind::Add),
        ("Delete", OperationKind::Delete),
        ("Move", OperationKind::Move),
    ] {
        let Some(tail) = rest.strip_prefix(word) else {
            continue;
        };
        if tail.is_empty() || !tail.chars().next()?.is_whitespace() {
            continue;
        }
        if let Some(path) = tail.trim_start().strip_prefix("File:") {
            return Some((kind, trim(path)));
        }
    }
    None
}
fn flush(ops: &mut Vec<Operation>, current: &mut Option<Operation>, hunk: &mut Option<Hunk>) {
    if let Some(mut op) = current.take() {
        if let Some(h) = hunk.take()
            && !h.lines.is_empty()
        {
            op.hunks.push(h);
        }
        ops.push(op);
    }
}
/// Parse the Hermes V4A dialect (including standalone Move File: src -> dst).
/// Unknown operation headers and incomplete/nested envelopes fail closed rather
/// than being ignored as they can be by the more permissive upstream parser.
pub fn parse_v4a(patch: &str, limits: &PatchLimits) -> PatchResult<Vec<Operation>> {
    check_text(patch, limits.max_patch_bytes, limits)?;
    let lines: Vec<_> = patch
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();
    let mut begin = None;
    let mut end = None;
    for (i, line) in lines.iter().enumerate() {
        if marker(line, "Begin") {
            if begin.is_some() || end.is_some() {
                return Err(err(E::Malformed, "nested or multiple Begin Patch markers"));
            }
            begin = Some(i);
        } else if marker(line, "End") {
            if end.is_some() {
                return Err(err(E::Malformed, "multiple End Patch markers"));
            }
            end = Some(i);
        }
    }
    if begin.is_some() && end.is_none() {
        return Err(err(E::Malformed, "Begin Patch is missing End Patch"));
    }
    if begin.zip(end).is_some_and(|(b, e)| b >= e) {
        return Err(err(E::Malformed, "patch markers are out of order"));
    }
    let start = begin.map(|n| n + 1).unwrap_or(0);
    let finish = end.unwrap_or(lines.len());
    let mut ops = Vec::new();
    let mut current: Option<Operation> = None;
    let mut hunk: Option<Hunk> = None;
    let mut hunk_count = 0usize;
    for &line in &lines[start..finish] {
        if let Some((kind, path)) = parse_header(line) {
            flush(&mut ops, &mut current, &mut hunk);
            if ops.len() >= limits.max_operations {
                return Err(err(E::Limit, "patch operation limit exceeded"));
            }
            let (path, new_path) = if kind == OperationKind::Move {
                let (src, dst) = path
                    .split_once("->")
                    .ok_or_else(|| err(E::Malformed, "Move File requires source -> destination"))?;
                (relative_patch_path(src)?, Some(relative_patch_path(dst)?))
            } else {
                (relative_patch_path(path)?, None)
            };
            current = Some(Operation {
                kind,
                path,
                new_path,
                hunks: vec![],
            });
            if matches!(kind, OperationKind::Delete | OperationKind::Move) {
                flush(&mut ops, &mut current, &mut hunk);
            } else if kind == OperationKind::Add {
                hunk = Some(Hunk {
                    context_hint: None,
                    lines: vec![],
                });
                hunk_count += 1;
            }
        } else if line.starts_with("***") {
            return Err(err(
                E::Malformed,
                format!("unknown patch operation header: {line}"),
            ));
        } else if let Some(rest) = line.strip_prefix("@@") {
            if let Some(op) = current.as_mut() {
                if let Some(h) = hunk.take()
                    && !h.lines.is_empty()
                {
                    op.hunks.push(h);
                }
                let hint = rest
                    .find("@@")
                    .map(|n| trim(&rest[..n]).to_owned())
                    .filter(|s| !s.is_empty());
                hunk = Some(Hunk {
                    context_hint: hint,
                    lines: vec![],
                });
                hunk_count += 1;
            }
        } else if current.is_some() && !line.is_empty() {
            if hunk.is_none() {
                hunk = Some(Hunk {
                    context_hint: None,
                    lines: vec![],
                });
                hunk_count += 1;
            }
            let first = line.chars().next().unwrap();
            if first != '\\' {
                let (prefix, content) = if matches!(first, '+' | '-' | ' ') {
                    (first, &line[1..])
                } else {
                    (' ', line)
                };
                hunk.as_mut().unwrap().lines.push(HunkLine {
                    prefix,
                    content: content.into(),
                });
            }
        }
        if hunk_count > limits.max_hunks {
            return Err(err(E::Limit, "patch hunk limit exceeded"));
        }
    }
    flush(&mut ops, &mut current, &mut hunk);
    if ops.len() > limits.max_operations {
        return Err(err(E::Limit, "patch operation limit exceeded"));
    }
    for op in &ops {
        if op.kind == OperationKind::Update && op.hunks.is_empty() {
            return Err(err(
                E::Malformed,
                format!("UPDATE {}: no hunks found", op.path),
            ));
        }
    }
    Ok(ops)
}
fn split_hunk(hunk: &Hunk) -> (Vec<&str>, Vec<&str>) {
    (
        hunk.lines
            .iter()
            .filter(|l| l.prefix != '+')
            .map(|l| l.content.as_str())
            .collect(),
        hunk.lines
            .iter()
            .filter(|l| l.prefix != '-')
            .map(|l| l.content.as_str())
            .collect(),
    )
}
fn content<'a>(state: &'a BTreeMap<String, Option<String>>, path: &str) -> PatchResult<&'a str> {
    state
        .get(path)
        .ok_or_else(|| {
            err(
                E::MissingSnapshot,
                format!("no explicit read/absence snapshot for {path}"),
            )
        })?
        .as_deref()
        .ok_or_else(|| err(E::MissingFile, format!("file not found: {path}")))
}
fn absent(state: &BTreeMap<String, Option<String>>, path: &str) -> PatchResult<()> {
    match state.get(path) {
        Some(None) => Ok(()),
        Some(Some(_)) => Err(err(
            E::Occupied,
            format!("destination already exists: {path}"),
        )),
        None => Err(err(
            E::MissingSnapshot,
            format!("no explicit absence snapshot for {path}"),
        )),
    }
}
fn hint_position(content: &str, hint: &str, budget: &mut Budget) -> PatchResult<usize> {
    budget.charge(content.len().saturating_add(hint.len()))?;
    let mut found = None;
    let mut cursor = 0;
    while let Some(relative) = content[cursor..].find(hint) {
        budget.charge(content.len() - cursor + hint.len())?;
        let at = cursor + relative;
        if found.is_some() {
            return Err(err(
                E::Ambiguous,
                "addition-only hunk context hint is ambiguous",
            ));
        }
        found = Some(at);
        cursor = at
            + content[at..]
                .chars()
                .next()
                .map(char::len_utf8)
                .unwrap_or(1);
        if cursor >= content.len() {
            break;
        }
    }
    found.ok_or_else(|| err(E::NoMatch, "addition-only hunk context hint was not found"))
}
fn addition(
    content: &str,
    hunk: &Hunk,
    replacement: &str,
    limits: &PatchLimits,
    budget: &mut Budget,
) -> PatchResult<String> {
    let mut out = String::new();
    if let Some(hint) = hunk.context_hint.as_deref().filter(|s| !s.is_empty()) {
        let pos = hint_position(content, hint, budget)?;
        if let Some(n) = content[pos..].find('\n') {
            let end = pos + n + 1;
            fuzzy::append_bounded(&mut out, &content[..end], limits.max_file_bytes)?;
            fuzzy::append_bounded(&mut out, replacement, limits.max_file_bytes)?;
            fuzzy::append_bounded(&mut out, "\n", limits.max_file_bytes)?;
            fuzzy::append_bounded(&mut out, &content[end..], limits.max_file_bytes)?;
        } else {
            fuzzy::append_bounded(&mut out, content, limits.max_file_bytes)?;
            fuzzy::append_bounded(&mut out, "\n", limits.max_file_bytes)?;
            fuzzy::append_bounded(&mut out, replacement, limits.max_file_bytes)?;
        }
    } else {
        fuzzy::append_bounded(
            &mut out,
            content.trim_end_matches('\n'),
            limits.max_file_bytes,
        )?;
        fuzzy::append_bounded(&mut out, "\n", limits.max_file_bytes)?;
        fuzzy::append_bounded(&mut out, replacement, limits.max_file_bytes)?;
        fuzzy::append_bounded(&mut out, "\n", limits.max_file_bytes)?;
    }
    Ok(out)
}
fn update(
    current: &str,
    op: &Operation,
    validation: bool,
    limits: &PatchLimits,
    budget: &mut Budget,
    notes: &mut Vec<String>,
) -> PatchResult<(String, bool)> {
    let mut text = current.to_owned();
    let mut real = false;
    for h in &op.hunks {
        let (search, replacement) = split_hunk(h);
        if search == replacement {
            real |= h.lines.iter().any(|l| matches!(l.prefix, '+' | '-'));
            continue;
        }
        real = true;
        let old = search.join("\n");
        let new = replacement.join("\n");
        if search.is_empty() {
            if validation {
                if let Some(hint) = h.context_hint.as_deref().filter(|s| !s.is_empty()) {
                    hint_position(&text, hint, budget)?;
                }
            } else {
                text = addition(&text, h, &new, limits, budget)?;
            }
            continue;
        }
        match fuzzy::replace_budget(&text, &old, &new, false, limits, budget) {
            Ok(plan) => {
                text = plan.content;
                notes.extend(plan.notes);
            }
            Err(e) => {
                if e.kind == E::Limit || !fuzzy::already_applied(&text, &old, &new) {
                    return Err(e);
                }
            }
        }
    }
    Ok((text, real))
}
fn simulate(
    ops: &[Operation],
    initial: &BTreeMap<String, Option<String>>,
    validation: bool,
    limits: &PatchLimits,
    budget: &mut Budget,
) -> PatchResult<(FileState, Vec<String>)> {
    let mut state = initial.clone();
    let mut real = false;
    let mut notes = Vec::new();
    for op in ops {
        budget.charge(1)?;
        match op.kind {
            OperationKind::Update => {
                let (text, change) = update(
                    content(&state, &op.path)?,
                    op,
                    validation,
                    limits,
                    budget,
                    &mut notes,
                )?;
                state.insert(op.path.clone(), Some(text));
                real |= change;
            }
            OperationKind::Add => {
                absent(&state, &op.path)?;
                let mut text = String::new();
                let mut first = true;
                for line in op
                    .hunks
                    .iter()
                    .flat_map(|h| &h.lines)
                    .filter(|l| l.prefix == '+')
                {
                    if !first {
                        fuzzy::append_bounded(&mut text, "\n", limits.max_file_bytes)?;
                    }
                    fuzzy::append_bounded(&mut text, &line.content, limits.max_file_bytes)?;
                    first = false;
                }
                state.insert(op.path.clone(), Some(text));
                real = true;
            }
            OperationKind::Delete => {
                content(&state, &op.path)?;
                state.insert(op.path.clone(), None);
                real = true;
            }
            OperationKind::Move => {
                let dst = op
                    .new_path
                    .as_deref()
                    .ok_or_else(|| err(E::Malformed, "move destination missing"))?;
                absent(&state, dst)?;
                let text = content(&state, &op.path)?.to_owned();
                state.insert(dst.into(), Some(text));
                state.insert(op.path.clone(), None);
                real = true;
            }
        }
        let total: usize = state
            .values()
            .filter_map(|v| v.as_ref())
            .map(|v| v.len())
            .sum();
        if total > limits.max_total_bytes {
            return Err(err(E::Limit, "patch total byte limit exceeded"));
        }
    }
    if !real {
        return Err(err(
            E::NoChanges,
            "Patch contains no changes (only context lines were provided)",
        ));
    }
    Ok((state, notes))
}
/// Plan a multi-file operation without touching disk. Every target, including
/// Add/Move destinations, needs an explicit `Some(content)` or `None` snapshot.
/// Missing map entries and read errors MUST NOT be treated as nonexistent files.
/// Returned `before` values bind the approval preview and stale-state check.
pub fn plan_v4a(
    patch: &str,
    snapshots: &BTreeMap<String, Option<String>>,
    limits: &PatchLimits,
) -> PatchResult<PatchPlan> {
    let operations = parse_v4a(patch, limits)?;
    let mut budget = Budget::new(limits);
    budget.charge(patch.len())?;
    let mut wanted = BTreeSet::new();
    for op in &operations {
        wanted.insert(op.path.clone());
        if let Some(p) = &op.new_path {
            wanted.insert(p.clone());
        }
    }
    let mut initial = BTreeMap::new();
    let mut total = 0usize;
    for path in wanted {
        let value = snapshots.get(&path).ok_or_else(|| {
            err(
                E::MissingSnapshot,
                format!("no explicit snapshot for {path}"),
            )
        })?;
        if let Some(text) = value {
            check_text(text, limits.max_file_bytes, limits)?;
            total = total.saturating_add(text.len());
            budget.charge(text.len())?;
        }
        if total > limits.max_total_bytes {
            return Err(err(E::Limit, "patch snapshot byte limit exceeded"));
        }
        initial.insert(path, value.clone());
    }
    // Match upstream two-phase acceptance, including validation's conservative
    // addition-only handling. Validation never returns a partial executable plan.
    simulate(&operations, &initial, true, limits, &mut budget)?;
    let (after, notes) = simulate(&operations, &initial, false, limits, &mut budget)?;
    let changes = after
        .into_iter()
        .filter_map(|(path, after)| {
            let before = initial[&path].clone();
            if before == after {
                None
            } else {
                Some(FileChange {
                    path,
                    before,
                    after,
                })
            }
        })
        .collect();
    let mut unique = Vec::new();
    for note in notes {
        if !unique.contains(&note) {
            unique.push(note);
        }
    }
    Ok(PatchPlan {
        changes,
        operations,
        notes: unique,
        work_used: budget.used(),
    })
}
