use super::{
    Budget, PatchErrorKind as E, PatchLimits, PatchResult, check_text, err, py_space, sequence,
    trim,
};
use std::collections::BTreeMap;

type Span = (usize, usize); // UTF-8 byte offsets, always on character boundaries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strategy {
    Exact,
    LineTrimmed,
    WhitespaceNormalized,
    IndentationFlexible,
    EscapeNormalized,
    TrimmedBoundary,
    UnicodeNormalized,
    BlockAnchor,
    ContextAware,
}
impl Strategy {
    pub fn name(self) -> &'static str {
        match self {
            Self::Exact => "exact",
            Self::LineTrimmed => "line_trimmed",
            Self::WhitespaceNormalized => "whitespace_normalized",
            Self::IndentationFlexible => "indentation_flexible",
            Self::EscapeNormalized => "escape_normalized",
            Self::TrimmedBoundary => "trimmed_boundary",
            Self::UnicodeNormalized => "unicode_normalized",
            Self::BlockAnchor => "block_anchor",
            Self::ContextAware => "context_aware",
        }
    }
    pub fn approximate(self) -> bool {
        matches!(self, Self::BlockAnchor | Self::ContextAware)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplacementPlan {
    pub content: String,
    pub match_count: usize,
    pub strategy: Strategy,
    pub notes: Vec<String>,
    pub work_used: usize,
}
const PRECISE: [Strategy; 7] = [
    Strategy::Exact,
    Strategy::LineTrimmed,
    Strategy::WhitespaceNormalized,
    Strategy::IndentationFlexible,
    Strategy::EscapeNormalized,
    Strategy::TrimmedBoundary,
    Strategy::UnicodeNormalized,
];

pub fn plan_replace(
    content: &str,
    old: &str,
    new: &str,
    replace_all: bool,
    limits: &PatchLimits,
) -> PatchResult<ReplacementPlan> {
    let mut budget = Budget::new(limits);
    let mut plan = replace_budget(content, old, new, replace_all, limits, &mut budget)?;
    plan.work_used = budget.used();
    Ok(plan)
}
pub(super) fn replace_budget(
    content: &str,
    old: &str,
    new: &str,
    all: bool,
    limits: &PatchLimits,
    budget: &mut Budget,
) -> PatchResult<ReplacementPlan> {
    check_text(content, limits.max_file_bytes, limits)?;
    check_text(old, limits.max_patch_bytes, limits)?;
    check_text(new, limits.max_patch_bytes, limits)?;
    budget.charge(
        content
            .len()
            .saturating_add(old.len())
            .saturating_add(new.len()),
    )?;
    if trim(old).is_empty() {
        return Err(err(
            E::InvalidInput,
            "old_string must contain non-blank text; read the file and provide an existing span",
        ));
    }
    let (old, new, correction) = correct_escapes(content, old, new)?;
    if old == new {
        return Err(err(E::NoChanges, "old_string and new_string are identical"));
    }
    let mut result = run_chain(content, &old, &new, all, &PRECISE, limits, budget)?;
    if result.is_none() {
        if let Some(stripped) =
            strip_gutter(&old, 1).filter(|v| !trim(v).is_empty() && !has_gutter(content))
        {
            let replacement = match strip_gutter(&new, 1) {
                Some(s) => s,
                None if has_gutter(&new) => {
                    return Err(err(
                        E::InvalidInput,
                        "replacement line-number gutter is incomplete or not consecutive; resend without N| prefixes",
                    ));
                }
                None => new.clone(),
            };
            if stripped == replacement {
                return Err(err(
                    E::NoChanges,
                    "gutter-stripped old_string and new_string are identical",
                ));
            }
            let strategies: &[Strategy] = if strip_gutter(&old, 2).is_some() {
                &PRECISE
            } else {
                &[Strategy::LineTrimmed]
            };
            result = run_chain(
                content,
                &stripped,
                &replacement,
                all,
                strategies,
                limits,
                budget,
            )?;
            if let Some(plan) = &mut result {
                plan.notes.push(
                    "Removed consecutive read_file N| line-number prefixes before matching.".into(),
                );
            }
        } else {
            result = run_chain(
                content,
                &old,
                &new,
                all,
                &[Strategy::BlockAnchor, Strategy::ContextAware],
                limits,
                budget,
            )?;
        }
    }
    let mut plan = result.ok_or_else(|| {
        err(
            E::NoMatch,
            "Could not find a match for old_string in the file",
        )
    })?;
    if let Some(note) = correction {
        plan.notes.push(note);
    }
    Ok(plan)
}
fn run_chain(
    content: &str,
    old: &str,
    new: &str,
    all: bool,
    strategies: &[Strategy],
    limits: &PatchLimits,
    budget: &mut Budget,
) -> PatchResult<Option<ReplacementPlan>> {
    for &strategy in strategies {
        let spans = find_spans(content, old, strategy, budget)?;
        if spans.is_empty() {
            continue;
        }
        if spans.len() > 1 && (!all || strategy.approximate()) {
            return Err(err(
                E::Ambiguous,
                format!(
                    "Found {} {}matches; provide unique context{}",
                    spans.len(),
                    if strategy.approximate() {
                        "approximate "
                    } else {
                        ""
                    },
                    if all {
                        " (replace_all cannot apply multiple approximate matches)"
                    } else {
                        " or replace_all for precise matches"
                    }
                ),
            ));
        }
        // Upstream may return overlapping normalized line windows. Refuse them
        // rather than splice a later offset into already-modified bytes.
        if spans.windows(2).any(|pair| pair[0].1 > pair[1].0) {
            return Err(err(
                E::Overlap,
                "normalized match spans overlap; provide a non-overlapping exact anchor",
            ));
        }
        if strategy != Strategy::Exact {
            check_escape_drift(content, &spans, old, new)?;
        }
        let mut effective = new.to_owned();
        for (literal, control) in [("\\t", "\t"), ("\\r", "\r")] {
            if effective.contains(literal)
                && spans.iter().any(|&(s, e)| content[s..e].contains(control))
            {
                effective = effective.replace(literal, control);
            }
        }
        let unicode_blocks = if strategy == Strategy::UnicodeNormalized {
            let normalized = normalize_unicode(old);
            Some((
                normalized.clone(),
                sequence::blocks(
                    &normalized.chars().collect::<Vec<_>>(),
                    &effective.chars().collect::<Vec<_>>(),
                    budget,
                )?,
            ))
        } else {
            None
        };
        let removed: usize = spans.iter().map(|(start, end)| end - start).sum();
        let capacity = content
            .len()
            .saturating_sub(removed)
            .saturating_add(effective.len().saturating_mul(spans.len()))
            .min(limits.max_file_bytes);
        let mut output = String::with_capacity(capacity);
        let mut cursor = 0;
        for &(start, end) in &spans {
            let region = &content[start..end];
            let mut replacement = if let Some((norm, blocks)) = &unicode_blocks {
                preserve_unicode(region, &effective, norm, blocks, limits.max_file_bytes)?
            } else {
                effective.clone()
            };
            if strategy != Strategy::Exact {
                replacement = reindent(
                    content,
                    start,
                    end,
                    old,
                    &replacement,
                    limits.max_file_bytes,
                )?;
            }
            append_bounded(&mut output, &content[cursor..start], limits.max_file_bytes)?;
            append_bounded(&mut output, &replacement, limits.max_file_bytes)?;
            cursor = end;
        }
        append_bounded(&mut output, &content[cursor..], limits.max_file_bytes)?;
        let notes = if strategy.approximate() {
            vec![format!(
                "Non-exact match (strategy: {}): review the change boundaries; the matched lines only approximately resemble old_string.",
                strategy.name()
            )]
        } else {
            vec![]
        };
        return Ok(Some(ReplacementPlan {
            content: output,
            match_count: spans.len(),
            strategy,
            notes,
            work_used: 0,
        }));
    }
    Ok(None)
}
pub(super) fn append_bounded(out: &mut String, s: &str, limit: usize) -> PatchResult<()> {
    if out.len().saturating_add(s.len()) > limit {
        return Err(err(
            E::Limit,
            "replacement exceeds configured file byte limit",
        ));
    }
    out.push_str(s);
    Ok(())
}
fn exact(content: &str, pattern: &str, budget: &mut Budget) -> PatchResult<Vec<Span>> {
    budget.charge(content.len().saturating_add(pattern.len()))?;
    Ok(content
        .match_indices(pattern)
        .map(|(i, s)| (i, i + s.len()))
        .collect())
}
fn lines(content: &str) -> (Vec<&str>, Vec<usize>) {
    let lines: Vec<_> = content.split('\n').collect();
    let mut offset = 0;
    let positions = lines
        .iter()
        .map(|line| {
            let at = offset;
            offset += line.len() + 1;
            at
        })
        .collect();
    (lines, positions)
}
fn line_matches(
    content: &str,
    pattern: &str,
    strategy: Strategy,
    budget: &mut Budget,
) -> PatchResult<Vec<Span>> {
    let (c, offsets) = lines(content);
    let p: Vec<_> = pattern.split('\n').collect();
    let n = p.len();
    if n > c.len() {
        return Ok(vec![]);
    }
    let transform = |line: &str, boundary: bool| -> String {
        match strategy {
            Strategy::IndentationFlexible => line.trim_start_matches(py_space).to_owned(),
            Strategy::TrimmedBoundary if !boundary => line.to_owned(),
            _ => trim(line).to_owned(),
        }
    };
    let p: Vec<_> = p
        .iter()
        .enumerate()
        .map(|(j, l)| transform(l, j == 0 || j + 1 == n))
        .collect();
    let mut result = Vec::new();
    for i in 0..=c.len() - n {
        let mut matched = true;
        for j in 0..n {
            budget.charge(c[i + j].len().saturating_add(p[j].len()).saturating_add(1))?;
            let actual = match strategy {
                Strategy::IndentationFlexible => c[i + j].trim_start_matches(py_space),
                Strategy::TrimmedBoundary if j != 0 && j + 1 != n => c[i + j],
                _ => trim(c[i + j]),
            };
            if actual != p[j] {
                matched = false;
                break;
            }
        }
        if matched {
            result.push((offsets[i], offsets[i + n - 1] + c[i + n - 1].len()));
        }
    }
    Ok(result)
}
fn collapse_spaces(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for c in s.chars() {
        if c == ' ' || c == '\t' {
            if !space {
                out.push(' ');
            }
            space = true;
        } else {
            space = false;
            out.push(c);
        }
    }
    out
}
fn whitespace_spans(content: &str, pattern: &str, budget: &mut Budget) -> PatchResult<Vec<Span>> {
    let normalized = collapse_spaces(content);
    let pattern = collapse_spaces(pattern);
    let hits = exact(&normalized, &pattern, budget)?;
    if hits.is_empty() {
        return Ok(hits);
    }
    // Preserve the upstream mapper's boundary choices, including its treatment
    // of extra whitespace immediately before a normalized match.
    let original: Vec<char> = content.chars().collect();
    let norm: Vec<char> = normalized.chars().collect();
    let original_bytes: Vec<usize> = content
        .char_indices()
        .map(|(i, _)| i)
        .chain([content.len()])
        .collect();
    let norm_bytes: Vec<usize> = normalized
        .char_indices()
        .map(|(i, _)| i)
        .chain([normalized.len()])
        .collect();
    let mut map = Vec::with_capacity(original.len());
    let (mut i, mut j) = (0, 0);
    while i < original.len() && j < norm.len() {
        map.push(j);
        if original[i] == norm[j] {
            i += 1;
            j += 1;
        } else if matches!(original[i], ' ' | '\t') && norm[j] == ' ' {
            i += 1;
            if i < original.len() && !matches!(original[i], ' ' | '\t') {
                j += 1;
            }
        } else {
            i += 1;
        }
    }
    map.resize(original.len(), norm.len());
    let mut first = BTreeMap::new();
    let mut last = BTreeMap::new();
    for (i, n) in map.iter().copied().enumerate() {
        first.entry(n).or_insert(i);
        last.insert(n, i);
    }
    let mut out = Vec::new();
    for (s, e) in hits {
        let ns = norm_bytes.binary_search(&s).unwrap();
        let ne = norm_bytes.binary_search(&e).unwrap();
        let start = *first.range(ns..).next().unwrap().1;
        let mut end = last
            .get(&(ne - 1))
            .map(|v| v + 1)
            .unwrap_or(start + ne - ns);
        if ne < norm.len() && norm[ne - 1] == ' ' {
            while end < original.len() && matches!(original[end], ' ' | '\t') {
                end += 1;
            }
        }
        out.push((
            original_bytes[start],
            original_bytes[end.min(original.len())],
        ));
    }
    Ok(out)
}
pub(super) fn normalize_unicode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        out.push_str(match ch {
            '\u{201c}' | '\u{201d}' => "\"",
            '\u{2018}' | '\u{2019}' => "'",
            '\u{2014}' => "--",
            '\u{2013}' | '\u{2212}' => "-",
            '\u{2026}' => "...",
            '\u{a0}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}' => " ",
            _ => {
                out.push(ch);
                continue;
            }
        });
    }
    out
}
fn unicode_map(s: &str) -> (Vec<usize>, Vec<usize>) {
    let mut norm = Vec::new();
    let mut bytes = Vec::new();
    let mut n = 0;
    for (i, c) in s.char_indices() {
        norm.push(n);
        bytes.push(i);
        n += normalize_unicode(&c.to_string()).chars().count();
    }
    norm.push(n);
    bytes.push(s.len());
    (norm, bytes)
}
fn unicode_spans(content: &str, pattern: &str, budget: &mut Budget) -> PatchResult<Vec<Span>> {
    let c = normalize_unicode(content);
    let p = normalize_unicode(pattern);
    if c == content && p == pattern {
        return Ok(vec![]);
    }
    let mut hits = exact(&c, &p, budget)?;
    if hits.is_empty() {
        hits = line_matches(&c, &p, Strategy::LineTrimmed, budget)?;
    }
    let norm_bytes: Vec<_> = c.char_indices().map(|(i, _)| i).chain([c.len()]).collect();
    let (map, bytes) = unicode_map(content);
    let mut out = Vec::new();
    for (s, e) in hits {
        let ns = norm_bytes.binary_search(&s).unwrap();
        let ne = norm_bytes.binary_search(&e).unwrap();
        if let Ok(start) = map[..map.len() - 1].binary_search(&ns) {
            let end = map.partition_point(|v| *v < ne);
            out.push((bytes[start], bytes[end]));
        }
    }
    Ok(out)
}
pub(super) fn find_spans(
    content: &str,
    pattern: &str,
    strategy: Strategy,
    budget: &mut Budget,
) -> PatchResult<Vec<Span>> {
    budget.charge(content.len().saturating_add(pattern.len()))?;
    match strategy {
        Strategy::Exact => exact(content, pattern, budget),
        Strategy::LineTrimmed | Strategy::IndentationFlexible | Strategy::TrimmedBoundary => {
            line_matches(content, pattern, strategy, budget)
        }
        Strategy::WhitespaceNormalized => whitespace_spans(content, pattern, budget),
        Strategy::EscapeNormalized => {
            let p = pattern
                .replace("\\n", "\n")
                .replace("\\t", "\t")
                .replace("\\r", "\r");
            if p == pattern {
                Ok(vec![])
            } else {
                exact(content, &p, budget)
            }
        }
        Strategy::UnicodeNormalized => unicode_spans(content, pattern, budget),
        Strategy::BlockAnchor | Strategy::ContextAware => {
            similarity_spans(content, pattern, strategy, budget)
        }
    }
}
fn similarity_spans(
    content: &str,
    pattern: &str,
    strategy: Strategy,
    budget: &mut Budget,
) -> PatchResult<Vec<Span>> {
    let normalized_c;
    let normalized_p;
    let (c, p) = if strategy == Strategy::BlockAnchor {
        normalized_c = normalize_unicode(content);
        normalized_p = normalize_unicode(pattern);
        (normalized_c.as_str(), normalized_p.as_str())
    } else {
        (content, pattern)
    };
    let (c, _) = lines(c);
    let (p, _) = lines(p);
    let (original, offsets) = lines(content);
    let n = p.len();
    if n > c.len() || (strategy == Strategy::BlockAnchor && n < 2) {
        return Ok(vec![]);
    }
    let mut potential = Vec::new();
    if strategy == Strategy::BlockAnchor {
        for i in 0..=c.len() - n {
            budget.charge(c[i].len() + c[i + n - 1].len() + p[0].len() + p[n - 1].len() + 1)?;
            if trim(c[i]) == trim(p[0]) && trim(c[i + n - 1]) == trim(p[n - 1]) {
                potential.push(i);
            }
        }
    } else {
        potential.extend(0..=c.len() - n);
    }
    let threshold = if potential.len() == 1 { 0.50 } else { 0.70 };
    let middle = p[1..n.saturating_sub(1).max(1)].join("\n");
    let mut out = Vec::new();
    for i in potential {
        let matched = if strategy == Strategy::BlockAnchor {
            n <= 2
                || sequence::ratio(&c[i + 1..i + n - 1].join("\n"), &middle, budget)? >= threshold
        } else {
            if sequence::ratio(trim(p[0]), trim(c[i]), budget)? < 0.80
                || sequence::ratio(trim(p[n - 1]), trim(c[i + n - 1]), budget)? < 0.80
            {
                continue;
            }
            let mut good = true;
            for j in 0..n {
                if !trim(p[j]).is_empty()
                    && sequence::ratio(trim(p[j]), trim(c[i + j]), budget)? < 0.80
                {
                    good = false;
                    break;
                }
            }
            good
        };
        if matched {
            out.push((offsets[i], offsets[i + n - 1] + original[i + n - 1].len()));
        }
    }
    Ok(out)
}
fn leading(s: &str) -> &str {
    &s[..s.len() - s.trim_start_matches([' ', '\t']).len()]
}
fn reindent(
    content: &str,
    start: usize,
    end: usize,
    old: &str,
    new: &str,
    limit: usize,
) -> PatchResult<String> {
    if new.is_empty() {
        return Ok(new.into());
    }
    let region = &content[start..end];
    let mut at = start;
    for line in region.split('\n') {
        if !trim(line).is_empty() {
            let line_start = content[..at].rfind('\n').map(|n| n + 1).unwrap_or(0);
            if !content[line_start..at]
                .trim_matches([' ', '\t', '\r'])
                .is_empty()
            {
                return Ok(new.into());
            }
            break;
        }
        at += line.len() + 1;
    }
    let Some(o) = old.split('\n').find(|l| !trim(l).is_empty()) else {
        return Ok(new.into());
    };
    let Some(f) = region.split('\n').find(|l| !trim(l).is_empty()) else {
        return Ok(new.into());
    };
    let oi = leading(o);
    let fi = leading(f);
    if oi == fi {
        return Ok(new.into());
    }
    let mut out = String::new();
    for (i, l) in new.split('\n').enumerate() {
        if i > 0 {
            append_bounded(&mut out, "\n", limit)?;
        }
        if trim(l).is_empty() {
            append_bounded(&mut out, l, limit)?;
        } else {
            append_bounded(&mut out, fi, limit)?;
            append_bounded(
                &mut out,
                if leading(l).starts_with(oi) {
                    &l[oi.len()..]
                } else {
                    l.trim_start_matches([' ', '\t'])
                },
                limit,
            )?;
        }
    }
    Ok(out)
}
fn preserve_unicode(
    region: &str,
    new: &str,
    norm_old: &str,
    blocks: &[(usize, usize, usize)],
    limit: usize,
) -> PatchResult<String> {
    if normalize_unicode(region) != norm_old {
        return Ok(new.into());
    }
    let (map, bytes) = unicode_map(region);
    let nb: Vec<_> = new
        .char_indices()
        .map(|(i, _)| i)
        .chain([new.len()])
        .collect();
    let mut out = String::new();
    let mut j = 0;
    for &(ai, bj, size) in blocks {
        if j < bj {
            append_bounded(&mut out, &new[nb[j]..nb[bj]], limit)?;
        }
        if size > 0 {
            let os = map.partition_point(|p| *p <= ai).saturating_sub(1);
            let oe = map.partition_point(|p| *p < ai + size);
            append_bounded(&mut out, &region[bytes[os]..bytes[oe]], limit)?;
        }
        j = bj + size;
    }
    Ok(out)
}
fn gutter(line: &str) -> Option<(u128, &str)> {
    let n = line.bytes().take_while(u8::is_ascii_digit).count();
    if n == 0 || line.as_bytes().get(n) != Some(&b'|') {
        return None;
    }
    Some((line[..n].parse().ok()?, &line[n + 1..]))
}
fn has_gutter(s: &str) -> bool {
    s.split('\n').any(|l| gutter(l).is_some())
}
fn strip_gutter(s: &str, min: usize) -> Option<String> {
    let mut expected = None;
    let mut numbered = 0;
    let mut out = Vec::new();
    for line in s.split('\n') {
        let l = if let Some((n, rest)) = gutter(line) {
            if expected.is_some_and(|v| v != n) {
                return None;
            }
            expected = Some(n);
            numbered += 1;
            rest
        } else {
            if !trim(line).is_empty() {
                return None;
            }
            line
        };
        if let Some(n) = expected {
            expected = Some(n.checked_add(1)?);
        }
        out.push(l);
    }
    if numbered >= min {
        Some(out.join("\n"))
    } else {
        None
    }
}
fn runs(s: &str) -> Vec<usize> {
    let mut out = Vec::new();
    let mut n = 0;
    for c in s.chars() {
        if c == '\\' {
            n += 1;
        } else if n > 0 {
            out.push(n);
            n = 0;
        }
    }
    if n > 0 {
        out.push(n);
    }
    out
}
fn strip_quotes(s: &str) -> String {
    s.replace("\\'", "'").replace("\\\"", "\"")
}
fn quotes_spurious(old: &str, new: &str) -> bool {
    for q in ['\'', '"'] {
        let suspect = format!("\\{q}");
        if !old.contains(&suspect) && !new.contains(&suspect) {
            continue;
        }
        for s in [old, new] {
            let mut n = 0;
            for c in s.chars() {
                if c == q && n != 1 {
                    return false;
                }
                if c == '\\' {
                    n += 1;
                } else {
                    n = 0;
                }
            }
        }
    }
    true
}
fn correct_escapes(
    content: &str,
    old: &str,
    new: &str,
) -> PatchResult<(String, String, Option<String>)> {
    if old.contains('\\') && !content.contains(old) {
        let quote_suspect = ["\\'", "\\\""]
            .iter()
            .any(|q| old.contains(q) && new.contains(q));
        if quote_suspect && quotes_spurious(old, new) {
            let stripped = strip_quotes(old);
            if content.contains(&stripped) {
                if ["\\'", "\\\""]
                    .iter()
                    .any(|q| new.contains(q) && !old.contains(q))
                {
                    return Err(err(
                        E::EscapeDrift,
                        "new_string escapes a quote kind not verified by old_string; resend intended escaping",
                    ));
                }
                return Ok((
                    stripped,
                    strip_quotes(new),
                    Some("Corrected verified spurious quote escaping before matching.".into()),
                ));
            }
        }
        let rs = runs(old);
        if !rs.is_empty() && rs.iter().all(|n| n % 2 == 0) {
            let mut halved = String::with_capacity(old.len());
            let mut n = 0;
            for c in old.chars() {
                if c == '\\' {
                    n += 1;
                    if n % 2 == 0 {
                        halved.push(c);
                    }
                } else {
                    n = 0;
                    halved.push(c);
                }
            }
            if content.contains(&halved) {
                if new.contains('\\') {
                    return Err(err(
                        E::EscapeDrift,
                        "halving old_string backslashes matches, but replacement backslashes are ambiguous; resend intended escaping",
                    ));
                }
                return Ok((halved,new.into(),Some("Halved verified doubled old_string backslash runs; replacement was unchanged.".into())));
            }
        }
    }
    Ok((old.into(), new.into(), None))
}
fn check_escape_drift(content: &str, spans: &[Span], old: &str, new: &str) -> PatchResult<()> {
    let regions: String = spans.iter().map(|&(s, e)| &content[s..e]).collect();
    for q in ["\\'", "\\\""] {
        if new.contains(q) && old.contains(q) && !regions.contains(q) {
            return Err(err(
                E::EscapeDrift,
                "unverified escaped quote drift; resend the file's intended escaping",
            ));
        }
    }
    if new.contains("\\n")
        && spans.iter().any(|&(s, e)| {
            let r = &content[s..e];
            r.contains('\n') && old.matches("\\n").count() > r.matches("\\n").count()
        })
    {
        return Err(err(
            E::EscapeDrift,
            "literal backslash-n would replace real line breaks; resend with actual newlines",
        ));
    }
    let o = runs(old);
    let f = runs(&regions);
    if !o.is_empty()
        && !f.is_empty()
        && o.len() == f.len()
        && o != f
        && o.iter().zip(&f).all(|(o, f)| *o == *f * 2)
        && (f.iter().any(|n| *n >= 2) || f.len() >= 2)
        && runs(new) != f
    {
        return Err(err(
            E::EscapeDrift,
            "unverified doubled backslash drift; resend intended escaping",
        ));
    }
    Ok(())
}
pub(super) fn already_applied(content: &str, old: &str, new: &str) -> bool {
    trim(new).chars().count() >= 8
        && content.contains(new)
        && (old == new || !content.contains(old))
}
