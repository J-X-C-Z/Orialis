use super::*;
use std::collections::BTreeMap;
#[test]
fn direct_strategy_reference_spans() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/file_patch_reference.json"
    ))
    .unwrap();
    for case in fixture["strategy_cases"].as_array().unwrap() {
        let name = case["strategy"].as_str().unwrap();
        let strategy = [
            Strategy::Exact,
            Strategy::LineTrimmed,
            Strategy::WhitespaceNormalized,
            Strategy::IndentationFlexible,
            Strategy::EscapeNormalized,
            Strategy::TrimmedBoundary,
            Strategy::UnicodeNormalized,
            Strategy::BlockAnchor,
            Strategy::ContextAware,
        ]
        .into_iter()
        .find(|s| s.name() == name)
        .unwrap();
        let content = case["content"].as_str().unwrap();
        let actual = fuzzy::find_spans(
            content,
            case["pattern"].as_str().unwrap(),
            strategy,
            &mut Budget::new(&PatchLimits::default()),
        )
        .unwrap();
        let byte_positions: Vec<_> = content
            .char_indices()
            .map(|(i, _)| i)
            .chain([content.len()])
            .collect();
        let expected: Vec<_> = case["expected_spans"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                (
                    byte_positions[s[0].as_u64().unwrap() as usize],
                    byte_positions[s[1].as_u64().unwrap() as usize],
                )
            })
            .collect();
        assert_eq!(actual, expected, "{name}");
    }
}
#[test]
fn malformed_paths_and_envelopes_fail_closed() {
    for path in [
        "../a",
        "a/../b",
        "/etc/passwd",
        "C:/Windows/a",
        "a\\b",
        "./",
        "a/",
        "a/.",
        "a\0b",
        "a\tb",
    ] {
        let patch = format!("*** Add File: {path}\n+x");
        assert!(
            parse_v4a(&patch, &PatchLimits::default()).is_err(),
            "{path:?}"
        );
    }
    for patch in [
        "*** Begin Patch\n*** Add File: a\n+x",
        "*** Begin Patch\n*** Begin Patch\n*** End Patch",
        "*** Move File: a",
        "*** Unknown File: a",
        "*** Update File: a",
    ] {
        assert!(
            parse_v4a(patch, &PatchLimits::default()).is_err(),
            "{patch}"
        );
    }
}
#[test]
fn missing_snapshot_is_not_evidence_of_absence() {
    let patch = "*** Add File: a\n+new";
    assert_eq!(
        plan_v4a(patch, &BTreeMap::new(), &PatchLimits::default())
            .unwrap_err()
            .kind,
        PatchErrorKind::MissingSnapshot
    );
    let state = BTreeMap::from([("a".into(), None)]);
    assert_eq!(
        plan_v4a(patch, &state, &PatchLimits::default())
            .unwrap()
            .changes[0]
            .after
            .as_deref(),
        Some("new")
    );
}
#[test]
fn late_multifile_failure_returns_no_plan_and_preserves_all_inputs() {
    let state = BTreeMap::from([
        ("a".into(), Some("one".into())),
        ("b".into(), Some("two".into())),
    ]);
    let copy = state.clone();
    let patch = "*** Update File: a\n-one\n+changed\n*** Update File: b\n-not present\n+wrong";
    assert!(plan_v4a(patch, &state, &PatchLimits::default()).is_err());
    assert_eq!(state, copy);
}
#[test]
fn sequential_moves_aliases_and_updates_share_overlay() {
    let state = BTreeMap::from([("a".into(), Some("旧值🙂".into())), ("b".into(), None)]);
    let patch = "*** Move File: ./a -> .//b\n*** Update File: b\n-旧值🙂\n+新值🙂";
    let p = plan_v4a(patch, &state, &PatchLimits::default()).unwrap();
    assert_eq!(p.changes.len(), 2);
    assert_eq!(p.changes[0].after, None);
    assert_eq!(p.changes[1].after.as_deref(), Some("新值🙂"));
}
#[test]
fn overlapping_fuzzy_windows_fail_closed() {
    let e = plan_replace(" a\n a\n a", "a\na", "b", true, &PatchLimits::default()).unwrap_err();
    assert_eq!(e.kind, PatchErrorKind::Overlap);
}
#[test]
fn deterministic_limits_bound_scan_output_and_reindent() {
    let low = PatchLimits {
        max_work: 10,
        ..PatchLimits::default()
    };
    assert_eq!(
        plan_replace("hello world", "hello", "goodbye", false, &low)
            .unwrap_err()
            .kind,
        PatchErrorKind::Limit
    );
    let low = PatchLimits {
        max_file_bytes: 24,
        ..PatchLimits::default()
    };
    assert_eq!(
        plan_replace("x x", "x", &"z".repeat(20), true, &low)
            .unwrap_err()
            .kind,
        PatchErrorKind::Limit
    );
    let content = format!("{}x\n", " ".repeat(900));
    let new = "y\n".repeat(500);
    let low = PatchLimits {
        max_file_bytes: 1000,
        ..PatchLimits::default()
    };
    assert_eq!(
        plan_replace(&content, "x \n", &new, false, &low)
            .unwrap_err()
            .kind,
        PatchErrorKind::Limit
    );
}
#[test]
fn sequence_matcher_autojunk_and_earliest_ties() {
    let a: Vec<_> = " abcd".chars().collect();
    let b: Vec<_> = "abcd abcd".chars().collect();
    let mut budget = Budget::new(&PatchLimits::default());
    assert_eq!(
        sequence::blocks(&a, &b, &mut budget).unwrap(),
        vec![(0, 4, 5), (5, 9, 0)]
    );
    let a: Vec<_> = "a".repeat(300).chars().collect();
    let b = a.clone();
    assert_eq!(
        sequence::blocks(&a, &b, &mut budget).unwrap(),
        vec![(0, 0, 300), (300, 300, 0)]
    );
}

#[test]
fn sequence_matcher_matches_python_reference_corpus() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/file_patch_reference.json"
    ))
    .unwrap();
    for case in fixture["sequence_cases"].as_array().unwrap() {
        let a: Vec<_> = case["a"].as_str().unwrap().chars().collect();
        let b: Vec<_> = case["b"].as_str().unwrap().chars().collect();
        let expected: Vec<(usize, usize, usize)> =
            serde_json::from_value(case["expected_blocks"].clone()).unwrap();
        let actual = sequence::blocks(&a, &b, &mut Budget::new(&PatchLimits::default())).unwrap();
        assert_eq!(actual, expected, "{}", case["id"]);
    }
}
