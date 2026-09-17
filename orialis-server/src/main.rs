mod agent_gateway;
mod mobile_realtime;

use agent_gateway::AgentRegistry;
use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Multipart, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, patch, post},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, FixedOffset, NaiveDate, NaiveTime, Utc};
use orialis_core::{metadata, ServiceMetadata, API_VERSION, SERVICE_NAME};
use scrypt::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Scrypt,
};
use serde::{de::DeserializeOwned, de::Error as DeError, Deserialize, Deserializer, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};
use std::{env, net::SocketAddr, path::PathBuf, sync::Arc};
use tokio::io::AsyncWriteExt;
use tracing::info;
use uuid::Uuid;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone)]
struct AppState {
    metadata: ServiceMetadata,
    pool: SqlitePool,
    agent: AgentRegistry,
    mobile: mobile_realtime::MobileRegistry,
    agent_device_token: Option<String>,
    agent_user_id: Option<String>,
    public_url: String,
    upload_dir: PathBuf,
}

#[derive(Clone)]
struct Config {
    host: String,
    port: u16,
    environment: String,
    public_url: String,
    database_url: String,
    agent_device_token: Option<String>,
    agent_user_id: Option<String>,
    upload_dir: PathBuf,
}

impl Config {
    fn from_env() -> Result<Self, String> {
        let port = env::var("ORIALIS_PORT")
            .unwrap_or_else(|_| "18443".into())
            .parse::<u16>()
            .map_err(|_| "ORIALIS_PORT must be a valid port number".to_string())?;
        Ok(Self {
            host: env::var("ORIALIS_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
            port,
            environment: env::var("ORIALIS_ENV").unwrap_or_else(|_| "development".into()),
            public_url: env::var("ORIALIS_PUBLIC_URL")
                .unwrap_or_else(|_| "https://orialis.jxcz.top".into()),
            database_url: env::var("ORIALIS_DATABASE_URL")
                .unwrap_or_else(|_| "sqlite://./orialis.db?mode=rwc".into()),
            agent_device_token: env::var("ORIALIS_AGENT_DEVICE_TOKEN")
                .ok()
                .filter(|token| !token.trim().is_empty()),
            agent_user_id: env::var("ORIALIS_AGENT_USER_ID")
                .ok()
                .map(|user_id| user_id.trim().to_owned())
                .filter(|user_id| !user_id.is_empty()),
            upload_dir: env::var("ORIALIS_UPLOAD_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("./uploads")),
        })
    }

    fn address(&self) -> Result<SocketAddr, String> {
        format!("{}:{}", self.host, self.port)
            .parse()
            .map_err(|_| "ORIALIS_HOST and ORIALIS_PORT do not form a valid socket address".into())
    }
}

#[derive(Debug)]
enum AppError {
    BadRequest(String),
    Unauthorized,
    Conflict(String),
    ServiceUnavailable(String),
    NotFound,
    Database(sqlx::Error),
}

impl From<sqlx::Error> for AppError {
    fn from(error: sqlx::Error) -> Self {
        Self::Database(error)
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message),
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "valid session required".to_string(),
            ),
            Self::Conflict(message) => (StatusCode::CONFLICT, "conflict", message),
            Self::ServiceUnavailable(message) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "service_unavailable",
                message,
            ),
            Self::NotFound => (
                StatusCode::NOT_FOUND,
                "not_found",
                "resource not found".to_string(),
            ),
            Self::Database(error) => {
                tracing::error!(%error, "database request failed");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "database_error",
                    "database request failed".to_string(),
                )
            }
        };
        (
            status,
            Json(serde_json::json!({
                "error": { "code": code, "message": message }
            })),
        )
            .into_response()
    }
}

#[derive(Serialize)]
struct HealthResponse {
    ok: bool,
    service: &'static str,
    version: &'static str,
    environment: String,
}

#[derive(Serialize)]
struct CapabilitiesResponse {
    service: &'static str,
    api_version: &'static str,
    web: bool,
    capabilities: Vec<&'static str>,
}

#[derive(Deserialize)]
struct Credentials {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct SessionResponse {
    #[serde(rename = "userId")]
    user_id: String,
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "expiresAt")]
    expires_at: String,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct Task {
    id: String,
    title: String,
    notes: Option<String>,
    important: bool,
    urgent: bool,
    completed: bool,
    completed_at: Option<String>,
    due: Option<String>,
    due_time: Option<String>,
    reminder_minutes: Option<i64>,
    project_id: Option<String>,
    #[serde(rename = "recurrence")]
    recurrence_rule: Option<String>,
    created_at: String,
    updated_at: String,
    version: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskInput {
    id: Option<String>,
    title: String,
    notes: Option<String>,
    important: Option<bool>,
    urgent: Option<bool>,
    completed: Option<bool>,
    completed_at: Option<String>,
    due: Option<String>,
    due_time: Option<String>,
    reminder_minutes: Option<i64>,
    project_id: Option<String>,
    recurrence: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskPatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    title: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    notes: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    important: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    urgent: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    completed: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    completed_at: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    due: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    due_time: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    reminder_minutes: Option<PatchValue<i64>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    project_id: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    recurrence: Option<PatchValue<Value>>,
    base_version: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskListResponse {
    items: Vec<Task>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskListQuery {
    after: Option<String>,
    limit: Option<i64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskCursor {
    v: u8,
    due_is_null: bool,
    due: Option<String>,
    due_time_is_null: bool,
    due_time: Option<String>,
    created_at: String,
    id: String,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct Project {
    id: String,
    name: String,
    goal: Option<String>,
    description: Option<String>,
    color: Option<String>,
    status: String,
    start_date: Option<String>,
    due: Option<String>,
    next_action_task_id: Option<String>,
    created_at: String,
    updated_at: String,
    version: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectInput {
    name: String,
    goal: Option<String>,
    description: Option<String>,
    color: Option<String>,
    status: Option<String>,
    start_date: Option<String>,
    due: Option<String>,
    next_action_task_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectPatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    name: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    goal: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    description: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    color: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    status: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    start_date: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    due: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    next_action_task_id: Option<PatchValue<String>>,
    base_version: i64,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct CalendarEvent {
    id: String,
    title: String,
    description: Option<String>,
    location: Option<String>,
    start_at: String,
    end_at: String,
    all_day: bool,
    reminder_minutes: Option<i64>,
    created_at: String,
    updated_at: String,
    version: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalendarEventInput {
    id: Option<String>,
    title: String,
    description: Option<String>,
    location: Option<String>,
    start_at: String,
    end_at: String,
    all_day: Option<bool>,
    reminder_minutes: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Attachment {
    id: String,
    name: String,
    mime_type: String,
    size: i64,
    download_url: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentInput {
    id: String,
}

#[derive(sqlx::FromRow)]
struct MessageRow {
    id: String,
    conversation_id: String,
    role: String,
    content: String,
    created_at: String,
    version: i64,
    attachments_json: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Message {
    id: String,
    conversation_id: String,
    role: String,
    content: String,
    created_at: String,
    version: i64,
    attachments: Vec<Attachment>,
}

impl MessageRow {
    fn into_message(self) -> Message {
        Message {
            id: self.id,
            conversation_id: self.conversation_id,
            role: self.role,
            content: self.content,
            created_at: self.created_at,
            version: self.version,
            attachments: serde_json::from_str(&self.attachments_json).unwrap_or_default(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageInput {
    id: Option<String>,
    content: String,
    #[serde(default)]
    attachments: Vec<AttachmentInput>,
}

const DEFAULT_CONVERSATION_ID: &str = "default";

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct Conversation {
    id: String,
    title: String,
    is_default: bool,
    #[serde(rename = "type")]
    conversation_type: String,
    created_at: String,
    updated_at: String,
    version: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConversationInput {
    id: Option<String>,
    title: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConversationPatch {
    title: String,
}

#[derive(Deserialize)]
struct DownloadQuery {
    token: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentUploadResponse {
    items: Vec<Attachment>,
}

const MAX_ATTACHMENT_BYTES: usize = 20 * 1024 * 1024;
const MAX_ATTACHMENT_COUNT: usize = 10;
const MAX_TOTAL_ATTACHMENT_BYTES: usize = 48 * 1024 * 1024;
const MAX_ATTACHMENT_REQUEST_BYTES: usize = 50 * 1024 * 1024;

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AgentDeviceRecord {
    device_id: String,
    platform: String,
    client: String,
    plugin_version: String,
    last_seen_at: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentDeviceResponse {
    device_id: String,
    platform: String,
    client: String,
    plugin_version: String,
    last_seen_at: String,
    online: bool,
    active: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentDevicesResponse {
    devices: Vec<AgentDeviceResponse>,
    active_device_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalendarEventPatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    title: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    description: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    location: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    start_at: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    end_at: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    all_day: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    reminder_minutes: Option<PatchValue<i64>>,
    base_version: i64,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct SyncEvent {
    cursor: i64,
    entity_type: String,
    entity_id: String,
    operation: String,
    entity_version: i64,
    tombstone: bool,
    mutation_id: Option<String>,
    payload_json: Option<String>,
    created_at: String,
}

#[derive(Deserialize)]
struct CursorQuery {
    after: Option<i64>,
    limit: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncResponse {
    events: Vec<SyncEvent>,
    next_cursor: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncSnapshot {
    cursor: i64,
    tasks: Vec<Task>,
    projects: Vec<Project>,
    calendar_events: Vec<CalendarEvent>,
    milestones: Vec<Milestone>,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct Milestone {
    id: String,
    user_id: String,
    project_id: String,
    title: String,
    due: Option<String>,
    completed: bool,
    completed_at: Option<String>,
    position: i64,
    created_at: String,
    updated_at: String,
    version: i64,
    deleted_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MilestoneInput {
    title: String,
    due: Option<String>,
    completed: Option<bool>,
    position: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MilestonePatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    title: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    due: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    completed: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    position: Option<PatchValue<i64>>,
    base_version: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectSummary {
    project: Project,
    total_tasks: i64,
    completed_tasks: i64,
    total_milestones: i64,
    completed_milestones: i64,
    total_units: i64,
    completed_units: i64,
    progress: f64,
    next_action: Option<Task>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectListResponse {
    items: Vec<Project>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
struct ProjectListQuery {
    after: Option<String>,
    limit: Option<i64>,
    status: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct ProjectCursor {
    v: u8,
    created_at: String,
    id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CalendarEventListResponse {
    items: Vec<CalendarEvent>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
struct CalendarEventListQuery {
    after: Option<String>,
    limit: Option<i64>,
    from: Option<String>,
    to: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct CalendarEventCursor {
    v: u8,
    start_at: String,
    id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MilestoneListResponse {
    items: Vec<Milestone>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
struct MilestoneListQuery {
    after: Option<String>,
    limit: Option<i64>,
}

#[derive(Serialize, Deserialize)]
struct MilestoneCursor {
    v: u8,
    position: i64,
    id: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum PatchValue<T> {
    Value(T),
    Null(()),
}

fn deserialize_patch<'de, D, T>(deserializer: D) -> Result<Option<PatchValue<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    let raw = Value::deserialize(deserializer)?;
    if raw.is_null() {
        return Ok(Some(PatchValue::Null(())));
    }
    T::deserialize(raw)
        .map(|value| Some(PatchValue::Value(value)))
        .map_err(D::Error::custom)
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "orialis_server=info".into()))
        .init();
    let config = Config::from_env().unwrap_or_else(|error| panic!("configuration error: {error}"));
    let address = config
        .address()
        .unwrap_or_else(|error| panic!("configuration error: {error}"));
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect(&config.database_url)
        .await
        .expect("failed to connect to SQLite");
    sqlx::query("PRAGMA journal_mode = WAL")
        .execute(&pool)
        .await
        .expect("failed to enable WAL mode");
    sqlx::query("PRAGMA synchronous = NORMAL")
        .execute(&pool)
        .await
        .expect("failed to configure SQLite sync");
    sqlx::query("PRAGMA busy_timeout = 5000")
        .execute(&pool)
        .await
        .expect("failed to configure SQLite busy timeout");
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&pool)
        .await
        .expect("failed to enable foreign keys");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("failed to run database migrations");

    let state = Arc::new(AppState {
        metadata: metadata(
            VERSION,
            config.environment.clone(),
            config.public_url.clone(),
        ),
        pool,
        agent: AgentRegistry::default(),
        mobile: mobile_realtime::MobileRegistry::default(),
        agent_device_token: config.agent_device_token.clone(),
        agent_user_id: config.agent_user_id.clone(),
        public_url: config.public_url.clone(),
        upload_dir: config.upload_dir.clone(),
    });
    let delivery_state = state.clone();
    tokio::spawn(async move {
        loop {
            agent_gateway::ws::dispatch_due_messages(delivery_state.clone()).await;
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    });
    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/v1/health", get(health))
        .route("/api/v1/meta", get(meta))
        .route("/api/v1/capabilities", get(capabilities))
        .route("/api/v1/auth/register", post(register))
        .route("/api/v1/auth/login", post(login))
        .route("/api/v1/auth/logout", post(logout))
        .route("/api/v1/auth/session", get(current_session))
        .route("/api/v1/tasks", get(list_tasks).post(create_task))
        .route("/api/v1/tasks/{id}", patch(update_task).delete(delete_task))
        .route("/api/v1/projects", get(list_projects).post(create_project))
        .route(
            "/api/v1/projects/{id}",
            patch(update_project).delete(delete_project),
        )
        .route("/api/v1/projects/{id}/summary", get(project_summary))
        .route(
            "/api/v1/projects/{project_id}/milestones",
            get(list_milestones).post(create_milestone),
        )
        .route(
            "/api/v1/projects/{project_id}/milestones/{id}",
            get(get_milestone)
                .patch(update_milestone)
                .delete(delete_milestone),
        )
        .route(
            "/api/v1/calendar-events",
            get(list_events).post(create_event),
        )
        .route(
            "/api/v1/calendar-events/{id}",
            patch(update_event).delete(delete_event),
        )
        .route("/api/v1/schedules", get(list_events).post(create_event))
        .route(
            "/api/v1/schedules/{id}",
            patch(update_event).delete(delete_event),
        )
        .route(
            "/api/v1/conversations",
            get(list_conversations).post(create_conversation),
        )
        .route(
            "/api/v1/conversations/{id}",
            patch(rename_conversation).delete(delete_conversation),
        )
        .route("/api/v1/sync/events", get(sync_events))
        .route("/api/v1/sync/snapshot", get(sync_snapshot))
        .route(
            "/api/v1/conversations/{conversation_id}/messages",
            get(list_messages).post(create_message),
        )
        .route(
            "/api/v1/conversations/{conversation_id}/attachments",
            post(upload_attachments),
        )
        .route(
            "/api/v1/attachments/{id}/download",
            get(download_attachment),
        )
        .layer(DefaultBodyLimit::max(MAX_ATTACHMENT_REQUEST_BYTES))
        .route("/api/v1/agent/devices", get(list_agent_devices))
        .route(
            "/api/v1/agent/devices/{device_id}/select",
            post(select_agent_device),
        )
        .route("/api/v1/ws", get(mobile_realtime::upgrade))
        .route("/api/v1/mobile/ws", get(mobile_realtime::upgrade))
        .route("/api/v1/agent/ws", get(agent_gateway::ws::upgrade))
        .route(
            "/api/v1/agent/debug/message",
            post(agent_gateway::ws::debug_message),
        )
        .fallback(not_found)
        .with_state(state);
    info!(service = SERVICE_NAME, %address, public_url = %config.public_url, "Orialis server listening");
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("failed to bind listener");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("Orialis server failed");
}

async fn health(State(state): State<Arc<AppState>>) -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        service: SERVICE_NAME,
        version: VERSION,
        environment: state.metadata.environment.clone(),
    })
}

async fn meta(State(state): State<Arc<AppState>>) -> Json<ServiceMetadata> {
    Json(state.metadata.clone())
}

async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        service: SERVICE_NAME,
        api_version: API_VERSION,
        web: false,
        capabilities: vec![
            "health",
            "metadata",
            "auth",
            "tasks",
            "projects",
            "calendar-events",
            "schedules",
            "incremental-sync",
            "messages",
            "conversations",
            "attachments",
            "agent-devices",
            "websocket",
        ],
    })
}

fn now() -> String {
    Utc::now().to_rfc3339()
}

fn new_id() -> String {
    Uuid::now_v7().to_string()
}

fn hash_token(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

fn mutation_id(headers: &HeaderMap) -> Option<String> {
    headers
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

async fn reject_replayed_mutation(
    pool: &SqlitePool,
    user_id: &str,
    headers: &HeaderMap,
) -> Result<(), AppError> {
    let Some(mutation_id) = mutation_id(headers) else {
        return Ok(());
    };
    let already_used = sqlx::query_scalar::<_, i64>(
        "SELECT EXISTS(SELECT 1 FROM sync_events WHERE user_id=? AND mutation_id=?)",
    )
    .bind(user_id)
    .bind(mutation_id)
    .fetch_one(pool)
    .await?;
    if already_used != 0 {
        return Err(AppError::Conflict(
            "Idempotency-Key was already used".into(),
        ));
    }
    Ok(())
}

fn validate_credentials(username: &str, password: &str) -> Result<(), AppError> {
    if !(3..=32).contains(&username.chars().count()) {
        return Err(AppError::BadRequest(
            "username must be 3-32 characters".into(),
        ));
    }
    if !(8..=128).contains(&password.chars().count()) {
        return Err(AppError::BadRequest(
            "password must be 8-128 characters".into(),
        ));
    }
    Ok(())
}

fn password_hash(password: &str) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut OsRng);
    Scrypt
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| AppError::BadRequest("password could not be hashed".into()))
}

fn verify_password(password: &str, encoded: &str) -> bool {
    PasswordHash::new(encoded)
        .ok()
        .map(|parsed| Scrypt.verify_password(password.as_bytes(), &parsed).is_ok())
        .unwrap_or(false)
}

async fn authenticated_user(headers: &HeaderMap, pool: &SqlitePool) -> Result<String, AppError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Session "))
        .or_else(|| {
            headers
                .get("cookie")
                .and_then(|value| value.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .find_map(|item| item.trim().strip_prefix("orialis_session="))
                })
        });
    if let Some(token) = token {
        return sqlx::query_scalar::<_, String>(
            "SELECT user_id FROM user_sessions
             WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?",
        )
        .bind(hash_token(token))
        .bind(now())
        .fetch_optional(pool)
        .await?
        .ok_or(AppError::Unauthorized);
    }
    if !development_device_auth_enabled() {
        return Err(AppError::Unauthorized);
    }
    let device_id = headers
        .get("x-orialis-device-id")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(AppError::Unauthorized)?;
    let digest = format!("{:x}", Sha256::digest(device_id.as_bytes()));
    let username = format!("device_{}", &digest[..24]);
    if let Some(user_id) = sqlx::query_scalar::<_, String>("SELECT id FROM users WHERE username=?")
        .bind(&username)
        .fetch_optional(pool)
        .await?
    {
        return Ok(user_id);
    }
    let user_id = new_id();
    sqlx::query(
        "INSERT OR IGNORE INTO users (id,username,password_hash,created_at,updated_at)
         VALUES (?,?,?,?,?)",
    )
    .bind(&user_id)
    .bind(&username)
    .bind("device-auth-only")
    .bind(now())
    .bind(now())
    .execute(pool)
    .await?;
    sqlx::query_scalar::<_, String>("SELECT id FROM users WHERE username=?")
        .bind(username)
        .fetch_one(pool)
        .await
        .map_err(AppError::from)
}

/// Accept the configured Agent token for HTTP attachment operations. The
/// WebSocket uses the same token, but upload/download also need an owner so
/// an Agent cannot access another user's files.
async fn authenticated_user_or_agent(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<String, AppError> {
    if let Ok(user_id) = authenticated_user(headers, &state.pool).await {
        return Ok(user_id);
    }
    let valid_agent_token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split_once(' '))
        .is_some_and(|(scheme, token)| {
            scheme.eq_ignore_ascii_case("bearer")
                && state.agent_device_token.as_deref() == Some(token)
                && !token.is_empty()
        });
    if !valid_agent_token {
        return Err(AppError::Unauthorized);
    }
    if let Some(user_id) = state.agent_user_id.as_deref() {
        let exists = sqlx::query_scalar::<_, i64>("SELECT EXISTS(SELECT 1 FROM users WHERE id=?)")
            .bind(user_id)
            .fetch_one(&state.pool)
            .await?;
        return (exists != 0)
            .then(|| user_id.to_owned())
            .ok_or(AppError::Unauthorized);
    }
    let users =
        sqlx::query_scalar::<_, String>("SELECT id FROM users ORDER BY created_at,id LIMIT 2")
            .fetch_all(&state.pool)
            .await?;
    if users.len() == 1 {
        Ok(users[0].clone())
    } else {
        Err(AppError::Unauthorized)
    }
}

fn development_device_auth_enabled() -> bool {
    matches!(
        std::env::var("ORIALIS_DEV_DEVICE_AUTH").as_deref(),
        Ok("1") | Ok("true") | Ok("TRUE") | Ok("yes") | Ok("YES")
    )
}

async fn append_event<'e, E>(
    executor: E,
    user_id: &str,
    entity_type: &str,
    entity_id: &str,
    operation: &str,
    entity_version: i64,
    payload_json: Option<String>,
    mutation_id: Option<String>,
) -> Result<(), AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    let timestamp = now();
    let tombstone = operation == "delete";
    sqlx::query(
        "INSERT INTO sync_events
         (id,user_id,cursor,entity_type,entity_id,operation,entity_version,tombstone,payload_json,mutation_id,deleted_at,created_at,updated_at,version)
         VALUES (?,?,(SELECT COALESCE(MAX(cursor),0)+1 FROM sync_events WHERE user_id=?),?,?,?,?,?,?,?,?,?,?,1)",
    )
    .bind(new_id())
    .bind(user_id)
    .bind(user_id)
    .bind(entity_type)
    .bind(entity_id)
    .bind(operation)
    .bind(entity_version)
    .bind(tombstone)
    .bind(payload_json)
    .bind(mutation_id)
    .bind(if tombstone { Some(timestamp.clone()) } else { None::<String> })
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(executor)
    .await?;
    Ok(())
}

async fn notify_sync_change(state: &AppState, user_id: &str, entity: Option<&str>) {
    let cursor = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE(MAX(cursor), 0) FROM sync_events WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_one(&state.pool)
    .await;
    match cursor {
        Ok(cursor) if cursor > 0 => state.mobile.notify(
            user_id,
            agent_gateway::protocol::mobile_sync_change_hint(cursor, entity),
        ),
        Ok(_) => {}
        Err(error) => {
            tracing::warn!(%error, "could not read sync cursor for realtime notification")
        }
    }
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(input): Json<Credentials>,
) -> Result<(StatusCode, Json<SessionResponse>), AppError> {
    validate_credentials(&input.username, &input.password)?;
    let id = new_id();
    let timestamp = now();
    let result = sqlx::query(
        "INSERT INTO users (id,username,password_hash,created_at,updated_at)
         VALUES (?,?,?,?,?)",
    )
    .bind(&id)
    .bind(input.username.trim())
    .bind(password_hash(&input.password)?)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&state.pool)
    .await;
    if let Err(sqlx::Error::Database(error)) = &result {
        if error.is_unique_violation() {
            return Err(AppError::Conflict("username already exists".into()));
        }
    }
    result?;
    Ok((
        StatusCode::CREATED,
        Json(create_session(&state.pool, &id).await?),
    ))
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(input): Json<Credentials>,
) -> Result<Json<SessionResponse>, AppError> {
    let row = sqlx::query_as::<_, (String, String)>(
        "SELECT id,password_hash FROM users WHERE username = ?",
    )
    .bind(input.username.trim())
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::Unauthorized)?;
    if !verify_password(&input.password, &row.1) {
        return Err(AppError::Unauthorized);
    }
    Ok(Json(create_session(&state.pool, &row.0).await?))
}

async fn create_session(pool: &SqlitePool, user_id: &str) -> Result<SessionResponse, AppError> {
    let token = format!("{}{}", Uuid::now_v7().simple(), Uuid::new_v4().simple());
    let expires_at = (Utc::now() + Duration::days(30)).to_rfc3339();
    sqlx::query(
        "INSERT INTO user_sessions
         (id,user_id,token_hash,expires_at,created_at,updated_at)
         VALUES (?,?,?,?,?,?)",
    )
    .bind(new_id())
    .bind(user_id)
    .bind(hash_token(&token))
    .bind(&expires_at)
    .bind(now())
    .bind(now())
    .execute(pool)
    .await?;
    Ok(SessionResponse {
        user_id: user_id.into(),
        access_token: token,
        expires_at,
    })
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<StatusCode, AppError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Session "))
        .ok_or(AppError::Unauthorized)?;
    sqlx::query("UPDATE user_sessions SET revoked_at=?,updated_at=? WHERE token_hash=?")
        .bind(now())
        .bind(now())
        .bind(hash_token(token))
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn current_session(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let row = sqlx::query_as::<_, (String, String)>("SELECT id,username FROM users WHERE id = ?")
        .bind(&user_id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(AppError::Unauthorized)?;
    Ok(Json(
        serde_json::json!({ "userId": row.0, "username": row.1 }),
    ))
}

async fn ensure_default_conversation(pool: &SqlitePool, user_id: &str) -> Result<(), AppError> {
    sqlx::query("INSERT INTO conversations (id,user_id,title,is_default,created_at,updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(user_id,id) DO NOTHING")
        .bind(DEFAULT_CONVERSATION_ID).bind(user_id).bind("主会话").bind(true).bind(now()).bind(now())
        .execute(pool).await?;
    Ok(())
}

async fn ensure_conversation(
    pool: &SqlitePool,
    user_id: &str,
    conversation_id: &str,
) -> Result<(), AppError> {
    ensure_default_conversation(pool, user_id).await?;
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM conversations WHERE user_id=? AND id=? AND deleted_at IS NULL)",
    )
    .bind(user_id)
    .bind(conversation_id)
    .fetch_one(pool)
    .await?;
    if !exists {
        return Err(AppError::NotFound);
    }
    Ok(())
}

async fn list_conversations(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<Conversation>>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    ensure_default_conversation(&state.pool, &user_id).await?;
    let items = sqlx::query_as::<_, Conversation>("SELECT id,title,is_default,CASE WHEN is_default=1 THEN 'main' ELSE 'normal' END AS conversation_type,created_at,updated_at,version FROM conversations WHERE user_id=? AND deleted_at IS NULL ORDER BY is_default DESC,updated_at DESC,id")
        .bind(user_id).fetch_all(&state.pool).await?;
    Ok(Json(items))
}

async fn create_conversation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<ConversationInput>,
) -> Result<(StatusCode, Json<Conversation>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let title = input.title.trim();
    if title.is_empty() {
        return Err(AppError::BadRequest("title is required".into()));
    }
    let id = input.id.unwrap_or_else(new_id);
    let timestamp = now();
    sqlx::query(
        "INSERT INTO conversations (id,user_id,title,created_at,updated_at) VALUES (?,?,?,?,?)",
    )
    .bind(&id)
    .bind(&user_id)
    .bind(title)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&state.pool)
    .await?;
    let item = sqlx::query_as::<_, Conversation>("SELECT id,title,is_default,CASE WHEN is_default=1 THEN 'main' ELSE 'normal' END AS conversation_type,created_at,updated_at,version FROM conversations WHERE user_id=? AND id=?")
        .bind(&user_id).bind(&id).fetch_one(&state.pool).await?;
    Ok((StatusCode::CREATED, Json(item)))
}

async fn rename_conversation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<ConversationPatch>,
) -> Result<Json<Conversation>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let title = input.title.trim();
    if title.is_empty() {
        return Err(AppError::BadRequest("title is required".into()));
    }
    let result = sqlx::query("UPDATE conversations SET title=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND deleted_at IS NULL")
        .bind(title).bind(now()).bind(&user_id).bind(&id).execute(&state.pool).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::NotFound);
    }
    let item = sqlx::query_as::<_, Conversation>("SELECT id,title,is_default,CASE WHEN is_default=1 THEN 'main' ELSE 'normal' END AS conversation_type,created_at,updated_at,version FROM conversations WHERE user_id=? AND id=?")
        .bind(user_id).bind(id).fetch_one(&state.pool).await?;
    Ok(Json(item))
}

async fn delete_conversation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    ensure_default_conversation(&state.pool, &user_id).await?;
    if id == DEFAULT_CONVERSATION_ID {
        return Err(AppError::Conflict(
            "default conversation cannot be deleted".into(),
        ));
    }
    let result = sqlx::query("UPDATE conversations SET deleted_at=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND deleted_at IS NULL")
        .bind(now()).bind(now()).bind(&user_id).bind(&id).execute(&state.pool).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn list_agent_devices(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<AgentDevicesResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    agent_devices_for_user(&state, &user_id).await.map(Json)
}

async fn agent_devices_for_user(
    state: &AppState,
    user_id: &str,
) -> Result<AgentDevicesResponse, AppError> {
    let active_device_id = sqlx::query_scalar::<_, Option<String>>(
        "SELECT active_device_id FROM agent_preferences WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?
    .flatten();
    let records = sqlx::query_as::<_, AgentDeviceRecord>(
        "SELECT device_id,platform,client,plugin_version,last_seen_at
         FROM agent_devices WHERE user_id=? ORDER BY updated_at DESC,device_id",
    )
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;
    let online = state.agent.online_agents(user_id).await;
    let devices = records
        .into_iter()
        .map(|record| {
            let is_online = online
                .iter()
                .any(|agent| agent.device_id == record.device_id);
            AgentDeviceResponse {
                active: active_device_id.as_deref() == Some(record.device_id.as_str()),
                device_id: record.device_id,
                platform: record.platform,
                client: record.client,
                plugin_version: record.plugin_version,
                last_seen_at: record.last_seen_at,
                online: is_online,
            }
        })
        .collect();
    Ok(AgentDevicesResponse {
        devices,
        active_device_id,
    })
}

async fn select_agent_device(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<AgentDevicesResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let device_id = device_id.trim();
    if device_id.is_empty() {
        return Err(AppError::BadRequest("device_id is required".into()));
    }
    let exists = sqlx::query_scalar::<_, i64>(
        "SELECT EXISTS(SELECT 1 FROM agent_devices WHERE user_id=? AND device_id=?)",
    )
    .bind(&user_id)
    .bind(device_id)
    .fetch_one(&state.pool)
    .await?;
    if exists == 0 {
        return Err(AppError::NotFound);
    }
    sqlx::query(
        "INSERT INTO agent_preferences (user_id,active_device_id,created_at,updated_at)
         VALUES (?,?,?,?)
         ON CONFLICT(user_id) DO UPDATE SET active_device_id=excluded.active_device_id,
             updated_at=excluded.updated_at, version=agent_preferences.version+1",
    )
    .bind(&user_id)
    .bind(device_id)
    .bind(now())
    .bind(now())
    .execute(&state.pool)
    .await?;
    state.mobile.notify(
        &user_id,
        agent_gateway::protocol::mobile_event(serde_json::json!({
            "kind": "agent_devices_changed",
            "reason": "selected",
            "activeDeviceId": device_id,
        })),
    );
    Ok(Json(agent_devices_for_user(&state, &user_id).await?))
}

async fn list_messages(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(conversation_id): Path<String>,
) -> Result<Json<Vec<Message>>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    ensure_conversation(&state.pool, &user_id, &conversation_id).await?;
    let messages = sqlx::query_as::<_, MessageRow>(
        "SELECT id,conversation_id,role,content,created_at,version,attachments_json
         FROM messages WHERE user_id=? AND conversation_id=?
         ORDER BY created_at,id",
    )
    .bind(&user_id)
    .bind(conversation_id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(
        messages.into_iter().map(MessageRow::into_message).collect(),
    ))
}

async fn create_message(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(conversation_id): Path<String>,
    Json(input): Json<MessageInput>,
) -> Result<(StatusCode, Json<Message>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    ensure_conversation(&state.pool, &user_id, &conversation_id).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let content = input.content.trim();
    if content.is_empty() && input.attachments.is_empty() {
        return Err(AppError::BadRequest("content is required".into()));
    }
    if conversation_id.trim().is_empty() {
        return Err(AppError::BadRequest("conversationId is required".into()));
    }
    if input.attachments.len() > MAX_ATTACHMENT_COUNT {
        return Err(AppError::BadRequest("too many attachments".into()));
    }
    let mut canonical_attachments = Vec::with_capacity(input.attachments.len());
    for attachment in &input.attachments {
        canonical_attachments
            .push(canonical_attachment(&state, &user_id, &conversation_id, attachment).await?);
    }
    let attachments_json = serde_json::to_string(&canonical_attachments)
        .map_err(|_| AppError::BadRequest("invalid attachments".into()))?;
    let id = input.id.unwrap_or_else(new_id);
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "INSERT INTO messages (id,user_id,conversation_id,role,content,attachments_json)
         VALUES (?,?,?,'user',?,?) ON CONFLICT(id) DO NOTHING",
    )
    .bind(&id)
    .bind(&user_id)
    .bind(&conversation_id)
    .bind(content)
    .bind(&attachments_json)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() == 0 {
        let existing = sqlx::query_as::<_, MessageRow>(
            "SELECT id,conversation_id,role,content,created_at,version,attachments_json
             FROM messages WHERE user_id=? AND id=? AND conversation_id=?",
        )
        .bind(&user_id)
        .bind(&id)
        .bind(&conversation_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| AppError::Conflict("message id already used".into()))?;
        tx.rollback().await?;
        return Ok((StatusCode::OK, Json(existing.into_message())));
    }
    sqlx::query(
        "INSERT INTO agent_delivery_queue
         (message_id,user_id,conversation_id,attempts,next_attempt_at)
         VALUES (?,?,?,0,?)",
    )
    .bind(&id)
    .bind(&user_id)
    .bind(&conversation_id)
    .bind(&timestamp)
    .execute(&mut *tx)
    .await?;
    let message = sqlx::query_as::<_, MessageRow>(
        "SELECT id,conversation_id,role,content,created_at,version,attachments_json
         FROM messages WHERE user_id=? AND id=? AND conversation_id=?",
    )
    .bind(&user_id)
    .bind(&id)
    .bind(&conversation_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    let message = message.into_message();
    state.mobile.notify(
        &user_id,
        agent_gateway::protocol::mobile_message(serde_json::to_value(&message).unwrap()),
    );
    let dispatch_state = state.clone();
    let dispatch_user_id = user_id.clone();
    let dispatch_conversation_id = conversation_id.clone();
    let dispatch_id = message.id.clone();
    let dispatch_content = message.content.clone();
    let dispatch_attachments = message
        .attachments
        .iter()
        .map(|attachment| agent_gateway::protocol::GatewayAttachment {
            id: attachment.id.clone(),
            name: attachment.name.clone(),
            mime_type: attachment.mime_type.clone(),
            size: attachment.size,
            download_url: attachment.download_url.clone(),
        })
        .collect();
    tokio::spawn(async move {
        agent_gateway::ws::dispatch_message(
            dispatch_state,
            dispatch_user_id,
            dispatch_conversation_id,
            dispatch_id,
            dispatch_content,
            dispatch_attachments,
        )
        .await;
    });
    Ok((StatusCode::CREATED, Json(message)))
}

async fn upload_attachments(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(conversation_id): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<AttachmentUploadResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    ensure_conversation(&state.pool, &user_id, &conversation_id).await?;
    if conversation_id.trim().is_empty() {
        return Err(AppError::BadRequest("conversationId is required".into()));
    }
    let idempotency_key = mutation_id(&headers);
    if let Some(key) = &idempotency_key {
        if key.len() > 200 {
            return Err(AppError::BadRequest("Idempotency-Key is too long".into()));
        }
        if let Some(response_json) = sqlx::query_scalar::<_, String>(
            "SELECT response_json FROM attachment_uploads
             WHERE user_id=? AND conversation_id=? AND idempotency_key=?",
        )
        .bind(&user_id)
        .bind(&conversation_id)
        .bind(key)
        .fetch_optional(&state.pool)
        .await?
        {
            return serde_json::from_str(&response_json)
                .map(|response| Ok(Json(response)))
                .map_err(|_| AppError::BadRequest("invalid stored upload response".into()))?;
        }
    }
    tokio::fs::create_dir_all(&state.upload_dir)
        .await
        .map_err(|error| {
            AppError::ServiceUnavailable(format!("attachment storage unavailable: {error}"))
        })?;

    let mut items = Vec::new();
    let mut stored_paths = Vec::new();
    let mut transaction = state.pool.begin().await?;
    let result: Result<AttachmentUploadResponse, AppError> = async {
    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|_| AppError::BadRequest("invalid multipart upload".into()))?
    {
        if items.len() >= MAX_ATTACHMENT_COUNT {
            return Err(AppError::BadRequest("too many attachments".into()));
        }
        let Some(file_name) = field.file_name() else {
            continue;
        };
        // Multipart clients on Windows may send a backslash-separated path,
        // while Unix Path::file_name only strips forward slashes. Normalize
        // both separators at the HTTP boundary before persisting metadata.
        let name = file_name
            .rsplit(|character| character == '/' || character == '\\')
            .next()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("文件")
            .chars()
            .take(180)
            .collect::<String>();
        let mime_type = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_owned();
        let id = new_id();
        let access_token = Uuid::new_v4().simple().to_string();
        let storage_path = state.upload_dir.join(format!("{id}.bin"));
        let mut file = tokio::fs::File::create(&storage_path).await.map_err(|error| {
            AppError::ServiceUnavailable(format!("could not store attachment: {error}"))
        })?;
        stored_paths.push(storage_path.clone());
        let mut size = 0usize;
        while let Some(chunk) = field.chunk().await.map_err(|_| AppError::BadRequest("could not read attachment".into()))? {
            size = size.saturating_add(chunk.len());
            let total = items.iter().map(|item: &Attachment| item.size as usize).sum::<usize>() + size;
            if size > MAX_ATTACHMENT_BYTES {
                return Err(AppError::BadRequest("attachment exceeds 20 MB".into()));
            }
            if total > MAX_TOTAL_ATTACHMENT_BYTES {
                return Err(AppError::BadRequest("attachments exceed 48 MB total".into()));
            }
            file.write_all(&chunk).await.map_err(|error| AppError::ServiceUnavailable(format!("could not store attachment: {error}")))?;
        }
        if size == 0 {
            return Err(AppError::BadRequest("attachment cannot be empty".into()));
        }
        file.flush().await.map_err(|error| AppError::ServiceUnavailable(format!("could not store attachment: {error}")))?;
        sqlx::query(
            "INSERT INTO attachments
             (id,user_id,conversation_id,original_name,mime_type,size_bytes,storage_path,access_token_hash)
             VALUES (?,?,?,?,?,?,?,?)",
        )
        .bind(&id)
        .bind(&user_id)
        .bind(&conversation_id)
        .bind(&name)
        .bind(&mime_type)
        .bind(size as i64)
        .bind(storage_path.to_string_lossy().as_ref())
        .bind(hash_token(&access_token))
        .execute(&mut *transaction)
        .await?;

        let download_url = format!(
            "{}/api/v1/attachments/{id}/download",
            state.public_url.trim_end_matches('/')
        );
        items.push(Attachment {
            id,
            name,
            mime_type,
            size: size as i64,
            download_url,
        });
    }
    if items.is_empty() {
        return Err(AppError::BadRequest("no files uploaded".into()));
    }
    Ok(AttachmentUploadResponse { items })
    }.await;
    let response = match result {
        Ok(response) => response,
        Err(error) => {
            for path in stored_paths {
                let _ = tokio::fs::remove_file(path).await;
            }
            return Err(error);
        }
    };
    if let Some(key) = idempotency_key {
        if let Err(error) = sqlx::query(
            "INSERT INTO attachment_uploads
             (user_id,conversation_id,idempotency_key,response_json)
             VALUES (?,?,?,?)",
        )
        .bind(&user_id)
        .bind(&conversation_id)
        .bind(key)
        .bind(
            serde_json::to_string(&response)
                .map_err(|_| AppError::BadRequest("invalid upload response".into()))?,
        )
        .execute(&mut *transaction)
        .await
        {
            for path in stored_paths {
                let _ = tokio::fs::remove_file(path).await;
            }
            return Err(AppError::from(error));
        }
    }
    if let Err(error) = transaction.commit().await {
        for path in stored_paths {
            let _ = tokio::fs::remove_file(path).await;
        }
        return Err(AppError::from(error));
    }
    Ok(Json(response))
}

async fn canonical_attachment(
    state: &AppState,
    user_id: &str,
    conversation_id: &str,
    attachment: &AttachmentInput,
) -> Result<Attachment, AppError> {
    let row = sqlx::query_as::<_, (String, String, i64, String)>(
        "SELECT original_name,mime_type,size_bytes,conversation_id
         FROM attachments WHERE id=? AND user_id=?",
    )
    .bind(&attachment.id)
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(|| AppError::BadRequest("attachment is not owned by this user".into()))?;
    if row.3 != conversation_id {
        return Err(AppError::BadRequest(
            "attachment does not belong to this conversation".into(),
        ));
    }
    Ok(Attachment {
        id: attachment.id.clone(),
        name: row.0,
        mime_type: row.1,
        size: row.2,
        download_url: format!(
            "{}/api/v1/attachments/{}/download",
            state.public_url.trim_end_matches('/'),
            attachment.id
        ),
    })
}

fn attachment_download_token<'a>(
    public_url: &str,
    id: &str,
    download_url: &'a str,
) -> Option<&'a str> {
    let prefix = format!(
        "{}/api/v1/attachments/{id}/download?token=",
        public_url.trim_end_matches('/')
    );
    download_url
        .strip_prefix(&prefix)
        .filter(|token| !token.is_empty() && !token.contains('&'))
}

async fn download_attachment(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<DownloadQuery>,
) -> Result<Response, AppError> {
    let row = sqlx::query_as::<_, (String, String, String, String)>(
        "SELECT user_id,mime_type,storage_path,access_token_hash
         FROM attachments WHERE id=?",
    )
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::NotFound)?;
    let session_user = authenticated_user_or_agent(&headers, &state).await.ok();
    let token_valid = query
        .token
        .as_deref()
        .is_some_and(|token| hash_token(token) == row.3);
    if session_user.as_deref() != Some(row.0.as_str()) && !token_valid {
        return Err(AppError::Unauthorized);
    }
    let root = tokio::fs::canonicalize(&state.upload_dir)
        .await
        .map_err(|_| AppError::NotFound)?;
    let path = tokio::fs::canonicalize(&row.2)
        .await
        .map_err(|_| AppError::NotFound)?;
    if !path.starts_with(&root) {
        return Err(AppError::NotFound);
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|_| AppError::NotFound)?;
    Ok((
        [(axum::http::header::CONTENT_TYPE, row.1)],
        Body::from(bytes),
    )
        .into_response())
}

async fn list_tasks(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<TaskListQuery>,
) -> Result<Json<TaskListResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(AppError::BadRequest(
            "limit must be between 1 and 100".into(),
        ));
    }
    let cursor = query.after.map(decode_task_cursor).transpose()?;
    let fetch_limit = limit + 1;
    let mut tasks = if let Some(cursor) = cursor {
        sqlx::query_as::<_, Task>(
            "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                    reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version
             FROM tasks
             WHERE user_id=? AND deleted_at IS NULL
               AND (due IS NULL,COALESCE(due,''),due_time IS NULL,
                    COALESCE(due_time,''),created_at,id) > (?,?,?,?,?,?)
             ORDER BY due IS NULL,due,due_time IS NULL,due_time,created_at,id
             LIMIT ?",
        )
        .bind(&user_id)
        .bind(cursor.due_is_null as i64)
        .bind(cursor.due.unwrap_or_default())
        .bind(cursor.due_time_is_null as i64)
        .bind(cursor.due_time.unwrap_or_default())
        .bind(cursor.created_at)
        .bind(cursor.id)
        .bind(fetch_limit)
        .fetch_all(&state.pool)
        .await?
    } else {
        sqlx::query_as::<_, Task>(
            "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                    reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version
             FROM tasks WHERE user_id=? AND deleted_at IS NULL
             ORDER BY due IS NULL,due,due_time IS NULL,due_time,created_at,id
             LIMIT ?",
        )
        .bind(&user_id)
        .bind(fetch_limit)
        .fetch_all(&state.pool)
        .await?
    };
    let has_more = tasks.len() > limit as usize;
    if has_more {
        tasks.pop();
    }
    let next_cursor = has_more
        .then(|| tasks.last().map(task_cursor).map(encode_task_cursor))
        .flatten()
        .transpose()?;
    Ok(Json(TaskListResponse {
        items: tasks,
        next_cursor,
        has_more,
    }))
}

fn task_cursor(task: &Task) -> TaskCursor {
    TaskCursor {
        v: 1,
        due_is_null: task.due.is_none(),
        due: task.due.clone(),
        due_time_is_null: task.due_time.is_none(),
        due_time: task.due_time.clone(),
        created_at: task.created_at.clone(),
        id: task.id.clone(),
    }
}

fn encode_task_cursor(cursor: TaskCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid task cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

fn decode_task_cursor(value: String) -> Result<TaskCursor, AppError> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AppError::BadRequest("invalid task cursor".into()))?;
    let cursor: TaskCursor = serde_json::from_slice(&payload)
        .map_err(|_| AppError::BadRequest("invalid task cursor".into()))?;
    if cursor.v != 1
        || cursor.due_is_null != cursor.due.is_none()
        || cursor.due_time_is_null != cursor.due_time.is_none()
        || cursor.id.is_empty()
        || cursor.created_at.is_empty()
    {
        return Err(AppError::BadRequest("invalid task cursor".into()));
    }
    Ok(cursor)
}

async fn fetch_task<'e, E>(executor: E, user_id: &str, id: &str) -> Result<Task, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, Task>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version
         FROM tasks WHERE user_id=? AND id=? AND deleted_at IS NULL",
    )
    .bind(user_id)
    .bind(id)
    .fetch_optional(executor)
    .await?
    .ok_or(AppError::NotFound)
}

async fn create_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<TaskInput>,
) -> Result<(StatusCode, Json<Task>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    if input.title.trim().is_empty() {
        return Err(AppError::BadRequest("title is required".into()));
    }
    if input.title.trim().chars().count() > 120 {
        return Err(AppError::BadRequest(
            "title must be at most 120 characters".into(),
        ));
    }
    if input.due.is_none() && input.due_time.is_some() {
        return Err(AppError::BadRequest("due_time requires due".into()));
    }
    validate_date("due", input.due.as_deref())?;
    validate_time("dueTime", input.due_time.as_deref())?;
    validate_reminder(input.reminder_minutes)?;
    if let Some(project_id) = input.project_id.as_deref() {
        ensure_project(&state.pool, &user_id, project_id).await?;
    }
    let id = input.id.unwrap_or_else(new_id);
    let timestamp = now();
    let completed = input.completed.unwrap_or(false);
    let completed_at = if completed {
        let completed_at = input.completed_at.unwrap_or_else(|| timestamp.clone());
        validate_timestamp("completedAt", &completed_at)?;
        Some(completed_at)
    } else {
        None
    };
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "INSERT INTO tasks
         (id,user_id,title,notes,important,urgent,completed,completed_at,due,due_time,
          reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
         ON CONFLICT(id) DO NOTHING",
    )
    .bind(&id)
    .bind(&user_id)
    .bind(input.title.trim())
    .bind(input.notes)
    .bind(input.important.unwrap_or(false))
    .bind(input.urgent.unwrap_or(false))
    .bind(completed)
    .bind(completed_at)
    .bind(input.due)
    .bind(input.due_time)
    .bind(input.reminder_minutes)
    .bind(input.project_id)
    .bind(input.recurrence.map(|value| value.to_string()))
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() == 0 {
        let existing = fetch_task(&mut *tx, &user_id, &id).await?;
        tx.rollback().await?;
        return Ok((StatusCode::OK, Json(existing)));
    }
    let task = fetch_task(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "task",
        &id,
        "upsert",
        task.version,
        Some(serde_json::to_string(&task).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok((StatusCode::CREATED, Json(task)))
}

async fn update_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<TaskPatch>,
) -> Result<Json<Task>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_task(&state.pool, &user_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("task version changed".into()));
    }
    let title = resolve_required(input.title, current.title, "title")?;
    let notes = resolve_nullable(input.notes, current.notes);
    let important = resolve_required(input.important, current.important, "important")?;
    let urgent = resolve_required(input.urgent, current.urgent, "urgent")?;
    let completed = resolve_required(input.completed, current.completed, "completed")?;
    let completed_at = if completed {
        match input.completed_at {
            Some(PatchValue::Value(value)) => {
                validate_timestamp("completedAt", &value)?;
                Some(value)
            }
            Some(PatchValue::Null(())) => Some(now()),
            None => match (current.completed, completed) {
                (false, true) => Some(now()),
                (true, true) => current.completed_at,
                _ => None,
            },
        }
    } else {
        None
    };
    let due = resolve_nullable(input.due, current.due);
    let due_time = resolve_nullable(input.due_time, current.due_time);
    let reminder_minutes = resolve_nullable(input.reminder_minutes, current.reminder_minutes);
    let project_id = resolve_nullable(input.project_id, current.project_id);
    let recurrence = match input.recurrence {
        None => current.recurrence_rule,
        Some(PatchValue::Value(value)) => Some(value.to_string()),
        Some(PatchValue::Null(())) => None,
    };
    validate_date("due", due.as_deref())?;
    validate_time("dueTime", due_time.as_deref())?;
    validate_reminder(reminder_minutes)?;
    if due.is_none() && due_time.is_some() {
        return Err(AppError::BadRequest("due_time requires due".into()));
    }
    if let Some(project_id) = project_id.as_deref() {
        ensure_project(&state.pool, &user_id, project_id).await?;
    }
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE tasks SET title=?,notes=?,important=?,urgent=?,completed=?,completed_at=?,due=?,due_time=?,
         reminder_minutes=?,project_id=?,recurrence_rule=?,updated_at=?,version=version+1
         WHERE user_id=? AND id=? AND version=?",
    )
    .bind(title.trim())
    .bind(notes)
    .bind(important)
    .bind(urgent)
    .bind(completed)
    .bind(completed_at)
    .bind(due)
    .bind(due_time)
    .bind(reminder_minutes)
    .bind(project_id)
    .bind(recurrence)
    .bind(now())
    .bind(&user_id)
    .bind(&id)
    .bind(input.base_version)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("task version changed".into()));
    }
    let task = fetch_task(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "task",
        &id,
        "upsert",
        task.version,
        Some(serde_json::to_string(&task).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok(Json(task))
}

async fn delete_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let task = fetch_task(&state.pool, &user_id, &id).await?;
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE tasks SET deleted_at=?,updated_at=?,version=version+1 WHERE user_id=? AND id=?",
    )
    .bind(&timestamp)
    .bind(&timestamp)
    .bind(&user_id)
    .bind(&id)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("task version changed".into()));
    }
    append_event(
        &mut *tx,
        &user_id,
        "task",
        &id,
        "delete",
        task.version + 1,
        None,
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_projects(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ProjectListQuery>,
) -> Result<Json<ProjectListResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(AppError::BadRequest(
            "limit must be between 1 and 100".into(),
        ));
    }
    let status = query.status.filter(|value| !value.trim().is_empty());
    if let Some(status) = &status {
        if !matches!(status.as_str(), "active" | "completed" | "archived") {
            return Err(AppError::BadRequest(
                "status must be active, completed, or archived".into(),
            ));
        }
    }
    let cursor = query.after.map(decode_project_cursor).transpose()?;
    let fetch_limit = limit + 1;
    let mut projects = sqlx::query_as::<_, Project>(
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,created_at,updated_at,version
         FROM projects
         WHERE user_id=? AND deleted_at IS NULL
           AND (? IS NULL OR status=?)
           AND (? IS NULL OR (created_at,id) > (?,?))
         ORDER BY created_at,id LIMIT ?",
    )
    .bind(&user_id)
    .bind(&status)
    .bind(&status)
    .bind(cursor.as_ref().map(|value| value.created_at.as_str()))
    .bind(cursor.as_ref().map(|value| value.created_at.as_str()))
    .bind(cursor.as_ref().map(|value| value.id.as_str()))
    .bind(fetch_limit)
    .fetch_all(&state.pool)
    .await?;
    let has_more = projects.len() > limit as usize;
    if has_more {
        projects.pop();
    }
    let next_cursor = has_more
        .then(|| {
            projects
                .last()
                .map(project_cursor)
                .map(encode_project_cursor)
        })
        .flatten()
        .transpose()?;
    Ok(Json(ProjectListResponse {
        items: projects,
        next_cursor,
        has_more,
    }))
}

fn project_cursor(project: &Project) -> ProjectCursor {
    ProjectCursor {
        v: 1,
        created_at: project.created_at.clone(),
        id: project.id.clone(),
    }
}

fn encode_project_cursor(cursor: ProjectCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid project cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

fn decode_project_cursor(value: String) -> Result<ProjectCursor, AppError> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AppError::BadRequest("invalid project cursor".into()))?;
    let cursor: ProjectCursor = serde_json::from_slice(&payload)
        .map_err(|_| AppError::BadRequest("invalid project cursor".into()))?;
    if cursor.v != 1 || cursor.created_at.is_empty() || cursor.id.is_empty() {
        return Err(AppError::BadRequest("invalid project cursor".into()));
    }
    Ok(cursor)
}

async fn fetch_project<'e, E>(executor: E, user_id: &str, id: &str) -> Result<Project, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, Project>(
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,created_at,updated_at,version
         FROM projects WHERE user_id=? AND id=? AND deleted_at IS NULL",
    ).bind(user_id).bind(id).fetch_optional(executor).await?.ok_or(AppError::NotFound)
}

async fn create_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<ProjectInput>,
) -> Result<(StatusCode, Json<Project>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    if input.name.trim().is_empty() {
        return Err(AppError::BadRequest("name is required".into()));
    }
    if input.name.trim().chars().count() > 120 {
        return Err(AppError::BadRequest(
            "name must be at most 120 characters".into(),
        ));
    }
    let status = input.status.as_deref().unwrap_or("active");
    validate_project_status(status)?;
    if input.next_action_task_id.is_some() {
        return Err(AppError::BadRequest(
            "nextActionTaskId must be null when creating a project".into(),
        ));
    }
    validate_date("startDate", input.start_date.as_deref())?;
    validate_date("due", input.due.as_deref())?;
    let id = new_id();
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    sqlx::query("INSERT INTO projects (id,user_id,name,goal,description,color,status,start_date,due,next_action_task_id,created_at,updated_at,version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)")
        .bind(&id).bind(&user_id).bind(input.name.trim()).bind(input.goal).bind(input.description).bind(input.color).bind(status).bind(input.start_date).bind(input.due).bind(None::<String>).bind(&timestamp).bind(&timestamp).execute(&mut *tx).await?;
    let project = fetch_project(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "project",
        &id,
        "upsert",
        project.version,
        Some(serde_json::to_string(&project).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project")).await;
    Ok((StatusCode::CREATED, Json(project)))
}

async fn update_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<ProjectPatch>,
) -> Result<Json<Project>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_project(&state.pool, &user_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("project version changed".into()));
    }
    let name = resolve_required(input.name, current.name, "name")?;
    let goal = resolve_nullable(input.goal, current.goal);
    let description = resolve_nullable(input.description, current.description);
    let color = resolve_nullable(input.color, current.color);
    let status = resolve_required(input.status, current.status, "status")?;
    let start_date = resolve_nullable(input.start_date, current.start_date);
    let due = resolve_nullable(input.due, current.due);
    let next_action_task_id =
        resolve_nullable(input.next_action_task_id, current.next_action_task_id);
    if name.trim().is_empty() || name.trim().chars().count() > 120 {
        return Err(AppError::BadRequest("name must be 1-120 characters".into()));
    }
    validate_project_status(&status)?;
    if let Some(task_id) = next_action_task_id.as_deref() {
        ensure_project_next_action(&state.pool, &user_id, &id, task_id).await?;
    }
    validate_date("startDate", start_date.as_deref())?;
    validate_date("due", due.as_deref())?;
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("UPDATE projects SET name=?,goal=?,description=?,color=?,status=?,start_date=?,due=?,next_action_task_id=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND version=?")
        .bind(name.trim()).bind(goal).bind(description).bind(color).bind(status).bind(start_date).bind(due).bind(next_action_task_id).bind(now()).bind(&user_id).bind(&id).bind(input.base_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("project version changed".into()));
    }
    let project = fetch_project(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "project",
        &id,
        "upsert",
        project.version,
        Some(serde_json::to_string(&project).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project")).await;
    Ok(Json(project))
}

async fn project_summary(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<ProjectSummary>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let project = fetch_project(&state.pool, &user_id, &id).await?;
    let (total_tasks, completed_tasks) = sqlx::query_as::<_, (i64, i64)>(
        "SELECT COUNT(*), COALESCE(SUM(completed),0)
         FROM tasks WHERE user_id=? AND project_id=? AND deleted_at IS NULL",
    )
    .bind(&user_id)
    .bind(&id)
    .fetch_one(&state.pool)
    .await?;
    let (total_milestones, completed_milestones) = sqlx::query_as::<_, (i64, i64)>(
        "SELECT COUNT(*), COALESCE(SUM(completed),0)
         FROM project_milestones m JOIN projects p ON p.id=m.project_id
         WHERE p.user_id=? AND p.id=? AND p.deleted_at IS NULL AND m.deleted_at IS NULL",
    )
    .bind(&user_id)
    .bind(&id)
    .fetch_one(&state.pool)
    .await?;
    let next_action = sqlx::query_as::<_, Task>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version
         FROM tasks
         WHERE user_id=? AND project_id=? AND deleted_at IS NULL AND completed=0
         ORDER BY due IS NULL,due,due_time IS NULL,due_time,created_at,id LIMIT 1",
    )
    .bind(&user_id)
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?;
    let total_units = total_tasks + total_milestones;
    let completed_units = completed_tasks + completed_milestones;
    let progress = if total_units == 0 {
        0.0
    } else {
        completed_units as f64 / total_units as f64 * 100.0
    };
    Ok(Json(ProjectSummary {
        project,
        total_tasks,
        completed_tasks,
        total_milestones,
        completed_milestones,
        total_units,
        completed_units,
        progress,
        next_action,
    }))
}

async fn delete_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let mut tx = state.pool.begin().await?;
    let project = fetch_project(&mut *tx, &user_id, &id).await?;
    let milestones = sqlx::query_as::<_, (String, i64)>(
        "SELECT id,version FROM project_milestones
         WHERE project_id=? AND deleted_at IS NULL",
    )
    .bind(&id)
    .fetch_all(&mut *tx)
    .await?;
    let timestamp = now();
    let result = sqlx::query(
        "UPDATE projects SET deleted_at=?,updated_at=?,version=version+1 WHERE user_id=? AND id=?",
    )
    .bind(&timestamp)
    .bind(&timestamp)
    .bind(&user_id)
    .bind(&id)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("project version changed".into()));
    }
    sqlx::query(
        "UPDATE project_milestones
         SET deleted_at=?,updated_at=?,version=version+1
         WHERE project_id=? AND deleted_at IS NULL",
    )
    .bind(&timestamp)
    .bind(&id)
    .execute(&mut *tx)
    .await?;
    for (milestone_id, version) in milestones {
        append_event(
            &mut *tx,
            &user_id,
            "project_milestone",
            &milestone_id,
            "delete",
            version + 1,
            None,
            None,
        )
        .await?;
    }
    append_event(
        &mut *tx,
        &user_id,
        "project",
        &id,
        "delete",
        project.version + 1,
        None,
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, None).await;
    Ok(StatusCode::NO_CONTENT)
}

fn resolve_required<T>(
    value: Option<PatchValue<T>>,
    current: T,
    field: &str,
) -> Result<T, AppError> {
    match value {
        None => Ok(current),
        Some(PatchValue::Value(value)) => Ok(value),
        Some(PatchValue::Null(())) => Err(AppError::BadRequest(format!("{field} cannot be null"))),
    }
}

fn resolve_nullable<T>(value: Option<PatchValue<T>>, current: Option<T>) -> Option<T> {
    match value {
        None => current,
        Some(PatchValue::Value(value)) => Some(value),
        Some(PatchValue::Null(())) => None,
    }
}

fn validate_date(field: &str, value: Option<&str>) -> Result<(), AppError> {
    if let Some(value) = value {
        NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .map_err(|_| AppError::BadRequest(format!("{field} must be YYYY-MM-DD")))?;
    }
    Ok(())
}

fn validate_timestamp(field: &str, value: &str) -> Result<(), AppError> {
    DateTime::parse_from_rfc3339(value)
        .map(|_| ())
        .map_err(|_| AppError::BadRequest(format!("{field} must be a valid RFC 3339 timestamp")))
}

fn validate_time(field: &str, value: Option<&str>) -> Result<(), AppError> {
    if let Some(value) = value {
        NaiveTime::parse_from_str(value, "%H:%M")
            .map_err(|_| AppError::BadRequest(format!("{field} must be HH:MM")))?;
    }
    Ok(())
}

fn validate_reminder(value: Option<i64>) -> Result<(), AppError> {
    if value.is_some_and(|minutes| minutes < 0) {
        return Err(AppError::BadRequest(
            "reminderMinutes must be non-negative".into(),
        ));
    }
    Ok(())
}

fn validate_calendar_range(start: &str, end: &str) -> Result<(), AppError> {
    let start = start
        .parse::<DateTime<FixedOffset>>()
        .map_err(|_| AppError::BadRequest("startAt must be a valid RFC 3339 timestamp".into()))?;
    let end = end
        .parse::<DateTime<FixedOffset>>()
        .map_err(|_| AppError::BadRequest("endAt must be a valid RFC 3339 timestamp".into()))?;
    if end < start {
        return Err(AppError::BadRequest(
            "endAt must not precede startAt".into(),
        ));
    }
    Ok(())
}

fn validate_milestone(title: &str, due: Option<&str>, position: i64) -> Result<(), AppError> {
    let length = title.trim().chars().count();
    if !(1..=200).contains(&length) {
        return Err(AppError::BadRequest(
            "milestone title must be 1-200 characters".into(),
        ));
    }
    validate_date("milestone due", due)?;
    if position < 0 {
        return Err(AppError::BadRequest(
            "milestone position must be non-negative".into(),
        ));
    }
    Ok(())
}

fn validate_project_status(status: &str) -> Result<(), AppError> {
    if matches!(status, "active" | "completed" | "archived") {
        Ok(())
    } else {
        Err(AppError::BadRequest(
            "status must be active, completed, or archived".into(),
        ))
    }
}

async fn ensure_project_next_action(
    pool: &SqlitePool,
    user_id: &str,
    project_id: &str,
    task_id: &str,
) -> Result<(), AppError> {
    let exists = sqlx::query_scalar::<_, i64>(
        "SELECT EXISTS(SELECT 1 FROM tasks
         WHERE id=? AND user_id=? AND project_id=? AND deleted_at IS NULL)",
    )
    .bind(task_id)
    .bind(user_id)
    .bind(project_id)
    .fetch_one(pool)
    .await?;
    if exists == 0 {
        return Err(AppError::BadRequest(
            "nextActionTaskId must reference an active task in this project".into(),
        ));
    }
    Ok(())
}

async fn ensure_project<'e, E>(executor: E, user_id: &str, project_id: &str) -> Result<(), AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_scalar::<_, String>(
        "SELECT id FROM projects WHERE id=? AND user_id=? AND deleted_at IS NULL",
    )
    .bind(project_id)
    .bind(user_id)
    .fetch_optional(executor)
    .await?
    .map(|_| ())
    .ok_or(AppError::NotFound)
}

async fn fetch_milestone<'e, E>(
    executor: E,
    user_id: &str,
    project_id: &str,
    id: &str,
) -> Result<Milestone, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, Milestone>(
        "SELECT m.id,p.user_id,m.project_id,m.title,m.due,m.completed,m.completed_at,
                m.position,m.created_at,m.updated_at,m.version,m.deleted_at
         FROM project_milestones m
         JOIN projects p ON p.id=m.project_id
         WHERE p.user_id=? AND p.deleted_at IS NULL
           AND m.project_id=? AND m.id=? AND m.deleted_at IS NULL",
    )
    .bind(user_id)
    .bind(project_id)
    .bind(id)
    .fetch_optional(executor)
    .await?
    .ok_or(AppError::NotFound)
}

async fn list_milestones(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(project_id): Path<String>,
    Query(query): Query<MilestoneListQuery>,
) -> Result<Json<MilestoneListResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    ensure_project(&state.pool, &user_id, &project_id).await?;
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(AppError::BadRequest(
            "limit must be between 1 and 100".into(),
        ));
    }
    let cursor = query.after.map(decode_milestone_cursor).transpose()?;
    let mut milestones = sqlx::query_as::<_, Milestone>(
        "SELECT m.id,p.user_id,m.project_id,m.title,m.due,m.completed,m.completed_at,
                m.position,m.created_at,m.updated_at,m.version,m.deleted_at
         FROM project_milestones m
         JOIN projects p ON p.id=m.project_id
         WHERE p.user_id=? AND p.deleted_at IS NULL
           AND m.project_id=? AND m.deleted_at IS NULL
           AND (? IS NULL OR (m.position,m.id) > (?,?))
         ORDER BY m.position,m.id LIMIT ?",
    )
    .bind(&user_id)
    .bind(&project_id)
    .bind(cursor.as_ref().map(|value| value.position))
    .bind(cursor.as_ref().map(|value| value.position))
    .bind(cursor.as_ref().map(|value| value.id.as_str()))
    .bind(limit + 1)
    .fetch_all(&state.pool)
    .await?;
    let has_more = milestones.len() > limit as usize;
    if has_more {
        milestones.pop();
    }
    let next_cursor = has_more
        .then(|| {
            milestones
                .last()
                .map(milestone_cursor)
                .map(encode_milestone_cursor)
        })
        .flatten()
        .transpose()?;
    Ok(Json(MilestoneListResponse {
        items: milestones,
        next_cursor,
        has_more,
    }))
}

fn milestone_cursor(milestone: &Milestone) -> MilestoneCursor {
    MilestoneCursor {
        v: 1,
        position: milestone.position,
        id: milestone.id.clone(),
    }
}

fn encode_milestone_cursor(cursor: MilestoneCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid milestone cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

fn decode_milestone_cursor(value: String) -> Result<MilestoneCursor, AppError> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AppError::BadRequest("invalid milestone cursor".into()))?;
    let cursor: MilestoneCursor = serde_json::from_slice(&payload)
        .map_err(|_| AppError::BadRequest("invalid milestone cursor".into()))?;
    if cursor.v != 1 || cursor.position < 0 || cursor.id.is_empty() {
        return Err(AppError::BadRequest("invalid milestone cursor".into()));
    }
    Ok(cursor)
}

async fn create_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(project_id): Path<String>,
    Json(input): Json<MilestoneInput>,
) -> Result<(StatusCode, Json<Milestone>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let mut tx = state.pool.begin().await?;
    ensure_project(&mut *tx, &user_id, &project_id).await?;
    let count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM project_milestones WHERE project_id=? AND deleted_at IS NULL",
    )
    .bind(&project_id)
    .fetch_one(&mut *tx)
    .await?;
    if count >= 100 {
        return Err(AppError::BadRequest(
            "project cannot have more than 100 milestones".into(),
        ));
    }
    let position = input.position.unwrap_or(count);
    validate_milestone(&input.title, input.due.as_deref(), position)?;
    let id = new_id();
    let timestamp = now();
    let completed = input.completed.unwrap_or(false);
    let completed_at = completed.then(|| timestamp.clone());
    sqlx::query(
        "INSERT INTO project_milestones
         (id,project_id,title,due,completed,completed_at,position,created_at,updated_at,version)
         VALUES (?,?,?,?,?,?,?,?,?,1)",
    )
    .bind(&id)
    .bind(&project_id)
    .bind(input.title.trim())
    .bind(input.due)
    .bind(completed)
    .bind(completed_at)
    .bind(position)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&mut *tx)
    .await?;
    let milestone = fetch_milestone(&mut *tx, &user_id, &project_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "project_milestone",
        &id,
        "upsert",
        milestone.version,
        Some(serde_json::to_string(&milestone).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok((StatusCode::CREATED, Json(milestone)))
}

async fn get_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
) -> Result<Json<Milestone>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    Ok(Json(
        fetch_milestone(&state.pool, &user_id, &project_id, &id).await?,
    ))
}

async fn update_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
    Json(input): Json<MilestonePatch>,
) -> Result<Json<Milestone>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_milestone(&state.pool, &user_id, &project_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("milestone version changed".into()));
    }
    let title = resolve_required(input.title, current.title, "title")?;
    let due = resolve_nullable(input.due, current.due);
    let completed = resolve_required(input.completed, current.completed, "completed")?;
    let position = resolve_required(input.position, current.position, "position")?;
    validate_milestone(&title, due.as_deref(), position)?;
    let completed_at = match (current.completed, completed) {
        (false, true) => Some(now()),
        (true, false) => None,
        _ => current.completed_at,
    };
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE project_milestones
         SET title=?,due=?,completed=?,completed_at=?,position=?,updated_at=?,version=version+1
         WHERE id=? AND project_id=? AND version=? AND deleted_at IS NULL",
    )
    .bind(title.trim())
    .bind(due)
    .bind(completed)
    .bind(completed_at)
    .bind(position)
    .bind(now())
    .bind(&id)
    .bind(&project_id)
    .bind(input.base_version)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("milestone version changed".into()));
    }
    let milestone = fetch_milestone(&mut *tx, &user_id, &project_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "project_milestone",
        &id,
        "upsert",
        milestone.version,
        Some(serde_json::to_string(&milestone).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok(Json(milestone))
}

async fn delete_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_milestone(&state.pool, &user_id, &project_id, &id).await?;
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE project_milestones
         SET deleted_at=?,updated_at=?,version=version+1
         WHERE id=? AND project_id=? AND deleted_at IS NULL",
    )
    .bind(&timestamp)
    .bind(&timestamp)
    .bind(&id)
    .bind(&project_id)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("milestone version changed".into()));
    }
    append_event(
        &mut *tx,
        &user_id,
        "project_milestone",
        &id,
        "delete",
        current.version + 1,
        None,
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_events(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<CalendarEventListQuery>,
) -> Result<Json<CalendarEventListResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    for (field, value) in [("from", query.from.as_deref()), ("to", query.to.as_deref())] {
        if let Some(value) = value {
            value.parse::<DateTime<FixedOffset>>().map_err(|_| {
                AppError::BadRequest(format!("{field} must be a valid RFC 3339 timestamp"))
            })?;
        }
    }
    if let (Some(from), Some(to)) = (&query.from, &query.to) {
        validate_calendar_range(from, to)?;
    }
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(AppError::BadRequest(
            "limit must be between 1 and 100".into(),
        ));
    }
    let cursor = query.after.map(decode_calendar_event_cursor).transpose()?;
    let mut events = sqlx::query_as::<_, CalendarEvent>(
        "SELECT id,title,description,location,start_at,end_at,all_day,reminder_minutes,created_at,updated_at,version
         FROM calendar_events
         WHERE user_id=? AND deleted_at IS NULL
           AND (? IS NULL OR start_at>=?) AND (? IS NULL OR start_at<?)
           AND (? IS NULL OR (start_at,id)>(?,?))
         ORDER BY start_at,id LIMIT ?",
    )
    .bind(&user_id)
    .bind(&query.from).bind(&query.from)
    .bind(&query.to).bind(&query.to)
    .bind(cursor.as_ref().map(|value| value.start_at.as_str()))
    .bind(cursor.as_ref().map(|value| value.start_at.as_str()))
    .bind(cursor.as_ref().map(|value| value.id.as_str()))
    .bind(limit + 1)
    .fetch_all(&state.pool)
    .await?;
    let has_more = events.len() > limit as usize;
    if has_more {
        events.pop();
    }
    let next_cursor = has_more
        .then(|| {
            events
                .last()
                .map(calendar_event_cursor)
                .map(encode_calendar_event_cursor)
        })
        .flatten()
        .transpose()?;
    Ok(Json(CalendarEventListResponse {
        items: events,
        next_cursor,
        has_more,
    }))
}

fn calendar_event_cursor(event: &CalendarEvent) -> CalendarEventCursor {
    CalendarEventCursor {
        v: 1,
        start_at: event.start_at.clone(),
        id: event.id.clone(),
    }
}

fn encode_calendar_event_cursor(cursor: CalendarEventCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

fn decode_calendar_event_cursor(value: String) -> Result<CalendarEventCursor, AppError> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    let cursor: CalendarEventCursor = serde_json::from_slice(&payload)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    if cursor.v != 1 || cursor.start_at.is_empty() || cursor.id.is_empty() {
        return Err(AppError::BadRequest("invalid calendar cursor".into()));
    }
    Ok(cursor)
}

async fn fetch_event<'e, E>(executor: E, user_id: &str, id: &str) -> Result<CalendarEvent, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, CalendarEvent>(
        "SELECT id,title,description,location,start_at,end_at,all_day,reminder_minutes,created_at,updated_at,version
         FROM calendar_events WHERE user_id=? AND id=? AND deleted_at IS NULL",
    ).bind(user_id).bind(id).fetch_optional(executor).await?.ok_or(AppError::NotFound)
}

async fn create_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<CalendarEventInput>,
) -> Result<(StatusCode, Json<CalendarEvent>), AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    if input.title.trim().is_empty() {
        return Err(AppError::BadRequest("title is required".into()));
    }
    validate_calendar_range(&input.start_at, &input.end_at)?;
    validate_reminder(input.reminder_minutes)?;
    let id = input.id.unwrap_or_else(new_id);
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("INSERT INTO calendar_events (id,user_id,title,description,location,start_at,end_at,all_day,reminder_minutes,created_at,updated_at,version) VALUES (?,?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO NOTHING")
        .bind(&id).bind(&user_id).bind(input.title.trim()).bind(input.description).bind(input.location).bind(input.start_at).bind(input.end_at).bind(input.all_day.unwrap_or(false)).bind(input.reminder_minutes).bind(&timestamp).bind(&timestamp).execute(&mut *tx).await?;
    if result.rows_affected() == 0 {
        let existing = fetch_event(&mut *tx, &user_id, &id).await?;
        tx.rollback().await?;
        return Ok((StatusCode::OK, Json(existing)));
    }
    let event = fetch_event(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "calendar_event",
        &id,
        "upsert",
        event.version,
        Some(serde_json::to_string(&event).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok((StatusCode::CREATED, Json(event)))
}

async fn update_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<CalendarEventPatch>,
) -> Result<Json<CalendarEvent>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_event(&state.pool, &user_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    let title = resolve_required(input.title, current.title, "title")?;
    let description = resolve_nullable(input.description, current.description);
    let location = resolve_nullable(input.location, current.location);
    let start_at = resolve_required(input.start_at, current.start_at, "startAt")?;
    let end_at = resolve_required(input.end_at, current.end_at, "endAt")?;
    let all_day = resolve_required(input.all_day, current.all_day, "allDay")?;
    let reminder_minutes = resolve_nullable(input.reminder_minutes, current.reminder_minutes);
    validate_calendar_range(&start_at, &end_at)?;
    validate_reminder(reminder_minutes)?;
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("UPDATE calendar_events SET title=?,description=?,location=?,start_at=?,end_at=?,all_day=?,reminder_minutes=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND version=?")
        .bind(title.trim()).bind(description).bind(location).bind(start_at).bind(end_at).bind(all_day).bind(reminder_minutes).bind(now()).bind(&user_id).bind(&id).bind(input.base_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    let event = fetch_event(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        &user_id,
        "calendar_event",
        &id,
        "upsert",
        event.version,
        Some(serde_json::to_string(&event).unwrap()),
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok(Json(event))
}

async fn delete_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let event = fetch_event(&state.pool, &user_id, &id).await?;
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("UPDATE calendar_events SET deleted_at=?,updated_at=?,version=version+1 WHERE user_id=? AND id=?")
        .bind(&timestamp).bind(&timestamp).bind(&user_id).bind(&id).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    append_event(
        &mut *tx,
        &user_id,
        "calendar_event",
        &id,
        "delete",
        event.version + 1,
        None,
        mutation_id(&headers),
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn sync_events(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<CursorQuery>,
) -> Result<Json<SyncResponse>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let after = query.after.unwrap_or(0);
    let limit = query.limit.unwrap_or(100).clamp(1, 500);
    let events = sqlx::query_as::<_, SyncEvent>(
        "SELECT cursor,entity_type,entity_id,operation,entity_version,tombstone,mutation_id,payload_json,created_at
         FROM sync_events WHERE user_id=? AND cursor>? ORDER BY cursor LIMIT ?",
    ).bind(&user_id).bind(after).bind(limit).fetch_all(&state.pool).await?;
    let next_cursor = events.last().map(|event| event.cursor).unwrap_or(after);
    Ok(Json(SyncResponse {
        events,
        next_cursor,
    }))
}

async fn sync_snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<SyncSnapshot>, AppError> {
    let user_id = authenticated_user(&headers, &state.pool).await?;
    let mut tx = state.pool.begin().await?;
    let tasks = sqlx::query_as::<_, Task>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,recurrence_rule,created_at,updated_at,version
         FROM tasks WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at",
    )
    .bind(&user_id)
    .fetch_all(&mut *tx)
    .await?;
    let projects = sqlx::query_as::<_, Project>(
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,created_at,updated_at,version
         FROM projects WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at",
    ).bind(&user_id).fetch_all(&mut *tx).await?;
    let calendar_events = sqlx::query_as::<_, CalendarEvent>(
        "SELECT id,title,description,location,start_at,end_at,all_day,reminder_minutes,created_at,updated_at,version
         FROM calendar_events WHERE user_id=? AND deleted_at IS NULL ORDER BY start_at",
    ).bind(&user_id).fetch_all(&mut *tx).await?;
    let milestones = sqlx::query_as::<_, Milestone>(
        "SELECT m.id,p.user_id,m.project_id,m.title,m.due,m.completed,m.completed_at,
                m.position,m.created_at,m.updated_at,m.version,m.deleted_at
         FROM project_milestones m
         JOIN projects p ON p.id=m.project_id
         WHERE p.user_id=? AND p.deleted_at IS NULL AND m.deleted_at IS NULL
         ORDER BY m.project_id,m.position,m.id",
    )
    .bind(&user_id)
    .fetch_all(&mut *tx)
    .await?;
    let cursor =
        sqlx::query_scalar::<_, Option<i64>>("SELECT MAX(cursor) FROM sync_events WHERE user_id=?")
            .bind(&user_id)
            .fetch_one(&mut *tx)
            .await?
            .unwrap_or(0);
    tx.commit().await?;
    Ok(Json(SyncSnapshot {
        cursor,
        tasks,
        projects,
        calendar_events,
        milestones,
    }))
}

async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": "route_not_found", "service": SERVICE_NAME })),
    )
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => info!("received Ctrl+C, shutting down"),
        _ = terminate => info!("received SIGTERM, shutting down"),
    }
}

#[cfg(test)]
mod attachment_tests {
    use super::*;

    #[test]
    fn attachment_download_url_must_be_canonical_and_single_token() {
        let token = attachment_download_token(
            "https://example.test/",
            "att-1",
            "https://example.test/api/v1/attachments/att-1/download?token=secret",
        );
        assert_eq!(token, Some("secret"));
        assert!(attachment_download_token(
            "https://example.test",
            "att-1",
            "https://evil.test/api/v1/attachments/att-1/download?token=secret"
        )
        .is_none());
        assert!(attachment_download_token(
            "https://example.test",
            "att-1",
            "https://example.test/api/v1/attachments/att-1/download?token=secret&next=evil"
        )
        .is_none());
    }

    #[test]
    fn attachment_upload_response_is_stable_for_idempotent_replay() {
        let response = AttachmentUploadResponse {
            items: vec![Attachment {
                id: "att-1".into(),
                name: "note.txt".into(),
                mime_type: "text/plain".into(),
                size: 4,
                download_url: "https://example.test/api/v1/attachments/att-1/download?token=secret"
                    .into(),
            }],
        };
        let encoded = serde_json::to_string(&response).unwrap();
        let replay: AttachmentUploadResponse = serde_json::from_str(&encoded).unwrap();
        assert_eq!(replay.items[0].id, "att-1");
        assert_eq!(replay.items[0].size, 4);
    }

    #[test]
    fn attachment_limits_cover_single_total_and_count() {
        assert_eq!(MAX_ATTACHMENT_BYTES, 20 * 1024 * 1024);
        assert!(MAX_TOTAL_ATTACHMENT_BYTES >= MAX_ATTACHMENT_BYTES);
        assert!(MAX_ATTACHMENT_REQUEST_BYTES > MAX_TOTAL_ATTACHMENT_BYTES);
        assert_eq!(MAX_ATTACHMENT_COUNT, 10);
    }
}
