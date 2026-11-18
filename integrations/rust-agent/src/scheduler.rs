//! Explicit, persistent local schedules. Nothing starts a timer or a user task
//! at module load. Hosts call `claim_due` and execute the returned occurrences.
use crate::delivery::{
    DeliveryBody, DeliveryFuture, DeliveryIdentity, DeliveryKind, DeliveryOutbox, DeliveryRequest,
    DeliveryStatus, DeliveryTarget, OwnedDatabase, digest, id,
};
use anyhow::{Context, Result, bail, ensure};
use chrono::{
    DateTime, Datelike, Duration as ChronoDuration, LocalResult, NaiveDate, TimeZone, Utc,
};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashSet,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DstFold {
    First,
    Second,
    Both,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScheduleSpec {
    Once {
        at_ms: i64,
    },
    Interval {
        anchor_ms: i64,
        every_seconds: u32,
    },
    Cron {
        expression: String,
        timezone: String,
        fold: DstFold,
    },
}
impl ScheduleSpec {
    pub fn once_rfc3339(value: &str) -> Result<Self> {
        let at_ms = DateTime::parse_from_rfc3339(value)?.timestamp_millis();
        instant(at_ms)?;
        Ok(Self::Once { at_ms })
    }
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Once { at_ms } => {
                instant(*at_ms)?;
            }
            Self::Interval {
                anchor_ms,
                every_seconds,
            } => {
                instant(*anchor_ms)?;
                ensure!(*every_seconds > 0, "interval must be at least one second");
            }
            Self::Cron {
                expression,
                timezone,
                ..
            } => {
                let _: Tz = timezone.parse().context("unknown IANA timezone")?;
                Cron::parse(expression)?;
            }
        };
        Ok(())
    }
    /// Strictly after this UTC instant. Cron gaps are skipped; fold policy is
    /// explicit, never guessed from the process-local timezone.
    pub fn next_after(&self, after_ms: i64) -> Result<Option<i64>> {
        self.validate()?;
        instant(after_ms)?;
        match self {
            Self::Once { at_ms } => Ok((*at_ms > after_ms).then_some(*at_ms)),
            Self::Interval {
                anchor_ms,
                every_seconds,
            } => {
                if after_ms < *anchor_ms {
                    return Ok(Some(*anchor_ms));
                }
                let step = i64::from(*every_seconds) * 1000;
                let n = (after_ms - *anchor_ms) / step + 1;
                let next = anchor_ms
                    .checked_add(n.checked_mul(step).context("interval overflow")?)
                    .context("interval overflow")?;
                instant(next)?;
                Ok(Some(next))
            }
            Self::Cron {
                expression,
                timezone,
                fold,
            } => {
                let cron = Cron::parse(expression)?;
                let tz: Tz = timezone.parse()?;
                let start = instant(after_ms)?.with_timezone(&tz).date_naive();
                for day in 0..=366 * 8 {
                    let date = start
                        .checked_add_signed(ChronoDuration::days(day))
                        .context("cron date overflow")?;
                    if !cron.date_matches(date) {
                        continue;
                    }
                    let mut best = None;
                    for &hour in &cron.hours.values {
                        for &minute in &cron.minutes.values {
                            let local = date
                                .and_hms_opt(u32::from(hour), u32::from(minute), 0)
                                .context("invalid cron wall time")?;
                            let candidates = match tz.from_local_datetime(&local) {
                                LocalResult::None => vec![],
                                LocalResult::Single(at) => vec![at],
                                LocalResult::Ambiguous(a, b) => {
                                    let (a, b) = if a < b { (a, b) } else { (b, a) };
                                    match fold {
                                        DstFold::First => vec![a],
                                        DstFold::Second => vec![b],
                                        DstFold::Both => vec![a, b],
                                    }
                                }
                            };
                            for candidate in candidates {
                                let ms = candidate.timestamp_millis();
                                if ms > after_ms && best.is_none_or(|value| ms < value) {
                                    best = Some(ms)
                                }
                            }
                        }
                    }
                    if best.is_some() {
                        return Ok(best);
                    }
                }
                bail!("cron has no occurrence in the next eight years")
            }
        }
    }
}
fn instant(ms: i64) -> Result<DateTime<Utc>> {
    ensure!(ms >= 0, "pre-epoch schedule instant unsupported");
    DateTime::from_timestamp_millis(ms).context("schedule instant out of range")
}
#[derive(Clone, Debug)]
struct Field {
    values: Vec<u8>,
    wild: bool,
}
impl Field {
    fn parse(text: &str, min: u8, max: u8, names: &[&str], sunday: bool) -> Result<Self> {
        ensure!(!text.is_empty() && text.len() <= 128, "invalid cron field");
        let mut values = HashSet::new();
        let number = |raw: &str| -> Result<u8> {
            let upper = raw.to_ascii_uppercase();
            let value = if let Some(index) = names.iter().position(|name| *name == upper) {
                index as u8 + min
            } else {
                raw.parse::<u8>().context("unsupported cron syntax")?
            };
            ensure!(value >= min && value <= max, "cron value out of range");
            Ok(value)
        };
        for part in text.split(',') {
            let mut stepped = part.split('/');
            let base = stepped.next().unwrap();
            let step = stepped
                .next()
                .map(|s| s.parse::<u8>())
                .transpose()?
                .unwrap_or(1);
            ensure!(step > 0 && stepped.next().is_none(), "invalid cron step");
            let (start, end) = if base == "*" {
                (min, max)
            } else if let Some((a, b)) = base.split_once('-') {
                (number(a)?, number(b)?)
            } else {
                let value = number(base)?;
                (value, if part.contains('/') { max } else { value })
            };
            ensure!(start <= end, "wrapping cron ranges unsupported");
            for value in (start..=end).step_by(step as usize) {
                values.insert(if sunday && value == 7 { 0 } else { value });
            }
        }
        let mut values: Vec<_> = values.into_iter().collect();
        values.sort_unstable();
        ensure!(!values.is_empty(), "empty cron field");
        Ok(Self {
            values,
            wild: text == "*",
        })
    }
    fn has(&self, value: u8) -> bool {
        self.values.binary_search(&value).is_ok()
    }
}
struct Cron {
    minutes: Field,
    hours: Field,
    days: Field,
    months: Field,
    weekdays: Field,
}
impl Cron {
    fn parse(expression: &str) -> Result<Self> {
        let expanded = match expression {
            "@hourly" => "0 * * * *",
            "@daily" | "@midnight" => "0 0 * * *",
            "@weekly" => "0 0 * * 0",
            "@monthly" => "0 0 1 * *",
            "@yearly" | "@annually" => "0 0 1 1 *",
            other => other,
        };
        let p: Vec<_> = expanded.split_whitespace().collect();
        ensure!(
            p.len() == 5,
            "cron requires five fields: minute hour day month weekday"
        );
        Ok(Self {
            minutes: Field::parse(p[0], 0, 59, &[], false)?,
            hours: Field::parse(p[1], 0, 23, &[], false)?,
            days: Field::parse(p[2], 1, 31, &[], false)?,
            months: Field::parse(
                p[3],
                1,
                12,
                &[
                    "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV",
                    "DEC",
                ],
                false,
            )?,
            weekdays: Field::parse(
                p[4],
                0,
                7,
                &["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"],
                true,
            )?,
        })
    }
    fn date_matches(&self, date: NaiveDate) -> bool {
        let dom = self.days.has(date.day() as u8);
        let dow = self
            .weekdays
            .has(date.weekday().num_days_from_sunday() as u8);
        self.months.has(date.month() as u8)
            && match (self.days.wild, self.weekdays.wild) {
                (true, true) => true,
                (true, false) => dow,
                (false, true) => dom,
                (false, false) => dom || dow,
            }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "policy", rename_all = "snake_case")]
pub enum MisfirePolicy {
    Skip { grace_seconds: u32 },
    CatchUpOnce { max_lateness_seconds: Option<u32> },
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum JobAction {
    Text { body: DeliveryBody },
    Generate { prompt: String },
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobSpec {
    pub job_id: String,
    pub target: DeliveryTarget,
    pub schedule: ScheduleSpec,
    pub misfire: MisfirePolicy,
    pub action: JobAction,
    pub delivery_kind: DeliveryKind,
}
impl JobSpec {
    fn validate(&self, identity: &DeliveryIdentity) -> Result<()> {
        id(&self.job_id)?;
        self.target.validate(identity)?;
        self.schedule.validate()?;
        match &self.action {
            JobAction::Text { body } => body.validate()?,
            JobAction::Generate { prompt } => ensure!(
                !prompt.trim().is_empty() && prompt.len() <= 256 * 1024,
                "invalid scheduled prompt"
            ),
        };
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JobRecord {
    pub revision: u64,
    pub spec: JobSpec,
    pub enabled: bool,
    pub next_fire_ms: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Occurrence {
    pub occurrence_id: String,
    pub job_id: String,
    pub scheduled_ms: i64,
    pub observed_ms: i64,
    pub target: DeliveryTarget,
    pub action: JobAction,
    pub delivery_kind: DeliveryKind,
    pub state: String,
    pub body: Option<DeliveryBody>,
}
impl Occurrence {
    pub fn route(&self) -> String {
        format!("cron_{}", self.occurrence_id)
    }
    pub fn delivery_request(&self) -> Result<DeliveryRequest> {
        Ok(DeliveryRequest {
            delivery_id: self.occurrence_id.clone(),
            target: self.target.clone(),
            kind: self.delivery_kind.clone(),
            body: self
                .body
                .clone()
                .context("occurrence has no committed result")?,
        })
    }
}
#[derive(Clone, Debug)]
pub enum ExecutionReceipt {
    Missing,
    Completed(DeliveryBody),
    Unknown,
    Cancelled,
}
/// The host must bind this implementation to the same owner as the scheduler.
/// `Missing` is a durable assertion that execution has never started. An unknown
/// outcome must NEVER be returned as Missing just because a request timed out.
pub trait ScheduledExecutor: Send + Sync {
    fn lookup<'a>(&'a self, occurrence: &'a Occurrence) -> DeliveryFuture<'a, ExecutionReceipt>;
    fn execute<'a>(&'a self, occurrence: &'a Occurrence) -> DeliveryFuture<'a, DeliveryBody>;
    fn cancel<'a>(&'a self, occurrence: &'a Occurrence) -> DeliveryFuture<'a, ()>;
}
/// Real Core bridge. Requires durable session context; never uses a fake model
/// response. Completed receipts are checked against the exact original input.
#[derive(Clone)]
pub struct CoreScheduledExecutor {
    core: crate::Core,
}
impl CoreScheduledExecutor {
    pub fn new(core: crate::Core) -> Result<Self> {
        ensure!(
            core.supports_session_context(),
            "scheduled Core requires durable session receipts"
        );
        Ok(Self { core })
    }
}
impl ScheduledExecutor for CoreScheduledExecutor {
    fn lookup<'a>(&'a self, o: &'a Occurrence) -> DeliveryFuture<'a, ExecutionReceipt> {
        Box::pin(async move {
            use crate::session_context::TurnLookup;
            let JobAction::Generate { prompt } = &o.action else {
                bail!("Core executor expects generated action")
            };
            match self
                .core
                .lookup_turn(o.route(), o.occurrence_id.clone())
                .await?
            {
                TurnLookup::Missing => Ok(ExecutionReceipt::Missing),
                TurnLookup::Completed { .. } => {
                    let result = self
                        .core
                        .lookup_completed(
                            o.route(),
                            o.occurrence_id.clone(),
                            json!({"role":"user","content":prompt}),
                        )
                        .await?
                        .context("completed Core receipt disappeared")?;
                    Ok(ExecutionReceipt::Completed(DeliveryBody::text(
                        result.answer,
                    )))
                }
                TurnLookup::Cancelled { .. } | TurnLookup::CancelledBeforeStart => {
                    Ok(ExecutionReceipt::Cancelled)
                }
                TurnLookup::Pending { .. } | TurnLookup::CommandCompleted { .. } => {
                    Ok(ExecutionReceipt::Unknown)
                }
            }
        })
    }
    fn execute<'a>(&'a self, o: &'a Occurrence) -> DeliveryFuture<'a, DeliveryBody> {
        Box::pin(async move {
            let JobAction::Generate { prompt } = &o.action else {
                bail!("Core executor expects generated action")
            };
            let result = self
                .core
                .chat_with_context(
                    crate::ChatRequest {
                        session_id: o.route(),
                        message: prompt.clone(),
                    },
                    crate::tool_runtime::TurnContext {
                        session_id: o.route(),
                        conversation_id: o.target.conversation_id.clone(),
                        input_id: o.occurrence_id.clone(),
                    },
                    None,
                )
                .await?;
            Ok(DeliveryBody::text(result.answer))
        })
    }
    fn cancel<'a>(&'a self, o: &'a Occurrence) -> DeliveryFuture<'a, ()> {
        Box::pin(async move {
            self.core
                .cancel_input(o.route(), o.occurrence_id.clone())
                .await?;
            Ok(())
        })
    }
}
#[derive(Clone, Copy, Debug)]
pub struct SchedulerLimits {
    pub max_jobs: usize,
    pub max_occurrences: usize,
    pub max_concurrent: usize,
    pub execution_timeout: Duration,
}
impl Default for SchedulerLimits {
    fn default() -> Self {
        Self {
            max_jobs: 4096,
            max_occurrences: 16384,
            max_concurrent: 4,
            execution_timeout: Duration::from_secs(900),
        }
    }
}
#[derive(Clone)]
pub struct Scheduler {
    db: Arc<OwnedDatabase>,
    identity: DeliveryIdentity,
    limits: SchedulerLimits,
    running: Arc<Mutex<HashSet<String>>>,
}
struct RunningGuard {
    running: Arc<Mutex<HashSet<String>>>,
    id: String,
}
impl Drop for RunningGuard {
    fn drop(&mut self) {
        if let Ok(mut set) = self.running.lock() {
            set.remove(&self.id);
        }
    }
}
impl Scheduler {
    pub async fn open(
        path: impl AsRef<Path>,
        identity: DeliveryIdentity,
        limits: SchedulerLimits,
    ) -> Result<Self> {
        ensure!(
            limits.max_jobs > 0
                && limits.max_occurrences > 0
                && limits.max_concurrent > 0
                && !limits.execution_timeout.is_zero()
                && limits.execution_timeout <= Duration::from_secs(86400),
            "invalid scheduler limits"
        );
        let path = path.as_ref().to_owned();
        let fingerprint = format!("scheduler:{}", digest(&serde_json::to_vec(&identity)?));
        let db = Arc::new(
            tokio::task::spawn_blocking(move || OwnedDatabase::open(&path, &fingerprint)).await??,
        );
        db.call(|db|{db.execute_batch("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,spec TEXT NOT NULL,enabled INTEGER NOT NULL,next_fire INTEGER); CREATE INDEX IF NOT EXISTS jobs_due ON jobs(enabled,next_fire); CREATE TABLE IF NOT EXISTS occurrences(id TEXT PRIMARY KEY,job_id TEXT NOT NULL,record TEXT NOT NULL,state TEXT NOT NULL); CREATE INDEX IF NOT EXISTS occurrences_state ON occurrences(state); CREATE INDEX IF NOT EXISTS occurrences_job_state ON occurrences(job_id,state); CREATE TABLE IF NOT EXISTS inbound_deliveries(id TEXT PRIMARY KEY,input_digest TEXT NOT NULL,occurrence_id TEXT NOT NULL);")?;let has_revision:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('jobs') WHERE name='revision')",[],|r|r.get(0))?;if !has_revision{db.execute("ALTER TABLE jobs ADD COLUMN revision INTEGER NOT NULL DEFAULT 1",[])?;}Ok(())}).await?;
        Ok(Self {
            db,
            identity,
            limits,
            running: Arc::new(Mutex::new(HashSet::new())),
        })
    }
    /// Create is idempotent for the exact current spec. Edits use optimistic
    /// revision checks; reusing a cancelled ID cannot revive old work.
    pub async fn create(&self, spec: JobSpec, now_ms: i64) -> Result<JobRecord> {
        spec.validate(&self.identity)?;
        instant(now_ms)?;
        let next = match spec.schedule {
            ScheduleSpec::Once { at_ms } => Some(at_ms),
            _ => spec.schedule.next_after(now_ms)?,
        };
        let limit = self.limits.max_jobs;
        self.db
            .call(move |db| {
                if let Some(old) = job(db, &spec.job_id)? {
                    ensure!(old.spec == spec, "job ID reused with changed spec");
                    return Ok(old);
                }
                let count: usize = db.query_row("SELECT COUNT(*) FROM jobs", [], |r| r.get(0))?;
                ensure!(count < limit, "scheduler job limit reached");
                db.execute(
                    "INSERT INTO jobs(id,spec,enabled,next_fire) VALUES(?1,?2,1,?3)",
                    params![spec.job_id, serde_json::to_string(&spec)?, next],
                )?;
                Ok(JobRecord {
                    revision: 1,
                    spec,
                    enabled: true,
                    next_fire_ms: next,
                })
            })
            .await
    }
    /// Admit an authenticated incoming cron/proactive delivery as TEXT, never a
    /// slash/control command. ACK only follows a committed durable occurrence.
    /// The host must validate the source connection and authorize this workflow.
    /// Inbound media must use the host media pipeline; it is rejected, not lost.
    pub async fn ingest_inbound(
        &self,
        frame: serde_json::Value,
        now_ms: i64,
    ) -> Result<(Occurrence, serde_json::Value)> {
        instant(now_ms)?;
        ensure!(frame["version"] == 1, "invalid inbound delivery version");
        let kind = match frame["type"].as_str() {
            Some("cron.delivery") => DeliveryKind::Cron,
            Some("proactive.delivery") => DeliveryKind::Proactive,
            Some("delivery.send") => DeliveryKind::Standalone,
            _ => bail!("not an inbound delivery"),
        };
        let input = frame["delivery_id"]
            .as_str()
            .context("inbound delivery ID missing")?
            .to_owned();
        id(&input)?;
        let conversation = frame["conversation_id"]
            .as_str()
            .context("inbound conversation missing")?
            .to_owned();
        id(&conversation)?;
        let content = frame["content"]
            .as_str()
            .context("inbound content missing")?
            .to_owned();
        ensure!(
            !content.trim().is_empty() && content.len() <= 256 * 1024,
            "invalid inbound content"
        );
        ensure!(
            frame
                .get("attachments")
                .is_none_or(|v| v.is_null() || v.as_array().is_some_and(Vec::is_empty)),
            "inbound delivery media requires host media pipeline"
        );
        ensure!(
            frame
                .get("metadata")
                .is_none_or(|v| v.is_null() || v.is_object()),
            "invalid inbound metadata"
        );
        let bytes = serde_json::to_vec(&frame)?;
        ensure!(
            bytes.len() <= crate::delivery::MAX_DELIVERY_BYTES,
            "inbound delivery exceeds byte limit"
        );
        let hash = digest(&bytes);
        let identity = self.identity.clone();
        let limits = self.limits;
        self.db.call(move|db|{
            let tx=db.transaction()?;
            if let Some((old,key))=tx.query_row("SELECT input_digest,occurrence_id FROM inbound_deliveries WHERE id=?1",[&input],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()?{
                ensure!(old==hash,"inbound delivery ID reused with different payload/target");let o=occurrence(&tx,&key)?.context("inbound occurrence disappeared")?;return Ok((o,json!({"version":1,"type":"delivery.ack","delivery_id":input,"conversation_id":conversation,"status":"duplicate"})))
            }
            let jobs:usize=tx.query_row("SELECT COUNT(*) FROM jobs",[],|r|r.get(0))?;let occurrences:usize=tx.query_row("SELECT COUNT(*) FROM occurrences",[],|r|r.get(0))?;ensure!(jobs<limits.max_jobs&&occurrences<limits.max_occurrences,"scheduler capacity exhausted");
            let scope=digest(&serde_json::to_vec(&(&identity,&input))?);let key=format!("delivery_in_{}",&scope[..40]);let job_id=format!("inbound_{}",&scope[..40]);
            let spec=JobSpec{job_id:job_id.clone(),target:DeliveryTarget{owner:identity.owner,device_id:identity.device_id,conversation_id:conversation.clone()},schedule:ScheduleSpec::Once{at_ms:now_ms},misfire:MisfirePolicy::CatchUpOnce{max_lateness_seconds:None},action:JobAction::Generate{prompt:content},delivery_kind:kind};
            let o=Occurrence{occurrence_id:key.clone(),job_id:job_id.clone(),scheduled_ms:now_ms,observed_ms:now_ms,target:spec.target.clone(),action:spec.action.clone(),delivery_kind:spec.delivery_kind.clone(),state:"queued".into(),body:None};
            tx.execute("INSERT INTO jobs(id,spec,enabled,next_fire) VALUES(?1,?2,1,NULL)",params![job_id,serde_json::to_string(&spec)?])?;tx.execute("INSERT INTO occurrences VALUES(?1,?2,?3,'queued')",params![key,job_id,serde_json::to_string(&o)?])?;tx.execute("INSERT INTO inbound_deliveries VALUES(?1,?2,?3)",params![input,hash,key])?;tx.commit()?;
            Ok((o,json!({"version":1,"type":"delivery.ack","delivery_id":input,"conversation_id":conversation,"status":"received"})))
        }).await
    }
    /// Optimistic update of an idle, enabled job. The approval must bind the
    /// returned revision; an intervening change is a conflict, never overwritten.
    pub async fn update(
        &self,
        expected_revision: u64,
        spec: JobSpec,
        now_ms: i64,
    ) -> Result<JobRecord> {
        spec.validate(&self.identity)?;
        instant(now_ms)?;
        let next = match spec.schedule {
            ScheduleSpec::Once { at_ms } => Some(at_ms),
            _ => spec.schedule.next_after(now_ms)?,
        };
        let running = self.running.clone();
        self.db
            .call(move |db| {
                let live = running
                    .lock()
                    .map_err(|_| anyhow::anyhow!("running set poisoned"))?;
                let tx = db.transaction()?;
                let old = job(&tx, &spec.job_id)?.context("unknown job")?;
                ensure!(
                    old.enabled
                        && old.revision == expected_revision
                        && old.spec.target == spec.target,
                    "job revision or target changed, or job removed"
                );
                let active: bool = active_for_job(&tx, &spec.job_id, &live)?;
                ensure!(
                    !active,
                    "job has an active or uncertain occurrence; cancel/reconcile it first"
                );
                let revision = old
                    .revision
                    .checked_add(1)
                    .filter(|n| *n <= i64::MAX as u64)
                    .context("job revision exhausted")?;
                tx.execute(
                    "UPDATE jobs SET spec=?2,next_fire=?3,revision=?4 WHERE id=?1",
                    params![spec.job_id, serde_json::to_string(&spec)?, next, revision],
                )?;
                tx.commit()?;
                Ok(JobRecord {
                    spec,
                    revision,
                    enabled: true,
                    next_fire_ms: next,
                })
            })
            .await
    }
    /// Queue a single manual run without altering the next scheduled fire.
    /// request_key is host-generated from trusted turn identity and exact action.
    pub async fn trigger_now(
        &self,
        job_id: &str,
        expected_revision: u64,
        request_key: &str,
        now_ms: i64,
    ) -> Result<Occurrence> {
        id(request_key)?;
        instant(now_ms)?;
        let key = job_id.to_owned();
        let request = request_key.to_owned();
        let limit = self.limits.max_occurrences;
        let running = self.running.clone();
        self.db
            .call(move |db| {
                let live = running
                    .lock()
                    .map_err(|_| anyhow::anyhow!("running set poisoned"))?;
                let tx = db.transaction()?;
                let record = job(&tx, &key)?.context("unknown job")?;
                ensure!(
                    record.enabled && record.revision == expected_revision,
                    "job removed or revision changed"
                );
                let occurrence_id = format!(
                    "delivery_manual_{}",
                    &digest(&serde_json::to_vec(&(
                        &record.spec.target,
                        &key,
                        expected_revision,
                        request
                    ))?)[..40]
                );
                if let Some(existing) = occurrence(&tx, &occurrence_id)? {
                    return Ok(existing);
                }
                let active: bool = active_for_job(&tx, &key, &live)?;
                ensure!(!active, "job already has an active or uncertain occurrence");
                let count: usize =
                    tx.query_row("SELECT COUNT(*) FROM occurrences", [], |r| r.get(0))?;
                ensure!(count < limit, "scheduler occurrence limit reached");
                let o = Occurrence {
                    occurrence_id: occurrence_id.clone(),
                    job_id: key.clone(),
                    scheduled_ms: now_ms,
                    observed_ms: now_ms,
                    target: record.spec.target,
                    action: record.spec.action,
                    delivery_kind: record.spec.delivery_kind,
                    state: "queued".into(),
                    body: None,
                };
                tx.execute(
                    "INSERT INTO occurrences VALUES(?1,?2,?3,'queued')",
                    params![occurrence_id, key, serde_json::to_string(&o)?],
                )?;
                tx.commit()?;
                Ok(o)
            })
            .await
    }
    pub async fn get(&self, key: &str) -> Result<Option<JobRecord>> {
        let key = key.to_owned();
        self.db.call(move |db| job(db, &key)).await
    }
    pub async fn list(&self, limit: usize, offset: usize) -> Result<Vec<JobRecord>> {
        ensure!((1..=256).contains(&limit), "invalid schedule page");
        self.db
            .call(move |db| {
                let mut q =
                    db.prepare_cached("SELECT id FROM jobs ORDER BY id LIMIT ?1 OFFSET ?2")?;
                let ids = q
                    .query_map(params![limit, offset], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                ids.into_iter()
                    .map(|key| job(db, &key)?.context("job disappeared"))
                    .collect()
            })
            .await
    }
    pub async fn occurrence(&self, key: &str) -> Result<Option<Occurrence>> {
        let key = key.to_owned();
        self.db.call(move |db| occurrence(db, &key)).await
    }
    /// Advance next-fire and insert each occurrence in one transaction. A restart
    /// cannot claim the same scheduled instant twice. Missed slots collapse to at
    /// most one occurrence per job, with observed_ms recording the gap boundary.
    pub async fn claim_due(&self, now_ms: i64, limit: usize) -> Result<Vec<Occurrence>> {
        instant(now_ms)?;
        ensure!((1..=256).contains(&limit), "invalid due page");
        let max = self.limits.max_occurrences;
        let running = self.running.clone();
        self.db.call(move|db|{
            let live=running.lock().map_err(|_|anyhow::anyhow!("running set poisoned"))?;let live_json=serde_json::to_string(&*live)?;
            let tx=db.transaction()?;let ids={let mut q=tx.prepare("SELECT id FROM jobs WHERE enabled=1 AND next_fire<=?1 AND NOT EXISTS (SELECT 1 FROM occurrences o WHERE o.job_id=jobs.id AND (o.state IN ('queued','executing','unknown','ready','enqueued') OR o.id IN (SELECT value FROM json_each(?3)))) ORDER BY next_fire,id LIMIT ?2")?;q.query_map(params![now_ms,limit,live_json],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?};
            let count:usize=tx.query_row("SELECT COUNT(*) FROM occurrences",[],|r|r.get(0))?;ensure!(count.saturating_add(ids.len())<=max,"scheduler occurrence limit reached");let mut out=vec![];
            for key in ids{
                let record=job(&tx,&key)?.context("due job disappeared")?;let scheduled=record.next_fire_ms.context("due job without next time")?;
                let lateness=now_ms-scheduled;let skip=match record.spec.misfire{MisfirePolicy::Skip{grace_seconds}=>lateness>i64::from(grace_seconds)*1000,MisfirePolicy::CatchUpOnce{max_lateness_seconds}=>max_lateness_seconds.is_some_and(|n|lateness>i64::from(n)*1000)};
                let next=record.spec.schedule.next_after(now_ms)?;
                let occurrence_id=format!("delivery_{}",&digest(&serde_json::to_vec(&(&record.spec.target,&key,record.revision,scheduled))?)[..40]);
                let o=Occurrence{occurrence_id:occurrence_id.clone(),job_id:key.clone(),scheduled_ms:scheduled,observed_ms:now_ms,target:record.spec.target,action:record.spec.action,delivery_kind:record.spec.delivery_kind,state:if skip{"skipped"}else{"queued"}.into(),body:None};
                tx.execute("INSERT INTO occurrences VALUES(?1,?2,?3,?4)",params![occurrence_id,key,serde_json::to_string(&o)?,o.state])?;
                tx.execute("UPDATE jobs SET next_fire=?2 WHERE id=?1",params![key,next])?;if !skip{out.push(o)}
            }
            tx.commit()?;Ok(out)
        }).await
    }
    /// Executable work only. Filtering `ready()` after pagination can starve
    /// queued occurrences behind old unknown/ready/enqueued reconciliation rows.
    pub async fn queued(&self, limit: usize) -> Result<Vec<Occurrence>> {
        ensure!((1..=256).contains(&limit), "invalid queued page");
        self.db
            .call(move |db| {
                let mut query = db.prepare_cached(
                    "SELECT record FROM occurrences WHERE state='queued' ORDER BY rowid LIMIT ?1",
                )?;
                let rows = query
                    .query_map([limit], |row| row.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                rows.into_iter()
                    .map(|raw| Ok(serde_json::from_str(&raw)?))
                    .collect()
            })
            .await
    }
    pub async fn ready(&self, limit: usize) -> Result<Vec<Occurrence>> {
        self.by_states(
            &["queued", "executing", "unknown", "ready", "enqueued"],
            limit,
        )
        .await
    }
    pub async fn recovery_page(
        &self,
        after_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Occurrence>> {
        ensure!((1..=256).contains(&limit), "invalid recovery page");
        let after = after_id.unwrap_or("").to_owned();
        self.db.call(move|db|{let mut q=db.prepare_cached("SELECT record FROM occurrences WHERE id>?1 AND state IN ('queued','executing','unknown','ready','enqueued','cancelled') ORDER BY id LIMIT ?2")?;let rows=q.query_map(params![after,limit],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;rows.into_iter().map(|s|Ok(serde_json::from_str(&s)?)).collect()}).await
    }
    async fn by_states(&self, states: &[&str], limit: usize) -> Result<Vec<Occurrence>> {
        ensure!((1..=256).contains(&limit), "invalid occurrence page");
        let states: Vec<String> = states.iter().map(|s| s.to_string()).collect();
        self.db.call(move|db|{let mut q=db.prepare_cached("SELECT record FROM occurrences WHERE state IN (SELECT value FROM json_each(?1)) ORDER BY CASE WHEN state='ready' THEN 0 ELSE 1 END,rowid LIMIT ?2")?;let rows=q.query_map(params![serde_json::to_string(&states)?,limit],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;rows.into_iter().map(|s|Ok(serde_json::from_str(&s)?)).collect()}).await
    }
    /// Only a verified Missing receipt allows model/tool entry. An in-flight,
    /// failed or timed-out unknown result is retained for later reconciliation.
    pub async fn execute_occurrence(
        &self,
        key: &str,
        executor: &dyn ScheduledExecutor,
    ) -> Result<Occurrence> {
        {
            let mut set = self
                .running
                .lock()
                .map_err(|_| anyhow::anyhow!("running set poisoned"))?;
            ensure!(
                set.len() < self.limits.max_concurrent,
                "scheduler execution concurrency exhausted"
            );
            ensure!(set.insert(key.into()), "occurrence already running");
        }
        let _guard = RunningGuard {
            running: self.running.clone(),
            id: key.into(),
        };
        let mut o = self.occurrence(key).await?.context("unknown occurrence")?;
        if !matches!(o.state.as_str(), "queued" | "executing" | "unknown") {
            return Ok(o);
        }
        let receipt = match &o.action {
            JobAction::Text { body } => ExecutionReceipt::Completed(body.clone()),
            JobAction::Generate { .. } => executor.lookup(&o).await?,
        };
        let body = match receipt {
            ExecutionReceipt::Completed(body) => body,
            ExecutionReceipt::Cancelled => return self.transition(key, "cancelled", None).await,
            ExecutionReceipt::Unknown => return self.transition(key, "unknown", None).await,
            ExecutionReceipt::Missing => {
                o = self.transition(key, "executing", None).await?;
                if o.state == "cancelled" {
                    return Ok(o);
                }
                match tokio::time::timeout(self.limits.execution_timeout, executor.execute(&o))
                    .await
                {
                    Ok(Ok(body)) => body,
                    _ => return self.transition(key, "unknown", None).await,
                }
            }
        };
        body.validate()?;
        self.transition(key, "ready", Some(body)).await
    }
    async fn transition(
        &self,
        key: &str,
        state: &str,
        body: Option<DeliveryBody>,
    ) -> Result<Occurrence> {
        let key = key.to_owned();
        let state = state.to_owned();
        self.db
            .call(move |db| {
                let mut o = occurrence(db, &key)?.context("occurrence missing")?;
                if o.state.starts_with("cancelled") {
                    return Ok(o);
                };
                o.state = state;
                if body.is_some() {
                    o.body = body
                };
                save_occurrence(db, &o)?;
                Ok(o)
            })
            .await
    }
    /// Same occurrence ID and immutable payload close the cross-database handoff
    /// window: if enqueue committed before our state update, retry is a no-op.
    pub async fn flush_deliveries(&self, outbox: &DeliveryOutbox, limit: usize) -> Result<usize> {
        ensure!(
            outbox.identity == self.identity,
            "scheduler/outbox identity mismatch"
        );
        // Cancelled rows may have reached the outbox before cancellation.
        for mut o in self.by_states(&["cancelled"], limit).await? {
            if self.confirm_delivery(&o.occurrence_id, outbox).await? {
                continue;
            }
            outbox.cancel(&o.occurrence_id).await?;
            o.state = "cancelled_synced".into();
            self.db.call(move |db| save_occurrence(db, &o)).await?;
        }
        let mut count = 0;
        for o in self.by_states(&["ready", "enqueued"], limit).await? {
            let status = outbox.enqueue(o.delivery_request()?).await?;
            let next = match status {
                DeliveryStatus::Pending => "enqueued",
                DeliveryStatus::Acknowledged { .. } => "acknowledged",
                DeliveryStatus::Cancelled => "cancelled",
            };
            let updated = self.transition(&o.occurrence_id, next, None).await?;
            if updated.state == "cancelled" {
                outbox.cancel(&o.occurrence_id).await?;
            }
            count += 1;
        }
        Ok(count)
    }
    /// Invoke after the live authenticated reader accepts a delivery ACK. A
    /// late receipt dominates a local cancellation: already accepted output
    /// cannot truthfully be described as retracted.
    pub async fn confirm_delivery(&self, key: &str, outbox: &DeliveryOutbox) -> Result<bool> {
        ensure!(
            outbox.identity == self.identity,
            "scheduler/outbox identity mismatch"
        );
        let Some(row) = outbox.inspect(key).await? else {
            return Ok(false);
        };
        if !matches!(row.status, DeliveryStatus::Acknowledged { .. }) {
            return Ok(false);
        }
        let key = key.to_owned();
        self.db
            .call(move |db| {
                let Some(mut o) = occurrence(db, &key)? else {
                    return Ok(false);
                };
                ensure!(
                    o.delivery_request()? == row.request,
                    "receipt differs from scheduled output"
                );
                o.state = if o.state.starts_with("cancelled") {
                    "acknowledged_after_cancel"
                } else {
                    "acknowledged"
                }
                .into();
                save_occurrence(db, &o)?;
                Ok(true)
            })
            .await
    }
    /// Local cancellation prevents later fires/delivery; it cannot undo effects
    /// or a frame already sent. Returned rows let the host fence running Core
    /// turns using executor.cancel without waiting for their route mutex.
    pub async fn cancel(&self, job_id: &str) -> Result<Vec<Occurrence>> {
        self.cancel_records(job_id, true, None).await
    }
    /// Cancel only current occurrences, preserving the job's future schedule.
    pub async fn cancel_run(&self, job_id: &str) -> Result<Vec<Occurrence>> {
        self.cancel_records(job_id, false, None).await
    }
    pub async fn cancel_at_revision(
        &self,
        job_id: &str,
        revision: u64,
        stop_schedule: bool,
    ) -> Result<Vec<Occurrence>> {
        self.cancel_records(job_id, stop_schedule, Some(revision))
            .await
    }
    async fn cancel_records(
        &self,
        job_id: &str,
        stop_schedule: bool,
        expected_revision: Option<u64>,
    ) -> Result<Vec<Occurrence>> {
        let key = job_id.to_owned();
        self.db.call(move|db|{
            let tx=db.transaction()?;let current=job(&tx,&key)?.context("unknown job")?;ensure!(expected_revision.is_none_or(|r|current.revision==r),"job revision changed during approval");
            if stop_schedule{tx.execute("UPDATE jobs SET enabled=0,next_fire=NULL WHERE id=?1",[&key])?;}
            let ids={let mut q=tx.prepare("SELECT id FROM occurrences WHERE job_id=?1 AND state NOT IN ('acknowledged','acknowledged_after_cancel','skipped','cancelled','cancelled_synced')")?;q.query_map([&key],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?};let mut out=vec![];
            for key in ids{let mut o=occurrence(&tx,&key)?.context("occurrence disappeared")?;o.state="cancelled".into();save_occurrence(&tx,&o)?;out.push(o)}tx.commit()?;Ok(out)
        }).await
    }
}
fn job(db: &Connection, key: &str) -> Result<Option<JobRecord>> {
    let row: Option<(String, bool, Option<i64>, u64)> = db
        .query_row(
            "SELECT spec,enabled,next_fire,revision FROM jobs WHERE id=?1",
            [key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    row.map(|(spec, enabled, next_fire_ms, revision)| {
        Ok(JobRecord {
            revision,
            spec: serde_json::from_str(&spec)?,
            enabled,
            next_fire_ms,
        })
    })
    .transpose()
}
fn occurrence(db: &Connection, key: &str) -> Result<Option<Occurrence>> {
    db.query_row("SELECT record FROM occurrences WHERE id=?1", [key], |r| {
        r.get::<_, String>(0)
    })
    .optional()?
    .map(|s| Ok(serde_json::from_str(&s)?))
    .transpose()
}
fn save_occurrence(db: &Connection, o: &Occurrence) -> Result<()> {
    db.execute(
        "UPDATE occurrences SET record=?2,state=?3 WHERE id=?1",
        params![o.occurrence_id, serde_json::to_string(o)?, o.state],
    )?;
    Ok(())
}

fn active_for_job(db: &Connection, key: &str, live: &HashSet<String>) -> Result<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM occurrences WHERE job_id=?1 AND (state IN ('queued','executing','unknown','ready','enqueued') OR id IN (SELECT value FROM json_each(?2))))",params![key,serde_json::to_string(live)?],|r|r.get(0))?)
}
