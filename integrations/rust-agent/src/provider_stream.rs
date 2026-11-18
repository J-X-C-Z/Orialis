//! Bounded OpenAI-compatible SSE assembly. This does not advertise gateway
//! streaming on its own: the caller must implement the negotiated wire events.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::collections::BTreeMap;

const MAX_EVENT_BYTES: usize = 262_144;
const MAX_TOTAL_BYTES: usize = 4_194_304;
const MAX_TOOL_CALLS: usize = 32;

#[derive(Default)]
pub struct StreamAssembler {
    pending: Vec<u8>,
    scan_from: usize,
    total_bytes: usize,
    answer: String,
    calls: BTreeMap<usize, ToolDelta>,
    completed: bool,
    finish_reason: Option<String>,
}
#[derive(Default)]
struct ToolDelta {
    id: String,
    name: String,
    arguments: String,
}
impl StreamAssembler {
    /// Accept arbitrary network fragments, including split UTF-8 and CRLF.
    /// Returned strings are displayable assistant content deltas only.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>> {
        ensure!(
            !self.completed || bytes.iter().all(u8::is_ascii_whitespace),
            "data after completed model stream"
        );
        self.total_bytes = self
            .total_bytes
            .checked_add(bytes.len())
            .context("stream length overflow")?;
        ensure!(
            self.total_bytes <= MAX_TOTAL_BYTES,
            "model stream too large"
        );
        self.pending.extend_from_slice(bytes);
        let mut content = Vec::new();
        let mut consumed = 0;
        loop {
            let search_start = consumed + self.scan_from;
            let Some((relative_end, delimiter)) = boundary(&self.pending[search_start..]) else {
                break;
            };
            let end = search_start + relative_end;
            ensure!(
                end - consumed <= MAX_EVENT_BYTES,
                "model stream event too large"
            );
            let event = std::str::from_utf8(&self.pending[consumed..end])
                .context("invalid UTF-8 model event")?;
            let data = event
                .lines()
                .filter_map(|line| {
                    line.strip_prefix("data:")
                        .map(|s| s.strip_prefix(' ').unwrap_or(s))
                })
                .collect::<Vec<_>>()
                .join("\n");
            consumed = end + delimiter;
            self.scan_from = 0;
            if data.is_empty() {
                continue;
            }
            ensure!(!self.completed, "model data after DONE");
            if data.trim() == "[DONE]" {
                self.completed = true;
                continue;
            }
            let v: Value = serde_json::from_str(&data).context("invalid model stream JSON")?;
            ensure!(v.get("error").is_none(), "provider streamed an error");
            let choices = v["choices"]
                .as_array()
                .context("model chunk missing choices")?;
            // Usage-only terminal frames are permitted.
            if choices.is_empty() {
                continue;
            }
            let choice = choices
                .iter()
                .find(|c| c["index"].as_u64().unwrap_or(0) == 0)
                .context("model stream lacks choice zero")?;
            if let Some(reason) = choice["finish_reason"].as_str() {
                self.finish_reason = Some(reason.to_owned());
            }
            let delta = &choice["delta"];
            ensure!(delta.is_object(), "model chunk missing delta");
            if let Some(role) = delta["role"].as_str() {
                ensure!(role == "assistant", "unexpected streamed role");
            }
            if let Some(text) = delta["content"].as_str() {
                ensure!(
                    self.answer.len() + text.len() <= MAX_TOTAL_BYTES,
                    "model answer too large"
                );
                self.answer.push_str(text);
                if !text.is_empty() {
                    content.push(text.to_owned());
                }
            } else {
                ensure!(
                    delta["content"].is_null(),
                    "stream content must be string or null"
                );
            }
            if let Some(calls) = delta.get("tool_calls").filter(|v| !v.is_null()) {
                for call in calls.as_array().context("tool call deltas must be array")? {
                    let index = call["index"]
                        .as_u64()
                        .context("tool delta index required")?
                        as usize;
                    ensure!(index < MAX_TOOL_CALLS, "too many streamed tools");
                    if let Some(kind) = call["type"].as_str() {
                        ensure!(kind == "function", "unsupported tool type");
                    }
                    let slot = self.calls.entry(index).or_default();
                    append(&mut slot.id, &call["id"], 1024)?;
                    append(&mut slot.name, &call["function"]["name"], 256)?;
                    append(
                        &mut slot.arguments,
                        &call["function"]["arguments"],
                        MAX_EVENT_BYTES,
                    )?;
                }
            }
        }
        // Move the unconsumed tail once per network chunk, not once per SSE
        // event. Resume delimiter scanning from the last three bytes so a long
        // byte-fragmented event is linear rather than repeatedly rescanned.
        if consumed > 0 {
            self.pending.drain(..consumed);
        }
        self.scan_from = self.pending.len().saturating_sub(3);
        ensure!(
            self.pending.len() <= MAX_EVENT_BYTES,
            "incomplete model event too large"
        );
        Ok(content)
    }
    pub fn finish(self) -> Result<Value> {
        ensure!(self.completed, "model stream ended without DONE");
        ensure!(
            self.pending.iter().all(u8::is_ascii_whitespace),
            "partial event after stream end"
        );
        ensure!(
            !matches!(
                self.finish_reason.as_deref(),
                Some("length" | "content_filter")
            ),
            "model stream stopped before a complete answer"
        );
        let mut answer = json!({"role":"assistant","content":self.answer});
        if !self.calls.is_empty() {
            let mut calls = Vec::with_capacity(self.calls.len());
            for (expected, (index, c)) in self.calls.into_iter().enumerate() {
                ensure!(
                    expected == index && !c.id.is_empty() && !c.name.is_empty(),
                    "incomplete tool call stream"
                );
                let args: Value = serde_json::from_str(&c.arguments)
                    .context("streamed tool arguments incomplete")?;
                ensure!(args.is_object(), "tool arguments must be object");
                calls.push(json!({"id":c.id,"type":"function","function":{"name":c.name,"arguments":c.arguments}}));
            }
            answer["tool_calls"] = Value::Array(calls);
        }
        Ok(answer)
    }
}
fn append(out: &mut String, v: &Value, cap: usize) -> Result<()> {
    if v.is_null() {
        return Ok(());
    }
    let s = v.as_str().context("tool delta must be string")?;
    ensure!(out.len() + s.len() <= cap, "tool delta exceeds bound");
    out.push_str(s);
    Ok(())
}
fn boundary(bytes: &[u8]) -> Option<(usize, usize)> {
    for i in 0..bytes.len().saturating_sub(1) {
        if bytes[i..].starts_with(b"\n\n") {
            return Some((i, 2));
        }
        if bytes[i..].starts_with(b"\r\n\r\n") {
            return Some((i, 4));
        }
    }
    None
}

pub async fn consume(
    mut response: reqwest::Response,
    deltas: &tokio::sync::mpsc::Sender<String>,
) -> Result<Value> {
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    ensure!(
        content_type
            .split(';')
            .next()
            .is_some_and(|s| s.trim() == "text/event-stream"),
        "provider did not return event-stream"
    );
    let mut parser = StreamAssembler::default();
    while let Some(chunk) = response.chunk().await? {
        for delta in parser.push(&chunk)? {
            // Backpressure is deliberate: never accumulate unbounded UI events.
            if deltas.send(delta).await.is_err() {
                bail!("stream consumer disconnected");
            }
        }
    }
    parser.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(v: Value) -> String {
        format!("data: {v}\n\n")
    }
    #[test]
    fn every_byte_split_and_crlf_keep_utf8() {
        let input = format!(
            "{}{}data: [DONE]\r\n\r\n",
            frame(
                json!({"choices":[{"index":0,"delta":{"role":"assistant","content":"中文🙂"},"finish_reason":null}]})
            ),
            frame(json!({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}))
        );
        let mut p = StreamAssembler::default();
        let mut d = Vec::new();
        for b in input.bytes() {
            d.extend(p.push(&[b]).unwrap());
        }
        assert_eq!(d.concat(), "中文🙂");
        assert_eq!(p.finish().unwrap()["content"], "中文🙂");
    }
    #[test]
    fn parallel_tool_argument_fragments_reassemble_by_index() {
        let mut p = StreamAssembler::default();
        for delta in [
            json!({"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"read","arguments":"{"}},{"index":0,"id":"a","function":{"name":"memo","arguments":"{\"v\":"}}]}),
            json!({"tool_calls":[{"index":0,"function":{"name":"ry","arguments":"1}"}},{"index":1,"function":{"arguments":"}"}}]}),
        ] {
            p.push(frame(json!({"choices":[{"index":0,"delta":delta}]})).as_bytes())
                .unwrap();
        }
        p.push(b"data: [DONE]\n\n").unwrap();
        let out = p.finish().unwrap();
        assert_eq!(out["tool_calls"][0]["function"]["name"], "memory");
        assert_eq!(out["tool_calls"][1]["id"], "b");
    }
    #[test]
    fn truncated_or_filtered_stream_is_not_success() {
        assert!(StreamAssembler::default().finish().is_err());
        let mut p = StreamAssembler::default();
        p.push(frame(json!({"choices":[{"delta":{},"finish_reason":"length"}]})).as_bytes())
            .unwrap();
        p.push(b"data: [DONE]\n\n").unwrap();
        assert!(p.finish().is_err());
    }
    #[test]
    fn invalid_tool_json_cannot_execute() {
        let mut p = StreamAssembler::default();
        p.push(frame(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"memory","arguments":"{broken"}}]}}]})).as_bytes()).unwrap();
        p.push(b"data: [DONE]\n\n").unwrap();
        assert!(p.finish().is_err());
    }
    #[test]
    fn limits_and_unexpected_roles_rejected() {
        let mut p = StreamAssembler::default();
        assert!(
            p.push(frame(json!({"choices":[{"delta":{"role":"system"}}]})).as_bytes())
                .is_err()
        );
        let mut p = StreamAssembler::default();
        assert!(p.push(&vec![b'x'; MAX_EVENT_BYTES + 1]).is_err());
    }
}
