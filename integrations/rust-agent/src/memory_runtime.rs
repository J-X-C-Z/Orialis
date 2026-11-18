//! Runtime bridge for the verified Hermes memory semantics. Local legacy CRUD
//! retains replace, while the model-facing surface exposes add/patch/remove.
use crate::{
    MemoryRequest,
    migration::{MemoryOperation, apply_memory_operations, find_memory_match},
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, TransactionBehavior, params};
use serde_json::{Map, Value, json};

#[derive(Debug)]
pub struct MemoryFailure {
    message: String,
    pub consolidation: bool,
}
impl std::fmt::Display for MemoryFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for MemoryFailure {}
pub fn default_target() -> String {
    "memory".into()
}
pub fn has_legacy_replace(req: &MemoryRequest) -> bool {
    req.action == "replace"
        || req
            .operations
            .as_ref()
            .is_some_and(|ops| ops.iter().any(|op| op.action == "replace"))
}
fn number(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}
pub fn apply(db: &mut Connection, req: &MemoryRequest, limit: usize) -> Result<Value> {
    ensure!(
        req.operations.as_ref().is_none_or(|ops| !ops.is_empty()),
        "memory operations cannot be empty"
    );
    let operations = req.operations.as_ref().cloned().unwrap_or_else(|| {
        vec![MemoryOperation {
            target: None,
            action: req.action.clone(),
            content: req.content.clone(),
            new_text: req.new_text.clone(),
            old_text: req.old_text.clone(),
            matched_entry: req.matched_entry.clone(),
        }]
    });
    ensure!(operations.len() <= 200, "memory operations exceed 200");
    ensure!(
        operations.iter().all(|op| op
            .target
            .as_deref()
            .is_none_or(|target| target == req.target)),
        "one memory request cannot write multiple targets"
    );
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let entries: Vec<String> = {
        let mut q = tx.prepare("SELECT content FROM memories WHERE target=?1 ORDER BY id")?;
        q.query_map([&req.target], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    if req.action == "read" && req.operations.as_ref().is_none_or(Vec::is_empty) {
        return Ok(json!({"entries":entries,"target":req.target}));
    }
    let next = apply_memory_operations(&entries, &operations, limit).map_err(|error| {
        let text = error.to_string();
        let consolidation =
            text == "memory character limit exceeded" || text == "no memory entry matched";
        anyhow::Error::new(MemoryFailure {
            message: text,
            consolidation,
        })
    })?;
    // Collect selected previous entries while replaying only pure in-memory
    // transformations. Persist exactly once after the entire batch validates.
    let mut working = entries.clone();
    let mut extra = Map::new();
    for (index, op) in operations.iter().enumerate() {
        let selected = if op.action == "add" {
            None
        } else {
            let i = if let Some(pinned) = &op.matched_entry {
                working
                    .iter()
                    .position(|e| e == pinned)
                    .context("staged memory entry changed")?
            } else {
                let span = op.old_text.as_deref().unwrap_or("");
                find_memory_match(
                    &working,
                    if op.action == "patch" {
                        span
                    } else {
                        span.trim()
                    },
                )?
            };
            Some((i, working[i].clone()))
        };
        let after = apply_memory_operations(&working, std::slice::from_ref(op), usize::MAX)?;
        if let Some((selected_index, old)) = selected {
            let field = match op.action.as_str() {
                "replace" => "replaced_entries",
                "patch" => "patched_entries",
                _ => "removed_entries",
            };
            extra.entry(field).or_insert_with(|| json!({}))[&(index + 1).to_string()] = json!(old);
            if op.action == "patch" {
                let changed = after[selected_index].clone();
                extra
                    .entry("patched_entries_after")
                    .or_insert_with(|| json!({}))[&(index + 1).to_string()] = json!(changed);
            }
        }
        working = after;
    }
    ensure!(working == next, "memory operation replay mismatch");
    if next != entries {
        tx.execute("DELETE FROM memories WHERE target=?1", [&req.target])?;
        let mut insert = tx.prepare_cached("INSERT INTO memories(target,content) VALUES(?1,?2)")?;
        for content in &next {
            insert.execute(params![req.target, content])?;
        }
    }
    tx.commit()?;
    let used = next.join("\n§\n").chars().count();
    let pct = used
        .saturating_mul(100)
        .checked_div(limit)
        .unwrap_or(0)
        .min(100);
    let mut result = json!({"success":true,"done":true,"target":req.target,"usage":format!("{pct}% — {}/{} chars",number(used),number(limit)),"entry_count":next.len(),"message":format!("Applied {} operation(s).",operations.len()),"note":"Write saved. This update is complete — do not repeat it."});
    result.as_object_mut().unwrap().extend(extra);
    Ok(result)
}
pub fn schema() -> Value {
    let properties = json!({"action":{"type":"string","enum":["add","patch","remove"]},"content":{"type":"string"},"new_text":{"type":"string"},"old_text":{"type":"string","description":"Entry selector for remove; one literal span for patch. Ambiguous distinct entries are rejected."}});
    json!({"type":"function","function":{"name":"memory","description":"Save useful lasting facts/preferences, never secrets or instructions. Use operations for atomic consolidation, checked against the final budget. A successful done result is terminal: do not repeat it. Changes enter new sessions, not the current pinned prompt.","parameters":{"type":"object","properties":{"target":{"type":"string","enum":["memory","user"],"default":"memory"},"operations":{"type":"array","minItems":1,"maxItems":200,"items":{"type":"object","properties":properties,"required":["action"],"additionalProperties":false}},"action":properties["action"],"content":properties["content"],"new_text":properties["new_text"],"old_text":properties["old_text"]},"additionalProperties":false}}})
}
/// Imported rows preserve metadata for audit/display, not provider transport.
/// Match upstream substitute_api_content: non-empty string for user/assistant.
pub fn provider_message(message: &Value) -> Result<Value> {
    let role = message["role"]
        .as_str()
        .context("stored message role missing")?;
    ensure!(
        ["system", "developer", "user", "assistant", "tool"].contains(&role),
        "invalid stored message role"
    );
    let mut out = Map::new();
    out.insert("role".into(), json!(role));
    let mut content = message.get("content").cloned().unwrap_or(Value::Null);
    if ["user", "assistant"].contains(&role)
        && let Some(sidecar) = message["api_content"].as_str().filter(|s| !s.is_empty())
    {
        content = json!(sidecar);
    }
    out.insert("content".into(), content);
    for key in [
        "name",
        "tool_call_id",
        "tool_calls",
        "reasoning_content",
        "reasoning",
        "reasoning_details",
    ] {
        if let Some(value) = message.get(key).filter(|v| !v.is_null()) {
            out.insert(key.into(), value.clone());
        }
    }
    Ok(Value::Object(out))
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::Store;
    use std::path::Path;
    fn req(v: Value) -> MemoryRequest {
        serde_json::from_value(v).unwrap()
    }
    #[test]
    fn atomic_batch_and_terminal_envelope() -> Result<()> {
        let mut store = Store::open(Path::new(":memory:"))?;
        let done = store.memory_action(&req(
            json!({"target":"user","operations":[{"action":"add","content":"drinks tea daily"}]}),
        ))?;
        assert_eq!(done["success"], true);
        assert_eq!(done["done"], true);
        assert!(done.get("entries").is_none());
        let changed=store.memory_action(&req(json!({"target":"user","operations":[{"action":"patch","old_text":"tea ","new_text":"coffee "},{"action":"add","content":"likes books"}]})))?;
        assert_eq!(changed["patched_entries"]["1"], "drinks tea daily");
        assert_eq!(
            store.memory("user")?,
            vec!["drinks coffee daily", "likes books"]
        );
        assert!(store.memory_action(&req(json!({"target":"user","operations":[{"action":"remove","old_text":"coffee"},{"action":"remove","old_text":"missing"}]}))).is_err());
        assert_eq!(store.memory("user")?.len(), 2);
        Ok(())
    }
    #[test]
    fn duplicate_add_does_not_write_or_echo() -> Result<()> {
        let mut store = Store::open(Path::new(":memory:"))?;
        let input = req(json!({"action":"add","content":"hello"}));
        store.memory_action(&input)?;
        let out = store.memory_action(&input)?;
        assert_eq!(out["entry_count"], 1);
        assert!(out.get("entries").is_none());
        Ok(())
    }
    #[test]
    fn patch_selector_preserves_whitespace_and_duplicate_after() -> Result<()> {
        let mut store = Store::open(Path::new(":memory:"))?;
        store.memory_action(&req(json!({"operations":[{"action":"add","content":"has X"},{"action":"add","content":"X at start"},{"action":"add","content":"has Y"}]})))?;
        let result = store.memory_action(&req(
            json!({"action":"patch","old_text":" X","content":" Y"}),
        ))?;
        assert_eq!(
            store.memory("memory")?,
            vec!["has Y", "X at start", "has Y"]
        );
        assert_eq!(result["patched_entries_after"]["1"], "has Y");
        assert!(
            store
                .memory_action(&req(
                    json!({"operations":[],"action":"add","content":"must not add"})
                ))
                .is_err()
        );
        Ok(())
    }
    #[test]
    fn mixed_targets_cannot_silently_write_wrong_store() -> Result<()> {
        let mut store = Store::open(Path::new(":memory:"))?;
        assert!(store.memory_action(&req(json!({"target":"memory","operations":[{"action":"add","target":"user","content":"wrong store"}]}))).is_err());
        assert!(store.memory("memory")?.is_empty());
        assert!(store.memory("user")?.is_empty());
        store.memory_action(&req(json!({"target":"memory","operations":[{"action":"add","target":"memory","content":"right store"}]})))?;
        assert_eq!(store.memory("memory")?, vec!["right store"]);
        Ok(())
    }
    #[test]
    fn provider_sidecar_and_private_metadata_are_separate() -> Result<()> {
        let raw = json!({"role":"assistant","content":"clean","api_content":"exact API bytes","message_uid":"private","timestamp":1,"tool_calls":[{"id":"t"}],"reasoning_content":"reason"});
        let result = provider_message(&raw)?;
        assert_eq!(result["content"], "exact API bytes");
        assert!(result.get("message_uid").is_none());
        assert!(result.get("api_content").is_none());
        assert_eq!(result["tool_calls"], raw["tool_calls"]);
        assert_eq!(raw["content"], "clean");
        assert_eq!(
            provider_message(
                &json!({"role":"tool","content":"tool","api_content":"bad","tool_call_id":"t"})
            )?["content"],
            "tool"
        );
        Ok(())
    }
}
