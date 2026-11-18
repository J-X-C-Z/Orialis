//! Bounded, filesystem-free planning for Hermes replace and V4A patches.
//!
//! Based on upstream Hermes `tools/fuzzy_match.py`, `escape_drift_autocorrect.py`
//! and `patch_parser.py` at the pinned revision recorded in FILE_PATCH.md.
//! A plan is NOT authorization. The caller must acquire complete read snapshots,
//! authorize the complete resulting change, and revalidate every snapshot before
//! committing through its confined filesystem backend. No shell or I/O lives here.

#[path = "file_patch/fuzzy.rs"]
mod fuzzy;
#[path = "file_patch/sequence.rs"]
mod sequence;
#[path = "file_patch/v4a.rs"]
mod v4a;

pub use fuzzy::{ReplacementPlan, Strategy, plan_replace};
pub use v4a::{
    FileChange, Hunk, HunkLine, Operation, OperationKind, PatchPlan, parse_v4a, plan_v4a,
};

use std::fmt;

#[derive(Clone, Copy, Debug)]
pub struct PatchLimits {
    pub max_file_bytes: usize,
    pub max_patch_bytes: usize,
    pub max_total_bytes: usize,
    pub max_lines: usize,
    pub max_operations: usize,
    pub max_hunks: usize,
    /// Deterministic upper bound on comparison/scan work, not a wall-clock timeout.
    pub max_work: usize,
}
impl Default for PatchLimits {
    fn default() -> Self {
        Self {
            max_file_bytes: 1024 * 1024,
            max_patch_bytes: 1024 * 1024,
            max_total_bytes: 8 * 1024 * 1024,
            max_lines: 100_000,
            max_operations: 128,
            max_hunks: 1024,
            max_work: 32 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatchErrorKind {
    InvalidInput,
    NoMatch,
    Ambiguous,
    EscapeDrift,
    Overlap,
    Limit,
    InvalidPath,
    MissingSnapshot,
    MissingFile,
    Occupied,
    Malformed,
    NoChanges,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PatchError {
    pub kind: PatchErrorKind,
    pub message: String,
}
impl fmt::Display for PatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for PatchError {}
pub type PatchResult<T> = Result<T, PatchError>;
pub(super) fn err(kind: PatchErrorKind, text: impl Into<String>) -> PatchError {
    PatchError {
        kind,
        message: text.into(),
    }
}
pub(super) struct Budget {
    remaining: usize,
    initial: usize,
}
impl Budget {
    fn new(limits: &PatchLimits) -> Self {
        Self {
            remaining: limits.max_work,
            initial: limits.max_work,
        }
    }
    fn charge(&mut self, n: usize) -> PatchResult<()> {
        self.remaining = self.remaining.checked_sub(n).ok_or_else(|| {
            err(
                PatchErrorKind::Limit,
                "patch comparison work limit exceeded; use a smaller exact edit",
            )
        })?;
        Ok(())
    }
    fn used(&self) -> usize {
        self.initial - self.remaining
    }
}
pub(super) fn check_text(s: &str, limit: usize, limits: &PatchLimits) -> PatchResult<()> {
    if s.len() > limit || s.bytes().filter(|b| *b == b'\n').count() >= limits.max_lines {
        return Err(err(
            PatchErrorKind::Limit,
            "patch text byte/line limit exceeded",
        ));
    }
    if s.contains('\0') {
        return Err(err(
            PatchErrorKind::InvalidInput,
            "NUL/binary text is not supported",
        ));
    }
    Ok(())
}
pub(super) fn py_space(c: char) -> bool {
    c.is_whitespace() || matches!(c, '\u{1c}'..='\u{1f}')
}
pub(super) fn trim(s: &str) -> &str {
    s.trim_matches(py_space)
}

#[cfg(test)]
#[path = "file_patch/tests.rs"]
mod tests;
