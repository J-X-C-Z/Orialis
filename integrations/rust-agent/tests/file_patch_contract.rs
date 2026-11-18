use hermes_rust_core::file_patch::*;
use serde_json::Value;
use std::collections::BTreeMap;
fn fixtures() -> Value {
    serde_json::from_str(include_str!("fixtures/file_patch_reference.json")).unwrap()
}
#[test]
fn fuzzy_reference_contract() {
    let fixtures = fixtures();
    let mut fails = Vec::new();
    for case in fixtures["fuzzy_cases"].as_array().unwrap() {
        let a = &case["input"];
        let e = &case["expected"];
        let result = plan_replace(
            a["content"].as_str().unwrap(),
            a["old_string"].as_str().unwrap(),
            a["new_string"].as_str().unwrap(),
            a["replace_all"].as_bool().unwrap(),
            &PatchLimits::default(),
        );
        match result {
            Ok(r) => {
                if !e["error"].is_null()
                    || r.content != e["content"].as_str().unwrap()
                    || r.match_count != e["count"].as_u64().unwrap() as usize
                    || r.strategy.name() != e["strategy"].as_str().unwrap_or("")
                {
                    fails.push(format!("{}: got {r:?}, expected {e}", case["id"]));
                }
            }
            Err(error) => {
                if e["error"].is_null() {
                    fails.push(format!("{}: got error {error}, expected {e}", case["id"]));
                }
            }
        }
    }
    assert!(
        fails.is_empty(),
        "{} failures:\n{}",
        fails.len(),
        fails.join("\n")
    );
}
#[test]
fn v4a_reference_contract() {
    let fixtures = fixtures();
    let mut fails = Vec::new();
    for case in fixtures["v4a_cases"].as_array().unwrap() {
        let a = &case["input"];
        let e = &case["expected"];
        let patch = a["patch"].as_str().unwrap();
        // Absolute aliases are intentionally rejected by this confined planner.
        if e["operations"].as_array().unwrap().iter().any(|op| {
            op["file_path"].as_str().is_some_and(|p| p.starts_with('/'))
                || op["new_path"].as_str().is_some_and(|p| p.starts_with('/'))
        }) {
            assert_eq!(
                parse_v4a(patch, &PatchLimits::default()).unwrap_err().kind,
                PatchErrorKind::InvalidPath
            );
            continue;
        }
        let mut snapshots = BTreeMap::new();
        for (path, body) in a["files"].as_object().unwrap() {
            snapshots.insert(
                path.trim_start_matches("./").to_string(),
                Some(body.as_str().unwrap().to_owned()),
            );
        }
        if let Ok(ops) = parse_v4a(patch, &PatchLimits::default()) {
            for op in ops {
                snapshots.entry(op.path).or_insert(None);
                if let Some(p) = op.new_path {
                    snapshots.entry(p).or_insert(None);
                }
            }
        }
        let result = plan_v4a(patch, &snapshots, &PatchLimits::default());
        let expected_ok =
            e["result"]["success"].as_bool().unwrap_or(false) && e["parse_error"].is_null();
        match result {
            Ok(r) => {
                if !expected_ok {
                    fails.push(format!("{}: unexpectedly accepted; {e}", case["id"]));
                    continue;
                }
                for c in r.changes {
                    snapshots.insert(c.path, c.after);
                }
                let actual: BTreeMap<_, _> = snapshots
                    .into_iter()
                    .filter_map(|(p, c)| c.map(|c| (format!("/work/{p}"), c)))
                    .collect();
                let expected: BTreeMap<String, String> =
                    serde_json::from_value(e["files"].clone()).unwrap();
                if actual != expected {
                    fails.push(format!(
                        "{}: got {actual:?}, expected {expected:?}",
                        case["id"]
                    ));
                }
            }
            Err(error) => {
                if expected_ok {
                    fails.push(format!("{}: got error {error}, expected {e}", case["id"]));
                }
            }
        }
    }
    assert!(
        fails.is_empty(),
        "{} failures:\n{}",
        fails.len(),
        fails.join("\n")
    );
}
