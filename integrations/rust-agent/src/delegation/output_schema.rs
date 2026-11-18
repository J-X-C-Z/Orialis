//! Bounded, local-only JSON Schema. Never fetch references or enable backtracking regexes.
use super::*;
use std::sync::OnceLock;
fn cpu() -> Arc<Semaphore> {
    static CPU: OnceLock<Arc<Semaphore>> = OnceLock::new();
    CPU.get_or_init(|| Arc::new(Semaphore::new(2))).clone()
}
pub(super) fn bounded_value(value: &Value, max_depth: usize, max_nodes: usize) -> Result<()> {
    let mut stack = vec![(value, 0usize)];
    let mut count = 0;
    while let Some((v, depth)) = stack.pop() {
        count += 1;
        ensure!(
            depth <= max_depth && count <= max_nodes,
            "JSON depth/node budget exceeded"
        );
        match v {
            Value::Object(m) => stack.extend(m.values().map(|v| (v, depth + 1))),
            Value::Array(v) => stack.extend(v.iter().map(|v| (v, depth + 1))),
            _ => (),
        }
    }
    Ok(())
}
pub(super) fn preflight(schema: &Value) -> Result<()> {
    ensure!(
        schema.is_object() && schema.to_string().len() <= 32 * 1024,
        "output_schema must be a bounded JSON Schema object"
    );
    bounded_value(schema, 32, 4096)?;
    let mut stack = vec![schema];
    while let Some(v) = stack.pop() {
        match v {
            Value::Object(map) => {
                for (key, value) in map {
                    ensure!(
                        !matches!(
                            key.as_str(),
                            "$dynamicRef"
                                | "$recursiveRef"
                                | "$dynamicAnchor"
                                | "$recursiveAnchor"
                                | "$anchor"
                                | "$id"
                        ),
                        "dynamic/recursive or rebased schema references are unsupported"
                    );
                    if key == "$ref" {
                        let reference = value.as_str().context("invalid schema reference")?;
                        ensure!(
                            reference.starts_with("#/") && !reference.contains('%'),
                            "only local JSON-pointer schema references are allowed"
                        );
                        ensure!(
                            schema.pointer(&reference[1..]).is_some(),
                            "schema reference target missing"
                        );
                    }
                    if key == "pattern" {
                        check_pattern(value.as_str().context("invalid schema pattern")?)?;
                    }
                    if key == "patternProperties" {
                        for pattern in value
                            .as_object()
                            .context("invalid patternProperties")?
                            .keys()
                        {
                            check_pattern(pattern)?;
                        }
                    }
                    if key == "$schema" {
                        ensure!(
                            value.as_str().is_some_and(|s| matches!(
                                s,
                                "https://json-schema.org/draft/2020-12/schema"
                                    | "https://json-schema.org/draft/2019-09/schema"
                                    | "http://json-schema.org/draft-07/schema#"
                                    | "http://json-schema.org/draft-06/schema#"
                                    | "http://json-schema.org/draft-04/schema#"
                            )),
                            "unsupported JSON Schema dialect"
                        );
                    }
                    stack.push(value);
                }
            }
            Value::Array(values) => stack.extend(values),
            _ => (),
        }
    }
    // Check the reference expansion graph, not just JSON nesting. Recursive
    // local schemas are intentionally rejected, as are exponentially expanded DAGs.
    let mut budget = 8192;
    check_refs(schema, schema, &mut BTreeSet::new(), 0, &mut budget)?;
    Ok(())
}
fn check_pattern(pattern: &str) -> Result<()> {
    ensure!(pattern.len() <= 512, "schema regex is too long");
    regex::RegexBuilder::new(pattern)
        .size_limit(128 * 1024)
        .dfa_size_limit(128 * 1024)
        .build()
        .context("schema patterns must use bounded linear-time regular expressions")?;
    Ok(())
}
fn check_refs(
    root: &Value,
    value: &Value,
    seen: &mut BTreeSet<String>,
    depth: usize,
    budget: &mut usize,
) -> Result<()> {
    ensure!(
        depth <= 48 && *budget > 0,
        "schema reference expansion budget exceeded"
    );
    *budget -= 1;
    match value {
        Value::Object(map) => {
            if let Some(reference) = map.get("$ref").and_then(Value::as_str) {
                ensure!(
                    seen.insert(reference.into()),
                    "recursive schema references unsupported"
                );
                check_refs(
                    root,
                    root.pointer(&reference[1..])
                        .context("missing schema reference")?,
                    seen,
                    depth + 1,
                    budget,
                )?;
                seen.remove(reference);
            }
            for v in map.values() {
                check_refs(root, v, seen, depth + 1, budget)?;
            }
        }
        Value::Array(v) => {
            for v in v {
                check_refs(root, v, seen, depth + 1, budget)?;
            }
        }
        _ => (),
    }
    Ok(())
}
fn compile(schema: &Value) -> Result<jsonschema::Validator> {
    preflight(schema)?;
    jsonschema::options()
        .with_pattern_options(jsonschema::PatternOptions::regex())
        .build(schema)
        .map_err(|_| anyhow::anyhow!("invalid or unsupported JSON Schema"))
}
pub(super) async fn validate_schema(schema: Value) -> Result<()> {
    let permit = cpu().acquire_owned().await?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        compile(&schema).map(|_| ())
    })
    .await?
}
pub(super) async fn validate_output(schema: Value, text: String) -> Result<Vec<String>> {
    let permit = cpu().acquire_owned().await?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let validator = compile(&schema)?;
        let value = match candidate(&text) {
            Ok(v) => v,
            Err(_) => return Ok(vec!["Response is not valid JSON".into()]),
        };
        bounded_value(&value, 48, 20_000)?;
        Ok(validator
            .iter_errors(&value)
            .take(10)
            .map(|e| truncate(&e.to_string(), 512))
            .collect())
    })
    .await?
}
fn candidate(text: &str) -> Result<Value> {
    let mut raw = text.trim();
    if raw.starts_with("```") {
        raw = raw.split_once('\n').map(|(_, s)| s).unwrap_or(raw);
        raw = raw.trim_end().strip_suffix("```").unwrap_or(raw).trim();
    }
    if let Ok(parsed) = serde_json::from_str(raw) {
        return Ok(parsed);
    }
    let mut candidates = Vec::new();
    for (open, close) in [('{', '}'), ('[', ']')] {
        if let (Some(start), Some(end)) = (raw.find(open), raw.rfind(close))
            && start < end
        {
            candidates.push((start, &raw[start..=end]));
        }
    }
    candidates.sort_by_key(|(start, _)| *start);
    for (_, candidate) in candidates {
        if let Ok(value) = serde_json::from_str(candidate) {
            return Ok(value);
        }
    }
    bail!("invalid JSON output")
}

#[cfg(test)]
mod benchmarks {
    use super::*;
    #[tokio::test]
    #[ignore = "Microbenchmark: run alone after compilation"]
    async fn measure_schema_compile_and_validation() -> Result<()> {
        tokio::task::spawn_blocking(||->Result<()>{
            let schema=json!({"type":"object","properties":{"summary":{"type":"string","maxLength":2000},"items":{"type":"array","maxItems":32,"items":{"type":"object","properties":{"name":{"type":"string"},"score":{"type":"number","minimum":0}},"required":["name","score"],"additionalProperties":false}}},"required":["summary","items"],"additionalProperties":false});
            let instance=json!({"summary":"bounded result","items":[{"name":"one","score":1.0}]});
            let mut cold=Vec::new();for _ in 0..100{let start=std::time::Instant::now();let validator=compile(&schema)?;assert!(validator.is_valid(&instance));cold.push(start.elapsed().as_secs_f64()*1e6);}
            let validator=compile(&schema)?;let mut warm=Vec::new();for _ in 0..100{let start=std::time::Instant::now();assert!(validator.is_valid(&instance));warm.push(start.elapsed().as_secs_f64()*1e6);}
            cold.sort_by(f64::total_cmp);warm.sort_by(f64::total_cmp);println!("schema_samples=100 compile_validate_p50_us={:.3} p95_us={:.3} reused_validate_p50_us={:.3} p95_us={:.3}",cold[50],cold[95],warm[50],warm[95]);Ok(())
        }).await?
    }
}
