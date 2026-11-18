//! Standalone Orialis adapter with optional durable event-v1 streaming.
use anyhow::{Context, Result, ensure};
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use hermes_rust_core::conversation_updates::{
    AuxiliaryClient, PendingUpdate, Phase, TurnInput, TurnUpdates,
};
use hermes_rust_core::gateway_events::{AckOutcome, CAPABILITIES, GatewayEvents, RunEvents};
use hermes_rust_core::journal::Journal;
use hermes_rust_core::tool_runtime::{TurnContext, TurnEvent, TurnObserver};
use hermes_rust_core::{ChatRequest, Core, CoreLimits, Provider, Store, wire};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{Message, client::IntoClientRequest, http::HeaderValue},
};

#[derive(Parser)]
struct Args {
    #[arg(long, env = "ORIALIS_SERVER_URL")]
    server: String,
    #[arg(long, env = "ORIALIS_DEVICE_ID")]
    device: String,
    #[arg(long, env = "ORIALIS_DEVICE_TOKEN", hide_env_values = true)]
    token: Option<String>,
    #[arg(long, default_value = "orialis-rust.sqlite")]
    db: PathBuf,
    #[arg(long, default_value = "https://api.openai.com/v1/chat/completions")]
    endpoint: String,
    #[arg(long, default_value = "gpt-4.1-mini")]
    model: String,
    /// Explicit alternate compatible model route. Credentials are not inherited.
    #[arg(long, requires = "fallback_model")]
    fallback_endpoint: Option<String>,
    #[arg(long, requires = "fallback_endpoint")]
    fallback_model: Option<String>,
    #[arg(
        long,
        env = "HERMES_FALLBACK_API_KEY",
        hide_env_values = true,
        requires = "fallback_endpoint"
    )]
    fallback_api_key: Option<String>,
    #[arg(long)]
    vision_endpoint: Option<String>,
    #[arg(long)]
    vision_model: Option<String>,
    #[arg(long, env = "HERMES_VISION_API_KEY", hide_env_values = true)]
    vision_api_key: Option<String>,
    /// Opt-in auxiliary image analysis; does not claim native tool-image support.
    #[arg(long, requires_all = ["verify_owner", "session_context", "vision_endpoint", "vision_model"], conflicts_with="native_tool_images")]
    vision_tools: bool,
    /// Enable native vision tool pixels via explicit OpenAI Chat user-image bridge.
    #[arg(long, requires_all=["verify_owner", "session_context"], conflicts_with="vision_tools")]
    native_tool_images: bool,
    /// Explicitly attest the configured fallback supports that same image bridge.
    #[arg(long, requires_all=["native_tool_images", "fallback_endpoint"])]
    fallback_native_tool_images: bool,
    /// Isolated bounded native children on the fixed primary model route.
    #[arg(long, requires_all=["verify_owner", "session_context"])]
    delegation: bool,
    /// Detached children and durable completion notifications on the origin conversation.
    #[arg(long, requires_all=["delegation", "verify_owner", "session_context"])]
    delegation_background: bool,
    /// Resume the originating parent model from a durable child completion.
    #[arg(long, requires_all=["delegation_background", "delegation", "verify_owner", "session_context"])]
    delegation_parent_resume: bool,
    /// Exact configured tool names inherited by children. Omitted means no tools.
    #[arg(long, requires = "delegation", value_delimiter = ',')]
    delegate_tools: Vec<String>,
    #[arg(long, env = "HERMES_CORE_API_KEY", hide_env_values = true)]
    api_key: Option<String>,
    #[arg(long)]
    mock: bool,
    /// Enable the implemented Orialis user-domain HTTP tool integration.
    #[arg(long)]
    domain_tools: bool,
    /// Public static webpage extraction. No browser session or user cookies.
    #[arg(long)]
    web_tools: bool,
    /// Explicit search backend: brave or firecrawl. Omitted exposes extraction only.
    #[arg(long,requires="web_tools",value_parser=["brave","firecrawl"])]
    search_provider: Option<String>,
    #[arg(long, requires = "search_provider")]
    search_endpoint: Option<String>,
    #[arg(
        long,
        env = "ORIALIS_SEARCH_API_KEY",
        hide_env_values = true,
        requires = "search_provider"
    )]
    search_api_key: Option<String>,
    /// Enable authenticated incoming attachments, with explicit provider input support.
    #[arg(long)]
    attachments: bool,
    /// Trusted public Orialis origin for attachment URLs when dispatch uses a private address.
    #[arg(long, requires = "attachments")]
    attachment_origin: Option<String>,
    /// Enable final MEDIA artifact upload from registered tools or explicit export roots.
    #[arg(long, requires = "attachments")]
    output_files: bool,
    /// Existing absolute directories explicitly allowed for final artifact export.
    #[arg(long, requires = "output_files")]
    artifact_root: Vec<PathBuf>,
    #[arg(long)]
    chat_images: bool,
    #[arg(long, requires = "attachments")]
    documents: bool,
    /// Explicit installed Poppler binary for PDF extraction; no automatic install.
    #[arg(long, requires = "documents")]
    pdf_program: Option<PathBuf>,
    /// Maximum simultaneous historyless screen/video analyses; bounded 1..=4.
    #[arg(long,default_value_t=4,value_parser=clap::value_parser!(u8).range(1..=4))]
    memory_concurrency: u8,
    /// Explicit owner-private Bilibili credential file. Omitted stays anonymous.
    #[arg(long)]
    bili_credentials: Option<PathBuf>,
    /// Trusted JSON local-tool configuration. No root means no local tools.
    #[arg(long,requires_all=["verify_owner","interactions","session_context"])]
    local_tools_json: Option<String>,
    /// Trusted Hermes-compatible mcp_servers JSON; only discovered tools are exposed.
    #[arg(long, requires_all = ["verify_owner", "session_context"])]
    mcp_servers_json: Option<String>,
    /// Restricted local text rendering only, not external/general browsing.
    /// Explicit disposable CDP endpoint; never discovers a user's browser.
    #[arg(long,requires_all=["verify_owner","interactions","session_context"])]
    browser_tools_json: Option<String>,
    /// Trusted local-only portable profile bridge; hub exchange runs separately.
    #[arg(long, requires_all=["verify_owner", "session_context"])]
    portable_profile_json: Option<String>,
    /// Persistent approval-gated local schedules on this same authenticated WS.
    #[arg(long,requires_all=["verify_owner","session_context","interactions"])]
    scheduler: bool,
    /// Authenticated durable text deliveries, independently of local scheduling.
    #[arg(long,requires_all=["verify_owner","session_context"])]
    inbound_deliveries: bool,
    #[arg(long, default_value = "UTC", requires = "scheduler")]
    scheduler_timezone: String,
    #[arg(long)]
    attachment_cache: Option<PathBuf>,
    #[arg(long, env = "ORIALIS_NEWS_PUBLISHER_TOKEN", hide_env_values = true)]
    news_publisher_token: Option<String>,
    /// Enable native clarification and exact once-only approval workflows.
    #[arg(long, requires = "stream_events")]
    interactions: bool,
    /// Verify bearer account ownership before every connection and bind private state.
    #[arg(long)]
    verify_owner: bool,
    /// Owner-bound lossless history, compaction and durable tool/final receipts.
    #[arg(long, requires = "verify_owner")]
    session_context: bool,
    /// Optional expected server user ID; requires --verify-owner.
    #[arg(long, requires = "verify_owner")]
    expected_owner: Option<String>,
    /// Explicit JSON array of shared directories; omitted exposes no workspace.
    #[arg(long, env = "ORIALIS_WORKSPACES")]
    workspaces_json: Option<String>,
    /// Enable negotiated streaming, typing and tool lifecycle events.
    #[arg(long)]
    stream_events: bool,
    /// Independent initial/progress responses and compare-and-swap titles.
    #[arg(long,requires_all=["stream_events","domain_tools","verify_owner"])]
    turn_updates: bool,
    #[arg(long, requires = "turn_updates")]
    auxiliary_endpoint: Option<String>,
    #[arg(long, requires = "turn_updates")]
    auxiliary_model: Option<String>,
    #[arg(
        long,
        env = "HERMES_AUXILIARY_API_KEY",
        hide_env_values = true,
        requires = "turn_updates"
    )]
    auxiliary_api_key: Option<String>,
    /// Total turn budget including queue and safe retries. Defaults to 45,
    /// or 900 with --stream-events; the release server caps total time at 900.
    #[arg(long)]
    turn_timeout_secs: Option<u64>,
    /// Hard provider iteration bound, not automatic context compression.
    #[arg(long)]
    max_provider_rounds: Option<usize>,
    /// Maximum tools executed per provider response (1..32).
    #[arg(long)]
    max_tool_calls: Option<usize>,
}
#[cfg(unix)]
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalConfig {
    root: PathBuf,
    #[serde(default)]
    write: hermes_rust_core::local_tools::Permission,
    #[serde(default)]
    execute: hermes_rust_core::local_tools::Permission,
    #[serde(default)]
    programs: Vec<hermes_rust_core::local_tools::Program>,
    sandbox: Option<PathBuf>,
    runtime_roots: Option<Vec<PathBuf>>,
    skills_root: Option<String>,
    python_program: Option<String>,
    /// Explicit preconfigured executor names available from hermes_tools.
    #[serde(default)]
    python_bridge_tools: Vec<String>,
}
/// Only trusted host configuration can select portable data. The authenticated
/// owner, native database and LocalTools grant are injected, never deserialized.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct PortableProfileConfig {
    profile: PathBuf,
    source_id: String,
    #[serde(default = "profile_interval_seconds")]
    interval_secs: u64,
    #[serde(default)]
    managed_skills: Vec<String>,
}
fn profile_interval_seconds() -> u64 {
    60
}
fn load_trusted_config(raw: &str) -> Result<String> {
    let Some(path) = raw.strip_prefix('@') else {
        return Ok(raw.to_owned());
    };
    ensure!(
        path.len() <= 4096 && std::path::Path::new(path).is_absolute(),
        "trusted config path must be absolute"
    );
    let bytes = std::fs::read(path)
        .with_context(|| format!("could not read trusted config {path}"))?;
    ensure!(bytes.len() <= 64 * 1024, "trusted config exceeds limit");
    String::from_utf8(bytes).context("trusted config is not UTF-8")
}
fn parse_portable_profile(raw: &str) -> Result<PortableProfileConfig> {
    ensure!(
        raw.len() <= 32 * 1024,
        "portable profile configuration exceeds limit"
    );
    let value: PortableProfileConfig =
        serde_json::from_str(raw).context("invalid trusted portable profile configuration")?;
    ensure!(
        (1..=3600).contains(&value.interval_secs),
        "portable profile interval_secs must be 1..3600"
    );
    ensure!(
        value.profile.is_absolute(),
        "portable profile root must be absolute"
    );
    Ok(value)
}
fn report_portable_profile(stage: &str, report: &hermes_rust_core::profile_bridge::BridgeReport) {
    // Report only allowlisted relative paths and counters, never private bodies,
    // host paths, credentials or authenticated account identifiers.
    eprintln!(
        "{}",
        json!({"event":"portable_profile.reconcile", "stage":stage,
        "ready_for_sync":report.ready_for_sync(), "report":report})
    );
}
async fn run_portable_profile(
    core: Core,
    bridge: hermes_rust_core::profile_bridge::ProfileBridge,
    interval: Duration,
) {
    let mut tick = tokio::time::interval(interval);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    tick.tick().await; // Startup already reconciled; no duplicate immediate scan.
    loop {
        tick.tick().await;
        // Exactly one bounded LOCAL reconciliation is in flight. Do not timeout
        // and queue detached blocking work. SSH/hub exchange is a companion.
        match core.reconcile_profile(bridge.clone()).await {
            Ok(report) => report_portable_profile("periodic", &report),
            Err(_) => eprintln!(
                "{}",
                json!({"event":"portable_profile.reconcile",
                "stage":"periodic", "ready_for_sync":false,
                "error":"local reconciliation failed; profile remains unsynchronized"})
            ),
        }
    }
}

async fn run_scheduler(
    scheduler: hermes_rust_core::scheduler::Scheduler,
    outbox: hermes_rust_core::delivery::DeliveryOutbox,
    executor: Arc<dyn hermes_rust_core::scheduler::ScheduledExecutor>,
    verifier: hermes_rust_core::account_scope::OwnerVerifier,
    scope: String,
) {
    let mut cursor = None;
    let mut recovered = false;
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut tasks = tokio::task::JoinSet::<String>::new();
    let mut active = std::collections::HashSet::new();
    let mut recovery_started = Instant::now();
    loop {
        tokio::select! {
            _=tick.tick()=>{
                let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis().min(i64::MAX as u128) as i64;
                let _=scheduler.claim_due(now,64).await;
                let mut candidates=Vec::new();
                if recovered && recovery_started.elapsed()>=Duration::from_secs(60) {recovered=false;cursor=None;recovery_started=Instant::now();}
                if !recovered && active.len()<4 && let Ok(page)=scheduler.recovery_page(cursor.as_deref(),4-active.len()).await {
                        if page.is_empty(){recovered=true;}
                        for occurrence in page {
                            cursor=Some(occurrence.occurrence_id.clone());let _=scheduler.confirm_delivery(&occurrence.occurrence_id,&outbox).await;
                            if matches!(occurrence.state.as_str(),"queued"|"executing"|"unknown"){candidates.push(occurrence);}
                        }
                }
                if let Ok(ready)=scheduler.queued(64).await{candidates.extend(ready);}
                for occurrence in candidates {
                    if active.len()>=4{break;}
                    if !active.contains(&occurrence.occurrence_id) {
                        // Authenticate immediately before sending old scheduled
                        // private context to model/tools; never follow a token remap.
                        if !matches!(verifier.verify().await,Ok(owner) if owner.scope()==scope){continue;}
                        active.insert(occurrence.occurrence_id.clone());let scheduler=scheduler.clone();let executor=executor.clone();
                        tasks.spawn(async move{let id=occurrence.occurrence_id;let _=scheduler.execute_occurrence(&id,executor.as_ref()).await;id});
                    }
                }
                let _=scheduler.flush_deliveries(&outbox,128).await;
            },
            done=tasks.join_next(),if !tasks.is_empty()=>{if let Some(Ok(id))=done{active.remove(&id);}},
        }
    }
}

/// Runs independently of a connection: committed results survive reconnects.
async fn run_inbound(
    inbox: hermes_rust_core::inbound_delivery::InboundDeliveries,
    budget: Duration,
) {
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut tasks = tokio::task::JoinSet::<String>::new();
    let mut active = std::collections::HashMap::<String, String>::new();
    loop {
        tokio::select! {
            _=tick.tick()=>{if let Ok(records)=inbox.ready(64).await {for record in records {
                if active.len()>=4 {break;}
                if !active.values().any(|conversation|conversation==&record.conversation_id) {
                    active.insert(record.delivery_id.clone(),record.conversation_id);
                    let inbox=inbox.clone();tasks.spawn(async move {let id=record.delivery_id;
                        let _=tokio::time::timeout(budget,inbox.execute(&id)).await;id});
                }
            }}},
            done=tasks.join_next(),if !tasks.is_empty()=>{if let Some(Ok(id))=done {active.remove(&id);}},
        }
    }
}

enum DeliveryTransport {
    Admission(hermes_rust_core::inbound_delivery::Admission),
    Rejected(Value),
    Output(String),
    ParentReply(String),
}

fn capabilities(
    attachments: bool,
    events: bool,
    workspace: bool,
    interactions: bool,
    artifacts: bool,
    updates: bool,
) -> Vec<String> {
    let mut caps = [
        "messages",
        "ack",
        "reconnect",
        "device_auth",
        "memory.analyze",
    ]
    .map(str::to_owned)
    .to_vec();
    if attachments {
        caps.push("attachments".into());
    }
    if updates {
        caps.push("reply_followups".into());
    }
    if artifacts && events {
        caps.extend(
            [
                "artifact.started",
                "artifact.progress",
                "artifact.completed",
                "artifact.failed",
            ]
            .map(str::to_owned),
        );
    }
    if workspace {
        caps.push("workspace.request".into());
    }
    if interactions {
        caps.extend(
            [
                "clarify.request",
                "clarify.resolve",
                "clarify.cancel",
                "approval.request",
                "approval.resolve",
            ]
            .map(str::to_owned),
        );
    }
    if events {
        caps.extend(CAPABILITIES.iter().map(|v| (*v).into()));
    }
    caps
}
/// Reuse credentials only for the identical configured endpoint. Selecting a
/// different route never silently transmits the primary model's API key.
fn endpoint_key<'a>(
    primary_endpoint: &str,
    primary_key: Option<&'a str>,
    route_endpoint: &str,
    route_key: Option<&'a str>,
) -> Option<&'a str> {
    route_key.or_else(|| {
        (primary_endpoint == route_endpoint)
            .then_some(primary_key)
            .flatten()
    })
}
fn turn_timeout(args: &Args) -> Result<Duration> {
    let seconds = args
        .turn_timeout_secs
        .unwrap_or(if args.stream_events { 900 } else { 45 });
    ensure!(
        (1..=900).contains(&seconds),
        "turn-timeout-secs must be 1..900"
    );
    Ok(Duration::from_secs(seconds))
}
fn core_limits(args: &Args) -> CoreLimits {
    let mut limits = if args.domain_tools
        || args.stream_events
        || args.attachments
        || args.session_context
        || args.vision_tools
        || args.native_tool_images
        || args.delegation
    {
        CoreLimits::full()
    } else {
        CoreLimits::default()
    };
    if let Some(rounds) = args.max_provider_rounds {
        limits.max_provider_rounds = rounds;
    }
    if let Some(calls) = args.max_tool_calls {
        limits.max_tool_calls_per_round = calls;
    }
    limits
}
#[derive(Clone)]
struct Services {
    core: Core,
    video: hermes_rust_core::memory_video::MemoryVideoClient,
    journal: Journal,
    events: Option<GatewayEvents>,
    turn_timeout: Duration,
    workspace: Option<Arc<hermes_rust_core::workspace::WorkspaceService>>,
    owner_verifier: Option<hermes_rust_core::account_scope::OwnerVerifier>,
    owner_scope: Option<String>,
    interactions: Option<hermes_rust_core::interactions::InteractionHub>,
    outputs: Option<hermes_rust_core::output_files::OutputFiles>,
    auxiliary: Option<AuxiliaryClient>,
    domain: Option<hermes_rust_core::domain_tools::DomainClient>,
    reply_followups: Arc<std::sync::atomic::AtomicBool>,
    #[cfg(unix)]
    local: Option<hermes_rust_core::local_tools::LocalTools>,
    browser: Option<hermes_rust_core::browser_tools::BrowserTools>,
    scheduler: Option<hermes_rust_core::scheduler::Scheduler>,
    deliveries: Option<hermes_rust_core::delivery::DeliveryOutbox>,
    scheduled_executor: Option<Arc<dyn hermes_rust_core::scheduler::ScheduledExecutor>>,
    delegation: Option<hermes_rust_core::delegation::DelegationRuntime>,
    delegation_delivery: Option<hermes_rust_core::delegation_delivery::DelegationDelivery>,
    parent_continuation: Option<hermes_rust_core::parent_continuation_host::ParentContinuationHost>,
    inbound: Option<hermes_rust_core::inbound_delivery::InboundDeliveries>,
}
const PREVIEW_OP_TIMEOUT: Duration = Duration::from_millis(250);

/// A turn-local preview worker. Optional UI never owns provider execution or
/// final persistence. A congested observer disables future provider previews.
struct Preview {
    observer: Option<TurnObserver>,
    terminal: Option<oneshot::Sender<Value>>,
    task: tokio::task::JoinHandle<()>,
}
impl Preview {
    async fn start(
        services: &Services,
        context: TurnContext,
        updates: Option<Arc<TurnUpdates>>,
    ) -> Option<Self> {
        let events = services.events.clone()?;
        let streaming = tokio::time::timeout(PREVIEW_OP_TIMEOUT, events.supports("agent.delta"))
            .await
            .ok()?
            .ok()?;
        let active = streaming
            || tokio::time::timeout(PREVIEW_OP_TIMEOUT, async {
                Ok::<_, anyhow::Error>(
                    events.supports("agent.start").await?
                        || events.supports("agent.typing").await?,
                )
            })
            .await
            .ok()?
            .ok()?;
        if !active {
            return None;
        }
        let (tx, rx) = mpsc::channel(128);
        let (terminal, done) = oneshot::channel();
        let journal = services.journal.clone();
        let task = tokio::spawn(async move {
            preview_worker(events, journal, context, rx, done, updates).await;
        });
        Some(Self {
            observer: streaming.then_some(TurnObserver(tx)),
            terminal: Some(terminal),
            task,
        })
    }
    fn observer(&self) -> Option<TurnObserver> {
        self.observer.clone()
    }
    async fn finish(mut self, frame: &Value) {
        self.observer = None;
        if let Some(terminal) = self.terminal.take() {
            let _ = terminal.send(frame.clone());
        }
        // Normally staging commits before the reply is sent. Never let a slow
        // optional UI store hold the final answer indefinitely. The detached
        // worker reconciles a racing durable Journal receipt after staging.
        let _ = tokio::time::timeout(PREVIEW_OP_TIMEOUT, &mut self.task).await;
    }
}
async fn flush_preview(run: &mut RunEvents, pending: &mut String) -> Result<()> {
    if !pending.is_empty() {
        run.append(pending).await?;
        pending.clear();
    }
    Ok(())
}
async fn apply_preview(run: &mut RunEvents, pending: &mut String, event: TurnEvent) -> Result<()> {
    if let TurnEvent::Delta(delta) = event {
        ensure!(
            pending.len().saturating_add(delta.len()) <= 256 * 1024,
            "preview buffer limit"
        );
        pending.push_str(&delta);
        if pending.len() >= 4096 {
            flush_preview(run, pending).await?;
        }
    } else {
        flush_preview(run, pending).await?;
        run.observe(event).await?;
    }
    Ok(())
}
async fn preview_worker(
    events: GatewayEvents,
    journal: Journal,
    context: TurnContext,
    mut rx: mpsc::Receiver<TurnEvent>,
    mut terminal: oneshot::Receiver<Value>,
    updates: Option<Arc<TurnUpdates>>,
) {
    let Ok(mut run) = events.begin_run(&context).await else {
        return;
    };
    let mut pending = String::new();
    let mut public_note = String::new();
    let mut preview_healthy = true;
    let mut channel_open = true;
    let mut flush = tokio::time::interval(Duration::from_millis(25));
    flush.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut heartbeat = tokio::time::interval(Duration::from_secs(15));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    heartbeat.tick().await;
    let final_frame = loop {
        tokio::select! {
            frame=&mut terminal => break frame.ok(),
            event=rx.recv(), if channel_open && preview_healthy => {
                if let Some(event)=event {
                    if let Some(updates)=&updates {match &event {
                        TurnEvent::Delta(text) if !text.trim().is_empty()=>{
                            let remaining=800usize.saturating_sub(public_note.chars().count());public_note.extend(text.chars().take(remaining));
                            updates.public_output(Some(&public_note));
                        },
                        TurnEvent::ToolStarted{name,..}=>updates.observe(Phase::Tool,Some(name)),
                        TurnEvent::ToolCompleted{..}=>{public_note.clear();updates.observe(Phase::Returned,None);},
                        _=>{},
                    }}
                    preview_healthy=matches!(tokio::time::timeout(PREVIEW_OP_TIMEOUT,apply_preview(&mut run,&mut pending,event)).await,Ok(Ok(())));
                } else {channel_open=false;}
            },
            _=flush.tick(), if preview_healthy && !pending.is_empty() => {
                preview_healthy=matches!(tokio::time::timeout(PREVIEW_OP_TIMEOUT,flush_preview(&mut run,&mut pending)).await,Ok(Ok(())));
            },
            _=heartbeat.tick()=> { let _=tokio::time::timeout(PREVIEW_OP_TIMEOUT,run.heartbeat()).await; },
        }
    };
    if preview_healthy {
        while let Ok(event) = rx.try_recv() {
            if !matches!(
                tokio::time::timeout(
                    PREVIEW_OP_TIMEOUT,
                    apply_preview(&mut run, &mut pending, event)
                )
                .await,
                Ok(Ok(()))
            ) {
                preview_healthy = false;
                break;
            }
        }
        if preview_healthy {
            let _ = tokio::time::timeout(PREVIEW_OP_TIMEOUT, flush_preview(&mut run, &mut pending))
                .await;
        }
    }
    match final_frame {
        Some(frame) if frame["type"] == "message.reply" => {
            let Some(id) = frame["message_id"].as_str() else {
                return;
            };
            let content = frame["content"].as_str().unwrap_or("");
            if run.defer_completion(id, content).await.is_ok() {
                // Both races are safe: ACK after staging calls confirm_message
                // in the reader; ACK before staging is found here.
                if let Ok(Some(saved)) =
                    journal.inspect(&format!("chat:{}", context.input_id)).await
                    && saved.state == "delivered"
                    && saved
                        .frame
                        .as_ref()
                        .is_some_and(|f| f["message_id"].as_str() == Some(id))
                {
                    let _ = events.confirm_message(id).await;
                }
            }
        }
        Some(frame) => {
            let _ = run
                .fail(
                    frame["code"].as_str().unwrap_or("TURN_FAILED"),
                    "This run did not complete successfully",
                )
                .await;
        }
        None => {
            let _=run.fail("TURN_INTERRUPTED","Connection or turn execution ended before completion; tool side effects were not retried").await;
        }
    }
}
async fn reconcile_completions(events: &GatewayEvents, journal: &Journal) -> Result<()> {
    for (input_id, final_id) in events.completion_candidates().await? {
        if let Some(saved) = journal.inspect(&format!("chat:{input_id}")).await?
            && saved.state == "delivered"
            && saved
                .frame
                .as_ref()
                .is_some_and(|f| f["message_id"].as_str() == Some(&final_id))
        {
            events.confirm_message(&final_id).await?;
        }
    }
    Ok(())
}
async fn prepare_final(services: &Services, anchor: &Value, body: &str) -> Result<Value> {
    let Some(outputs) = &services.outputs else {
        return wire::final_reply(anchor, body);
    };
    let scope = hermes_rust_core::output_files::OutputScope {
        conversation_id: wire::text(anchor, "conversation_id")?.into(),
        input_id: wire::text(anchor, "message_id")?.into(),
    };
    match outputs.finalize_media(&scope, body).await {
        Ok(media) => {
            let frame =
                wire::final_reply_with_attachments(anchor, &media.text, &media.attachments)?;
            if !media.artifacts.is_empty() {
                outputs
                    .bind_final(
                        wire::text(&frame, "message_id")?,
                        &scope,
                        &media
                            .artifacts
                            .iter()
                            .map(|a| a.artifact_id.clone())
                            .collect::<Vec<_>>(),
                    )
                    .await?;
            }
            Ok(frame)
        }
        Err(_) => wire::final_reply(
            anchor,
            &format!("{body}\n\n附件尚未完成上传，原始内容已保留；未确认的上传不会自动重复执行。"),
        ),
    }
}
async fn reconcile_artifact_receipts(services: &Services) -> Result<()> {
    if let Some(outputs) = &services.outputs {
        let mut after = None;
        loop {
            let ids = outputs.pending_final_bindings(after.as_deref()).await?;
            if ids.is_empty() {
                break;
            }
            for id in &ids {
                let reply_delivered = if let Some(parent) = &services.parent_continuation {
                    parent.reply_delivered(id).await?
                } else {
                    false
                };
                if services.journal.is_delivered(id).await? || reply_delivered {
                    outputs.ack_final(id).await?;
                }
            }
            after = ids.last().cloned();
        }
    }
    Ok(())
}
async fn pump_artifact_events(
    outputs: hermes_rust_core::output_files::OutputFiles,
    events: GatewayEvents,
) {
    let mut retry = tokio::time::interval(Duration::from_secs(2));
    retry.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {_=outputs.notified()=>{},_=retry.tick()=>{}}
        loop {
            let batch = match outputs.pending_events_all().await {
                Ok(batch) => batch,
                Err(_) => break,
            };
            if batch.is_empty() {
                break;
            }
            let mut accepted = true;
            for event in batch {
                let key = format!("artifact:{}:{}", event.artifact_id, event.id);
                if events
                    .enqueue_feature_once(&key, event.payload)
                    .await
                    .is_err()
                    || outputs
                        .acknowledge_event(&event.scope, event.id)
                        .await
                        .is_err()
                {
                    accepted = false;
                    break;
                }
            }
            if !accepted {
                break;
            }
        }
    }
}

struct UpdateLease {
    updates: Arc<TurnUpdates>,
    forward: tokio::task::JoinHandle<()>,
}
impl Drop for UpdateLease {
    fn drop(&mut self) {
        self.updates.close();
        self.forward.abort();
    }
}
fn start_turn_updates(
    services: &Services,
    frame: &Value,
    tx: mpsc::Sender<PendingUpdate>,
) -> Option<UpdateLease> {
    let auxiliary = services.auxiliary.clone()?;
    let mut input = TurnInput::new(
        frame["conversation_id"].as_str()?,
        frame["message_id"].as_str()?,
        frame["content"].as_str().unwrap_or(""),
    );
    input.attachment_names = frame["attachments"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v["name"].as_str().map(str::to_owned))
        .collect();
    if !input.is_command
        && let Some(domain) = services.domain.clone()
    {
        let helper = auxiliary.clone();
        let title_input = input.clone();
        tokio::spawn(async move {
            let _ = helper.name_conversation(&domain, &title_input).await;
        });
    }
    let (updates, mut rx) = TurnUpdates::start(
        auxiliary,
        input,
        services
            .reply_followups
            .load(std::sync::atomic::Ordering::Acquire),
    );
    let updates = Arc::new(updates);
    let forward = tokio::spawn(async move {
        while let Some(update) = rx.recv().await {
            if update.is_current() && tx.send(update).await.is_err() {
                break;
            }
        }
    });
    Some(UpdateLease { updates, forward })
}

async fn work_chat(
    services: &Services,
    frame: Value,
    budget: Duration,
    update_tx: mpsc::Sender<PendingUpdate>,
) -> Result<Value> {
    let updates = start_turn_updates(services, &frame, update_tx);
    let c = &services.core;
    let j = &services.journal;
    let id = wire::text(&frame, "message_id")?;
    let conv = wire::text(&frame, "conversation_id")?;
    let mut preview = None;
    let mut retryable = false;
    let mut result = if frame["attachments"]
        .as_array()
        .is_some_and(|a| !a.is_empty())
        && !c.supports_media()
    {
        wire::error("UNSUPPORTED_ATTACHMENTS", Some(id))
    } else if frame["content"]
        .as_str()
        .is_some_and(|s| matches!(s.trim(), "/new" | "/reset"))
    {
        if let Some(inbox) = &services.inbound {
            inbox.cancel_conversation(conv).await?;
        }
        if let Some(parent) = &services.parent_continuation {
            parent.suppress_conversation(conv).await?;
        }
        if c.supports_session_context() {
            c.reset_for_input(wire::digest(conv), id.into()).await?;
        } else {
            c.reset(wire::digest(conv)).await?;
        }
        wire::final_reply(
            &frame,
            "已开始新会话。旧聊天历史已保留，新问题会加载当前记忆。",
        )?
    } else if frame["content"]
        .as_str()
        .is_some_and(|s| s.trim_start().starts_with('/'))
    {
        if c.supports_session_context() {
            let trusted = TurnContext {
                conversation_id: conv.into(),
                input_id: id.into(),
                session_id: wire::digest(conv),
            };
            match hermes_rust_core::session_commands::normalize(&frame, &trusted) {
                Ok(Some(request)) => match c.execute_session_command(request).await {
                    Ok(response) => response.frame,
                    Err(_) => wire::final_reply(
                        &frame,
                        "无法执行此会话命令：参数、会话范围或请求标识不正确。",
                    )?,
                },
                _ => wire::final_reply(&frame, "无法解析此会话命令。")?,
            }
        } else {
            wire::error("UNSUPPORTED_COMMAND", Some(id))
        }
    } else {
        match tokio::time::timeout(budget, async {
            let mut attempts = 0;
            loop {
                let context = TurnContext {
                    conversation_id: conv.into(),
                    input_id: id.into(),
                    session_id: wire::digest(conv),
                };
                preview = Preview::start(
                    services,
                    context.clone(),
                    updates.as_ref().map(|u| u.updates.clone()),
                )
                .await;
                let text = frame["content"].as_str().unwrap_or("");
                let media: Vec<hermes_rust_core::attachments::AttachmentMetadata> =
                    serde_json::from_value(
                        frame
                            .get("attachments")
                            .filter(|v| !v.is_null())
                            .cloned()
                            .unwrap_or_else(|| json!([])),
                    )?;
                let user = hermes_rust_core::media_runtime::user_reference(text, &media, &context)?;
                let outcome = c
                    .chat_with_user_message(
                        ChatRequest {
                            session_id: wire::digest(conv),
                            message: text.into(),
                        },
                        context,
                        user,
                        preview.as_ref().and_then(Preview::observer),
                    )
                    .await;
                // Core certifies these failures occurred before any tool effect.
                // A new run isolates every retry's partial preview tokens.
                if outcome.as_ref().err().is_some_and(|e| {
                    e.downcast_ref::<hermes_rust_core::RetryableProviderError>()
                        .is_some()
                }) && attempts < 2
                {
                    if let Some(prior) = preview.take() {
                        prior.finish(&wire::error("PROVIDER_RETRY", Some(id))).await;
                    }
                    attempts += 1;
                    tokio::time::sleep(Duration::from_millis(100 * attempts)).await;
                    continue;
                }
                break outcome;
            }
        })
        .await
        {
            Ok(Ok(answer)) => prepare_final(services, &frame, &answer.answer).await?,
            Ok(Err(e))
                if e.downcast_ref::<hermes_rust_core::RetryableProviderError>()
                    .is_some() =>
            {
                retryable = true;
                wire::error("RETRYABLE_TURN_FAILED", Some(id))
            }
            Ok(Err(e)) if e.to_string().contains("context limit") => wire::final_reply(
                &frame,
                "当前会话已达上下文限制。请发送 /new 开始新会话；旧历史会保留。",
            )?,
            _ => wire::error("TURN_FAILED", Some(id)),
        }
    };
    if let Some(updates) = &updates {
        updates.updates.close();
    }
    let committed = if retryable {
        j.retryable_if_pending(&format!("chat:{id}"), &result)
            .await?
    } else {
        j.finish_if_pending(&format!("chat:{id}"), &result).await?
    };
    if !committed {
        let prior = j
            .inspect(&format!("chat:{id}"))
            .await?
            .context("turn journal disappeared")?;
        ensure!(
            prior.state == "ready",
            "turn already completed or cancelled"
        );
        result = prior.frame.context("terminal receipt missing")?;
    }
    if let Some(preview) = preview {
        preview.finish(&result).await;
    }
    Ok(result)
}
fn spawn_chat(
    jobs: &mut tokio::task::JoinSet<Option<String>>,
    services: Services,
    tx: mpsc::Sender<Value>,
    update_tx: mpsc::Sender<PendingUpdate>,
    frame: Value,
    received: Instant,
) -> tokio::sync::watch::Sender<bool> {
    let (cancel, mut cancelled) = tokio::sync::watch::channel(false);
    jobs.spawn(async move {
        let conv = frame["conversation_id"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let id = frame["message_id"].as_str().unwrap_or_default().to_owned();
        let budget = services.turn_timeout.saturating_sub(received.elapsed());
        let result = if budget.is_zero() {
            let result = wire::final_reply(
                &frame,
                &format!(
                    "请求排队超过{}秒，请重新发送。此请求未调用模型。",
                    services.turn_timeout.as_secs()
                ),
            );
            if let Ok(ref reply) = result {
                let _ = services.journal.finish(&format!("chat:{id}"), reply).await;
            }
            result
        } else {
            tokio::select! { biased;
                _=cancelled.changed()=>Err(anyhow::anyhow!("turn cancelled by trusted control")),
                result=work_chat(&services, frame, budget, update_tx)=>result,
            }
        };
        if let Ok(reply) = result {
            let _ = tx.send(reply).await;
        }
        Some(conv)
    });
    cancel
}
#[derive(Clone)]
struct ActiveChat {
    frame: Value,
    cancel: tokio::sync::watch::Sender<bool>,
}

async fn cancel_chat(
    services: &Services,
    frame: &Value,
    active: Option<&ActiveChat>,
    queued: Vec<Value>,
    tx: &mpsc::Sender<Value>,
) -> Result<()> {
    let conv = wire::text(frame, "conversation_id")?;
    let mut count = if let Some(inbox) = &services.inbound {
        inbox.cancel_conversation(conv).await?
    } else {
        0
    };
    for original in queued.iter().chain(active.map(|a| &a.frame)) {
        let id = wire::text(original, "message_id")?;
        let result = services
            .core
            .cancel_input(wire::digest(conv), id.to_owned())
            .await?;
        if matches!(
            result,
            hermes_rust_core::session_context::TurnLookup::Completed { .. }
                | hermes_rust_core::session_context::TurnLookup::CommandCompleted { .. }
        ) {
            continue;
        }
        let cancelled = wire::final_reply(
            original,
            "已取消此请求。已经完成的工具操作不会被撤销，执行记录已保留。",
        )?;
        if services
            .journal
            .finish_if_pending(&format!("chat:{id}"), &cancelled)
            .await?
        {
            tx.send(cancelled)
                .await
                .context("outbound channel closed")?;
            count += 1;
        }
        if let Some(active) = active
            && active.frame["message_id"] == id
        {
            let _ = active.cancel.send(true);
        }
    }
    if let Some(parent) = &services.parent_continuation {
        count += parent.suppress_conversation(conv).await?;
    } else if let Some(runtime) = &services.delegation {
        count += runtime.cancel_conversation(conv).await?;
    }
    if let Some(hub) = &services.interactions {
        hub.cancel_conversation(conv);
    }
    if let Some(browser) = &services.browser {
        browser.cancel_conversation(conv);
    }
    #[cfg(unix)]
    if let Some(local) = &services.local {
        local.cancel_conversation(conv).await;
    }
    let response = wire::final_reply(
        frame,
        if count > 0 {
            "已停止当前会话的未完成请求。已执行的操作不会自动撤销。"
        } else {
            "当前没有可取消的请求。已完成的回答和操作保持不变。"
        },
    )?;
    services
        .journal
        .finish_if_pending(
            &format!("chat:{}", wire::text(frame, "message_id")?),
            &response,
        )
        .await?;
    tx.send(response).await.context("outbound channel closed")?;
    Ok(())
}

async fn connection(a: &Args, services: &Services) -> Result<()> {
    if let Some(verifier) = &services.owner_verifier {
        let owner = verifier.verify().await?;
        ensure!(
            services.owner_scope.as_deref() == Some(owner.scope().as_str()),
            "server account changed; connection refused"
        );
    }
    let j = &services.journal;
    reconcile_artifact_receipts(services).await?;
    let p = &services.video;
    let mut req = a.server.clone().into_client_request()?;
    if let Some(token) = &a.token {
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))?,
        );
    }
    let mut limits = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
    limits.max_message_size = Some(1_500_000);
    limits.max_frame_size = Some(1_500_000);
    let (mut ws, _) = tokio::time::timeout(
        Duration::from_secs(15),
        connect_async_with_config(req, Some(limits), true),
    )
    .await??;
    let platform = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    };
    let mut initial_caps = capabilities(
        a.attachments,
        a.stream_events,
        a.workspaces_json.is_some(),
        a.interactions,
        a.output_files,
        a.turn_updates || a.delegation_parent_resume,
    );
    if a.session_context {
        initial_caps.push("session.status".into());
    }
    if services.inbound.is_some() || a.scheduler || a.delegation_background {
        initial_caps.extend(["delivery", "cron_delivery", "proactive_delivery"].map(str::to_owned));
    }
    ws.send(Message::Text(serde_json::to_string(&json!({"version":1,"type":"hello","device_id":a.device,"client":"orialis-rust-core","plugin_version":"0.1.0","platform":platform,"capabilities":initial_caps}))?.into())).await?;
    let raw = tokio::time::timeout(Duration::from_secs(15), ws.next())
        .await?
        .context("closed before hello_ack")??;
    let ack = wire::parse(raw.to_text()?)?;
    ensure!(ack["type"] == "hello_ack", "expected hello_ack");
    services.reply_followups.store(
        ack["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|v| v == "reply_followups")),
        std::sync::atomic::Ordering::Release,
    );
    if let Some(parent) = &services.parent_continuation {
        parent.set_reply_followups(
            services
                .reply_followups
                .load(std::sync::atomic::Ordering::Acquire),
        );
    }
    // Orialis records peer capabilities in this second handshake. Resume is
    // server -> client; our persistent outgoing seq is never reset from its ACK.
    let mut caps = capabilities(
        a.attachments,
        a.stream_events,
        a.workspaces_json.is_some(),
        a.interactions,
        a.output_files,
        a.turn_updates || a.delegation_parent_resume,
    );
    if a.session_context {
        caps.push("session.status".into());
    }
    if services.inbound.is_some() || a.scheduler || a.delegation_background {
        caps.extend(["delivery", "cron_delivery", "proactive_delivery"].map(str::to_owned));
    }
    let handshake = if let Some(events) = &services.events {
        events.negotiate(&ack).await?;
        reconcile_completions(events, j).await?;
        if let Some(hub) = &services.interactions {
            let _ = tokio::time::timeout(Duration::from_secs(1), hub.flush()).await;
        }
        events.capabilities_hello(&caps).await?
    } else {
        json!({"version":1,"type":"capabilities.hello","capabilities":caps})
    };
    ws.send(Message::Text(serde_json::to_string(&handshake)?.into()))
        .await?;
    let (tx, mut rx) = mpsc::channel::<Value>(128);
    let (delivery_tx, mut delivery_rx) = mpsc::channel::<DeliveryTransport>(32);
    let delivery_admission_limit = Arc::new(Semaphore::new(4));
    let delivery_output_limit = Arc::new(Semaphore::new(4));
    let parent_reply_output_limit = Arc::new(Semaphore::new(2));
    let (update_tx, mut update_rx) = mpsc::channel::<PendingUpdate>(32);
    let mut sent_updates = std::collections::HashMap::<String, PendingUpdate>::new();
    let memory_limit = Arc::new(Semaphore::new(usize::from(a.memory_concurrency)));
    let workspace_limit = Arc::new(Semaphore::new(8));
    let control_limit = Arc::new(Semaphore::new(8));
    let mut jobs = tokio::task::JoinSet::<Option<String>>::new();
    let mut active_chats = std::collections::HashMap::<String, ActiveChat>::new();
    let mut pending =
        std::collections::HashMap::<String, std::collections::VecDeque<(Value, Instant)>>::new();
    let mut waiting_conversations = std::collections::VecDeque::<String>::new();
    let mut pending_count = 0usize;
    let mut tick = tokio::time::interval(Duration::from_secs(20));
    let mut last_rx = Instant::now();
    let mut event_cursor = 0u64;
    let mut pump_events = true;
    let mut reply_cursor = 0i64;
    let mut replay_pending = true;
    let mut events_enabled = services.events.is_some();
    let mut delivery_tick = tokio::time::interval(Duration::from_secs(1));
    delivery_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut delivery_attempts = std::collections::HashMap::<String, Instant>::new();
    let mut delivery_cursor: Option<String> = None;
    let mut parent_reply_cursor: Option<String> = None;
    let mut parent_reply_verifications = std::collections::HashMap::<String, Instant>::new();
    let mut delivery_capabilities = ack["capabilities"].as_array().cloned().unwrap_or_default();
    let mut event_retry = tokio::time::interval(Duration::from_secs(15));
    event_retry.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut receipt_replay = services.inbound.is_some();
    let outcome:Result<()>=async {loop {tokio::select! {
   _=std::future::ready(()),if receipt_replay=>{
       if let Some(inbox)=&services.inbound {
           let receipts=inbox.pending_receipts(32).await?;receipt_replay=receipts.len()==32;
           for admission in receipts {
               ws.send(Message::Text(serde_json::to_string(&admission.ack)?.into())).await?;
               inbox.received(&admission.record.delivery_id).await?;
           }
       }else{receipt_replay=false;}
   },
   _=std::future::ready(()),if replay_pending=>{
      let frames=j.replay_page(reply_cursor,32).await?;replay_pending=frames.len()==32;
      for (cursor,frame) in frames {
        reply_cursor=cursor;
        if frame["type"]=="message.reply" && !j.prepare_reply_send(wire::text(&frame,"message_id")?).await?{continue;}
        ws.send(Message::Text(serde_json::to_string(&frame)?.into())).await?;
        if frame["type"]=="memory.result" {j.memory_sent(wire::text(&frame,"request_id")?).await?;}
        else if frame["type"]=="error" && let Some(id)=frame["reply_to"].as_str(){j.error_sent(id).await?;}
      }
   },
   _=async {if !pump_events {if let Some(events)=&services.events {events.notified().await;} else {std::future::pending::<()>().await;}}}, if events_enabled=>{
      pump_events=false;
      if let Some(events)=&services.events {
        match tokio::time::timeout(PREVIEW_OP_TIMEOUT,events.pending_after(event_cursor,32)).await {
          Ok(Ok(frames))=>{pump_events=frames.len()==32;for frame in frames {ws.send(Message::Text(serde_json::to_string(&frame)?.into())).await?;event_cursor=frame["seq"].as_u64().context("stored event sequence missing")?;}},
          _=>{events_enabled=false;eprintln!("Optional event transport paused; durable final replies remain enabled.");}
        }
      }
   },
   _=event_retry.tick(), if events_enabled=>{event_cursor=0;pump_events=true;},
   _=async {
       if let Some(parent)=&services.parent_continuation {
           tokio::select! {_=delivery_tick.tick()=>{},_=parent.output_notified()=>{}}
       }else if let Some(delegated)=&services.delegation_delivery {
           tokio::select! {_=delivery_tick.tick()=>{},_=delegated.output_notified()=>{}}
       }else{delivery_tick.tick().await;}
   },if services.deliveries.is_some()=>{
     if let Some(outbox)=&services.deliveries {
       let page=outbox.pending_after(delivery_cursor.as_deref(),32).await?;
       let full_page=page.len()==32; let mut exhausted=true;
       for delivery in page {
         let id=&delivery.request.delivery_id;
         let previous_cursor=delivery_cursor.replace(id.clone());
         if services.parent_continuation.is_none() && hermes_rust_core::parent_continuation_host::ParentContinuationHost::is_output_id(id) {continue;}
         if let Some(parent)=&services.parent_continuation && parent.suppress_legacy_output(id).await? {continue;}
         if !delivery_capabilities.iter().any(|c|c==delivery.request.kind.capability()) {continue;}
         if delivery_attempts.get(id).is_some_and(|time|time.elapsed()<Duration::from_secs(15)){continue;}
         if let Ok(permit)=delivery_output_limit.clone().try_acquire_owned() {
             let id=id.clone();let inbox=services.inbound.clone();let delegated=services.delegation_delivery.clone();let parent=services.parent_continuation.clone();let tx=delivery_tx.clone();
             delivery_attempts.insert(id.clone(),Instant::now());
             jobs.spawn(async move {let _permit=permit;
                 if let Some(inbox)=inbox && inbox.verify_output(&id).await.is_err(){return None;}
                 if let Some(delegated)=delegated && delegated.verify_output(&id).await.is_err(){return None;}
                 if let Some(parent)=parent && parent.verify_output(&id).await.is_err(){return None;}
                 let _=tx.send(DeliveryTransport::Output(id)).await;None
             });
         }else{
             // Do not skip the rest of this page when the bounded verifier is full.
             delivery_cursor=previous_cursor;exhausted=false;break;
         }
       }
       if exhausted && !full_page {delivery_cursor=None;}
       delivery_attempts.retain(|_,time|time.elapsed()<Duration::from_secs(60));
     }
     if let Some(parent)=&services.parent_continuation {
       let page=parent.pending_replies_after(parent_reply_cursor.as_deref(),32).await?;
       let full_page=page.len()==32;let mut exhausted=true;
       for row in page {
         let id=row.request.message_id();let previous=parent_reply_cursor.replace(id.clone());
         if parent_reply_verifications.get(&id).is_some_and(|time|time.elapsed()<Duration::from_secs(1)){continue;}
         let Ok(permit)=parent_reply_output_limit.clone().try_acquire_owned() else {parent_reply_cursor=previous;exhausted=false;break;};
         parent_reply_verifications.insert(id.clone(),Instant::now());
         let parent=parent.clone();let tx=delivery_tx.clone();
         jobs.spawn(async move {let _permit=permit;
           if parent.verify_reply(&id).await.is_ok(){let _=tx.send(DeliveryTransport::ParentReply(id)).await;}
           None
         });
       }
       if exhausted && !full_page{parent_reply_cursor=None;}
       parent_reply_verifications.retain(|_,time|time.elapsed()<Duration::from_secs(60));
     }
   },
   delivery=delivery_rx.recv()=>{if let Some(delivery)=delivery {match delivery {
       DeliveryTransport::Admission(admission)=>{
           ws.send(Message::Text(serde_json::to_string(&admission.ack)?.into())).await?;
           if let Some(inbox)=&services.inbound {inbox.received(&admission.record.delivery_id).await?;}
       },
       DeliveryTransport::Rejected(frame)=>{ws.send(Message::Text(serde_json::to_string(&frame)?.into())).await?;},
       DeliveryTransport::ParentReply(id)=>{
           if let Some(parent)=&services.parent_continuation && let Some(permit)=parent.prepare_reply_send(&id).await? {
               tokio::time::timeout(Duration::from_secs(2),ws.send(Message::Text(serde_json::to_string(permit.frame())?.into()))).await??;
               drop(permit);
           }
       },
       DeliveryTransport::Output(id)=>{
           if hermes_rust_core::parent_continuation_host::ParentContinuationHost::is_output_id(&id) {
               if let Some(parent)=&services.parent_continuation && let Some(permit)=parent.prepare_send(&id).await? {
                   tokio::time::timeout(Duration::from_secs(2),ws.send(Message::Text(serde_json::to_string(permit.frame())?.into()))).await??;
                   drop(permit);
               }
           }else if let Some(parent)=&services.parent_continuation && parent.suppress_legacy_output(&id).await? {
               // Durable continuation queue, never competing raw summary delivery.
           }else if let Some(delegated)=&services.delegation_delivery && delegated.owns(&id).await? {
               if let Some(permit)=delegated.prepare_send(&id).await? {
                   tokio::time::timeout(Duration::from_secs(2),ws.send(Message::Text(serde_json::to_string(permit.frame())?.into()))).await??;
                   drop(permit);
               }
           }else if let Some(inbox)=&services.inbound {
               if let Some(permit)=inbox.prepare_send(&id).await? {
                   tokio::time::timeout(Duration::from_secs(2),ws.send(Message::Text(serde_json::to_string(permit.frame())?.into()))).await??;
                   drop(permit);
               }
           }else if let Some(outbox)=&services.deliveries && let Some(row)=outbox.inspect(&id).await?
               && row.status==hermes_rust_core::delivery::DeliveryStatus::Pending {
               tokio::time::timeout(Duration::from_secs(2),ws.send(Message::Text(serde_json::to_string(&row.request.frame()?)?.into()))).await??;
           }
       },
   }}},
   update=update_rx.recv()=>{if let Some(update)=update {
      sent_updates.retain(|_,pending|pending.is_current());
      if sent_updates.len()<32 && let Some(frame)=update.frame_if_current(){
        let id=wire::text(frame,"message_id")?.to_owned();ws.send(Message::Text(serde_json::to_string(frame)?.into())).await?;sent_updates.insert(id,update);
      }
   }},
   outgoing=rx.recv()=>{if let Some(frame)=outgoing{if frame["type"]=="message.reply" && !j.prepare_reply_send(wire::text(&frame,"message_id")?).await? {continue;} ws.send(Message::Text(serde_json::to_string(&frame)?.into())).await?;if frame["type"]=="memory.result"{j.memory_sent(wire::text(&frame,"request_id")?).await?;}else if frame["type"]=="error"&& let Some(id)=frame["reply_to"].as_str(){j.error_sent(id).await?;}}},
   _=tick.tick()=>{ensure!(last_rx.elapsed()<Duration::from_secs(60),"peer timeout");ws.send(Message::Text("{\"version\":1,\"type\":\"ping\"}".into())).await?;},
   finished=jobs.join_next(),if !jobs.is_empty()=>{if let Some(Ok(Some(conv)))=finished{
      active_chats.remove(&conv);
      if pending.get(&conv).is_some_and(|q| !q.is_empty()) { waiting_conversations.push_back(conv); }
      while active_chats.len()<8 {
        let Some(next)=waiting_conversations.pop_front() else {break};
        if active_chats.contains_key(&next) {continue;}
        if let Some((frame,received))=pending.get_mut(&next).and_then(|q|q.pop_front()) {
          pending_count-=1; j.queued(wire::text(&frame,"message_id")?,"running").await?;
          let anchor=frame.clone();let cancel=spawn_chat(&mut jobs,services.clone(),tx.clone(),update_tx.clone(),frame,received);active_chats.insert(next.clone(),ActiveChat{frame:anchor,cancel});
        }
        if pending.get(&next).is_some_and(|q|q.is_empty()){pending.remove(&next);}
      }
   }},
   incoming=ws.next()=>{let raw=incoming.context("websocket closed")??;last_rx=Instant::now();match raw {Message::Ping(data)=>{ws.send(Message::Pong(data)).await?;continue;},Message::Pong(_)=>continue,Message::Close(_)=>break,Message::Text(_)=>{},_=>continue};
    ensure!(raw.len()<=1_500_000,"frame too large");let frame=match wire::parse(raw.to_text()?){Ok(v)=>v,Err(_)=>{let rejected:Value=serde_json::from_str(raw.to_text()?).unwrap_or(Value::Null);let response=if rejected["type"]=="memory.analyze" && rejected["request_id"].as_str().is_some_and(|s|!s.trim().is_empty() && s.len()<=160){json!({"version":1,"type":"memory.result","request_id":rejected["request_id"],"error":"Unsupported or invalid screen-memory request"})}else{wire::error("INVALID_MESSAGE",rejected["message_id"].as_str())};ws.send(Message::Text(serde_json::to_string(&response)?.into())).await?;continue;}};
    match frame["type"].as_str().unwrap(){
     "ping"=>ws.send(Message::Text("{\"version\":1,\"type\":\"pong\"}".into())).await?,
     "pong"=>{},
     "hello_ack"|"capabilities.ack"=>{
       delivery_capabilities=frame["capabilities"].as_array().cloned().unwrap_or_default();
       services.reply_followups.store(frame["capabilities"].as_array().is_some_and(|caps|caps.iter().any(|v|v=="reply_followups")),std::sync::atomic::Ordering::Release);
       if let Some(parent)=&services.parent_continuation {parent.set_reply_followups(services.reply_followups.load(std::sync::atomic::Ordering::Acquire));}
       if let Some(events)=&services.events {
        if matches!(tokio::time::timeout(PREVIEW_OP_TIMEOUT,events.negotiate(&frame)).await,Ok(Ok(()))) {events_enabled=true;event_cursor=0;pump_events=true;
          if let Some(hub)=services.interactions.clone(){jobs.spawn(async move{let _=hub.flush().await;None});}
        }
        else {events_enabled=false;eprintln!("Optional event negotiation failed; final-only delivery continues.");}
     }},
     "agent.ack"=>{if let Some(events)=&services.events {
        match tokio::time::timeout(PREVIEW_OP_TIMEOUT,events.acknowledge(&frame)).await {
          Ok(Ok(AckOutcome::ReplayFrom(expected)))=>{event_cursor=expected-1;pump_events=true;},
          Ok(Ok(AckOutcome::Accepted|AckOutcome::Ignored))=>{},
          _=>{events_enabled=false;eprintln!("Optional event acknowledgement rejected; outbox preserved, final replies continue.");}
        }
     }},
     "error"=>{if let Some(reply_id)=frame["reply_to"].as_str(){
        if hermes_rust_core::continuation_reply::ContinuationReplyOutbox::is_reply_id(reply_id) {
            if frame["code"]=="REPLY_REJECTED" && let Some(parent)=&services.parent_continuation {parent.reject_reply(frame.clone()).await?;}
            continue;
        }
        let retry=j.reject(reply_id).await?;eprintln!("Server rejected a correlated reply; rejection recorded. Original final retries are bounded to two, with no repeated inference.");if let Some(reply)=retry{let tx=tx.clone();jobs.spawn(async move{tokio::time::sleep(Duration::from_millis(200)).await;let _=tx.send(reply).await;None});}}},
     "message.ack"=>{if frame["status"]=="received" {
        let id=wire::text(&frame,"message_id")?;
        if hermes_rust_core::continuation_reply::ContinuationReplyOutbox::is_reply_id(id) {
            if let Some(parent)=&services.parent_continuation {parent.acknowledge_reply(frame.clone()).await?;}
            continue;
        }
        if let Some(update)=sent_updates.remove(id){update.confirmed();}
        j.ack(id).await?;
        if let Some(delegated)=&services.delegation_delivery {delegated.parent_terminal();}
        if let Some(parent)=&services.parent_continuation {parent.parent_terminal();}
        if let Some(outputs)=&services.outputs {let _=tokio::time::timeout(PREVIEW_OP_TIMEOUT,outputs.ack_final(id)).await;}
        if let Some(events)=&services.events {
            let _=tokio::time::timeout(PREVIEW_OP_TIMEOUT,events.confirm_message(id)).await;
            pump_events=true;
        }
     }},
     "delivery.ack"=>{if let Some(outbox)=&services.deliveries && outbox.acknowledge(frame.clone()).await? {let id=wire::text(&frame,"delivery_id")?;if let Some(scheduler)=&services.scheduler {scheduler.confirm_delivery(id,outbox).await?;}delivery_attempts.remove(id);}},
     "cron.delivery"|"proactive.delivery"|"delivery.send"=>{
         let id=wire::text(&frame,"delivery_id")?.to_owned();let conv=wire::text(&frame,"conversation_id")?.to_owned();
         let rejected=json!({"version":1,"type":"delivery.ack","delivery_id":id,"conversation_id":conv,"status":"rejected"});
         if let Some(inbox)=services.inbound.clone() && let Ok(permit)=delivery_admission_limit.clone().try_acquire_owned() {
             let tx=delivery_tx.clone();jobs.spawn(async move {let _permit=permit;
                 let result=match inbox.admit(frame).await {Ok(admission)=>DeliveryTransport::Admission(admission),Err(_)=>DeliveryTransport::Rejected(rejected)};
                 let _=tx.send(result).await;None
             });
         }else{ws.send(Message::Text(serde_json::to_string(&rejected)?.into())).await?;}
     },
     "session.info"=>{
        let id=wire::text(&frame,"request_id")?.to_owned();let conv=wire::text(&frame,"conversation_id")?.to_owned();
        if services.core.supports_session_context() && let Ok(permit)=control_limit.clone().try_acquire_owned(){
            let core=services.core.clone();let tx=tx.clone();
            jobs.spawn(async move{let _permit=permit;let trusted=TurnContext{session_id:wire::digest(&conv),conversation_id:conv.clone(),input_id:id.clone()};
                let response=async {let request=hermes_rust_core::session_commands::normalize(&frame,&trusted)?.context("not a session command")?;core.execute_session_command(request).await}.await;
                let reply=response.map(|r|r.frame).unwrap_or_else(|_|json!({"version":1,"type":"session.reply","request_id":id,"conversation_id":conv,"status":"error","message":"Invalid, conflicting or unavailable session request"}));
                let _=tx.send(reply).await;None
            });
        }else{ws.send(Message::Text(serde_json::to_string(&json!({"version":1,"type":"session.reply","request_id":id,"conversation_id":conv,"status":"unknown","message":"Session context disabled or control queue busy"}))?.into())).await?;}
     },
     "message.send"=>{let id=wire::text(&frame,"message_id")?.to_owned();let mut claim=j.claim(&format!("chat:{id}"),&frame).await;
      if services.core.supports_session_context() && matches!(&claim,Ok((state,None)) if state=="uncertain") {
        let conv=wire::text(&frame,"conversation_id")?;
        match services.core.lookup_turn(wire::digest(conv),id.clone()).await {
            Ok(hermes_rust_core::session_context::TurnLookup::Missing|hermes_rust_core::session_context::TurnLookup::Completed{..}|hermes_rust_core::session_context::TurnLookup::CommandCompleted{..}) |
            Ok(hermes_rust_core::session_context::TurnLookup::Pending{uncertain_effects:false,..}) if j.resume_uncertain(&format!("chat:{id}")).await? => {claim=Ok(("new".into(),None));},
            _=>{},
        }
      }
      match claim {Err(_)=>{ws.send(Message::Text(serde_json::to_string(&wire::error("ID_CONFLICT",Some(&id)))?.into())).await?;},Ok((state,saved))=>{
       ws.send(Message::Text(serde_json::to_string(&json!({"version":1,"type":"message.ack","message_id":id,"status":"received"}))?.into())).await?;
       if state=="retry_wait" { /* scheduled original-final resend; do not bypass backoff */ }
       else if state=="rejected" {ws.send(Message::Text(serde_json::to_string(&wire::error("FINAL_REJECTED",Some(&id)))?.into())).await?;}
       else if let Some(saved)=saved{ws.send(Message::Text(serde_json::to_string(&saved)?.into())).await?;}
       else if state=="new"{let conv=wire::text(&frame,"conversation_id")?.to_owned();let received=Instant::now();
        if services.core.supports_session_context() && frame["content"].as_str().is_some_and(|s|s.trim()=="/stop") {
            let queued=pending.remove(&conv).unwrap_or_default();pending_count-=queued.len();waiting_conversations.retain(|c|c!=&conv);
            let active=active_chats.get(&conv).cloned();let services=services.clone();let tx=tx.clone();
            jobs.spawn(async move {if let Err(error)=cancel_chat(&services,&frame,active.as_ref(),queued.into_iter().map(|(f,_)|f).collect(),&tx).await {eprintln!("Cancellation failed: {error}");}None});
            continue;
        }
        if active_chats.len()>=8 || active_chats.contains_key(&conv){
          if pending_count>=64 || pending.get(&conv).map_or(0,|q|q.len())>=8 {
            let e=wire::final_reply(&frame,"请求队列已满，请稍后重新发送。此请求未调用模型。")?;
            j.finish(&format!("chat:{id}"),&e).await?;ws.send(Message::Text(serde_json::to_string(&e)?.into())).await?;
          }else{
            j.queued(&id,"queued").await?;
            if !active_chats.contains_key(&conv) && !pending.contains_key(&conv){waiting_conversations.push_back(conv.clone());}
            pending.entry(conv).or_default().push_back((frame,received));pending_count+=1;
          }
        }else{let anchor=frame.clone();let cancel=spawn_chat(&mut jobs,services.clone(),tx.clone(),update_tx.clone(),frame,received);active_chats.insert(conv,ActiveChat{frame:anchor,cancel});}
       }else if state=="uncertain"{ws.send(Message::Text(serde_json::to_string(&wire::error("INTERRUPTED_UNCERTAIN",Some(&id)))?.into())).await?;}
      }}},
     "clarify.response"|"clarify.resolve"|"clarify.cancel"|"approval.response"|"approval.resolve"=>{
        if let Some(hub)=services.interactions.clone(){let tx=tx.clone();jobs.spawn(async move{
          let response=match hub.resolve(&frame).await{Ok(response)=>response,Err(_)=>wire::error("INTERACTION_NOT_RESOLVED",frame["request_id"].as_str())};let _=tx.send(response).await;None
        });}else{ws.send(Message::Text(serde_json::to_string(&wire::error("INTERACTIONS_DISABLED",frame["request_id"].as_str()))?.into())).await?;}
     },
     "workspace.request"=>{
        let request_id=wire::text(&frame,"request_id")?.to_owned();
        let conv=wire::text(&frame,"conversation_id")?.to_owned();
        if let Some(workspace)=&services.workspace {
            // The authenticated Orialis mobile bridge overwrites _clientId and
            // rejects close_client/all from mobile payloads. Treat this identity
            // as trusted only at this server transport boundary, never in tools.
            let client=frame["payload"]["_clientId"].as_str().filter(|id|!id.is_empty()&&id.len()<=160);
            if let Some(client)=client {
                if frame["payload"]["op"]=="terminal.close_client" { workspace.close_client(client).await; }
                else if let Ok(permit)=workspace_limit.clone().try_acquire_owned() {
                    let workspace=workspace.clone();let client=client.to_owned();let tx=tx.clone();
                    jobs.spawn(async move {let _permit=permit;
                        let result=tokio::time::timeout(Duration::from_secs(15),workspace.handle(&conv,&client,&frame["payload"])).await.unwrap_or_else(|_|json!({"ok":false,"error":"workspace request timed out","code":"timeout"}));
                        let _=tx.send(hermes_rust_core::workspace::WorkspaceService::response_frame(&request_id,&conv,result)).await;None
                    });
                } else { ws.send(Message::Text(serde_json::to_string(&hermes_rust_core::workspace::WorkspaceService::response_frame(&request_id,&conv,json!({"ok":false,"error":"workspace busy","code":"busy"})))?.into())).await?; }
            } else { ws.send(Message::Text(serde_json::to_string(&hermes_rust_core::workspace::WorkspaceService::response_frame(&request_id,&conv,json!({"ok":false,"error":"trusted client identity missing","code":"unauthorized"})))?.into())).await?; }
        } else { ws.send(Message::Text(serde_json::to_string(&hermes_rust_core::workspace::WorkspaceService::response_frame(&request_id,&conv,json!({"ok":false,"error":"workspace sharing is not configured","code":"disabled"})))?.into())).await?; }
     },
     "memory.analyze"=>{let id=wire::text(&frame,"request_id")?.to_owned();match j.claim(&format!("memory:{id}"),&frame).await{
      Ok((_,Some(saved)))=>ws.send(Message::Text(serde_json::to_string(&saved)?.into())).await?,
      Ok((state,None)) if state=="new"=>{let permit=memory_limit.clone().try_acquire_owned();if let Ok(permit)=permit {let j=j.clone();let p=p.clone();let tx=tx.clone();jobs.spawn(async move {let _permit=permit;let result=p.analyze(&frame).await.unwrap_or_else(|_|json!({"version":1,"type":"memory.result","request_id":id,"error":"Rust 屏幕记忆暂未完成理解，请稍后重试"}));if j.finish(&format!("memory:{id}"),&result).await.is_ok(){let _=tx.send(result).await;}None});}else{let e=json!({"version":1,"type":"memory.result","request_id":id,"error":"Rust memory worker is busy; retry later"});j.finish(&format!("memory:{id}"),&e).await?;ws.send(Message::Text(serde_json::to_string(&e)?.into())).await?;}},
      Ok((state,None)) if state=="running"=>{},
      _=>{ws.send(Message::Text(serde_json::to_string(&json!({"version":1,"type":"memory.result","request_id":id,"error":"Conflicting or interrupted request; retry with a new request ID"}))?.into())).await?;}
     }},
     _=>ws.send(Message::Text(serde_json::to_string(&wire::error("UNSUPPORTED_FRAME",None))?.into())).await?,
    }
   }
 }}Ok(())}.await;
    services
        .reply_followups
        .store(false, std::sync::atomic::Ordering::Release);
    if let Some(parent) = &services.parent_continuation {
        parent.set_reply_followups(false);
    }
    if let Some(hub) = &services.interactions {
        hub.disconnect();
    }
    if let Some(browser) = &services.browser {
        browser.disconnect();
    }
    jobs.abort_all();
    while jobs.join_next().await.is_some() {}
    if let Some(workspace) = &services.workspace {
        workspace.close().await;
    }
    if let Some(hub) = &services.interactions {
        let _ = tokio::time::timeout(Duration::from_secs(1), hub.flush()).await;
    }
    j.interrupted().await?;
    outcome
}
#[tokio::main(worker_threads = 2)]
async fn main() -> Result<()> {
    let a = Args::parse();
    // Reject unsafe/unknown browser options before contacting any endpoint.
    // Parse alone never connects, launches a process or creates artifact files.
    let browser_config = a
        .browser_tools_json
        .as_deref()
        .map(|raw| hermes_rust_core::browser_host::BrowserHostConfig::parse(raw, &a.db))
        .transpose()?;
    ensure!(
        wire::valid_device(&a.device),
        "device must be USER_DEVICE_AGENT with 2..24 ASCII alphanumeric characters per segment"
    );
    let url = reqwest::Url::parse(&a.server)?;
    ensure!(
        url.path() == "/api/v1/agent/ws"
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none(),
        "invalid Orialis server URL"
    );
    ensure!(
        url.scheme() == "wss"
            || (url.scheme() == "ws"
                && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))),
        "use WSS except for loopback tests"
    );
    if url.scheme() == "wss" {
        ensure!(a.token.is_some(), "remote Orialis requires a device token");
    }
    let mut p = Provider::new(
        a.endpoint.clone(),
        a.model.clone(),
        a.api_key.clone(),
        a.mock,
    )?;
    if a.native_tool_images {
        p = p.with_native_tool_images(
            hermes_rust_core::tool_images::NativeToolImageMode::OpenAiChatUserBridge,
        );
    }
    if let Some(endpoint) = &a.fallback_endpoint {
        ensure!(
            !a.native_tool_images || a.fallback_native_tool_images,
            "native tool images require explicit --fallback-native-tool-images for the configured fallback"
        );
        let mut fallback = Provider::new(
            endpoint.clone(),
            a.fallback_model
                .clone()
                .context("fallback model required")?,
            a.fallback_api_key.clone(),
            false,
        )?;
        if a.fallback_native_tool_images {
            fallback = fallback.with_native_tool_images(
                hermes_rust_core::tool_images::NativeToolImageMode::OpenAiChatUserBridge,
            );
        }
        p = p.with_fallbacks(vec![fallback])?;
    }
    let delegation_model = p.clone();
    let vision_endpoint = a.vision_endpoint.as_deref().unwrap_or(&a.endpoint);
    let vision_model = a.vision_model.as_deref().unwrap_or(&a.model);
    let vision_key = endpoint_key(
        &a.endpoint,
        a.api_key.as_deref(),
        vision_endpoint,
        a.vision_api_key.as_deref(),
    );
    let vision = Provider::new(
        vision_endpoint.into(),
        vision_model.into(),
        vision_key.map(str::to_owned),
        a.mock,
    )?;
    let video = hermes_rust_core::memory_video::MemoryVideoClient::new_with_concurrency(
        &vision,
        a.bili_credentials
            .as_deref()
            .map(hermes_rust_core::memory_video::CredentialStore::new)
            .transpose()?,
        usize::from(a.memory_concurrency),
    )?;
    let timeout = turn_timeout(&a)?;
    let owner_verifier = if a.verify_owner {
        Some(hermes_rust_core::account_scope::OwnerVerifier::new(
            &a.server,
            &a.device,
            a.token
                .as_deref()
                .context("owner verification requires a device token")?,
            a.expected_owner.clone(),
        )?)
    } else {
        None
    };
    let owner_scope = if let Some(verifier) = &owner_verifier {
        let owner = verifier.verify().await?;
        hermes_rust_core::account_scope::bind_store(&a.db, &owner)?;
        Some(owner.scope())
    } else {
        None
    };
    let identity = if let Some(owner) = &owner_scope {
        format!("{}|{}|{owner}", a.server, a.device)
    } else {
        format!("{}|{}", a.server, a.device)
    };
    let j = Journal::open(&a.db, &identity).await?;
    let events = if a.stream_events {
        Some(GatewayEvents::open(&a.db, &identity).await?)
    } else {
        None
    };
    let interactions = if a.interactions {
        let events = events
            .as_ref()
            .context("interactions require event transport")?;
        events
            .enable_features(
                &[
                    "clarify.request",
                    "clarify.resolve",
                    "clarify.cancel",
                    "approval.request",
                    "approval.resolve",
                ]
                .map(str::to_owned),
            )
            .await?;
        Some(
            hermes_rust_core::interactions::InteractionHub::open(
                &a.db.with_extension("interactions.sqlite"),
                &identity,
                Arc::new(events.clone()),
                Duration::from_secs(300),
            )
            .await?,
        )
    } else {
        None
    };
    let auxiliary = if a.turn_updates {
        let cache = hermes_rust_core::conversation_updates::UpdateCache::open(
            &a.db.with_extension("updates.sqlite"),
            &identity,
        )?;
        Some(AuxiliaryClient::new(
            a.auxiliary_endpoint.as_deref().unwrap_or(&a.endpoint),
            a.auxiliary_model.as_deref().unwrap_or(&a.model),
            endpoint_key(
                &a.endpoint,
                a.api_key.as_deref(),
                a.auxiliary_endpoint.as_deref().unwrap_or(&a.endpoint),
                a.auxiliary_api_key.as_deref(),
            ),
            cache,
        )?)
    } else {
        None
    };
    let mut domain = None;
    let mut configured_tools: Vec<Arc<dyn hermes_rust_core::tool_runtime::ToolExecutor>> =
        Vec::new();
    let mut store = Store::open(&a.db)?;
    if a.domain_tools {
        store = store.with_base_prompt(format!(
            "{}\n\n{}",
            hermes_rust_core::BASE_PROMPT,
            hermes_rust_core::native_ui::PLATFORM_HINT
        ))?;
    }
    let mut c = Core::new(store, p).with_limits(core_limits(&a))?;
    if a.domain_tools {
        let token = a
            .token
            .as_deref()
            .context("domain tools require a configured device token")?;
        let client = hermes_rust_core::domain_tools::DomainClient::new(
            &a.server,
            &a.device,
            token,
            a.news_publisher_token.as_deref(),
        )?;
        domain = Some(client.clone());
        if let (Some(verifier), Some(scope)) = (&owner_verifier, &owner_scope) {
            configured_tools.push(Arc::new(
                hermes_rust_core::host_tools::OwnerCheckedDomainTools {
                    client,
                    verifier: verifier.clone(),
                    expected_scope: scope.clone(),
                },
            ));
        } else {
            configured_tools.push(Arc::new(hermes_rust_core::host_tools::OrialisDomainTools(
                client,
            )));
        }
    }
    if a.web_tools {
        use hermes_rust_core::web_tools::{SearchConfig, SearchProvider, WebConfig, WebTools};
        let search = if let Some(provider) = a.search_provider.as_deref() {
            let (provider, default_endpoint) = match provider {
                "brave" => (
                    SearchProvider::Brave,
                    "https://api.search.brave.com/res/v1/web/search",
                ),
                "firecrawl" => (
                    SearchProvider::Firecrawl,
                    "https://api.firecrawl.dev/v2/search",
                ),
                _ => unreachable!("clap validated provider"),
            };
            Some(SearchConfig {
                provider,
                endpoint: a.search_endpoint.clone().unwrap_or(default_endpoint.into()),
                api_key: a
                    .search_api_key
                    .clone()
                    .context("search requires a separately configured API key")?,
            })
        } else {
            None
        };
        configured_tools.push(Arc::new(WebTools::new(WebConfig {
            search,
            ..Default::default()
        })?));
    }
    if let Some(hub) = &interactions {
        configured_tools.push(Arc::new(hermes_rust_core::interactions::ClarifyTool(
            hub.clone(),
        )));
    }
    c = c.with_tool_executors(configured_tools.clone())?;
    if a.session_context {
        c = c.with_session_context(
            owner_scope
                .clone()
                .context("session context requires verified account scope")?,
            hermes_rust_core::session_context::CompressionPolicy::default(),
        )?;
    }
    let mut outputs = None;
    let mut attachment_transport = None;
    if a.attachments {
        let token = a
            .token
            .as_ref()
            .context("attachments require a configured device token")?;
        let cache = a
            .attachment_cache
            .clone()
            .unwrap_or_else(|| a.db.with_extension("attachments"));
        let transport = hermes_rust_core::attachments::AttachmentTransport::new(
            hermes_rust_core::attachments::AttachmentConfig::new(
                a.attachment_origin.clone().unwrap_or_else(|| a.server.clone()),
                a.device.clone(),
                token.clone(),
                cache,
            ),
        )?;
        let transport = if let Some(scope) = &owner_scope {
            transport.with_verified_owner_scope(scope.clone())?
        } else {
            transport
        };
        attachment_transport = Some(transport.clone());
        if a.output_files {
            let mut config = hermes_rust_core::output_files::OutputConfig::new(
                a.db.with_extension("output.sqlite"),
                a.db.with_extension("output-spool"),
            );
            config.artifact_roots = a.artifact_root.clone();
            outputs = Some(
                hermes_rust_core::output_files::OutputFiles::open(config, transport.clone())
                    .await?,
            );
            if let Some(events) = &events {
                events
                    .enable_features(
                        &[
                            "artifact.started",
                            "artifact.progress",
                            "artifact.completed",
                            "artifact.failed",
                        ]
                        .map(str::to_owned),
                    )
                    .await?;
            }
        }
        let limits = hermes_rust_core::attachments::ModelInputLimits {
            supports_images: a.chat_images,
            document_extractor: if a.documents {
                Some(hermes_rust_core::document_extract::DocumentExtractor::new(
                    hermes_rust_core::document_extract::DocumentConfig {
                        pdf_program: a.pdf_program.clone(),
                        ..Default::default()
                    },
                )?)
            } else {
                None
            },
            ..Default::default()
        };
        c = c.with_media_resolver(Arc::new(
            hermes_rust_core::media_runtime::OrialisMediaResolver { transport, limits },
        ));
    }
    if a.vision_tools || a.native_tool_images {
        use hermes_rust_core::vision_tools::{VisionConfig, VisionProviderConfig, VisionTools};
        ensure!(
            !a.mock,
            "vision tools require an actual explicitly configured provider, not --mock"
        );
        let mut config = VisionConfig::new(
            owner_scope
                .clone()
                .context("vision tools require verified owner")?,
        );
        if a.native_tool_images {
            config.native = true;
        } else {
            config.provider = Some(VisionProviderConfig {
                endpoint: a
                    .vision_endpoint
                    .clone()
                    .context("vision tool endpoint is required")?,
                model: a
                    .vision_model
                    .clone()
                    .context("vision tool model is required")?,
                api_key: a.vision_api_key.clone(),
            });
        }
        let mut tools = VisionTools::new(config)?;
        if let Some(transport) = attachment_transport {
            tools = tools.with_transport(transport)?;
        }
        configured_tools.push(Arc::new(tools));
    }
    let browser = if let Some(config) = browser_config {
        let browser = hermes_rust_core::browser_tools::BrowserTools::new(
            config,
            owner_scope
                .clone()
                .context("browser tools require verified owner")?,
            interactions
                .clone()
                .context("browser tools require interactions")?,
            outputs.clone(),
        )?;
        configured_tools.push(Arc::new(browser.clone()));
        Some(browser)
    } else {
        None
    };
    #[cfg(unix)]
    let mut profile_skill_grant = None;
    #[cfg(unix)]
    let local = if let Some(raw) = &a.local_tools_json {
        let value: LocalConfig =
            serde_json::from_str(raw).context("invalid trusted local tool configuration")?;
        let mut config = hermes_rust_core::local_tools::LocalToolsConfig::new(
            owner_scope
                .clone()
                .context("local tools require verified owner")?,
            value.root,
            a.db.with_extension("local.sqlite"),
        );
        config.write = value.write;
        config.execute = value.execute;
        config.programs = value.programs;
        if let Some(path) = value.sandbox {
            config.sandbox = path;
        }
        if let Some(roots) = value.runtime_roots {
            config.runtime_roots = roots;
        }
        config.skills_root = value.skills_root;
        config.python_program = value.python_program;
        let bridge = if value.python_bridge_tools.is_empty() {
            None
        } else {
            ensure!(
                config.python_program.is_some(),
                "Python callbacks require a configured Python runtime"
            );
            let dispatcher =
                hermes_rust_core::host_tools::ExecutorGroup::new(configured_tools.clone())?;
            Some(hermes_rust_core::local_tools::PythonBridge::new(
                Arc::new(dispatcher),
                value.python_bridge_tools,
            )?)
        };
        // Capture exactly the grant opened below. Profile JSON cannot substitute
        // another database, workspace, skills root or owner.
        profile_skill_grant = config.skills_root.as_ref().map(|skills_root| {
            (
                config.state_database.clone(),
                config.root.clone(),
                skills_root.clone(),
            )
        });
        let local = hermes_rust_core::local_tools::LocalTools::open_with_python_bridge(
            config,
            interactions.clone(),
            outputs.clone(),
            bridge,
        )
        .await?;
        configured_tools.push(Arc::new(local.clone()));
        Some(local)
    } else {
        None
    };
    #[cfg(not(unix))]
    ensure!(
        a.local_tools_json.is_none(),
        "local tools are not supported on this platform"
    );
    if let Some(raw) = &a.mcp_servers_json {
        let raw = load_trusted_config(raw)?;
        let mcp = hermes_rust_core::mcp_tools::McpTools::connect(&raw).await?;
        configured_tools.push(Arc::new(mcp));
    }
    let portable_profile = if let Some(raw) = &a.portable_profile_json {
        use hermes_rust_core::profile_bridge::{BridgeConfig, ProfileBridge};
        let config = parse_portable_profile(raw)?;
        #[cfg(unix)]
        let managed_skills = if config.managed_skills.is_empty() {
            None
        } else {
            let (database, workspace_root, skills_root) = profile_skill_grant
                .as_ref()
                .context("managed profile skills require configured LocalTools skills_root")?;
            Some(hermes_rust_core::profile_bridge::ManagedSkillsConfig {
                database: std::fs::canonicalize(database)?,
                workspace_root: workspace_root.clone(),
                skills_root: skills_root.clone(),
                names: config.managed_skills,
            })
        };
        #[cfg(not(unix))]
        let managed_skills = {
            ensure!(
                config.managed_skills.is_empty(),
                "managed profile skills are unsupported on this platform"
            );
            None
        };
        let bridge = ProfileBridge::new(BridgeConfig {
            owner: owner_scope
                .clone()
                .context("portable profile requires verified owner")?,
            source_id: config.source_id,
            profile: config.profile,
            managed_skills,
        })?;
        let report = c
            .reconcile_profile(bridge.clone())
            .await
            .context("portable profile startup reconciliation failed")?;
        report_portable_profile("startup", &report);
        Some((bridge, Duration::from_secs(config.interval_secs)))
    } else {
        None
    };
    let delegation = if a.delegation {
        use hermes_rust_core::delegation::{DelegationConfig, DelegationRuntime};
        let allowed_tools: std::collections::BTreeSet<String> =
            a.delegate_tools.iter().cloned().collect();
        ensure!(
            allowed_tools.len() == a.delegate_tools.len(),
            "duplicate inherited delegation tool"
        );
        // Only the digest is retained by the child database. Never log this
        // configuration or raw keys; credential changes also invalidate scopes.
        let capability_scope = wire::digest(&serde_json::to_string(&json!({
            "owner": owner_scope, "server":a.server, "device":a.device,
            "local":a.local_tools_json, "domain":a.domain_tools,
            "mcp":a.mcp_servers_json,
            "browser":a.browser_tools_json,
            "web":a.web_tools, "search_provider":a.search_provider,
            "search_endpoint":a.search_endpoint,
            "search_key_hash":a.search_api_key.as_deref().map(wire::digest),
            "news_key_hash":a.news_publisher_token.as_deref().map(wire::digest),
            "provider_key_hash":a.api_key.as_deref().map(wire::digest),
            "fallback_key_hash":a.fallback_api_key.as_deref().map(wire::digest),
            "vision_key_hash":a.vision_api_key.as_deref().map(wire::digest),
            "vision_endpoint":a.vision_endpoint,"vision_model":a.vision_model,
            "native_images":a.native_tool_images,"auxiliary_vision":a.vision_tools,
            "artifacts":a.artifact_root,"outputs":a.output_files,"tools":allowed_tools,
        }))?);
        let config = DelegationConfig {
            background_enabled: a.delegation_background,
            allowed_tools: allowed_tools.clone(),
            capability_scope: Some(capability_scope),
            ..Default::default()
        };
        let runtime = DelegationRuntime::open(
            &a.db.with_extension("delegation.sqlite"),
            owner_scope
                .as_deref()
                .context("delegation requires verified owner")?,
            Arc::new(delegation_model),
            Arc::new(hermes_rust_core::tool_runtime::ToolRouter::new(
                configured_tools.clone(),
            )?),
            config,
        )?;
        let enabled: std::collections::BTreeSet<_> = runtime.enabled_tools().into_iter().collect();
        ensure!(
            enabled == allowed_tools,
            "inherited delegation tools include unknown, unavailable or forbidden names"
        );
        configured_tools.push(Arc::new(runtime.clone()));
        Some(runtime)
    } else {
        None
    };
    c = c.with_tool_executors(configured_tools.clone())?;
    let mut scheduler = None;
    let mut deliveries = None;
    let mut scheduled_executor = None;
    if a.scheduler || a.inbound_deliveries || a.delegation_background {
        use hermes_rust_core::delivery::{DeliveryIdentity, DeliveryLimits, DeliveryOutbox};
        let identity = DeliveryIdentity::new(
            owner_scope
                .as_deref()
                .context("delivery requires verified owner")?,
            &a.server,
            &a.device,
            a.token.as_deref().context("delivery requires token")?,
        )?;
        let outbox = DeliveryOutbox::open(
            a.db.with_extension("delivery.sqlite"),
            identity.clone(),
            DeliveryLimits::default(),
        )
        .await?;
        if a.scheduler {
            use hermes_rust_core::{
                cron_tools::CronTools,
                scheduler::{CoreScheduledExecutor, ScheduledExecutor, Scheduler, SchedulerLimits},
            };
            let schedule = Scheduler::open(
                a.db.with_extension("scheduler.sqlite"),
                identity,
                SchedulerLimits::default(),
            )
            .await?;
            let executor: Arc<dyn ScheduledExecutor> =
                Arc::new(CoreScheduledExecutor::new(c.clone())?);
            configured_tools.push(Arc::new(CronTools::new(
                schedule.clone(),
                outbox.clone(),
                executor.clone(),
                interactions
                    .clone()
                    .context("scheduler requires interaction approvals")?,
                a.scheduler_timezone.clone(),
            )?));
            c = c.with_tool_executors(configured_tools)?;
            scheduler = Some(schedule);
            scheduled_executor = Some(executor);
        }
        deliveries = Some(outbox);
    }
    let inbound = if a.inbound_deliveries {
        use hermes_rust_core::inbound_delivery::{ConversationVerifier, InboundDeliveries};
        Some(
            InboundDeliveries::new(
                c.clone(),
                deliveries.clone().context("delivery outbox absent")?,
                ConversationVerifier::new(
                    &a.server,
                    &a.device,
                    a.token.as_deref().context("inbound token absent")?,
                    owner_scope.clone().context("inbound owner absent")?,
                )?,
            )
            .await?,
        )
    } else {
        None
    };
    let delegation_delivery = if a.delegation_background {
        Some(
            hermes_rust_core::delegation_delivery::DelegationDelivery::new(
                delegation
                    .clone()
                    .context("background delegation runtime absent")?,
                c.clone(),
                deliveries
                    .clone()
                    .context("background delegation outbox absent")?,
                hermes_rust_core::inbound_delivery::ConversationVerifier::new(
                    &a.server,
                    &a.device,
                    a.token
                        .as_deref()
                        .context("background delegation token absent")?,
                    owner_scope
                        .clone()
                        .context("background delegation owner absent")?,
                )?,
            )
            .with_parent_journal(j.clone()),
        )
    } else {
        None
    };
    let parent_continuation = if a.delegation_parent_resume {
        use hermes_rust_core::parent_continuation::{ContinuationConfig, ParentContinuation};
        let runtime = delegation
            .clone()
            .context("parent continuation runtime absent")?;
        let owner = owner_scope
            .clone()
            .context("parent continuation owner absent")?;
        let queue = ParentContinuation::open(
            a.db.with_extension("parent-continuation.sqlite"),
            &owner,
            runtime.clone(),
            ContinuationConfig {
                enabled: true,
                max_final_bytes: 1024 * 1024,
                run_timeout: timeout,
                ..Default::default()
            },
        )
        .await?;
        Some(
            hermes_rust_core::parent_continuation_host::ParentContinuationHost::new(
                queue,
                runtime,
                c.clone(),
                deliveries
                    .clone()
                    .context("parent continuation outbox absent")?,
                hermes_rust_core::inbound_delivery::ConversationVerifier::new(
                    &a.server,
                    &a.device,
                    a.token
                        .as_deref()
                        .context("parent continuation token absent")?,
                    owner,
                )?,
                j.clone(),
            )
            .await?
            .with_outputs(outputs.clone()),
        )
    } else {
        None
    };
    let workspace = a
        .workspaces_json
        .as_deref()
        .map(hermes_rust_core::workspace::WorkspaceService::from_json)
        .transpose()?
        .map(Arc::new);
    let services = Services {
        core: c,
        video,
        journal: j,
        events,
        turn_timeout: timeout,
        workspace,
        owner_verifier,
        owner_scope,
        interactions,
        outputs,
        auxiliary,
        domain,
        reply_followups: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        #[cfg(unix)]
        local,
        browser,
        scheduler,
        deliveries,
        scheduled_executor,
        delegation,
        delegation_delivery,
        parent_continuation,
        inbound,
    };
    let mut background = Vec::new();
    let parent_task = services.parent_continuation.clone().map(|host| {
        tokio::spawn(async move {
            host.run().await;
        })
    });
    if services.parent_continuation.is_none()
        && let Some(delivery) = services.delegation_delivery.clone()
    {
        background.push(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_error: Option<Instant> = None;
            loop {
                tokio::select! {_=tick.tick()=>{},_=delivery.completion_notified()=>{}}
                if delivery.flush(32).await.is_err()
                    && last_error.is_none_or(|time| time.elapsed() >= Duration::from_secs(60))
                {
                    eprintln!(
                        "Background delegation handoff paused; committed results remain journaled."
                    );
                    last_error = Some(Instant::now());
                }
            }
        }));
    }
    if let Some((bridge, interval)) = portable_profile {
        background.push(tokio::spawn(run_portable_profile(
            services.core.clone(),
            bridge,
            interval,
        )));
    }
    if let Some(inbox) = &services.inbound {
        background.push(tokio::spawn(run_inbound(inbox.clone(), timeout)));
    }
    if let (Some(outputs), Some(events)) = (&services.outputs, &services.events) {
        background.push(tokio::spawn(pump_artifact_events(
            outputs.clone(),
            events.clone(),
        )));
    }
    if let (Some(scheduler), Some(outbox), Some(executor)) = (
        &services.scheduler,
        &services.deliveries,
        &services.scheduled_executor,
    ) {
        background.push(tokio::spawn(run_scheduler(
            scheduler.clone(),
            outbox.clone(),
            executor.clone(),
            services
                .owner_verifier
                .clone()
                .context("scheduler owner verifier absent")?,
            services
                .owner_scope
                .clone()
                .context("scheduler owner scope absent")?,
        )));
    }
    let (shutdown_tx, mut shutdown) = tokio::sync::watch::channel(false);
    let signal_task = tokio::spawn(async move {
        #[cfg(unix)]
        {
            if let Ok(mut terminate) =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            {
                tokio::select! {_=tokio::signal::ctrl_c()=>{},_=terminate.recv()=>{}}
            } else {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        let _ = shutdown_tx.send(true);
    });
    let mut delay = 1;
    loop {
        let start = Instant::now();
        tokio::select! {
            _=shutdown.changed()=>break,
            result=connection(&a, &services)=>{if result.is_err(){eprintln!("Orialis connection ended; pending completed replies remain journaled.");}}
        }
        if start.elapsed() > Duration::from_secs(60) {
            delay = 1;
        }
        tokio::select! {_=shutdown.changed()=>break,_=tokio::time::sleep(Duration::from_secs(delay))=>{}}
        delay = (delay * 2).min(30);
    }
    // Parent continuations cancel their Core route and retain final/uncertain
    // receipts before the other producers and journals are stopped.
    if let Some(parent) = &services.parent_continuation {
        parent.stop();
    }
    if let Some(task) = parent_task {
        let _ = task.await;
    }
    // No new execution after shutdown. Abort network/model producers first;
    // admitted tool effects still record their known results in Core receipts.
    for task in background {
        task.abort();
        let _ = task.await;
    }
    if let Some(browser) = &services.browser {
        browser.shutdown();
    }
    if let Some(hub) = &services.interactions {
        hub.disconnect();
        let _ = hub.flush().await;
    }
    #[cfg(unix)]
    if let Some(local) = &services.local {
        local.shutdown().await;
    }
    if let Some(workspace) = &services.workspace {
        workspace.close().await;
    }
    services.journal.interrupted().await?;
    if let Some(runtime) = &services.delegation {
        runtime.drain().await?;
    }
    // Let terminal observers and cancelled permission/tool workers settle their
    // already-admitted journal writes without blocking on an external model.
    tokio::time::sleep(Duration::from_millis(100)).await;
    if let Some(events) = &services.events {
        events.shutdown().await?;
    }
    services.journal.shutdown().await?;
    signal_task.abort();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn browser_host_requires_authenticated_scoped_approval_transport() {
        assert!(args(&[]).browser_tools_json.is_none());
        let base = [
            "agent",
            "--server",
            "ws://127.0.0.1/api/v1/agent/ws",
            "--device",
            "TE_ST_Rust",
        ];
        for missing in [
            "--verify-owner",
            "--session-context",
            "--interactions",
            "--stream-events",
        ] {
            let flags = [
                "--verify-owner",
                "--session-context",
                "--interactions",
                "--stream-events",
            ];
            let values = base
                .into_iter()
                .chain(flags.into_iter().filter(|v| *v != missing))
                .chain(["--browser-tools-json", "{}"]);
            assert!(Args::try_parse_from(values).is_err(), "{missing}");
        }
        let selected = args(&[
            "--verify-owner",
            "--session-context",
            "--interactions",
            "--stream-events",
            "--browser-tools-json",
            "{}",
        ]);
        assert_eq!(selected.browser_tools_json.as_deref(), Some("{}"));
        assert!(!selected.native_tool_images);
        assert!(!selected.output_files);
        assert!(selected.delegate_tools.is_empty());
    }
    fn args(extra: &[&str]) -> Args {
        let mut values = vec![
            "orialis_agent",
            "--server",
            "ws://127.0.0.1/api/v1/agent/ws",
            "--device",
            "TE_ST_Rust",
        ];
        values.extend_from_slice(extra);
        Args::try_parse_from(values).unwrap()
    }
    #[test]
    fn native_host_features_are_explicit_and_scoped() {
        let baseline = args(&[]);
        assert!(
            !baseline.native_tool_images && !baseline.delegation && !baseline.delegation_background
        );
        assert!(baseline.delegate_tools.is_empty());
        let selected = args(&[
            "--verify-owner",
            "--session-context",
            "--delegation",
            "--delegate-tools",
            "list_tasks,read_file",
            "--native-tool-images",
        ]);
        assert_eq!(selected.delegate_tools, vec!["list_tasks", "read_file"]);
        assert!(selected.native_tool_images);
        assert_eq!(core_limits(&selected).max_provider_rounds, 32);
        let base = [
            "agent",
            "--server",
            "ws://127.0.0.1/api/v1/agent/ws",
            "--device",
            "TE_ST_Rust",
        ];
        for extra in [
            vec!["--native-tool-images"],
            vec!["--delegate-tools", "read_file"],
            vec!["--delegation-background"],
            vec![
                "--delegation-background",
                "--verify-owner",
                "--session-context",
            ],
            vec![
                "--verify-owner",
                "--session-context",
                "--native-tool-images",
                "--vision-tools",
                "--vision-endpoint",
                "http://127.0.0.1/v1/chat/completions",
                "--vision-model",
                "test",
            ],
            vec!["--fallback-native-tool-images"],
        ] {
            assert!(Args::try_parse_from(base.iter().copied().chain(extra)).is_err());
        }
    }
    #[test]
    fn portable_profile_host_config_cannot_select_private_bindings() {
        assert!(args(&[]).portable_profile_json.is_none());
        let base = [
            "agent",
            "--server",
            "ws://127.0.0.1/api/v1/agent/ws",
            "--device",
            "TE_ST_Rust",
        ];
        assert!(
            Args::try_parse_from(
                base.iter()
                    .copied()
                    .chain(["--portable-profile-json", "{}"])
            )
            .is_err()
        );
        let selected = args(&[
            "--verify-owner",
            "--session-context",
            "--portable-profile-json",
            r#"{"profile":"/tmp/example","source_id":"device-a"}"#,
        ]);
        let config =
            parse_portable_profile(selected.portable_profile_json.as_deref().unwrap()).unwrap();
        assert_eq!(config.interval_secs, 60);
        assert!(config.managed_skills.is_empty());
        for forbidden in [
            "owner",
            "database",
            "workspace_root",
            "skills_root",
            "ssh",
            "hub_store",
        ] {
            let value =
                json!({"profile":"/tmp/example", "source_id":"test", (forbidden):"untrusted"});
            assert!(
                parse_portable_profile(&value.to_string()).is_err(),
                "{forbidden}"
            );
        }
        for value in [
            json!({"profile":"relative", "source_id":"test"}),
            json!({"profile":"/tmp/example", "source_id":"test", "interval_secs":0}),
            json!({"profile":"/tmp/example", "source_id":"test", "interval_secs":3601}),
            json!({"profile":"/tmp/example", "source_id":"test", "managed_skills":{"database":"other"}}),
        ] {
            assert!(parse_portable_profile(&value.to_string()).is_err());
        }
    }
    #[test]
    fn alternate_routes_do_not_inherit_primary_credentials() {
        assert_eq!(
            endpoint_key(
                "https://one.example/api",
                Some("synthetic-primary"),
                "https://one.example/api",
                None
            ),
            Some("synthetic-primary")
        );
        assert_eq!(
            endpoint_key(
                "https://one.example/api",
                Some("synthetic-primary"),
                "https://two.example/api",
                None
            ),
            None
        );
        assert_eq!(
            endpoint_key(
                "https://one.example/api",
                Some("synthetic-primary"),
                "https://one.example/other",
                None
            ),
            None
        );
        assert_eq!(
            endpoint_key(
                "https://one.example/api",
                Some("synthetic-primary"),
                "https://two.example/api",
                Some("synthetic-secondary")
            ),
            Some("synthetic-secondary")
        );
    }
    #[test]
    fn legacy_and_stream_profiles_have_explicit_deadlines() {
        assert_eq!(turn_timeout(&args(&[])).unwrap(), Duration::from_secs(45));
        assert_eq!(
            turn_timeout(&args(&["--stream-events"])).unwrap(),
            Duration::from_secs(900)
        );
        assert_eq!(
            turn_timeout(&args(&["--stream-events", "--turn-timeout-secs", "60"])).unwrap(),
            Duration::from_secs(60)
        );
        assert!(turn_timeout(&args(&["--turn-timeout-secs", "0"])).is_err());
        assert!(turn_timeout(&args(&["--turn-timeout-secs", "901"])).is_err());
    }
    #[test]
    fn full_profile_enlarges_explicit_resource_bounds() {
        assert_eq!(core_limits(&args(&[])).max_provider_rounds, 5);
        for flag in ["--domain-tools", "--stream-events", "--attachments"] {
            let limits = core_limits(&args(&[flag]));
            assert_eq!(limits.max_provider_rounds, 32);
            assert_eq!(limits.max_tool_calls_per_round, 32);
            assert_eq!(limits.max_context_messages, 4096);
        }
        let limits = core_limits(&args(&[
            "--max-provider-rounds",
            "12",
            "--max-tool-calls",
            "4",
        ]));
        assert_eq!(limits.max_provider_rounds, 12);
        assert_eq!(limits.max_tool_calls_per_round, 4);
    }
    #[test]
    fn optional_event_capabilities_do_not_claim_unimplemented_workflows() {
        let legacy = capabilities(false, false, false, false, false, false);
        assert_eq!(legacy.len(), 5);
        assert!(!legacy.iter().any(|s| s.starts_with("agent.")));
        let stream = capabilities(true, true, false, false, false, false);
        for supported in CAPABILITIES {
            assert!(stream.iter().any(|c| c == supported));
        }
        assert!(stream.iter().any(|s| s == "attachments"));
        assert!(
            !stream
                .iter()
                .any(|s| s.starts_with("approval.") || s.starts_with("clarify."))
        );
    }
}
