//! Orialis Agent Gateway v1 supported subset. Validation is separate from execution capabilities.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
pub fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    let t = v[k].as_str().context(format!("missing {k}"))?;
    ensure!(!t.trim().is_empty(), "empty {k}");
    Ok(t)
}
pub fn digest(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
pub fn chat_id(id: &str) -> String {
    let mut s = String::from("orialis:");
    for b in id.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            s.push(b as char)
        } else {
            s.push_str(&format!("%{b:02X}"))
        }
    }
    s
}
pub fn final_reply(anchor: &Value, content: &str) -> Result<Value> {
    let cid = text(anchor, "conversation_id")?;
    let mid = text(anchor, "message_id")?;
    // Python json.dumps(..., ensure_ascii=False, sort_keys=True) defaults to comma-space separators.
    let identity = format!(
        "[{}, {}, {}, null]",
        serde_json::to_string(&chat_id(cid))?,
        serde_json::to_string(mid)?,
        serde_json::to_string(content)?
    );
    Ok(
        json!({"version":1,"type":"message.reply","message_id":format!("final_{}",&digest(&identity)[..24]),"conversation_id":cid,"reply_to":mid,"content":content}),
    )
}
/// Same deterministic final identity as the Hermes adapter, including the exact
/// attachment payload. Python's default JSON separators are significant here.
pub fn final_reply_with_attachments(
    anchor: &Value,
    content: &str,
    attachments: &[crate::attachments::AttachmentMetadata],
) -> Result<Value> {
    if attachments.is_empty() {
        return final_reply(anchor, content);
    }
    let cid = text(anchor, "conversation_id")?;
    let mid = text(anchor, "message_id")?;
    let attachments = serde_json::to_value(attachments)?;
    let identity = python_json(&json!([chat_id(cid), mid, content, attachments]));
    let mut reply = json!({"version":1,"type":"message.reply","message_id":format!("final_{}",&digest(&identity)[..24]),"conversation_id":cid,"reply_to":mid,"content":content,"attachments":attachments});
    validate(&mut reply)?;
    Ok(reply)
}
fn python_json(value: &Value) -> String {
    match value {
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(python_json)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Object(values) => {
            let mut keys: Vec<_> = values.keys().collect();
            keys.sort();
            format!(
                "{{{}}}",
                keys.into_iter()
                    .map(|k| format!(
                        "{}: {}",
                        serde_json::to_string(k).unwrap(),
                        python_json(&values[k])
                    ))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        }
        _ => serde_json::to_string(value).expect("JSON value serialization"),
    }
}
pub fn error(code: &str, anchor: Option<&str>) -> Value {
    let mut v = json!({"version":1,"type":"error","code":code,"message":"The request was not completed. Check its recorded status and any completed tool actions before deciding whether to retry."});
    if let Some(id) = anchor {
        v["reply_to"] = json!(id)
    }
    v
}
pub fn parse(raw: &str) -> Result<Value> {
    let mut v: Value = serde_json::from_str(raw)?;
    validate(&mut v)?;
    Ok(v)
}
pub fn encode(v: &Value) -> Result<String> {
    let mut v = v.clone();
    validate(&mut v)?;
    Ok(serde_json::to_string(&v)?)
}
pub fn validate(v: &mut Value) -> Result<()> {
    ensure!(
        v.is_object() && v["version"].as_i64() == Some(1),
        "invalid version"
    );
    let kind = text(v, "type")?.to_owned();
    match kind.as_str() {
        "message.send" | "message.reply" => {
            text(v, "message_id")?;
            text(v, "conversation_id")?;
            if kind == "message.reply" {
                text(v, "reply_to")?;
            }
            if !v["attachments"].is_null() {
                attachments(&mut v["attachments"])?;
            }
            if let Some(c) = v.get("content") {
                ensure!(c.is_string(), "content must be string");
            }
            ensure!(
                v["content"].as_str().is_some_and(|s| !s.trim().is_empty())
                    || v["attachments"].as_array().is_some_and(|a| !a.is_empty()),
                "content or attachment required"
            );
        }
        "clarify.response" | "clarify.resolve" | "clarify.cancel" | "approval.response"
        | "approval.resolve" => {
            ensure!(
                text(v, "request_id")?.len() <= 160,
                "interaction request id too long"
            );
            let conversation = v["conversation_id"]
                .as_str()
                .or_else(|| v["session_id"].as_str())
                .context("interaction scope missing")?;
            ensure!(
                !conversation.trim().is_empty() && conversation.len() <= 160,
                "invalid interaction scope"
            );
            if let Some(seq) = v.get("seq") {
                ensure!(
                    seq.as_u64().is_some_and(|n| n > 0),
                    "invalid interaction sequence"
                );
                ensure!(
                    text(v, "event_id")?.len() <= 160,
                    "invalid interaction event id"
                );
            }
        }
        "workspace.request" | "workspace.response" => {
            for key in ["request_id", "conversation_id"] {
                ensure!(text(v, key)?.len() <= 160, "workspace identifier too long");
            }
            ensure!(
                v["payload"].is_object() && v["payload"].to_string().len() <= 1_500_000,
                "invalid workspace payload"
            );
        }
        "session.info" | "session.reset" => {
            for key in ["request_id", "conversation_id", "session_id"] {
                ensure!(text(v, key)?.len() <= 160, "invalid session identifier");
            }
        }
        "session.reply" => {
            for key in ["request_id", "conversation_id", "status"] {
                ensure!(text(v, key)?.len() <= 160, "invalid session response");
            }
            if let Some(message) = v.get("message") {
                ensure!(
                    message.is_null() || message.as_str().is_some_and(|s| s.len() <= 4000),
                    "invalid session response message"
                );
            }
        }
        "memory.analyze" => crate::screen_memory::validate_request(v)?,
        "memory.result" => {
            ensure!(text(v, "request_id")?.len() <= 160, "request_id too long");
            ensure!(
                v["content"].is_null() != v["error"].is_null(),
                "exactly one of content/error required"
            );
            for field in ["content", "error"] {
                if !v[field].is_null() {
                    ensure!(text(v, field)?.len() <= 100_000, "result too large");
                }
            }
            ensure!(
                v["category"].is_null() || matches!(v["category"].as_str(), Some("ai" | "other")),
                "invalid category"
            );
            ensure!(
                v["video_status"].is_null()
                    || matches!(
                        v["video_status"].as_str(),
                        Some("none" | "analyzed" | "unavailable")
                    ),
                "invalid video_status"
            );
            for (field, max) in [("video_summary", 100_000), ("video_error", 4000)] {
                if !v[field].is_null() {
                    ensure!(text(v, field)?.len() <= max, "result too large");
                }
            }
            if !v["source_url"].is_null() {
                web_url(text(v, "source_url")?)?;
            }
        }
        "message.ack" => {
            text(v, "message_id")?;
            text(v, "status")?;
        }
        "agent.ack" => {
            text(v, "event_id")?;
            ensure!(
                v["seq"].as_u64().is_some_and(|n| n > 0),
                "invalid event acknowledgement sequence"
            );
            ensure!(
                matches!(
                    v["status"].as_str(),
                    Some("received" | "duplicate" | "gap" | "unknown")
                ),
                "invalid event acknowledgement status"
            );
            if v["status"] == "gap" {
                ensure!(
                    v["expected_seq"].as_u64().is_some_and(|n| n > 0),
                    "gap requires positive expected_seq"
                );
            } else if !v["expected_seq"].is_null() {
                ensure!(
                    v["expected_seq"].as_u64().is_some_and(|n| n > 0),
                    "invalid expected_seq"
                );
            }
        }
        "hello" => {
            for k in ["device_id", "client", "plugin_version", "platform"] {
                text(v, k)?;
            }
            ensure!(valid_device(text(v, "device_id")?), "invalid device id");
            capabilities(v)?;
        }
        "hello_ack" | "capabilities.hello" | "capabilities.ack" => {
            capabilities(v)?;
            for k in ["resume_from", "next_seq"] {
                if !v[k].is_null() {
                    ensure!(v[k].as_u64().is_some(), "invalid sequence");
                }
            }
        }
        "delivery.send" | "cron.delivery" | "proactive.delivery" => {
            for key in ["delivery_id", "conversation_id"] {
                ensure!(text(v, key)?.len() <= 160, "delivery identifier too long");
            }
            if let Some(attachments_value) = v.get_mut("attachments") {
                attachments(attachments_value)?;
            }
            if let Some(content) = v.get("content") {
                ensure!(
                    content.as_str().is_some_and(|s| s.len() <= 256 * 1024),
                    "invalid delivery content"
                );
            }
            ensure!(
                v["content"].as_str().is_some_and(|s| !s.trim().is_empty())
                    || v["attachments"].as_array().is_some_and(|a| !a.is_empty()),
                "delivery requires content or attachment"
            );
        }
        "delivery.ack" => {
            ensure!(
                text(v, "delivery_id")?.len() <= 160,
                "invalid delivery identity"
            );
            ensure!(
                text(v, "conversation_id")?.len() <= 160,
                "invalid delivery conversation"
            );
            ensure!(
                matches!(
                    text(v, "status")?,
                    "received" | "accepted" | "duplicate" | "rejected" | "error"
                ),
                "invalid delivery status"
            );
        }
        "ping" | "pong" => {}
        "error" => {
            text(v, "code")?;
            text(v, "message")?;
            if !v["reply_to"].is_null() {
                text(v, "reply_to")?;
            }
        }
        _ => bail!("unsupported frame type"),
    }
    Ok(())
}
fn capabilities(v: &mut Value) -> Result<()> {
    if v.get("capabilities").is_none() {
        v["capabilities"] = v.get("features").cloned().unwrap_or(json!([]));
    }
    if v["capabilities"].is_null() {
        v["capabilities"] = json!([]);
    }
    let a = v["capabilities"]
        .as_array()
        .context("invalid capabilities")?;
    ensure!(
        a.len() <= 64
            && a.iter()
                .all(|x| x.as_str().is_some_and(|s| !s.trim().is_empty())),
        "invalid capabilities"
    );
    Ok(())
}
pub fn valid_device(id: &str) -> bool {
    let p: Vec<_> = id.split('_').collect();
    id.len() <= 80
        && p.len() == 3
        && p.iter()
            .all(|s| (2..=24).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric()))
}
pub fn web_url(s: &str) -> Result<()> {
    ensure!(s.len() <= 8192, "URL too long");
    let u = reqwest::Url::parse(s)?;
    ensure!(
        matches!(u.scheme(), "http" | "https")
            && u.host_str().is_some()
            && u.username().is_empty()
            && u.password().is_none(),
        "invalid source URL"
    );
    Ok(())
}
fn attachments(v: &mut Value) -> Result<()> {
    let a = v.as_array_mut().context("invalid attachments")?;
    ensure!(a.len() <= 16, "too many attachments");
    for item in a {
        let o = item.as_object_mut().context("invalid attachment")?;
        for (old, new) in [("mimeType", "mime_type"), ("downloadUrl", "download_url")] {
            if !o.contains_key(new)
                && let Some(v) = o.remove(old)
            {
                o.insert(new.into(), v);
            }
        }
        ensure!(
            o.keys()
                .all(|k| ["id", "name", "mime_type", "size", "download_url"].contains(&k.as_str())),
            "unexpected attachment field"
        );
        for k in ["id", "name", "mime_type", "download_url"] {
            text(item, k)?;
        }
        ensure!(
            text(item, "name")?.chars().count() <= 180,
            "attachment name too long"
        );
        let mime = text(item, "mime_type")?
            .split(';')
            .next()
            .unwrap()
            .trim()
            .to_lowercase();
        ensure!(
            mime.starts_with("image/")
                || mime.starts_with("text/")
                || [
                    "application/pdf",
                    "application/json",
                    "application/xml",
                    "application/octet-stream",
                    "application/zip"
                ]
                .contains(&mime.as_str()),
            "unsupported attachment MIME"
        );
        if !item["size"].is_null() {
            ensure!(
                item["size"].as_u64().is_some_and(|n| n > 0),
                "invalid attachment size"
            );
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn correlation_unicode() {
        let a = json!({"message_id":"m","conversation_id":"中文 /+"});
        let r = final_reply(&a, "回答").unwrap();
        assert_eq!(chat_id("中文 /+"), "orialis:%E4%B8%AD%E6%96%87%20%2F%2B");
        assert_eq!(r["reply_to"], "m");
        assert_eq!(r["conversation_id"], "中文 /+");
        assert!(r["message_id"].as_str().unwrap().starts_with("final_"));
    }
    #[test]
    fn agent_ack_requires_exact_structural_receipt_fields() {
        let valid = json!({"version":1,"type":"agent.ack","event_id":"event-id","seq":2,"status":"gap","expected_seq":1});
        assert!(parse(&valid.to_string()).is_ok());
        for (key, value) in [
            ("seq", json!(0)),
            ("seq", json!(true)),
            ("event_id", json!("")),
            ("status", json!("accepted")),
            ("expected_seq", json!(0)),
            ("expected_seq", Value::Null),
        ] {
            let mut invalid = valid.clone();
            invalid[key] = value;
            assert!(parse(&invalid.to_string()).is_err());
        }
    }
    #[test]
    fn delivery_text_and_attachment_wire_validation() {
        for kind in ["delivery.send", "cron.delivery", "proactive.delivery"] {
            let good = json!({"version":1,"type":kind,"delivery_id":"job","conversation_id":"c","content":"/new"});
            assert!(parse(&good.to_string()).is_ok());
            for (key, value) in [
                ("delivery_id", json!("x".repeat(161))),
                ("conversation_id", json!("")),
                ("content", json!(1)),
                ("content", json!("")),
                ("attachments", Value::Null),
            ] {
                let mut bad = good.clone();
                bad[key] = value;
                assert!(parse(&bad.to_string()).is_err());
            }
            let media = json!({"version":1,"type":kind,"delivery_id":"job","conversation_id":"c",
                "attachments":[{"id":"a","name":"a.png","mime_type":"image/png","download_url":"/api/v1/attachments/a"}]});
            assert!(parse(&media.to_string()).is_ok());
        }
    }
    #[test]
    fn invalid_frames() {
        for v in [
            json!({"version":true,"type":"ping"}),
            json!({"version":1,"type":"message.send","message_id":"m","conversation_id":"c","content":""}),
            json!({"version":1,"type":"voice.start"}),
        ] {
            assert!(validate(&mut v.clone()).is_err());
        }
    }
}
