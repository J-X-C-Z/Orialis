use super::*;
use rusqlite::{Connection, OptionalExtension, params};
use std::fs::File;

const TABLES:&str = "
CREATE TABLE IF NOT EXISTS delegation_owner(id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS delegation_generations(session TEXT PRIMARY KEY,generation INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS delegation_batches(id TEXT PRIMARY KEY,argument_digest TEXT NOT NULL,state TEXT NOT NULL,result TEXT);
CREATE TABLE IF NOT EXISTS delegation_children(id TEXT PRIMARY KEY,batch_id TEXT NOT NULL,root TEXT NOT NULL,conversation TEXT NOT NULL,generation INTEGER NOT NULL,input TEXT NOT NULL,parent TEXT,depth INTEGER NOT NULL,ordinal INTEGER NOT NULL,run INTEGER NOT NULL,status TEXT NOT NULL,task TEXT NOT NULL,messages TEXT NOT NULL,output TEXT,pending_steer TEXT NOT NULL DEFAULT '[]',scope TEXT NOT NULL,iterations INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS delegation_children_root ON delegation_children(root,generation);
CREATE INDEX IF NOT EXISTS delegation_children_parent ON delegation_children(parent);
CREATE TABLE IF NOT EXISTS delegation_background(batch TEXT PRIMARY KEY REFERENCES delegation_batches(id),notification_id TEXT NOT NULL UNIQUE,root TEXT NOT NULL,conversation TEXT NOT NULL,generation INTEGER NOT NULL,input TEXT NOT NULL,handle TEXT NOT NULL,result TEXT,state TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS delegation_background_pending_order ON delegation_background(state,notification_id);
CREATE TABLE IF NOT EXISTS delegation_receipts(child TEXT NOT NULL,run INTEGER NOT NULL,call_id TEXT NOT NULL,call TEXT NOT NULL,status TEXT NOT NULL,result TEXT,PRIMARY KEY(child,run,call_id));
";
pub(super) struct Store {
    pub(super) db: Connection,
    _lock: Option<File>,
}
#[derive(Clone)]
pub(super) struct Child {
    pub id: String,
    pub batch: String,
    pub parent: Option<String>,
    pub depth: usize,
    pub ordinal: usize,
    pub run: i64,
    pub status: String,
    pub task: Task,
    pub messages: Vec<Value>,
    pub output: Option<Value>,
    pub scope: String,
    pub iterations: usize,
}
impl Store {
    pub fn open(path: &Path, owner: &str) -> Result<Self> {
        let db = crate::private_db::open_private(path)?;
        let lock = if path == Path::new(":memory:") {
            None
        } else {
            #[cfg(unix)]
            {
                use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
                let file = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(path)?;
                ensure!(
                    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                    "delegation database already has a runtime owner"
                );
                Some(file)
            }
            #[cfg(not(unix))]
            {
                bail!("delegation disk ownership requires Unix file locking")
            }
        };
        db.busy_timeout(Duration::from_secs(2))?;
        db.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        db.execute_batch(TABLES)?;
        db.execute(
            "INSERT OR IGNORE INTO delegation_owner VALUES(1,?1)",
            [digest(owner)],
        )?;
        let actual: String =
            db.query_row("SELECT owner FROM delegation_owner WHERE id=1", [], |r| {
                r.get(0)
            })?;
        ensure!(actual == digest(owner), "delegation owner mismatch");
        let mut store = Self { db, _lock: lock };
        store.recover()?;
        Ok(store)
    }
    fn recover(&mut self) -> Result<()> {
        let ids: Vec<String> = {
            let mut s=self.db.prepare("SELECT id FROM delegation_children WHERE status IN ('pending','running','stopping')")?;
            s.query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        for id in ids {
            let run = self.child(&id)?.run;
            self.interrupt(
                &id,
                run,
                "runtime restarted; unfinished effects are not retried",
            )?;
        }
        let batches: Vec<String> = {
            let mut s = self
                .db
                .prepare("SELECT id FROM delegation_batches WHERE result IS NULL")?;
            s.query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        for batch in batches {
            self.finish_batch(&batch)?;
        }
        Ok(())
    }
    pub fn ensure_generation(&mut self, session: &str, generation: i64) -> Result<()> {
        self.db.execute(
            "INSERT OR IGNORE INTO delegation_generations VALUES(?1,?2)",
            params![session, generation],
        )?;
        self.check_generation(session, generation)
    }
    pub fn check_generation(&self, session: &str, generation: i64) -> Result<()> {
        let n: Option<i64> = self
            .db
            .query_row(
                "SELECT generation FROM delegation_generations WHERE session=?1",
                [session],
                |r| r.get(0),
            )
            .optional()?;
        ensure!(n == Some(generation), "stale delegation parent generation");
        Ok(())
    }
    pub fn advance_generation(&mut self, session: &str, generation: i64) -> Result<Vec<String>> {
        ensure!(
            !session.is_empty() && generation >= 0,
            "invalid delegation generation"
        );
        let tx = self.db.transaction()?;
        let old: Option<i64> = tx
            .query_row(
                "SELECT generation FROM delegation_generations WHERE session=?1",
                [session],
                |r| r.get(0),
            )
            .optional()?;
        if old.is_some_and(|n| generation <= n) {
            return Ok(vec![]);
        }
        tx.execute("INSERT INTO delegation_generations VALUES(?1,?2) ON CONFLICT(session) DO UPDATE SET generation=excluded.generation",params![session,generation])?;
        let ids = {
            let mut s=tx.prepare("SELECT id FROM delegation_children WHERE root=?1 AND generation<?2 AND status IN ('pending','running','stopping')")?;
            s.query_map(params![session, generation], |r| r.get(0))?
                .collect::<rusqlite::Result<Vec<String>>>()?
        };
        tx.execute("UPDATE delegation_children SET status='stopping' WHERE root=?1 AND generation<?2 AND status IN ('pending','running')",params![session,generation])?;
        tx.execute(
            "UPDATE delegation_background SET state='suppressed' WHERE root=?1 AND generation<?2",
            params![session, generation],
        )?;
        tx.commit()?;
        Ok(ids)
    }
    pub fn batch_existing(&self, id: &str, raw: &Value) -> Result<Option<Value>> {
        let row: Option<(String, Option<String>)> = self
            .db
            .query_row(
                "SELECT argument_digest,result FROM delegation_batches WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((hash, result)) = row {
            ensure!(
                hash == digest(&raw.to_string()),
                "delegation call identity reused with different arguments"
            );
            let handle: Option<String> = self
                .db
                .query_row(
                    "SELECT handle FROM delegation_background WHERE batch=?1",
                    [id],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(handle) = handle {
                return Ok(Some(serde_json::from_str(&handle)?));
            }
            if let Some(result) = result {
                return Ok(Some(serde_json::from_str(&result)?));
            }
            let children = self.batch_children(id)?;
            ensure!(
                !children
                    .iter()
                    .any(|c| matches!(c.status.as_str(), "pending" | "running" | "stopping")),
                "delegation batch already running"
            );
            return Ok(Some(batch_result(id, &children)));
        }
        Ok(None)
    }
    #[allow(clippy::too_many_arguments)] // All values belong to one atomic admission transaction.
    pub fn reserve(
        &mut self,
        id: &str,
        raw: &Value,
        tasks: &[Task],
        authority: &Authority,
        scope: &str,
        iterations: usize,
        cfg: &DelegationConfig,
    ) -> Result<Vec<Child>> {
        self.check_generation(&authority.context.session_id, authority.generation)?;
        let tx = self.db.transaction()?;
        let n: usize =
            tx.query_row("SELECT count(*) FROM delegation_children", [], |r| r.get(0))?;
        let batches: usize =
            tx.query_row("SELECT count(*) FROM delegation_batches", [], |r| r.get(0))?;
        ensure!(
            n + tasks.len() <= cfg.max_retained_children && batches < cfg.max_batches,
            "delegation durable retention limit reached; archive via trusted host before spawning"
        );
        tx.execute(
            "INSERT INTO delegation_batches VALUES(?1,?2,'running',NULL)",
            params![id, digest(&raw.to_string())],
        )?;
        let mut children = Vec::new();
        for (ordinal, task) in tasks.iter().enumerate() {
            let child = Child {
                id: format!("child-{}", &digest(&format!("{id}:{ordinal}"))[..32]),
                batch: id.into(),
                parent: authority.parent.clone(),
                depth: authority.depth + 1,
                ordinal,
                run: 0,
                status: "pending".into(),
                task: task.clone(),
                messages: vec![],
                output: None,
                scope: scope.into(),
                iterations,
            };
            tx.execute("INSERT INTO delegation_children(id,batch_id,root,conversation,generation,input,parent,depth,ordinal,run,status,task,messages,scope,iterations) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0,'pending',?10,'[]',?11,?12)",params![child.id,id,authority.context.session_id,authority.context.conversation_id,authority.generation,authority.context.input_id,authority.parent,child.depth,ordinal,serde_json::to_string(task)?,scope,iterations])?;
            children.push(child);
        }
        background::insert_record(&tx, id, authority, &children)?;
        tx.commit()?;
        Ok(children)
    }
    pub fn child(&self, id: &str) -> Result<Child> {
        let tuple=self.db.query_row("SELECT id,batch_id,parent,depth,ordinal,run,status,task,messages,output,scope,iterations FROM delegation_children WHERE id=?1",[id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,usize>(3)?,r.get::<_,usize>(4)?,r.get::<_,i64>(5)?,r.get::<_,String>(6)?,r.get::<_,String>(7)?,r.get::<_,String>(8)?,r.get::<_,Option<String>>(9)?,r.get::<_,String>(10)?,r.get::<_,usize>(11)?)))?;
        Ok(Child {
            id: tuple.0,
            batch: tuple.1,
            parent: tuple.2,
            depth: tuple.3,
            ordinal: tuple.4,
            run: tuple.5,
            status: tuple.6,
            task: serde_json::from_str(&tuple.7)?,
            messages: serde_json::from_str(&tuple.8)?,
            output: tuple.9.map(|s| serde_json::from_str(&s)).transpose()?,
            scope: tuple.10,
            iterations: tuple.11,
        })
    }
    pub fn owned_child(&self, id: &str, a: &Authority) -> Result<Child> {
        let scope: Option<(String, String, i64)> = self
            .db
            .query_row(
                "SELECT root,conversation,generation FROM delegation_children WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        ensure!(
            scope
                == Some((
                    a.context.session_id.clone(),
                    a.context.conversation_id.clone(),
                    a.generation
                )),
            "unknown subagent or ownership/generation mismatch"
        );
        if let Some(parent) = &a.parent {
            ensure!(
                self.descendants(parent)?.iter().any(|s| s == id),
                "child cannot control itself, ancestor or sibling"
            );
        }
        self.child(id)
    }
    pub fn descendants(&self, id: &str) -> Result<Vec<String>> {
        let mut s=self.db.prepare("WITH RECURSIVE tree(id) AS (SELECT id FROM delegation_children WHERE parent=?1 UNION ALL SELECT c.id FROM delegation_children c JOIN tree t ON c.parent=t.id) SELECT id FROM tree")?;
        Ok(s.query_map([id], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub fn list(&self, a: &Authority) -> Result<Value> {
        let ids: Vec<String> = {
            let mut s=self.db.prepare("SELECT id FROM delegation_children WHERE root=?1 AND conversation=?2 AND generation=?3 ORDER BY rowid DESC LIMIT 201")?;
            s.query_map(
                params![
                    a.context.session_id,
                    a.context.conversation_id,
                    a.generation
                ],
                |r| r.get(0),
            )?
            .collect::<rusqlite::Result<_>>()?
        };
        let mut entries = Vec::new();
        for id in ids.iter().take(200) {
            if let Ok(c) = self.owned_child(id, a) {
                entries.push(json!({"subagent_id":c.id,"parent_id":c.parent,"depth":c.depth,"goal":truncate(&c.task.goal,512),"status":c.status,"run":c.run,"accepting_steer":c.status=="running","summary":c.output.as_ref().and_then(|o|o["summary"].as_str()).map(|s|truncate(s,1024))}));
            }
        }
        Ok(
            json!({"action":"list","count":entries.len(),"subagents":entries,"truncated":ids.len()>200}),
        )
    }
    pub fn batch_children(&self, batch: &str) -> Result<Vec<Child>> {
        let ids: Vec<String> = {
            let mut s = self
                .db
                .prepare("SELECT id FROM delegation_children WHERE batch_id=?1 ORDER BY ordinal")?;
            s.query_map([batch], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        ids.iter().map(|s| self.child(s)).collect()
    }
    pub fn finish_batch(&mut self, id: &str) -> Result<Value> {
        let cached: Option<Option<String>> = self
            .db
            .query_row(
                "SELECT result FROM delegation_batches WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(Some(cached)) = cached {
            return Ok(serde_json::from_str(&cached)?);
        }
        let children = self.batch_children(id)?;
        ensure!(
            !children
                .iter()
                .any(|c| matches!(c.status.as_str(), "pending" | "running" | "stopping")),
            "batch children have not settled"
        );
        let mut result = batch_result(id, &children);
        let background: bool = self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM delegation_background WHERE batch=?1)",
            [id],
            |r| r.get(0),
        )?;
        if background {
            result["mode"] = json!("background");
        }
        let serialized = result.to_string();
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE delegation_batches SET state='completed',result=?2 WHERE id=?1",
            params![id, serialized],
        )?;
        tx.execute(
            "UPDATE delegation_background SET result=?2 WHERE batch=?1 AND result IS NULL",
            params![id, serialized],
        )?;
        tx.commit()?;
        Ok(result)
    }
    pub fn start(&mut self, c: &Child, messages: &[Value]) -> Result<()> {
        let n=self.db.execute("UPDATE delegation_children SET status='running',messages=?3 WHERE id=?1 AND run=?2 AND status='pending'",params![c.id,c.run,serde_json::to_string(messages)?])?;
        ensure!(n == 1, "child no longer eligible to start");
        Ok(())
    }
    pub fn save(&mut self, c: &Child, messages: &[Value]) -> Result<()> {
        let n=self.db.execute("UPDATE delegation_children SET messages=?3 WHERE id=?1 AND run=?2 AND status='running'",params![c.id,c.run,serde_json::to_string(messages)?])?;
        ensure!(n == 1, "child cancelled or generation changed");
        Ok(())
    }
    pub fn steer(&mut self, id: &str, run: i64, text: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        let old:Option<String>=tx.query_row("SELECT pending_steer FROM delegation_children WHERE id=?1 AND run=?2 AND status='running'",params![id,run],|r|r.get(0)).optional()?;
        let mut pending: Vec<String> =
            serde_json::from_str(&old.context("child is not accepting steering")?)?;
        ensure!(
            pending.len() < 16
                && pending.iter().map(String::len).sum::<usize>() + text.len() <= 32 * 1024,
            "child steering queue full"
        );
        pending.push(text.into());
        tx.execute(
            "UPDATE delegation_children SET pending_steer=?3 WHERE id=?1 AND run=?2",
            params![id, run, serde_json::to_string(&pending)?],
        )?;
        tx.commit()?;
        Ok(())
    }
    /// Drain + append under one transaction; accepted steering is never silently lost.
    pub fn drain_steer(&mut self, c: &Child, messages: &mut Vec<Value>) -> Result<()> {
        let tx = self.db.transaction()?;
        let pending:String=tx.query_row("SELECT pending_steer FROM delegation_children WHERE id=?1 AND run=?2 AND status='running'",params![c.id,c.run],|r|r.get(0))?;
        let pending: Vec<String> = serde_json::from_str(&pending)?;
        if !pending.is_empty() {
            messages.push(
                json!({"role":"user","content":format!("Parent steering:\n{}",pending.join("\n"))}),
            );
            tx.execute("UPDATE delegation_children SET messages=?3,pending_steer='[]' WHERE id=?1 AND run=?2",params![c.id,c.run,serde_json::to_string(messages)?])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn stop(&mut self, id: &str, run: i64) -> Result<()> {
        let n=self.db.execute("UPDATE delegation_children SET status='stopping' WHERE id=?1 AND run=?2 AND status IN ('pending','running','stopping')",params![id,run])?;
        ensure!(n == 1, "child already finished");
        Ok(())
    }
    pub fn begin_tool(&mut self, c: &Child, id: &str, call: &Value) -> Result<Option<Value>> {
        let tx = self.db.transaction()?;
        let status: String = tx.query_row(
            "SELECT status FROM delegation_children WHERE id=?1 AND run=?2",
            params![c.id, c.run],
            |r| r.get(0),
        )?;
        ensure!(status == "running", "child cancelled before tool effect");
        let receipt:Option<(String,String,Option<String>)>=tx.query_row("SELECT call,status,result FROM delegation_receipts WHERE child=?1 AND run=?2 AND call_id=?3",params![c.id,c.run,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        if let Some((previous, status, result)) = receipt {
            ensure!(
                serde_json::from_str::<Value>(&previous)? == *call,
                "child tool-call identity reused with different arguments"
            );
            ensure!(
                status == "completed",
                "uncertain child tool effect; never replay automatically"
            );
            return Ok(Some(serde_json::from_str(
                &result.context("completed receipt missing result")?,
            )?));
        }
        tx.execute(
            "INSERT INTO delegation_receipts VALUES(?1,?2,?3,?4,'started',NULL)",
            params![c.id, c.run, id, call.to_string()],
        )?;
        tx.commit()?;
        Ok(None)
    }
    pub fn finish_tool(
        &mut self,
        c: &Child,
        id: &str,
        result: &Value,
        messages: &[Value],
    ) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("UPDATE delegation_receipts SET status='completed',result=?4 WHERE child=?1 AND run=?2 AND call_id=?3 AND status='started'",params![c.id,c.run,id,result.to_string()])?;
        tx.execute("UPDATE delegation_children SET messages=?3 WHERE id=?1 AND run=?2 AND status IN ('running','stopping')",params![c.id,c.run,serde_json::to_string(messages)?])?;
        tx.commit()?;
        Ok(())
    }
    pub fn finish(&mut self, c: &Child, mut output: Value, messages: &[Value]) -> Result<Value> {
        let tx = self.db.transaction()?;
        let (state, pending, existing): (String, String, Option<String>) = tx.query_row(
            "SELECT status,pending_steer,output FROM delegation_children WHERE id=?1 AND run=?2",
            params![c.id, c.run],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        if !matches!(state.as_str(), "pending" | "running" | "stopping") {
            return Ok(serde_json::from_str(
                &existing.context("terminal child output missing")?,
            )?);
        }
        if state == "stopping" && output["uncertain_effects"] != true {
            output["status"] = json!("interrupted");
            output["partial"] = json!(true);
        }
        let pending: Vec<String> = serde_json::from_str(&pending)?;
        if !pending.is_empty() {
            output["missed_steer"] = json!(pending);
        }
        let status = output["status"].as_str().context("result missing status")?;
        tx.execute("UPDATE delegation_children SET status=?3,output=?4,messages=?5,pending_steer='[]' WHERE id=?1 AND run=?2",params![c.id,c.run,status,output.to_string(),serde_json::to_string(messages)?])?;
        tx.commit()?;
        Ok(output)
    }
    pub fn cleanup_failed(&mut self, child: &Child) -> Result<()> {
        let current = self.child(&child.id)?;
        if current.run != child.run {
            return Ok(());
        }
        let mut output = current
            .output
            .unwrap_or_else(|| json!({"subagent_id":child.id,"summary":"","partial":true}));
        output["cleanup_pending"] = json!(true);
        output["partial"] = json!(true);
        // Preserve uncertainty as the stronger outcome.
        if output["uncertain_effects"] != true {
            output["status"] = json!("cleanup_pending");
        }
        self.db.execute(
            "UPDATE delegation_children SET status=?3,output=?4 WHERE id=?1 AND run=?2",
            params![
                child.id,
                child.run,
                output["status"].as_str(),
                output.to_string()
            ],
        )?;
        Ok(())
    }
    pub fn interrupt(&mut self, id: &str, run: i64, reason: &str) -> Result<()> {
        let c = self.child(id)?;
        if c.run != run || !matches!(c.status.as_str(), "pending" | "running" | "stopping") {
            return Ok(());
        }
        let uncertain:bool=self.db.query_row("WITH RECURSIVE tree(id) AS (SELECT ?1 UNION ALL SELECT c.id FROM delegation_children c JOIN tree t ON c.parent=t.id) SELECT EXISTS(SELECT 1 FROM delegation_receipts r JOIN tree t ON r.child=t.id WHERE r.status='started' AND (r.child<>?1 OR r.run=?2))",params![id,run],|r|r.get(0))?;
        let summary = c
            .messages
            .iter()
            .rev()
            .filter(|v| v["role"] == "assistant")
            .find_map(|v| v["content"].as_str())
            .unwrap_or("");
        let result = json!({"subagent_id":id,"task_index":c.ordinal,"status":if uncertain{"uncertain"}else{"interrupted"},"summary":truncate(summary,24_000),"partial":true,"uncertain_effects":uncertain,"error":reason});
        self.finish(&c, result, &c.messages)?;
        Ok(())
    }
    #[allow(clippy::too_many_arguments)] // Claim, identity and bounded transcript append must be atomic.
    pub fn continue_child(
        &mut self,
        id: &str,
        batch: &str,
        raw: &Value,
        message: &str,
        a: &Authority,
        scope: &str,
        cfg: &DelegationConfig,
    ) -> Result<Child> {
        let mut child = self.owned_child(id, a)?;
        let batch_published: bool = self.db.query_row(
            "SELECT result IS NOT NULL FROM delegation_batches WHERE id=?1",
            [&child.batch],
            |r| r.get(0),
        )?;
        ensure!(
            batch_published,
            "child previous batch is still finishing; wait for cleanup and durable result publication"
        );
        ensure!(
            child.scope == scope,
            "delegation route or capability scope changed; cannot continue"
        );
        ensure!(
            child.depth <= cfg.max_depth,
            "continued child depth exceeds configured limit"
        );
        ensure!(
            matches!(
                child.status.as_str(),
                "completed" | "error" | "interrupted" | "budget_exhausted"
            ),
            "child not finished or has uncertain effects; reconciliation required"
        );
        ensure!(
            child
                .messages
                .iter()
                .all(|m| m["tool_calls"]
                    .as_array()
                    .is_none_or(|calls| calls.iter().all(|call| child
                        .messages
                        .iter()
                        .any(|m| m["role"] == "tool" && m["tool_call_id"] == call["id"])))),
            "unfinished tool transcript requires reconciliation"
        );
        child
            .messages
            .push(json!({"role":"user","content":message}));
        ensure!(
            serde_json::to_vec(&child.messages)?.len() <= cfg.max_context_bytes,
            "child context budget exhausted"
        );
        let tx = self.db.transaction()?;
        let batches: usize =
            tx.query_row("SELECT count(*) FROM delegation_batches", [], |r| r.get(0))?;
        ensure!(
            batches < cfg.max_batches,
            "delegation durable retention limit reached"
        );
        tx.execute(
            "INSERT INTO delegation_batches VALUES(?1,?2,'running',NULL)",
            params![batch, digest(&raw.to_string())],
        )?;
        let n=tx.execute("UPDATE delegation_children SET batch_id=?3,run=run+1,status='pending',messages=?4,output=NULL,input=?5,ordinal=0 WHERE id=?1 AND run=?2 AND status=?6",params![id,child.run,batch,serde_json::to_string(&child.messages)?,a.context.input_id,child.status])?;
        ensure!(n == 1, "child continuation already claimed");
        background::insert_record(&tx, batch, a, std::slice::from_ref(&child))?;
        tx.commit()?;
        child.run += 1;
        child.batch = batch.into();
        child.status = "pending".into();
        child.output = None;
        child.ordinal = 0;
        Ok(child)
    }
}
pub(super) fn batch_result(id: &str, children: &[Child]) -> Value {
    let results:Vec<Value>=children.iter().map(|c|c.output.clone().unwrap_or_else(||json!({"subagent_id":c.id,"task_index":c.ordinal,"status":c.status,"summary":"","partial":true})) ).collect();
    let mut groups: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    for c in children {
        if let Some(group) = &c.task.group {
            groups.entry(group.clone()).or_default().push(c.id.clone());
        }
    }
    json!({"delegation_id":id,"mode":"inline","results":results,"groups":groups,"partial":children.iter().any(|c|c.status!="completed")})
}

// A single connection-owning thread keeps fsync/busy waits off Tokio. Admission
// permits travel WITH commands, so dropping an awaiting future does not release
// queue budget or cancel a bookkeeping write that was already admitted.
type DbCommand = Box<dyn FnOnce(&mut Store) + Send + 'static>;
pub(super) struct AsyncStore {
    sender: std::sync::mpsc::Sender<DbCommand>,
    permits: Arc<Semaphore>,
    thread: std::thread::JoinHandle<()>,
}
macro_rules! db_method {
    ($name:ident ($($arg:ident:$ty:ty),*) -> $ret:ty; [$($prep:tt)*] => $body:expr) => {
        pub async fn $name(&self,$($arg:$ty),*) -> Result<$ret> {
            $($prep)*
            self.run(move |db| $body(db)).await
        }
    };
}
impl AsyncStore {
    pub fn open(path: &Path, owner: &str) -> Result<Self> {
        let mut db = Store::open(path, owner)?;
        let (sender, receiver) = std::sync::mpsc::channel::<DbCommand>();
        let thread = std::thread::Builder::new()
            .name("delegation-sqlite".into())
            .spawn(move || {
                while let Ok(command) = receiver.recv() {
                    command(&mut db);
                }
            })?;
        Ok(Self {
            sender,
            permits: Arc::new(Semaphore::new(128)),
            thread,
        })
    }
    pub async fn settle(&self) -> Result<()> {
        self.run(|db| db.recover()).await
    }
    pub async fn shutdown(self) -> Result<()> {
        let Self { sender, thread, .. } = self;
        drop(sender);
        tokio::task::spawn_blocking(move || {
            thread
                .join()
                .map_err(|_| anyhow::anyhow!("delegation database actor panicked"))
        })
        .await?
    }
    async fn run<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Store) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let permit = self.permits.clone().acquire_owned().await?;
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.sender
            .send(Box::new(move |db| {
                let _permit = permit;
                let _ = tx.send(f(db));
            }))
            .map_err(|_| anyhow::anyhow!("delegation database actor closed"))?;
        rx.await
            .context("delegation database actor response lost")?
    }
    /// Drop-path recovery contains no new external effects. It can add at most
    /// one command per active child/batch (both bounded by live admission).
    pub fn abandoned_child(&self, id: String, run: i64) {
        let _ = self.sender.send(Box::new(move |db| {
            let _ = db.interrupt(
                &id,
                run,
                "child future dropped; unfinished effects are never automatically replayed",
            );
        }));
    }
    pub fn abandoned_batch(
        &self,
        id: String,
        children: Vec<(String, i64)>,
        permit: Option<tokio::sync::OwnedSemaphorePermit>,
    ) {
        let _ = self.sender.send(Box::new(move |db| {
            let _permit = permit;
            let children = if children.is_empty() {
                db.batch_children(&id)
                    .unwrap_or_default()
                    .into_iter()
                    .map(|c| (c.id, c.run))
                    .collect()
            } else {
                children
            };
            for (child, run) in children {
                let _ = db.interrupt(
                    &child,
                    run,
                    "parent future dropped; inspect partial/uncertain child result",
                );
            }
            let _ = db.finish_batch(&id);
        }));
    }
    db_method!(pending_completions_after(after_notification_id:Option<&str>,limit:usize)->Vec<BackgroundCompletion>;[let after_notification_id=after_notification_id.map(str::to_owned);]=> |db:&mut Store|db.pending_completions_after(after_notification_id.as_deref(),limit));
    db_method!(inspect_completion(id:&str)->Option<BackgroundCompletion>;[let id=id.to_owned();]=> |db:&mut Store|db.inspect_completion(&id));
    db_method!(current_completion(id:&str)->Option<BackgroundCompletion>;[let id=id.to_owned();]=> |db:&mut Store|db.current_completion(&id));
    db_method!(current_completion_identity(id:&str)->Option<(String,String,i64)>;[let id=id.to_owned();]=> |db:&mut Store|db.current_completion_identity(&id));
    db_method!(mark_completion_enqueued(id:&str)->bool;[let id=id.to_owned();]=> |db:&mut Store|db.mark_completion_enqueued(&id));
    db_method!(cancel_conversation(conversation:&str)->usize;[let conversation=conversation.to_owned();]=> |db:&mut Store|db.cancel_conversation(&conversation));
    db_method!(ensure_generation(session:&str,generation:i64)->();[let session=session.to_owned();]=> |db:&mut Store|db.ensure_generation(&session,generation));
    db_method!(advance_generation(session:&str,generation:i64)->Vec<String>;[let session=session.to_owned();]=> |db:&mut Store|db.advance_generation(&session,generation));
    db_method!(list(a:&Authority)->Value;[let a=a.clone();]=> |db:&mut Store|db.list(&a));
    db_method!(owned_child(id:&str,a:&Authority)->Child;[let id=id.to_owned();let a=a.clone();]=> |db:&mut Store|db.owned_child(&id,&a));
    db_method!(descendants(id:&str)->Vec<String>;[let id=id.to_owned();]=> |db:&mut Store|db.descendants(&id));
    db_method!(steer(id:&str,run:i64,text:&str)->();[let id=id.to_owned();let text=text.to_owned();]=> |db:&mut Store|db.steer(&id,run,&text));
    db_method!(stop(id:&str,run:i64)->();[let id=id.to_owned();]=> |db:&mut Store|db.stop(&id,run));
    db_method!(batch_existing(id:&str,raw:&Value)->Option<Value>;[let id=id.to_owned();let raw=raw.clone();]=> |db:&mut Store|db.batch_existing(&id,&raw));
    db_method!(finish_batch(id:&str)->Value;[let id=id.to_owned();]=> |db:&mut Store|db.finish_batch(&id));
    db_method!(start(c:&Child,messages:&[Value])->();[let c=c.clone();let messages=messages.to_vec();]=> |db:&mut Store|db.start(&c,&messages));
    db_method!(save(c:&Child,messages:&[Value])->();[let c=c.clone();let messages=messages.to_vec();]=> |db:&mut Store|db.save(&c,&messages));
    db_method!(begin_tool(c:&Child,id:&str,call:&Value)->Option<Value>;[let c=c.clone();let id=id.to_owned();let call=call.clone();]=> |db:&mut Store|db.begin_tool(&c,&id,&call));
    db_method!(finish_tool(c:&Child,id:&str,result:&Value,messages:&[Value])->();[let c=c.clone();let id=id.to_owned();let result=result.clone();let messages=messages.to_vec();]=> |db:&mut Store|db.finish_tool(&c,&id,&result,&messages));
    db_method!(finish(c:&Child,output:Value,messages:&[Value])->Value;[let c=c.clone();let messages=messages.to_vec();]=> |db:&mut Store|db.finish(&c,output,&messages));
    db_method!(interrupt(id:&str,run:i64,reason:&str)->();[let id=id.to_owned();let reason=reason.to_owned();]=> |db:&mut Store|db.interrupt(&id,run,&reason));
    db_method!(cleanup_failed(c:&Child)->();[let c=c.clone();]=> |db:&mut Store|db.cleanup_failed(&c));
    pub async fn drain_steer(&self, c: &Child, messages: &mut Vec<Value>) -> Result<()> {
        let c = c.clone();
        let mut copy = messages.clone();
        *messages = self
            .run(move |db| {
                db.drain_steer(&c, &mut copy)?;
                Ok(copy)
            })
            .await?;
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn reserve(
        &self,
        id: &str,
        raw: &Value,
        tasks: &[Task],
        a: &Authority,
        scope: &str,
        iterations: usize,
        cfg: &DelegationConfig,
    ) -> Result<Vec<Child>> {
        let (id, raw, tasks, a, scope, cfg) = (
            id.to_owned(),
            raw.clone(),
            tasks.to_vec(),
            a.clone(),
            scope.to_owned(),
            cfg.clone(),
        );
        self.run(move |db| db.reserve(&id, &raw, &tasks, &a, &scope, iterations, &cfg))
            .await
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn continue_child(
        &self,
        id: &str,
        batch: &str,
        raw: &Value,
        message: &str,
        a: &Authority,
        scope: &str,
        cfg: &DelegationConfig,
    ) -> Result<Child> {
        let (id, batch, raw, message, a, scope, cfg) = (
            id.to_owned(),
            batch.to_owned(),
            raw.clone(),
            message.to_owned(),
            a.clone(),
            scope.to_owned(),
            cfg.clone(),
        );
        self.run(move |db| db.continue_child(&id, &batch, &raw, &message, &a, &scope, &cfg))
            .await
    }
}
