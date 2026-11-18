//! Bounded, sanitized execution output and owner/root/epoch-scoped recovery.
use super::python_clean::clean;
use super::*;
pub(super) const SPILL_CAP: usize = 5_000_000;
const STORE_CAP: i64 = 20_000_000;
pub(super) const OUTPUT_PREFIX: &str = "python-output://";

pub(super) struct Capture {
    head: Vec<u8>,
    tail: VecDeque<u8>,
    tail_limit: usize,
    pub total: u64,
}
impl Capture {
    pub fn new(limit: usize) -> Self {
        Self {
            head: Vec::new(),
            tail: VecDeque::new(),
            tail_limit: limit.max(1024),
            total: 0,
        }
    }
    pub fn push(&mut self, bytes: &[u8]) {
        let prior = self.total;
        self.total = self.total.saturating_add(bytes.len() as u64);
        let keep = bytes.len().min(SPILL_CAP - self.head.len());
        self.head.extend_from_slice(&bytes[..keep]);
        if self.total > SPILL_CAP as u64 {
            if prior <= SPILL_CAP as u64 {
                self.tail.extend(
                    self.head[self.head.len().saturating_sub(self.tail_limit)..]
                        .iter()
                        .copied(),
                );
            }
            self.tail.extend(&bytes[keep..]);
            if self.tail.len() > self.tail_limit {
                self.tail.drain(..self.tail.len() - self.tail_limit);
            }
        }
    }
    pub fn finish(&self) -> Captured {
        let mut text = clean(&String::from_utf8_lossy(&self.head));
        let mut capped = self.total > SPILL_CAP as u64;
        if capped {
            text.push_str("\n[... host capture capped; omitted middle is unavailable ...]\n");
            text.push_str(&clean(&String::from_utf8_lossy(
                &self.tail.iter().copied().collect::<Vec<_>>(),
            )));
        }
        // UTF-8 repair can expand raw bytes. Keep the persistence bound in bytes.
        if text.len() > SPILL_CAP {
            text = head_tail(&text, SPILL_CAP).0;
            capped = true;
        }
        Captured {
            text,
            raw_total: self.total,
            capped,
        }
    }
}
pub(super) struct CellOutput<'a> {
    pub stdout: &'a Capture,
    pub stderr: &'a Capture,
    pub trace: &'a str,
    pub notice: &'a str,
}
pub(super) struct Captured {
    pub text: String,
    pub raw_total: u64,
    pub capped: bool,
}
fn prefix_boundary(text: &str, mut end: usize) -> usize {
    end = end.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    end
}
fn suffix_boundary(text: &str, mut start: usize) -> usize {
    start = start.min(text.len());
    while !text.is_char_boundary(start) {
        start += 1;
    }
    start
}
pub(super) fn head_tail(text: &str, limit: usize) -> (String, usize) {
    if text.len() <= limit {
        return (text.to_owned(), text.len());
    }
    if limit < 80 {
        let end = prefix_boundary(text, limit);
        return (text[..end].to_owned(), end);
    }
    let budget = limit.saturating_sub(80);
    let head = prefix_boundary(text, budget * 40 / 100);
    let tail = suffix_boundary(text, text.len().saturating_sub(budget - budget * 40 / 100));
    let captured = head + text.len() - tail;
    let notice = format!("\n[... {} bytes omitted ...]\n", text.len() - captured);
    (
        format!("{}{}{}", &text[..head], notice, &text[tail..]),
        captured,
    )
}
impl LocalTools {
    fn save_python_output(
        &self,
        context: &TurnContext,
        generation: i64,
        text: &str,
    ) -> Result<String> {
        ensure!(text.len() <= SPILL_CAP, "clean output exceeds spill bound");
        let reference = format!("{OUTPUT_PREFIX}{}", uuid::Uuid::new_v4());
        let mut db = self.inner.db.lock().unwrap();
        let tx = db.transaction()?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS local_python_outputs(id INTEGER PRIMARY KEY,reference TEXT NOT NULL UNIQUE,scope TEXT NOT NULL,generation INTEGER NOT NULL,body BLOB NOT NULL)")?;
        tx.execute(
            "INSERT INTO local_python_outputs(reference,scope,generation,body) VALUES(?1,?2,?3,?4)",
            params![reference, scope(context)?, generation, text.as_bytes()],
        )?;
        loop {
            let (count, bytes): (i64, i64) = tx.query_row(
                "SELECT COUNT(*),COALESCE(SUM(length(body)),0) FROM local_python_outputs",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            if count <= 16 && bytes <= STORE_CAP {
                break;
            }
            tx.execute("DELETE FROM local_python_outputs WHERE id=(SELECT MIN(id) FROM local_python_outputs)",[])?;
        }
        tx.commit()?;
        Ok(reference)
    }
    pub(super) async fn read_python_output(
        &self,
        args: Value,
        context: &TurnContext,
        expected_generation: Option<i64>,
    ) -> Result<Value> {
        known(&args, &["path", "offset", "limit"])?;
        let path = string(&args, "path")?.to_owned();
        let token = path
            .strip_prefix(OUTPUT_PREFIX)
            .context("invalid output reference")?;
        uuid::Uuid::parse_str(token).context("invalid output reference")?;
        let offset = number(&args, "offset", 1, SPILL_CAP + 1)?;
        let limit = number(&args, "limit", 8192, 65536)?;
        ensure!(
            offset > 0 && limit >= 4,
            "output byte offset must be >=1 and limit must be 4..65536"
        );
        let tools = self.clone();
        let context = context.clone();
        tokio::task::spawn_blocking(move||{
            let generation=match expected_generation { Some(generation) => generation, None => tools.inner.python.current_generation(&context.session_id)? };
            tools.inner.python.check_generation(&context.session_id,generation)?;
            let db=tools.inner.db.lock().unwrap();
            let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_python_outputs')",[],|r|r.get(0))?;
            ensure!(exists,"output is unavailable or expired in this session generation");
            let bytes:Vec<u8>=db.query_row("SELECT body FROM local_python_outputs WHERE reference=?1 AND scope=?2 AND generation=?3",params![path,scope(&context)?,generation],|r|r.get(0)).optional()?.context("output is unavailable or expired in this session generation")?;
            drop(db);
            tools.inner.python.check_generation(&context.session_id,generation)?;
            let text=String::from_utf8(bytes)?;
            let start=(offset-1).min(text.len());ensure!(text.is_char_boundary(start),"output offset is not a UTF-8 byte boundary; use next_offset");
            let end=prefix_boundary(&text,start.saturating_add(limit));
            Ok(json!({"path":path,"content":&text[start..end],"offset_unit":"utf8_bytes","total_bytes":text.len(),"next_offset":if end<text.len(){Some(end+1)}else{None},"complete_read":end==text.len(),"sanitized":true,"read_only":true}))
        }).await?
    }
    pub(super) fn finish_python_output(
        &self,
        context: &TurnContext,
        generation: i64,
        streams: CellOutput<'_>,
        value: &mut Value,
    ) {
        let out = streams.stdout.finish();
        let mut err = streams.stderr.finish();
        if !streams.trace.is_empty() {
            err.text.push_str(&clean(streams.trace));
        }
        if err.text.len() > SPILL_CAP {
            err.text = head_tail(&err.text, SPILL_CAP).0;
            err.capped = true;
        }
        let notice = head_tail(streams.notice, self.inner.cfg.output_bytes / 2).0;
        let notice_budget = if notice.is_empty() {
            0
        } else {
            notice.len() + 2
        };
        let stderr_limit =
            10_000.min(self.inner.cfg.output_bytes.saturating_sub(notice_budget) / 2);
        let (error_inline, error_captured) = head_tail(&err.text, stderr_limit);
        let join = if error_inline.is_empty() {
            ""
        } else {
            "\n--- stderr ---\n"
        };
        let stdout_limit = 50_000.min(
            self.inner
                .cfg
                .output_bytes
                .saturating_sub(error_inline.len() + join.len() + notice_budget),
        );
        let (stdout_inline, stdout_captured) = head_tail(&out.text, stdout_limit);
        value["output"] = json!(format!(
            "{stdout_inline}{join}{error_inline}{}{notice}",
            if notice.is_empty() { "" } else { "\n\n" }
        ));
        value["output_is_bounded_tail"] = json!(false);
        value["output_truncation"] = json!("head_tail");
        value["output_bytes_seen"] = json!(out.raw_total.saturating_add(err.raw_total));
        value["output_truncated"] = json!(
            out.capped
                || err.capped
                || out.text.len() > stdout_limit
                || err.text.len() > stderr_limit
        );
        for (name, capture, limit, captured) in [
            ("stdout", out, stdout_limit, stdout_captured),
            ("stderr", err, stderr_limit, error_captured),
        ] {
            let truncated = capture.capped || capture.text.len() > limit;
            value[format!("{name}_truncated")] = json!(truncated);
            value[format!("{name}_bytes_captured")] = json!(captured);
            value[format!("{name}_bytes_total")] = if capture.capped {
                Value::Null
            } else {
                json!(capture.text.len())
            };
            value[format!("{name}_bytes_omitted")] = if capture.capped {
                Value::Null
            } else {
                json!(capture.text.len() - captured)
            };
            value[format!("{name}_raw_bytes_total")] = json!(capture.raw_total);
            value[format!("{name}_capture_capped")] = json!(capture.capped);
            if truncated {
                match self.save_python_output(context, generation, &capture.text) {
                    Ok(path) => {
                        value[format!("{name}_spill_path")] = json!(path);
                        value[format!("{name}_spill_complete")] = json!(!capture.capped);
                        append_warning(
                            value,
                            &format!(
                                "{name} was truncated (40/60 head/tail shown). {} sanitized output is recoverable with read_file(path={path:?}, offset=1, limit=8192); follow byte next_offset. Do not rerun effects to recover output.",
                                if capture.capped { "Capped" } else { "Full" }
                            ),
                        );
                    }
                    Err(_) => append_warning(
                        value,
                        &format!(
                            "{name} was truncated and sanitized output storage failed; the code already ran. Do not repeat effects to recover output."
                        ),
                    ),
                }
            }
        }
    }
}
pub(super) fn append_warning(value: &mut Value, text: &str) {
    let previous = value["warning"].as_str().unwrap_or("");
    value["warning"] = json!(format!(
        "{previous}{}{text}",
        if previous.is_empty() { "" } else { " " }
    ));
}
