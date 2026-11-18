//! Validation-only port of Orialis mobile response UI v1. Never executes UI actions,
//! fetches media/source URLs or treats a rendered proposal as user confirmation.
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, Datelike, NaiveDate};
use regex::Regex;
use reqwest::Url;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    ops::Range,
    sync::LazyLock,
};

pub const MAX_DOCUMENT_BYTES: usize = 32_768;
pub const PLATFORM_HINT: &str = include_str!("../tests/fixtures/native_ui/platform_hint.txt");
pub const BLOCK_TYPES: [&str; 26] = [
    "metrics",
    "chart",
    "tabs",
    "checklist",
    "choices",
    "svg",
    "diagram",
    "math",
    "plot",
    "timeline",
    "simulation",
    "form",
    "table",
    "sources",
    "diff",
    "media",
    "actions",
    "progress",
    "heatmap",
    "accordion",
    "callout",
    "steps",
    "comparison",
    "facts",
    "code",
    "agenda",
];
static FORM_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z][A-Za-z0-9_-]{0,39}$").unwrap());
static ITEM_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9_-]{1,160}$").unwrap());
static ACTION_TIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})$")
        .unwrap()
});
static ISO_TIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)? ?([zZ]|([-+])(\d\d)(?::?(\d\d))?)?)?$").unwrap()
});

#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    pub version: u64,
    pub title: Option<String>,
    pub fallback: String,
    pub blocks: Vec<Value>,
}
impl Document {
    pub fn supported(&self) -> bool {
        self.version == 1
    }
}
pub fn capabilities() -> Value {
    serde_json::from_str(include_str!("../tests/fixtures/native_ui/response_ui.json"))
        .expect("pinned UI metadata")
}
pub fn parse_document(source: &str) -> Result<Document> {
    ensure!(
        source.len() <= MAX_DOCUMENT_BYTES,
        "UI document exceeds 32768 UTF-8 bytes"
    );
    let data: Value = serde_json::from_str(source).context("invalid UI JSON")?;
    ensure!(data.is_object(), "UI document must be an object");
    let version = data["version"]
        .as_u64()
        .filter(|v| *v > 0)
        .context("UI version must be a positive integer")?;
    let fallback = text(&data["fallback"], 4000, false, "fallback")?.to_owned();
    optional(&data["title"], 80, "title")?;
    let mut blocks = vec![];
    if version == 1 {
        for block in array(&data["blocks"], 1, 12, "blocks")? {
            validate_block(block)?;
            blocks.push(block.clone());
        }
    }
    Ok(Document {
        version,
        title: data["title"].as_str().map(str::to_owned),
        fallback,
        blocks,
    })
}
fn text<'a>(value: &'a Value, max: usize, empty: bool, name: &str) -> Result<&'a str> {
    let s = value
        .as_str()
        .with_context(|| format!("{name} must be a string"))?;
    ensure!(
        (empty || !s.trim().is_empty()) && s.chars().count() <= max,
        "{name} must be nonempty and at most {max} characters"
    );
    Ok(s)
}
fn optional(value: &Value, max: usize, name: &str) -> Result<()> {
    if !value.is_null() {
        text(value, max, false, name)?;
    }
    Ok(())
}
fn array<'a>(v: &'a Value, min: usize, max: usize, name: &str) -> Result<&'a Vec<Value>> {
    let a = v
        .as_array()
        .with_context(|| format!("{name} must be an array"))?;
    ensure!(
        (min..=max).contains(&a.len()),
        "{name} must contain {min}..{max} items"
    );
    Ok(a)
}
fn number(v: &Value, min: f64, max: f64, name: &str) -> Result<f64> {
    let n = v
        .as_f64()
        .with_context(|| format!("{name} must be numeric"))?;
    ensure!(
        n.is_finite() && n >= min && n <= max,
        "{name} is outside its finite numeric bounds"
    );
    Ok(n)
}
fn choice(v: &Value, choices: &[&str], optional: bool, name: &str) -> Result<()> {
    ensure!(
        (optional && v.is_null()) || v.as_str().is_some_and(|s| choices.contains(&s)),
        "unsupported {name}"
    );
    Ok(())
}
fn date(s: &str, positive_year: bool) -> Result<NaiveDate> {
    ensure!(s.len() == 10 && s.is_ascii(), "date must be YYYY-MM-DD");
    let d = NaiveDate::parse_from_str(s, "%Y-%m-%d")?;
    ensure!(
        d.format("%Y-%m-%d").to_string() == s && (!positive_year || d.year() >= 1),
        "invalid calendar date"
    );
    Ok(d)
}
fn action_time(v: &Value) -> Result<DateTime<chrono::FixedOffset>> {
    let s = text(v, 40, false, "timestamp")?;
    ensure!(
        ACTION_TIME.is_match(s),
        "timestamp must have explicit timezone and at most six fractional digits"
    );
    date(&s[..10], false)?;
    ensure!(
        s[11..13].parse::<u8>()? < 24 && s[14..16].parse::<u8>()? < 60,
        "invalid local time"
    );
    if s.as_bytes().get(16) == Some(&b':') {
        ensure!(s[17..19].parse::<u8>()? < 60, "invalid second");
    }
    let full = if s.as_bytes().get(16) != Some(&b':') {
        format!("{}:00{}", &s[..16], &s[16..])
    } else {
        s.to_owned()
    };
    Ok(DateTime::parse_from_rfc3339(&full)?)
}
// Mirrors DateTime.tryParse for display-only timeline dates, including ISO compact
// forms and normalized day/time overflow; creation proposals use strict action_time.
fn timeline_time(v: &Value) -> Result<()> {
    if v.is_null() {
        return Ok(());
    }
    let s = text(v, 80, false, "time")?;
    let c = ISO_TIME.captures(s).context("invalid ISO8601 time")?;
    let part = |i: usize, default: i64| -> Result<i64> {
        Ok(match c.get(i) {
            Some(m) => m.as_str().parse()?,
            None => default,
        })
    };
    let y = part(1, 0)?;
    let m = part(2, 1)? - 1;
    let year = y + m.div_euclid(12);
    let month = m.rem_euclid(12) + 1;
    let d = NaiveDate::from_ymd_opt(i32::try_from(year)?, month as u32, 1)
        .context("invalid timeline year")?;
    let seconds = (part(3, 1)? - 1) * 86400 + part(4, 0)? * 3600 + part(5, 0)? * 60 + part(6, 0)?;
    ensure!(
        d.and_hms_opt(0, 0, 0)
            .unwrap()
            .checked_add_signed(chrono::Duration::seconds(seconds))
            .is_some(),
        "timeline time out of range"
    );
    Ok(())
}
pub fn validate_block(block: &Value) -> Result<()> {
    ensure!(block.is_object(), "UI block must be an object");
    optional(&block["title"], 80, "block title")?;
    optional(&block["unit"], 32, "unit")?;
    let kind = block["type"].as_str().context("block type required")?;
    ensure!(BLOCK_TYPES.contains(&kind), "unsupported UI block type");
    let items = array(&block["items"], 1, 12, "items")?;
    for item in items {
        ensure!(item.is_object(), "item must be object");
        text(&item["label"], 120, false, "label")?;
    }
    match kind {
        "diagram" => validate_diagram(block, items)?,
        "plot" => validate_plot(block, items)?,
        "form" => validate_form(block, items)?,
        "table" | "comparison" => {
            let columns = array(
                &block["columns"],
                if kind == "comparison" { 2 } else { 1 },
                if kind == "comparison" { 4 } else { 8 },
                "columns",
            )?;
            let mut unique = HashSet::new();
            for column in columns {
                let s = text(column, 120, false, "column")?;
                ensure!(
                    kind != "comparison" || unique.insert(s),
                    "comparison columns must be unique"
                );
            }
            if kind == "comparison" && !block["recommendedIndex"].is_null() {
                ensure!(
                    block["recommendedIndex"]
                        .as_u64()
                        .is_some_and(|i| i < columns.len() as u64),
                    "invalid recommendedIndex"
                );
            }
            for item in items {
                let field = if kind == "comparison" {
                    "values"
                } else {
                    "cells"
                };
                for cell in array(&item[field], columns.len(), columns.len(), field)? {
                    if kind == "table" && cell.is_number() {
                        number(cell, -1e12, 1e12, "cell")?;
                    } else {
                        text(cell, 1000, true, "cell")?;
                    }
                }
            }
        }
        "media" | "actions" | "agenda" => {
            let mut ids = HashSet::new();
            for item in items {
                let id = text(&item["id"], 160, false, "id")?;
                ensure!(
                    ITEM_ID.is_match(id) && ids.insert(id),
                    "invalid or duplicate item id"
                );
                if kind == "media" {
                    text(&item["mimeType"], 120, false, "mimeType")?;
                    optional(&item["name"], 240, "name")?;
                    continue;
                }
                text(&item["title"], 240, false, "title")?;
                optional(&item["notes"], 4000, "notes")?;
                optional(&item["location"], 240, "location")?;
                if kind == "agenda" {
                    ensure!(item.get("kind").is_none(), "agenda does not accept kind");
                }
                if kind == "actions" && item["kind"] == "task" {
                    if !item["due"].is_null() {
                        date(text(&item["due"], 10, false, "due")?, false)?;
                    }
                } else if kind == "agenda" || item["kind"] == "schedule" {
                    ensure!(
                        action_time(&item["startAt"])? < action_time(&item["endAt"])?,
                        "startAt must precede endAt"
                    );
                } else {
                    bail!("unsupported action kind");
                }
            }
        }
        "heatmap" => {
            let mut dates = HashSet::new();
            for item in items {
                let s = text(&item["date"], 10, false, "date")?;
                date(s, true)?;
                ensure!(dates.insert(s), "duplicate heatmap date");
                number(&item["value"], 0., 1e6, "value")?;
            }
        }
        "progress" => {
            choice(&block["style"], &["linear", "ring"], true, "progress style")?;
            for item in items {
                let max = if item["max"].is_null() {
                    100.
                } else {
                    number(&item["max"], f64::from_bits(1), 1e6, "max")?
                };
                number(&item["value"], 0., max, "value")?;
                optional(&item["detail"], 240, "detail")?;
            }
        }
        "simulation" => {
            ensure!(items.len() == 1, "simulation requires one item");
            let i = &items[0];
            choice(&i["kind"], &["sine", "fourier"], false, "simulation kind")?;
            if !i["terms"].is_null() {
                ensure!(
                    i["terms"].as_u64().is_some_and(|n| (1..=25).contains(&n)),
                    "terms must be integer 1..25"
                );
            }
            for k in ["amplitude", "frequency"] {
                if !i[k].is_null() {
                    number(&i[k], 0.1, 5., k)?;
                }
            }
        }
        _ => {
            for item in items {
                match kind {
                    "metrics" => {
                        text(&item["value"], 120, false, "value")?;
                        optional(&item["detail"], 240, "detail")?;
                    }
                    "chart" => {
                        number(&item["value"], -f64::MAX, f64::MAX, "value")?;
                    }
                    "tabs" | "accordion" => {
                        text(&item["content"], 4000, false, "content")?;
                    }
                    "checklist" => ensure!(item["checked"].is_boolean(), "checked must be boolean"),
                    "choices" => {
                        text(&item["prompt"], 1000, false, "prompt")?;
                    }
                    "svg" => validate_svg(text(&item["source"], 16000, false, "SVG source")?)?,
                    "math" => {
                        text(&item["source"], 4000, false, "math source")?;
                    }
                    "timeline" => {
                        optional(&item["detail"], 1000, "detail")?;
                        timeline_time(&item["time"])?;
                    }
                    "sources" => {
                        source_url(&item["url"])?;
                        optional(&item["excerpt"], 4000, "excerpt")?;
                        optional(&item["sourceId"], 120, "sourceId")?;
                    }
                    "diff" => {
                        text(&item["before"], 4000, true, "before")?;
                        text(&item["after"], 4000, true, "after")?;
                    }
                    "callout" => {
                        text(&item["content"], 4000, false, "content")?;
                        choice(
                            &item["tone"],
                            &["info", "success", "warning", "critical"],
                            true,
                            "tone",
                        )?;
                    }
                    "steps" => {
                        optional(&item["detail"], 1000, "detail")?;
                        choice(
                            &item["status"],
                            &["pending", "current", "done"],
                            true,
                            "status",
                        )?;
                    }
                    "facts" => {
                        text(&item["value"], 1000, false, "value")?;
                        optional(&item["detail"], 240, "detail")?;
                    }
                    "code" => {
                        text(&item["source"], 16000, false, "source")?;
                        optional(&item["language"], 32, "language")?;
                    }
                    _ => unreachable!("catalog validated"),
                }
            }
        }
    }
    Ok(())
}
fn validate_diagram(block: &Value, items: &[Value]) -> Result<()> {
    choice(
        &block["layout"],
        &["flow", "mindmap", "graph"],
        true,
        "diagram layout",
    )?;
    let mut ids = HashSet::new();
    let mut parents = HashMap::new();
    for item in items {
        let id = text(&item["id"], 40, false, "node id")?;
        ensure!(ids.insert(id), "duplicate node id");
        optional(&item["detail"], 1000, "detail")?;
        optional(&item["parent"], 40, "parent")?;
        if let Some(p) = item["parent"].as_str() {
            parents.insert(id, p);
        }
    }
    for (id, parent) in &parents {
        ensure!(
            ids.contains(parent) && id != parent,
            "unknown or self parent"
        );
    }
    for id in &ids {
        let mut visited = HashSet::from([*id]);
        let mut current = parents.get(id);
        while let Some(next) = current {
            ensure!(visited.insert(*next), "diagram parent cycle");
            current = parents.get(next);
        }
    }
    if !block["edges"].is_null() {
        for edge in array(&block["edges"], 0, 24, "edges")? {
            ensure!(
                edge.is_object()
                    && edge["from"].as_str().is_some_and(|s| ids.contains(s))
                    && edge["to"].as_str().is_some_and(|s| ids.contains(s)),
                "edge references missing node"
            );
            optional(&edge["label"], 80, "edge label")?;
        }
    }
    Ok(())
}
fn validate_plot(block: &Value, items: &[Value]) -> Result<()> {
    choice(
        &block["kind"],
        &["line", "scatter", "pie", "area", "bar", "radar"],
        false,
        "plot kind",
    )?;
    let kind = block["kind"].as_str().unwrap();
    for (k, max) in [("xLabel", 80), ("yLabel", 80), ("xUnit", 32)] {
        optional(&block[k], max, k)?;
    }
    let mut pie_total = 0.;
    let mut axes: Option<Vec<(f64, Option<String>)>> = None;
    for item in items {
        let points = array(
            &item["points"],
            if kind == "radar" { 3 } else { 1 },
            120,
            "points",
        )?;
        let mut coordinates = vec![];
        let mut previous = None;
        let mut current_axes = vec![];
        for point in points {
            ensure!(point.is_object(), "point must be object");
            let x = number(&point["x"], -1e6, 1e6, "x")?;
            let y = number(
                &point["y"],
                if matches!(kind, "pie" | "radar") {
                    0.
                } else {
                    -1e6
                },
                1e6,
                "y",
            )?;
            optional(&point["label"], 120, "point label")?;
            if matches!(kind, "area" | "bar" | "radar") {
                ensure!(
                    !coordinates.contains(&x),
                    "plot x coordinates must be unique"
                );
                coordinates.push(x);
            }
            if kind == "area" {
                ensure!(
                    previous.is_none_or(|p| x > p),
                    "area x coordinates must increase"
                );
            }
            previous = Some(x);
            pie_total += y;
            current_axes.push((x, point["label"].as_str().map(str::to_owned)));
        }
        if kind == "radar" {
            if let Some(a) = &axes {
                ensure!(a == &current_axes, "radar axes must match");
            } else {
                axes = Some(current_axes);
            }
        }
    }
    ensure!(
        kind != "pie" || pie_total > 0.,
        "pie total must be positive"
    );
    Ok(())
}
fn validate_form(block: &Value, items: &[Value]) -> Result<()> {
    optional(&block["prompt"], 1000, "form prompt")?;
    let mut ids = HashSet::new();
    for item in items {
        let id = text(&item["id"], 40, false, "form id")?;
        ensure!(
            FORM_ID.is_match(id) && ids.insert(id),
            "invalid or duplicate form id"
        );
        ensure!(
            item["required"].is_null() || item["required"].is_boolean(),
            "required must be boolean"
        );
        let value = &item["value"];
        match item["kind"].as_str() {
            Some("text") => {
                if !value.is_null() {
                    text(value, 1000, true, "form value")?;
                }
            }
            Some("date") => {
                if !value.is_null() {
                    date(text(value, 10, false, "date value")?, true)?;
                }
            }
            Some("select" | "multiselect") => {
                let options = array(&item["options"], 1, 12, "options")?;
                let mut unique = HashSet::new();
                for option in options {
                    ensure!(
                        unique.insert(text(option, 120, false, "option")?),
                        "options must be unique"
                    );
                }
                if !value.is_null() {
                    if item["kind"] == "select" {
                        ensure!(options.contains(value), "value not in options");
                    } else {
                        let mut selected = HashSet::new();
                        for selected_value in array(value, 0, 12, "selected values")? {
                            ensure!(
                                options.contains(selected_value)
                                    && selected.insert(selected_value.as_str().unwrap()),
                                "invalid or duplicate selected option"
                            );
                        }
                    }
                }
            }
            Some("slider") => {
                let min = number(&item["min"], -1e6, 1e6, "min")?;
                let max = number(&item["max"], -1e6, 1e6, "max")?;
                ensure!(min < max, "slider min must precede max");
                if !value.is_null() {
                    number(value, min, max, "slider value")?;
                }
            }
            _ => bail!("unsupported form kind"),
        }
    }
    Ok(())
}
fn source_url(v: &Value) -> Result<()> {
    let s = text(v, 2000, false, "source url")?;
    ensure!(
        !s.chars().any(char::is_whitespace),
        "source url contains whitespace"
    );
    let url = Url::parse(s)?;
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none(),
        "source URL must be HTTP(S), have a host and no credentials"
    );
    Ok(())
}

pub fn validate_svg(source: &str) -> Result<()> {
    ensure!(
        !source.is_empty()
            && source.chars().count() <= 16000
            && !source.contains("<!")
            && !source.contains("<?"),
        "SVG declarations, entities and processing instructions are forbidden"
    );
    let document = roxmltree::Document::parse(source).context("invalid SVG XML")?;
    let root = document.root_element();
    let ns = "http://www.w3.org/2000/svg";
    ensure!(
        root.tag_name().name() == "svg"
            && root.tag_name().namespace() == Some(ns)
            && root
                .namespaces()
                .any(|n| n.name().is_none() && n.uri() == ns),
        "SVG root must use the SVG default namespace"
    );
    let view = root.attribute("viewBox").context("SVG viewBox required")?;
    static BOX_SPLIT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\s,]+").unwrap());
    let box_values: Vec<_> = BOX_SPLIT
        .split(view.trim())
        .map(str::parse::<f64>)
        .collect::<std::result::Result<_, _>>()?;
    ensure!(
        box_values.len() == 4
            && box_values.iter().all(|n| n.is_finite())
            && box_values[2] > 0.
            && box_values[3] > 0.
            && box_values[2] <= 10000.
            && box_values[3] <= 10000.,
        "invalid SVG viewBox"
    );
    const ELEMENTS: &[&str] = &[
        "svg",
        "g",
        "defs",
        "path",
        "rect",
        "circle",
        "ellipse",
        "line",
        "polyline",
        "polygon",
        "linearGradient",
        "radialGradient",
        "stop",
        "clipPath",
        "title",
        "desc",
    ];
    const ATTRIBUTES: &[&str] = &[
        "viewBox",
        "width",
        "height",
        "id",
        "x",
        "y",
        "x1",
        "y1",
        "x2",
        "y2",
        "cx",
        "cy",
        "r",
        "rx",
        "ry",
        "d",
        "points",
        "fill",
        "fill-opacity",
        "fill-rule",
        "stroke",
        "stroke-width",
        "stroke-opacity",
        "stroke-linecap",
        "stroke-linejoin",
        "stroke-miterlimit",
        "stroke-dasharray",
        "stroke-dashoffset",
        "opacity",
        "transform",
        "clip-path",
        "clip-rule",
        "clipPathUnits",
        "gradientUnits",
        "gradientTransform",
        "offset",
        "stop-color",
        "stop-opacity",
        "fx",
        "fy",
        "spreadMethod",
        "preserveAspectRatio",
    ];
    static URL_REF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)url\s*\(").unwrap());
    static LOCAL_REF: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^url\(#[a-zA-Z_][\w.-]*\)$").unwrap());
    let mut count = 0;
    for node in document.descendants().filter(|n| n.is_element()) {
        count += 1;
        ensure!(
            count <= 256 && ELEMENTS.contains(&node.tag_name().name()),
            "unsupported SVG element or element count"
        );
        ensure!(
            node.namespaces()
                .all(|n| n.name().is_none() && n.uri() == ns),
            "prefixed or foreign SVG namespaces are forbidden"
        );
        let opening = &source[node.range().start..];
        let name = opening
            .trim_start_matches('<')
            .split(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .next()
            .unwrap_or("");
        ensure!(!name.contains(':'), "prefixed SVG elements forbidden");
        for a in node.attributes() {
            let name = a.name();
            let value = a.value();
            ensure!(
                a.namespace().is_none() && ATTRIBUTES.contains(&name),
                "unsupported SVG attribute"
            );
            ensure!(
                !value.contains(['\\', '<', '>']),
                "invalid SVG attribute value"
            );
            if URL_REF.is_match(value) {
                ensure!(
                    matches!(name, "fill" | "stroke" | "clip-path") && LOCAL_REF.is_match(value),
                    "external SVG reference forbidden"
                );
            }
        }
    }
    Ok(())
}

#[derive(Debug)]
pub struct Fence {
    pub range: Range<usize>,
    pub complete: bool,
    pub document: std::result::Result<Document, String>,
}
/// Inspect only explicit UI fences. Ordinary code fences are never reinterpreted.
pub fn validate_content_fences(content: &str) -> Vec<Fence> {
    let mut result = vec![];
    let mut ordinary: Option<(char, usize)> = None;
    let mut start: Option<(usize, usize)> = None;
    let mut offset = 0;
    for line in content.split_inclusive('\n') {
        let trimmed = line.trim();
        if let Some((opening, body)) = start {
            if trimmed == "```" {
                result.push(Fence {
                    range: opening..offset + line.len(),
                    complete: true,
                    document: parse_document(&content[body..offset]).map_err(|e| e.to_string()),
                });
                start = None;
            }
        } else if let Some((marker, count)) = ordinary {
            if trimmed.chars().take_while(|c| *c == marker).count() >= count
                && trimmed.chars().all(|c| c == marker)
            {
                ordinary = None;
            }
        } else if trimmed == "```orialis-ui" {
            start = Some((offset, offset + line.len()));
        } else if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            let marker = trimmed.chars().next().unwrap();
            ordinary = Some((marker, trimmed.chars().take_while(|c| *c == marker).count()));
        }
        offset += line.len();
    }
    if let Some((opening, _)) = start {
        result.push(Fence {
            range: opening..content.len(),
            complete: false,
            document: Err("incomplete UI fence".into()),
        });
    }
    result
}
/// Text exports substitute valid authored fallbacks; invalid/incomplete data stays visible.
pub fn fallback_text(content: &str) -> String {
    let mut output = String::new();
    let mut last = 0;
    for fence in validate_content_fences(content) {
        if let Ok(doc) = fence.document {
            output.push_str(&content[last..fence.range.start]);
            output.push_str(&doc.fallback);
            output.push('\n');
            last = fence.range.end;
        }
    }
    output.push_str(&content[last..]);
    output
}
