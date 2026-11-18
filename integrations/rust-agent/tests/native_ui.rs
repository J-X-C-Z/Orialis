#[path = "../src/native_ui.rs"]
mod native_ui;
use native_ui::*;
use serde_json::{Value, json};
use std::collections::HashSet;
fn fixtures() -> Vec<Value> {
    let mut result: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/native_ui/platform-examples.json")).unwrap();
    for raw in [
        include_str!("fixtures/native_ui/response-ui-v1.example.json"),
        include_str!("fixtures/native_ui/response-ui-v1.extended.example.json"),
        include_str!("fixtures/native_ui/response-ui-v1.board.example.json"),
    ] {
        result.push(serde_json::from_str(raw).unwrap());
    }
    result
}
#[test]
fn original_platform_and_all_three_mobile_fixtures_validate_all_26_types() {
    let mut types = HashSet::new();
    for doc in fixtures() {
        let parsed = parse_document(&doc.to_string()).unwrap_or_else(|e| panic!("{e}: {doc}"));
        assert!(parsed.supported());
        for block in parsed.blocks {
            types.insert(block["type"].as_str().unwrap().to_owned());
        }
    }
    assert_eq!(types.len(), 26);
    assert_eq!(types, BLOCK_TYPES.into_iter().map(str::to_owned).collect());
    assert_eq!(capabilities()["block_types"].as_array().unwrap().len(), 26);
    for kind in BLOCK_TYPES {
        assert!(PLATFORM_HINT.contains(&format!("{kind}:")));
    }
}
#[test]
fn document_boundaries_unicode_future_fallback_and_malformed_json() {
    for raw in [
        "{}",
        "[]",
        "{",
        "null",
        r#"{"version":true,"fallback":"x","blocks":[]}"#,
        r#"{"version":1,"fallback":" ","blocks":[]}"#,
    ] {
        assert!(parse_document(raw).is_err());
    }
    let d = json!({"version":1,"fallback":"😀".repeat(4000),"blocks":[{"type":"facts","items":[{"label":"x","value":"y"}]}]});
    assert!(parse_document(&d.to_string()).is_ok());
    let mut oversized = d.clone();
    oversized["unknown"] = json!("界".repeat(11000));
    assert!(parse_document(&oversized.to_string()).is_err());
    let future =
        parse_document(r#"{"version":2,"fallback":"read this","blocks":"unknown future syntax"}"#)
            .unwrap();
    assert!(!future.supported());
    assert!(future.blocks.is_empty());
    assert_eq!(future.fallback, "read this");
}
#[test]
fn rejects_wrong_types_bounds_and_nested_invariants() {
    let invalid = vec![
        json!({"type":"html","items":[{"label":"x"}]}),
        json!({"type":"metrics","items":[{"label":"x","value":1}]}),
        json!({"type":"chart","items":[{"label":"x","value":"1"}]}),
        json!({"type":"checklist","items":[{"label":"x","checked":1}]}),
        json!({"type":"diagram","items":[{"id":"a","label":"a","parent":"b"},{"id":"b","label":"b","parent":"a"}]}),
        json!({"type":"diagram","items":[{"id":"a","label":"a"}],"edges":[{"from":"a","to":"missing"}]}),
        json!({"type":"plot","kind":"pie","items":[{"label":"x","points":[{"x":0,"y":0}]}]}),
        json!({"type":"plot","kind":"area","items":[{"label":"x","points":[{"x":2,"y":0},{"x":1,"y":1}]}]}),
        json!({"type":"plot","kind":"bar","items":[{"label":"x","points":[{"x":1,"y":0},{"x":1.0,"y":1}]}]}),
        json!({"type":"plot","kind":"radar","items":[{"label":"x","points":[{"x":1,"y":0},{"x":2,"y":1},{"x":3,"y":1}]},{"label":"y","points":[{"x":1,"y":0},{"x":2,"y":1},{"x":4,"y":1}]}]}),
        json!({"type":"progress","items":[{"label":"x","value":101}]}),
        json!({"type":"progress","items":[{"label":"x","value":0,"max":0}]}),
        json!({"type":"heatmap","items":[{"label":"x","value":1,"date":"2027-02-29"}]}),
        json!({"type":"heatmap","items":[{"label":"x","value":1,"date":"2028-02-29"},{"label":"y","value":2,"date":"2028-02-29"}]}),
        json!({"type":"simulation","items":[{"label":"x","kind":"sine","terms":1.0}]}),
        json!({"type":"form","items":[{"label":"x","id":"x","kind":"select","options":["a","a"]}]}),
        json!({"type":"form","items":[{"label":"x","id":"x","kind":"multiselect","options":["a"],"value":["a","a"]}]}),
        json!({"type":"form","items":[{"label":"x","id":"x","kind":"slider","min":1,"max":1}]}),
        json!({"type":"table","columns":["a"],"items":[{"label":"x","cells":[]}]}),
        json!({"type":"sources","items":[{"label":"x","url":"https://user:secret@example.test"}]}),
        json!({"type":"sources","items":[{"label":"x","url":"javascript:alert(1)"}]}),
        json!({"type":"media","items":[{"label":"x","id":"../../secret","mimeType":"image/png"}]}),
        json!({"type":"actions","items":[{"label":"x","id":"x","kind":"task","title":"x","due":"2030-13-01"}]}),
        json!({"type":"agenda","items":[{"label":"x","id":"x","kind":"schedule","title":"x","startAt":"2030-01-01T01:00Z","endAt":"2030-01-01T02:00Z"}]}),
        json!({"type":"agenda","items":[{"label":"x","id":"x","title":"x","startAt":"2030-01-01T09:00+08:00","endAt":"2030-01-01T01:00Z"}]}),
        json!({"type":"agenda","items":[{"label":"x","id":"x","title":"x","startAt":"2030-01-01T01:00","endAt":"2030-01-01T02:00"}]}),
        json!({"type":"callout","items":[{"label":"x","content":"x","tone":"execute"}]}),
        json!({"type":"steps","items":[{"label":"x","status":"invented"}]}),
        json!({"type":"comparison","columns":["a","a"],"items":[{"label":"x","values":["1","2"]}]}),
        json!({"type":"comparison","columns":["a","b"],"recommendedIndex":2,"items":[{"label":"x","values":["1","2"]}]}),
        json!({"type":"facts","items":[{"label":"x","value":""}]}),
        json!({"type":"code","items":[{"label":"x","source":"x","language":""}]}),
    ];
    for block in invalid {
        assert!(
            validate_block(&block).is_err(),
            "unexpectedly accepted {block}"
        );
    }
}
#[test]
fn svg_is_a_parsed_static_allowlist_not_a_substring_check() {
    let good = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><defs><linearGradient id="gradient"><stop offset="0" stop-color="red"/></linearGradient></defs><rect width="10" height="10" fill="url(#gradient)"/><title>Safe drawing</title></svg>"##;
    validate_svg(good).unwrap();
    for source in [
        good.replace("<rect", "<script"),
        good.replace("fill=", "onclick="),
        good.replace("url(#gradient)", "url(https://example.test/a)"),
        good.replace("url(#gradient)", "url(&#104;ttps://example.test/a)"),
        good.replace("viewBox=", "style="),
        good.replace("0 0 20 20", "0 0 -20 20"),
        good.replace("<title>", "<!DOCTYPE svg><title>"),
        good.replace("<title>", "<?xml version='1.0'?><title>"),
        good.replace("<rect", "<image"),
        good.replace("<title>", "<text>"),
        good.replace("<svg ", "<s:svg xmlns:s=\"http://www.w3.org/2000/svg\" "),
        good.replace("<title>Safe drawing</title>", &"<g/>".repeat(256)),
    ] {
        assert!(
            validate_svg(&source).is_err(),
            "accepted unsafe SVG {source}"
        );
    }
}
#[test]
fn action_times_and_timeline_iso_forms_match_the_mobile_contract() {
    for time in [
        "2030-01-02",
        "20300102",
        "2030-01-02T09:00:00Z",
        "2030-01-02 09:00",
        "2030-01-42",
    ] {
        validate_block(&json!({"type":"timeline","items":[{"label":"x","time":time}]})).unwrap();
    }
    validate_block(&json!({"type":"agenda","items":[{"label":"x","id":"x","title":"x","startAt":"2030-01-01T23:00Z","endAt":"2030-01-02T02:00+01:00"}]})).unwrap();
}
#[test]
fn closed_fences_validate_independently_and_fallbacks_preserve_other_text() {
    let doc = json!({"version":1,"fallback":"Readable fallback","blocks":[{"type":"facts","items":[{"label":"x","value":"y"}]}]});
    let text = format!("Before\n```orialis-ui\n{doc}\n```\nAfter\n```orialis-ui\nnot json\n```\n");
    let results = validate_content_fences(&text);
    assert_eq!(results.len(), 2);
    assert!(results[0].complete && results[0].document.is_ok());
    assert!(results[1].document.is_err());
    assert_eq!(
        fallback_text(&text),
        "Before\nReadable fallback\nAfter\n```orialis-ui\nnot json\n```\n"
    );
    assert!(validate_content_fences("```text\n```orialis-ui\n{}\n```\n").is_empty());
    let incomplete = validate_content_fences("```orialis-ui\n{");
    assert!(!incomplete[0].complete);
}
