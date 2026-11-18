//! Owner- and conversation-bound host controls. No model, tools, or route mutex.
//!
//! `TurnContext` MUST come from the authenticated host, never model arguments.
//! Responses are durable snapshots, not transport/delivery acknowledgements.
use crate::{Core, session_context as sc, tool_runtime::TurnContext, wire};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const MAX_CONTENT: usize = 48 * 1024;
const MAX_RECEIPTS: i64 = 16_384;
const MAX_RECEIPT_BYTES: i64 = 64 * 1024 * 1024;
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS session_control_receipts (
 route_id TEXT NOT NULL,input_id TEXT NOT NULL,fingerprint TEXT NOT NULL,response_json TEXT NOT NULL,
 PRIMARY KEY(route_id,input_id));
CREATE TABLE IF NOT EXISTS session_control_totals (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), receipts INTEGER NOT NULL, bytes INTEGER NOT NULL);
INSERT OR IGNORE INTO session_control_totals SELECT 1,count(*),COALESCE(sum(length(CAST(response_json AS BLOB))),0) FROM session_control_receipts;
CREATE INDEX IF NOT EXISTS session_controls_turn_latest ON context_turns(route_id,generation,created_at DESC);
CREATE INDEX IF NOT EXISTS session_controls_turn_binding ON context_turns(session_id,route_id);";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum SessionSelector {
    Current,
    Generation(i64),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum NormalizedCommand {
    List {
        limit: usize,
        offset: usize,
    },
    Info {
        session: SessionSelector,
    },
    History {
        session: SessionSelector,
        limit: usize,
        offset: usize,
    },
    /// Protocol session.info requests a live durable-state snapshot.
    Status {
        session: SessionSelector,
    },
    HostReset,
    HostStop,
    Unsupported {
        command: String,
    },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum ReplyKind {
    Message,
    Command,
    Session,
}
#[derive(Clone, Debug, Serialize)]
pub struct RequestAnchor {
    pub kind: ReplyKind,
    pub input_id: String,
    pub conversation_id: String,
}
#[derive(Clone, Debug)]
pub struct CommandRequest {
    command: NormalizedCommand,
    anchor: RequestAnchor,
    route: String,
    fingerprint: String,
}
impl CommandRequest {
    pub fn command(&self) -> &NormalizedCommand {
        &self.command
    }
    pub fn anchor(&self) -> &RequestAnchor {
        &self.anchor
    }
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }
    /// Host reset/stop must finish through the host's existing fenced path.
    /// This formats the resulting response only; it does not execute or record it.
    pub fn host_response(&self, status: &str, data: Value) -> Result<CommandResponse> {
        ensure!(
            matches!(
                self.command,
                NormalizedCommand::HostReset | NormalizedCommand::HostStop
            ),
            "not a host action"
        );
        ensure!(
            matches!(status, "completed" | "cancelled" | "error"),
            "invalid host result status"
        );
        response(self, status, data)
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CommandResponse {
    pub frame: Value,
    pub data: Value,
    pub status: String,
}
fn identifier(value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= 160 && !value.chars().any(char::is_control),
        "invalid command identifier"
    );
    Ok(())
}
fn selector(raw: Option<&str>, route: &str) -> Result<SessionSelector> {
    let Some(raw) = raw else {
        return Ok(SessionSelector::Current);
    };
    if raw == "current" {
        return Ok(SessionSelector::Current);
    }
    if raw == route {
        return Ok(SessionSelector::Generation(0));
    }
    let number = raw.strip_prefix(&format!("{route}.")).unwrap_or(raw);
    ensure!(
        !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()),
        "session selector is outside this conversation"
    );
    let generation: i64 = number.parse().context("invalid generation")?;
    ensure!(
        generation >= 0 && (number == "0" || !number.starts_with('0')),
        "noncanonical generation"
    );
    Ok(SessionSelector::Generation(generation))
}
fn page(args: &[&str]) -> Result<(usize, usize)> {
    let (mut limit, mut offset) = (20, 0);
    let (mut seen_limit, mut seen_offset) = (false, false);
    let (pairs, remainder) = args.as_chunks::<2>();
    ensure!(
        remainder.is_empty(),
        "pagination expects --limit N and/or --offset N"
    );
    for pair in pairs {
        match pair[0] {
            "--limit" if !seen_limit => {
                limit = pair[1].parse()?;
                seen_limit = true;
            }
            "--offset" if !seen_offset => {
                offset = pair[1].parse()?;
                seen_offset = true;
            }
            _ => bail!("unsupported or duplicate pagination option"),
        }
    }
    ensure!(
        (1..=50).contains(&limit) && offset <= 100_000,
        "pagination bounds exceeded"
    );
    Ok((limit, offset))
}
fn slash(text: &str, route: &str) -> Result<NormalizedCommand> {
    let words: Vec<_> = text.split_whitespace().collect();
    let name = words
        .first()
        .context("empty command")?
        .trim_start_matches('/')
        .to_ascii_lowercase();
    let args = &words[1..];
    Ok(match name.as_str() {
        "new" | "reset" if args.is_empty() => NormalizedCommand::HostReset,
        "stop" if args.is_empty() => NormalizedCommand::HostStop,
        "status" if args.is_empty() => NormalizedCommand::Info {
            session: SessionSelector::Current,
        },
        "sessions" => {
            let args = if args.first().is_some_and(|a| matches!(*a, "list" | "ls")) {
                &args[1..]
            } else {
                args
            };
            if args.first().is_some_and(|a| !a.starts_with("--")) {
                NormalizedCommand::Unsupported { command: name }
            } else {
                let (limit, offset) = page(args)?;
                NormalizedCommand::List { limit, offset }
            }
        }
        "session" => {
            let verb = args.first().copied().unwrap_or("info");
            let rest = if args.is_empty() { args } else { &args[1..] };
            match verb {
                "info" if rest.len() <= 1 => NormalizedCommand::Info {
                    session: selector(rest.first().copied(), route)?,
                },
                "history" => {
                    let selected = rest.first().filter(|s| !s.starts_with("--")).copied();
                    let (limit, offset) = page(if selected.is_some() { &rest[1..] } else { rest })?;
                    NormalizedCommand::History {
                        session: selector(selected, route)?,
                        limit,
                        offset,
                    }
                }
                "list" => {
                    let (limit, offset) = page(rest)?;
                    NormalizedCommand::List { limit, offset }
                }
                _ => NormalizedCommand::Unsupported { command: name },
            }
        }
        _ => NormalizedCommand::Unsupported { command: name },
    })
}
/// Normalize only authenticated requests. None means an ordinary model message.
/// Exact payload fingerprint includes otherwise ignored fields to detect ID reuse.
pub fn normalize(frame: &Value, trusted: &TurnContext) -> Result<Option<CommandRequest>> {
    let kind = frame["type"].as_str().unwrap_or("");
    let (reply_kind, input_field) = match kind {
        "message.send" => {
            if !frame["content"]
                .as_str()
                .is_some_and(|s| s.trim_start().starts_with('/'))
            {
                return Ok(None);
            }
            (ReplyKind::Message, "message_id")
        }
        "command.request" | "slash.command" => (ReplyKind::Command, "request_id"),
        "session.info" | "session.list" | "session.open" | "session.close" | "session.reset" => {
            (ReplyKind::Session, "request_id")
        }
        _ => return Ok(None),
    };
    ensure!(
        frame["version"] == 1,
        "unsupported command protocol version"
    );
    identifier(&trusted.conversation_id)?;
    identifier(&trusted.input_id)?;
    ensure!(
        trusted.session_id == wire::digest(&trusted.conversation_id),
        "trusted route must be the canonical conversation digest"
    );
    ensure!(
        frame[input_field].as_str() == Some(&trusted.input_id),
        "command input anchor mismatch"
    );
    // Legacy session.list permits a missing conversation_id; the trusted host
    // must still supply its actual authenticated conversation, never invent one.
    ensure!(
        frame["conversation_id"].as_str() == Some(&trusted.conversation_id)
            || (kind == "session.list" && frame.get("conversation_id").is_none()),
        "command conversation anchor mismatch"
    );
    ensure!(
        frame
            .get("attachments")
            .is_none_or(|value| value.as_array().is_some_and(Vec::is_empty)),
        "attachments cannot be silently discarded by a command"
    );
    if let Some(key) = frame.get("session_key") {
        ensure!(
            key.as_str() == Some(&trusted.session_id),
            "session key is outside this conversation"
        );
    }
    let raw = serde_json::to_string(frame)?;
    ensure!(raw.len() <= 16 * 1024, "command frame too large");
    let command = match kind {
        "message.send" => slash(wire::text(frame, "content")?, &trusted.session_id)?,
        "command.request" | "slash.command" => {
            let name = wire::text(frame, "command")?;
            let args = match frame.get("args") {
                None => "",
                Some(v) => v.as_str().context("command args must be a string")?,
            };
            slash(&format!("{name} {args}"), &trusted.session_id)?
        }
        "session.info" => NormalizedCommand::Status {
            session: {
                let target = wire::text(frame, "session_id")?;
                if target == trusted.conversation_id {
                    SessionSelector::Current
                } else {
                    selector(Some(target), &trusted.session_id)?
                }
            },
        },
        "session.list" => NormalizedCommand::List {
            limit: 20,
            offset: 0,
        },
        "session.reset" => {
            // Fixed server never emits this extension. Do not silently reset
            // the current route when a compatibility peer targets another one.
            let target = wire::text(frame, "session_id")?;
            ensure!(
                target == "current" || target == trusted.conversation_id,
                "targeted session.reset is unsupported; use the current conversation /reset"
            );
            NormalizedCommand::HostReset
        }
        _ => NormalizedCommand::Unsupported {
            command: kind.into(),
        },
    };
    Ok(Some(CommandRequest {
        command,
        anchor: RequestAnchor {
            kind: reply_kind,
            input_id: trusted.input_id.clone(),
            conversation_id: trusted.conversation_id.clone(),
        },
        route: trusted.session_id.clone(),
        fingerprint: wire::digest(&raw),
    }))
}
fn current(db: &Connection, route: &str) -> Result<i64> {
    let n = db
        .query_row("SELECT generation FROM routes WHERE id=?1", [route], |r| {
            r.get(0)
        })
        .optional()?
        .unwrap_or(0);
    ensure!(n >= 0, "invalid route generation");
    Ok(n)
}
fn session_id(route: &str, generation: i64) -> String {
    if generation == 0 {
        route.into()
    } else {
        format!("{route}.{generation}")
    }
}
/// Prefix similarity alone is not ownership. Only the current canonical route,
/// generation zero, or an actual route-bound turn/reset receipt establishes it.
fn scoped_session(
    db: &Connection,
    route: &str,
    selected: &SessionSelector,
) -> Result<(String, i64, i64)> {
    let active = current(db, route)?;
    let n = match selected {
        SessionSelector::Current => active,
        SessionSelector::Generation(n) => *n,
    };
    ensure!(n >= 0 && n <= active, "session generation is unavailable");
    let session = session_id(route, n);
    let bound: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM context_turns WHERE route_id=?1 AND generation=?2 AND session_id=?3) OR EXISTS(SELECT 1 FROM context_command_receipts WHERE route_id=?1 AND generation=?2 AND kind='reset')", params![route,n,session], |r| r.get(0))?;
    ensure!(
        n == 0 || n == active || bound,
        "historical generation has no trusted route binding"
    );
    let ambiguous: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM context_turns WHERE session_id=?1 AND route_id<>?2) OR EXISTS(SELECT 1 FROM routes WHERE id=?1 AND id<>?2)", params![session,route], |r| r.get(0))?;
    ensure!(!ambiguous, "ambiguous session route binding");
    Ok((session, n, active))
}
fn info(
    db: &Connection,
    route: &str,
    selected: &SessionSelector,
    runtime_active: bool,
) -> Result<Value> {
    let (session, generation, active) = scoped_session(db, route, selected)?;
    let stored: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sessions WHERE id=?1)",
        [&session],
        |r| r.get(0),
    )?;
    let state = db.query_row("SELECT active_from_seq,revision,history_revision,updated_at,raw_count FROM context_state WHERE session_id=?1", [&session], |r| Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?,r.get::<_,f64>(3)?,r.get::<_,i64>(4)?))).optional()?;
    let count = state.map_or(0, |s| s.4);
    let latest: Option<String> = db.query_row("SELECT state FROM context_turns WHERE route_id=?1 AND generation=?2 AND session_id=?3 ORDER BY created_at DESC,rowid DESC LIMIT 1", params![route,generation,session], |r| r.get(0)).optional()?;
    let status = match latest.as_deref() {
        Some("active") if runtime_active && generation == active => "running",
        Some("active") => "unknown",
        Some(_) | None if runtime_active && generation == active => "unknown",
        Some("finalized") => "completed",
        Some("cancelled") => "cancelled",
        Some("interrupted") => "unknown",
        _ => "idle",
    };
    Ok(
        json!({"session_id":session,"generation":generation,"current":generation==active,"materialized":stored,"total_messages":count,"active_from_seq":state.map(|s|s.0),"context_revision":state.map(|s|s.1),"history_revision":state.map(|s|s.2),"updated_at":state.map(|s|s.3),"status":status,"durable_state":latest,"status_source":"durable_core_and_host_snapshot"}),
    )
}
fn response(req: &CommandRequest, status: &str, data: Value) -> Result<CommandResponse> {
    let mut content = serde_json::to_string(&data)?;
    ensure!(
        content.len() <= MAX_CONTENT,
        "command response exceeds bounded content limit"
    );
    let a = &req.anchor;
    let frame = match a.kind {
        ReplyKind::Message => wire::final_reply(
            &json!({"conversation_id":a.conversation_id,"message_id":a.input_id}),
            &content,
        )?,
        ReplyKind::Command => {
            json!({"version":1,"type":"command.reply","request_id":a.input_id,"conversation_id":a.conversation_id,"status":status,"content":content})
        }
        ReplyKind::Session => {
            if content.len() > 4000 {
                // Typed server SessionReply has no data field. Keep a truthful
                // summary with explicit paging guidance, never invalid JSON.
                let sessions = data["sessions"]
                    .as_array()
                    .context("oversized non-list session response")?;
                let mut compact: Vec<Value> = sessions.iter().map(|s| json!({"session_id":s["session_id"],"generation":s["generation"],"current":s["current"],"total_messages":s["total_messages"]})).collect();
                loop {
                    let next = if compact.len() < sessions.len() {
                        json!(data["offset"].as_u64().unwrap_or(0) + compact.len() as u64)
                    } else {
                        data["next_offset"].clone()
                    };
                    content = serde_json::to_string(
                        &json!({"scope":"current_conversation","sessions":compact,"next_offset":next,"compact":true,"message":"Use /sessions for full details."}),
                    )?;
                    if content.len() <= 4000 {
                        break;
                    }
                    ensure!(!compact.is_empty(), "session reply exceeds 4000 byte limit");
                    compact.pop();
                }
            }
            json!({"version":1,"type":"session.reply","request_id":a.input_id,"conversation_id":a.conversation_id,"status":status,"message":content})
        }
    };
    Ok(CommandResponse {
        frame,
        data,
        status: status.into(),
    })
}
fn read(
    db: &Connection,
    scope: &sc::OwnerScope,
    req: &CommandRequest,
    runtime_active: bool,
) -> Result<CommandResponse> {
    let (status, data) = match &req.command {
        NormalizedCommand::Info { session } => (
            "completed".to_owned(),
            info(db, &req.route, session, runtime_active)?,
        ),
        NormalizedCommand::Status { session } => {
            let data = info(db, &req.route, session, runtime_active)?;
            (data["status"].as_str().unwrap().to_owned(), data)
        }
        NormalizedCommand::List { limit, offset } => {
            let active = current(db, &req.route)?;
            let mut query = db.prepare("SELECT generation FROM (SELECT 0 AS generation UNION SELECT ?2 UNION SELECT generation FROM context_turns WHERE route_id=?1 UNION SELECT generation FROM context_command_receipts WHERE route_id=?1 AND kind='reset') WHERE generation>=0 AND generation<=?2 ORDER BY generation DESC LIMIT ?3 OFFSET ?4")?;
            let generations = query
                .query_map(
                    params![req.route, active, (*limit + 1) as i64, *offset as i64],
                    |r| r.get::<_, i64>(0),
                )?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let has_more = generations.len() > *limit;
            let mut sessions = Vec::new();
            for n in generations.into_iter().take(*limit) {
                sessions.push(info(
                    db,
                    &req.route,
                    &SessionSelector::Generation(n),
                    runtime_active,
                )?);
            }
            (
                "completed".into(),
                json!({"scope":"current_conversation","sessions":sessions,"offset":offset,"next_offset":if has_more {Some(offset+limit)} else {None}}),
            )
        }
        NormalizedCommand::History {
            session,
            limit,
            offset,
        } => {
            let metadata = info(db, &req.route, session, runtime_active)?;
            let id = metadata["session_id"].as_str().unwrap();
            // Raw rows preserve compacted history. Imported archives are not
            // implicitly authorized by a conversation route.
            let rows = if metadata["context_revision"].is_null() {
                vec![]
            } else {
                sc::history(db, scope, id, *offset, *limit, false)?
            };
            let mut history = Vec::new();
            let mut bytes = 0;
            for row in rows {
                let mut value = serde_json::to_value(row)?;
                if serde_json::to_vec(&value)?.len() > 16 * 1024 {
                    let text = value["body"]["content"]
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| value["body"].to_string());
                    value["body"] = json!({"role":value["body"]["role"],"content":text.chars().take(2000).collect::<String>(),"history_view_truncated":true});
                    value["truncated"] = json!(true);
                }
                let size = serde_json::to_vec(&value)?.len();
                if bytes + size > MAX_CONTENT - 2048 {
                    break;
                }
                bytes += size + 1;
                history.push(value);
            }
            let end = offset + history.len();
            let has_more = (end as u64) < metadata["total_messages"].as_u64().unwrap_or(0);
            (
                "completed".into(),
                json!({"scope":"current_conversation","session":metadata,"history":history,"offset":offset,"next_offset":if has_more {Some(end)} else {None}}),
            )
        }
        NormalizedCommand::Unsupported { command } => (
            "error".into(),
            json!({"code":"not_supported","command":command,"message":"This host does not implement this command or requested options. No configuration or session was changed."}),
        ),
        NormalizedCommand::HostReset | NormalizedCommand::HostStop => {
            bail!("host_action_required: execute through the existing fenced reset/stop path")
        }
    };
    response(req, &status, data)
}
impl Core {
    /// No model calls and no per-route async lock. Requires owner-bound session
    /// context. Persists the exact snapshot and reserves its input ID atomically.
    /// Same ID+payload replays across restart, conflicting payload/kind fails.
    pub async fn execute_session_command(
        &self,
        request: CommandRequest,
    ) -> Result<CommandResponse> {
        ensure!(
            !matches!(
                request.command,
                NormalizedCommand::HostReset | NormalizedCommand::HostStop
            ),
            "host_action_required: use reset_for_input / existing host cancellation"
        );
        let runtime = self
            .session
            .clone()
            .context("session context is not enabled")?;
        let locks = self.locks.clone();
        self.db(move |store| {
            sc::check_owner(&store.db, &runtime.scope)?;
            let tx = store.db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            sc::check_owner(&tx, &runtime.scope)?;
            let schema_count: i64 = tx.query_row("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('session_control_receipts','session_control_totals')", [], |row| row.get(0))?;
            if schema_count != 2 { tx.execute_batch(SCHEMA)?; }
            let previous: Option<(String,String)> = tx.query_row("SELECT fingerprint,response_json FROM session_control_receipts WHERE route_id=?1 AND input_id=?2", params![request.route,request.anchor.input_id], |r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            if let Some((fingerprint, raw)) = previous {
                ensure!(fingerprint == request.fingerprint, "command input payload conflict");
                return Ok(serde_json::from_str(&raw)?);
            }
            let used: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM context_turns WHERE route_id=?1 AND input_id=?2) OR EXISTS(SELECT 1 FROM context_command_receipts WHERE route_id=?1 AND input_id=?2) OR EXISTS(SELECT 1 FROM context_cancelled_inputs WHERE route_id=?1 AND input_id=?2)", params![request.route,request.anchor.input_id], |r|r.get(0))?;
            ensure!(!used, "command input ID was already used by another operation");
            let route_lock = locks.lock().map_err(|_| anyhow::anyhow!("session lock poisoned"))?.get(&request.route).and_then(std::sync::Weak::upgrade);
            let runtime_active = route_lock.is_some_and(|lock| lock.try_lock().is_err());
            let result = read(&tx, &runtime.scope, &request, runtime_active)?;
            let raw = serde_json::to_string(&result)?;
            let (count, bytes): (i64,i64) = tx.query_row("SELECT receipts,bytes FROM session_control_totals WHERE singleton=1", [], |r|Ok((r.get(0)?,r.get(1)?)))?;
            ensure!(count < MAX_RECEIPTS && bytes + raw.len() as i64 <= MAX_RECEIPT_BYTES, "session command receipt capacity exhausted; retained IDs are never silently evicted");
            let generation = current(&tx, &request.route)?;
            tx.execute("INSERT INTO context_command_receipts(route_id,input_id,kind,generation) VALUES(?1,?2,'read_control',?3)", params![request.route,request.anchor.input_id,generation])?;
            tx.execute("INSERT INTO session_control_receipts VALUES(?1,?2,?3,?4)", params![request.route,request.anchor.input_id,request.fingerprint,raw])?;
            tx.execute("UPDATE session_control_totals SET receipts=receipts+1,bytes=bytes+?1 WHERE singleton=1", [raw.len() as i64])?;
            tx.commit()?;
            Ok(result)
        }).await
    }
}
