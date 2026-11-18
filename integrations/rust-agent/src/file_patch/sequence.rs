//! Character-based difflib.SequenceMatcher(None, a, b) semantics, including
//! autojunk (length >= 200), earliest-match ties and adjacent block merging.
//! Work is charged before scans so adversarial repeated text fails closed.
use super::{Budget, PatchResult};
use std::collections::HashMap;

pub(super) fn blocks(
    a: &[char],
    b: &[char],
    budget: &mut Budget,
) -> PatchResult<Vec<(usize, usize, usize)>> {
    budget.charge(a.len().saturating_add(b.len()))?;
    let mut positions: HashMap<char, Vec<usize>> = HashMap::new();
    for (j, ch) in b.iter().enumerate() {
        positions.entry(*ch).or_default().push(j);
    }
    if b.len() >= 200 {
        let threshold = b.len() / 100 + 1;
        positions.retain(|_, indices| indices.len() <= threshold);
    }
    let mut queue = vec![(0, a.len(), 0, b.len())];
    let mut found = Vec::new();
    while let Some((alo, ahi, blo, bhi)) = queue.pop() {
        let (mut best_i, mut best_j, mut size) = (alo, blo, 0);
        let mut previous: HashMap<usize, usize> = HashMap::new();
        budget.charge(ahi - alo)?;
        for (i, ch) in a.iter().enumerate().take(ahi).skip(alo) {
            let mut next = HashMap::new();
            if let Some(indices) = positions.get(ch) {
                budget.charge(indices.len())?;
                for &j in indices {
                    if j < blo {
                        continue;
                    }
                    if j >= bhi {
                        break;
                    }
                    let k = j
                        .checked_sub(1)
                        .and_then(|v| previous.get(&v))
                        .copied()
                        .unwrap_or(0)
                        + 1;
                    next.insert(j, k);
                    if k > size {
                        (best_i, best_j, size) = (i + 1 - k, j + 1 - k, k);
                    }
                }
            }
            previous = next;
        }
        while best_i > alo && best_j > blo && a[best_i - 1] == b[best_j - 1] {
            budget.charge(1)?;
            best_i -= 1;
            best_j -= 1;
            size += 1;
        }
        while best_i + size < ahi && best_j + size < bhi && a[best_i + size] == b[best_j + size] {
            budget.charge(1)?;
            size += 1;
        }
        if size > 0 {
            found.push((best_i, best_j, size));
            if alo < best_i && blo < best_j {
                queue.push((alo, best_i, blo, best_j));
            }
            if best_i + size < ahi && best_j + size < bhi {
                queue.push((best_i + size, ahi, best_j + size, bhi));
            }
        }
    }
    found.sort_unstable();
    let mut merged: Vec<(usize, usize, usize)> = Vec::with_capacity(found.len() + 1);
    for (i, j, n) in found {
        if let Some(last) = merged.last_mut()
            && last.0 + last.2 == i
            && last.1 + last.2 == j
        {
            last.2 += n;
            continue;
        }
        merged.push((i, j, n));
    }
    merged.push((a.len(), b.len(), 0));
    Ok(merged)
}
pub(super) fn ratio(a: &str, b: &str, budget: &mut Budget) -> PatchResult<f64> {
    budget.charge(a.len().saturating_add(b.len()))?;
    if a == b {
        return Ok(1.0);
    }
    let a: Vec<_> = a.chars().collect();
    let b: Vec<_> = b.chars().collect();
    let matched: usize = blocks(&a, &b, budget)?.iter().map(|v| v.2).sum();
    Ok(if a.len() + b.len() == 0 {
        1.0
    } else {
        2.0 * matched as f64 / (a.len() + b.len()) as f64
    })
}
