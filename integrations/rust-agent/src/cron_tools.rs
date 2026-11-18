//! Approval-gated `cronjob_manage` subset. Scheduling is not calendar CRUD.
//! The model cannot choose owner, device, alternate delivery targets or provider.
use crate::{
    delivery::{DeliveryIdentity, DeliveryKind, DeliveryOutbox, DeliveryTarget, digest},
    interactions::InteractionHub,
    scheduler::{
        DstFold, JobAction, JobRecord, JobSpec, MisfirePolicy, ScheduleSpec, ScheduledExecutor,
        Scheduler,
    },
    tool_runtime::{ToolExecutor, TurnContext},
};
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, LocalResult, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use futures_util::future::BoxFuture;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

pub struct CronTools {
    scheduler: Scheduler,
    outbox: DeliveryOutbox,
    executor: Arc<dyn ScheduledExecutor>,
    hub: InteractionHub,
    identity: DeliveryIdentity,
    timezone: String,
}
impl CronTools {
    pub fn new(
        scheduler: Scheduler,
        outbox: DeliveryOutbox,
        executor: Arc<dyn ScheduledExecutor>,
        hub: InteractionHub,
        timezone: String,
    ) -> Result<Self> {
        let _: Tz = timezone
            .parse()
            .context("unknown scheduler default timezone")?;
        let identity = outbox.identity.clone();
        Ok(Self {
            scheduler,
            outbox,
            executor,
            hub,
            identity,
            timezone,
        })
    }
    async fn scoped_job(&self, context: &TurnContext, key: &str) -> Result<JobRecord> {
        let job = self
            .scheduler
            .get(key)
            .await?
            .context("unknown job; list jobs first")?;
        ensure!(
            job.spec.target.owner == self.identity.owner
                && job.spec.target.device_id == self.identity.device_id
                && job.spec.target.conversation_id == context.conversation_id,
            "job is not owned by this trusted conversation"
        );
        Ok(job)
    }
    async fn run(&self, args: Value, context: &TurnContext) -> Result<Value> {
        ensure!(
            [
                &context.conversation_id,
                &context.input_id,
                &context.session_id
            ]
            .iter()
            .all(|s| !s.trim().is_empty() && s.len() <= 160),
            "cron tool lacks trusted turn context"
        );
        let action = args["action"].as_str().context("cron action missing")?;
        let allowed: &[&str] = match action {
            "create" => &[
                "action", "prompt", "schedule", "timezone", "catch_up", "deliver",
            ],
            "update" => &[
                "action", "job_id", "prompt", "schedule", "timezone", "catch_up", "deliver",
            ],
            "list" => &["action"],
            "remove" | "cancel" | "run" => &["action", "job_id"],
            _ => {
                return Ok(
                    json!({"success":false,"error":"not_supported","detail":"Supported actions: create, list, update, remove, run, cancel. Pause/resume and advanced cron providers/scripts are not implemented."}),
                );
            }
        };
        let unsupported = args
            .as_object()
            .context("cron arguments must be object")?
            .keys()
            .filter(|key| !allowed.contains(&key.as_str()))
            .cloned()
            .collect::<Vec<_>>();
        if !unsupported.is_empty() {
            return Ok(json!({"success":false,"error":"not_supported","fields":unsupported}));
        }
        if let Some(deliver) = args.get("deliver") {
            ensure!(
                deliver.as_str() == Some("origin"),
                "cron delivery is restricted to this trusted conversation"
            );
        }
        if let Some(zone) = args.get("timezone") {
            let zone = zone.as_str().context("timezone must be string")?;
            let _: Tz = zone.parse().context("unknown IANA timezone")?;
        }
        let now_ms = wall_ms()?;
        if action == "list" {
            let mut offset = 0;
            let mut result = vec![];
            let mut more = false;
            loop {
                let page = self.scheduler.list(64, offset).await?;
                let end = page.len() < 64;
                offset += page.len();
                for job in page {
                    if job.spec.target.owner == self.identity.owner
                        && job.spec.target.device_id == self.identity.device_id
                        && job.spec.target.conversation_id == context.conversation_id
                    {
                        if result.len() == 100 {
                            more = true;
                            break;
                        }
                        let prompt = match &job.spec.action {
                            JobAction::Generate { prompt } => {
                                prompt.chars().take(512).collect::<String>()
                            }
                            JobAction::Text { body } => body.content.chars().take(512).collect(),
                        };
                        result.push(json!({"job_id":job.spec.job_id,"revision":job.revision,"enabled":job.enabled,"next_fire_ms":job.next_fire_ms,"schedule":job.spec.schedule,"prompt_preview":prompt}));
                    }
                }
                if end || more {
                    break;
                }
            }
            return Ok(json!({"success":true,"jobs":result,"truncated":more}));
        }
        let request_key = digest(&serde_json::to_vec(&json!([
            context.conversation_id,
            context.input_id,
            args
        ]))?);
        let old = if action == "create" {
            None
        } else {
            Some(
                self.scoped_job(
                    context,
                    args["job_id"]
                        .as_str()
                        .context("job_id required; list first")?,
                )
                .await?,
            )
        };
        let mut spec = if let Some(old) = &old {
            old.spec.clone()
        } else {
            let prompt = required_prompt(&args)?;
            let zone = args["timezone"].as_str().unwrap_or(&self.timezone);
            let schedule = parse_schedule(
                args["schedule"].as_str().context("schedule required")?,
                zone,
                now_ms,
            )?;
            JobSpec {
                job_id: format!("cron_{}", &request_key[..32]),
                target: DeliveryTarget {
                    owner: self.identity.owner.clone(),
                    device_id: self.identity.device_id.clone(),
                    conversation_id: context.conversation_id.clone(),
                },
                misfire: default_misfire(&schedule),
                schedule,
                action: JobAction::Generate { prompt },
                delivery_kind: DeliveryKind::Cron,
            }
        };
        if action == "update" {
            ensure!(
                args.get("prompt").is_some()
                    || args.get("schedule").is_some()
                    || args.get("timezone").is_some()
                    || args.get("catch_up").is_some(),
                "update has no changes"
            );
            if args.get("prompt").is_some() {
                spec.action = JobAction::Generate {
                    prompt: required_prompt(&args)?,
                };
            }
            if let Some(schedule) = args.get("schedule") {
                let zone = args["timezone"].as_str().unwrap_or(match &spec.schedule {
                    ScheduleSpec::Cron { timezone, .. } => timezone,
                    _ => &self.timezone,
                });
                spec.schedule = parse_schedule(
                    schedule.as_str().context("schedule must be string")?,
                    zone,
                    now_ms,
                )?;
            } else if let Some(zone) = args.get("timezone") {
                let zone = zone.as_str().context("timezone must be string")?;
                let _: Tz = zone.parse()?;
                if let ScheduleSpec::Cron { timezone, .. } = &mut spec.schedule {
                    *timezone = zone.into()
                } else {
                    bail!(
                        "timezone-only update requires a cron schedule; provide a new timestamp for one-shot"
                    )
                }
            }
        }
        if let Some(catch_up) = args.get("catch_up") {
            spec.misfire = if catch_up.as_bool().context("catch_up must be boolean")? {
                MisfirePolicy::CatchUpOnce {
                    max_lateness_seconds: None,
                }
            } else {
                MisfirePolicy::Skip { grace_seconds: 120 }
            };
        }
        spec.schedule.validate()?;
        let next = if action == "run" {
            Some(now_ms)
        } else {
            match spec.schedule {
                ScheduleSpec::Once { at_ms } => Some(at_ms),
                _ => spec.schedule.next_after(now_ms)?,
            }
        };
        let bound = json!({"tool":"cronjob_manage","operation":action,"request_key":request_key,"expected_revision":old.as_ref().map(|r|r.revision),"spec":spec,"next_fire_ms":next});
        let prompt = match &spec.action {
            JobAction::Generate { prompt } => prompt.clone(),
            JobAction::Text { body } => body.content.clone(),
        };
        ensure!(
            prompt.len() <= 16 * 1024,
            "scheduled prompt too long for explicit approval"
        );
        let zone = match &spec.schedule {
            ScheduleSpec::Cron { timezone, .. } => timezone.as_str(),
            _ => &self.timezone,
        };
        let next_display = next
            .and_then(DateTime::<Utc>::from_timestamp_millis)
            .map(|dt| dt.to_rfc3339())
            .unwrap_or_else(|| "none".into());
        let description = format!(
            "Operation: {action}\nJob: {}\nRecipient: current Orialis conversation {}\nTimezone: {zone}\nSchedule: {}\nNext/manual fire (UTC): {next_display}\nMissed-run policy: {}\nTask content:\n{prompt}\nOnly the final generated result is sent. A server delivery ACK does not prove persistent storage. Cron DST gaps are skipped; repeated local times use the first occurrence.",
            spec.job_id,
            context.conversation_id,
            serde_json::to_string(&spec.schedule)?,
            serde_json::to_string(&spec.misfire)?
        );
        self.hub
            .approve(
                context,
                &bound,
                "Approve this scheduled-task change once",
                &description,
            )
            .await?
            .verify(context, &bound)?;
        match action {
            "create" => {
                let stored = self.scheduler.create(spec, now_ms).await?;
                Ok(json!({"success":true,"job":stored,"persisted":true,"execution":"not_started"}))
            }
            "update" => {
                let stored = self
                    .scheduler
                    .update(old.context("job missing")?.revision, spec, now_ms)
                    .await?;
                Ok(json!({"success":true,"job":stored,"persisted":true}))
            }
            "run" => {
                let old = old.context("job missing")?;
                let run = self
                    .scheduler
                    .trigger_now(&spec.job_id, old.revision, &request_key, now_ms)
                    .await?;
                Ok(
                    json!({"success":true,"occurrence_id":run.occurrence_id,"state":run.state,"generated":false,"delivered":false}),
                )
            }
            "remove" | "cancel" => {
                // Scope and revision can change while the approval dialog is up.
                let current = self.scoped_job(context, &spec.job_id).await?;
                ensure!(
                    current.revision == old.context("job missing")?.revision,
                    "job changed during approval; approve the new revision"
                );
                let rows = self
                    .scheduler
                    .cancel_at_revision(&spec.job_id, current.revision, action == "remove")
                    .await?;
                let mut cancel_errors = 0;
                for o in &rows {
                    if self.executor.cancel(o).await.is_err() {
                        cancel_errors += 1;
                    }
                    self.outbox.cancel(&o.occurrence_id).await?;
                }
                Ok(
                    json!({"success":true,"job_id":spec.job_id,"schedule_removed":action=="remove","local_occurrences_cancelled":rows.len(),"executor_fence_errors":cancel_errors,"prior_effects_may_remain":true}),
                )
            }
            _ => unreachable!(),
        }
    }
}
impl ToolExecutor for CronTools {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"cronjob_manage","description":"Create/list/update/remove/run/cancel persistent local cron tasks. All writes require explicit one-use approval. Results go only to this conversation. Runs use a fresh session and a self-contained prompt. This is not calendar create_schedule. Only five-field cron, durations and explicit timestamps are supported; no scripts, monitors, provider pins, skills, multi-platform recipients, pause/resume or repeat counts.","parameters":{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["create","list","update","remove","run","cancel"]},"job_id":{"type":"string"},"schedule":{"type":"string","description":"Five-field cron (minute hour day month weekday), RFC3339 timestamp, local ISO datetime with timezone, recurring '30m'/'every 2h', or one-shot 'in 30m'."},"prompt":{"type":"string","description":"Self-contained task instructions, required for create; optional replacement for update."},"timezone":{"type":"string","description":"IANA timezone for cron or a local ISO timestamp. Defaults to the host-configured zone, shown at approval."},"catch_up":{"type":"boolean"},"deliver":{"type":"string","enum":["origin"]}},"required":["action"]}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        args: Value,
        context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            ensure!(name == "cronjob_manage", "unknown cron tool");
            self.run(args, context).await
        })
    }
}
fn required_prompt(args: &Value) -> Result<String> {
    let prompt = args["prompt"].as_str().context("prompt required")?;
    ensure!(
        !prompt.trim().is_empty() && prompt.len() <= 16 * 1024,
        "invalid scheduled prompt"
    );
    Ok(prompt.into())
}
fn default_misfire(schedule: &ScheduleSpec) -> MisfirePolicy {
    if matches!(schedule, ScheduleSpec::Once { .. }) {
        MisfirePolicy::Skip { grace_seconds: 120 }
    } else {
        MisfirePolicy::CatchUpOnce {
            max_lateness_seconds: None,
        }
    }
}
fn wall_ms() -> Result<i64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .try_into()?)
}
/// Narrow, documented subset of upstream parse_schedule. No natural-language
/// guessing; ambiguous/nonexistent one-shot wall times require an explicit offset.
pub fn parse_schedule(value: &str, timezone: &str, now_ms: i64) -> Result<ScheduleSpec> {
    let tz: Tz = timezone.parse().context("unknown IANA timezone")?;
    let value = value.trim();
    ensure!(!value.is_empty() && value.len() <= 256, "invalid schedule");
    let lower = value.to_ascii_lowercase();
    let (duration, once) = if let Some(tail) = lower.strip_prefix("in ") {
        (tail.trim(), true)
    } else {
        (lower.strip_prefix("every ").unwrap_or(&lower).trim(), false)
    };
    let unit = duration.chars().last().unwrap();
    if matches!(unit, 's' | 'm' | 'h' | 'd')
        && duration[..duration.len() - 1]
            .bytes()
            .all(|b| b.is_ascii_digit())
    {
        let n = duration[..duration.len() - 1].parse::<u64>()?;
        let seconds = n
            .checked_mul(match unit {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                _ => 86400,
            })
            .context("duration overflow")?;
        ensure!(
            seconds > 0 && seconds <= u32::MAX as u64,
            "duration out of range"
        );
        let at = now_ms
            .checked_add((seconds as i64) * 1000)
            .context("schedule overflow")?;
        return Ok(if once {
            ScheduleSpec::Once { at_ms: at }
        } else {
            ScheduleSpec::Interval {
                anchor_ms: at,
                every_seconds: seconds as u32,
            }
        });
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(value) {
        return Ok(ScheduleSpec::Once {
            at_ms: dt.timestamp_millis(),
        });
    }
    if let Ok(local) = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S")
        .or_else(|_| NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M"))
    {
        let LocalResult::Single(at) = tz.from_local_datetime(&local) else {
            bail!("ambiguous or nonexistent local time; provide an explicit UTC offset")
        };
        return Ok(ScheduleSpec::Once {
            at_ms: at.timestamp_millis(),
        });
    }
    let schedule = ScheduleSpec::Cron {
        expression: value.into(),
        timezone: timezone.into(),
        fold: DstFold::First,
    };
    schedule
        .validate()
        .context("not_supported: use five-field cron, a duration, or an explicit timestamp")?;
    Ok(schedule)
}
