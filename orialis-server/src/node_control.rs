use crate::AppState;
use axum::{
    extract::{FromRequest, FromRequestParts, Path, Query, Request, State},
    http::{request::Parts, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use scrypt::{
    password_hash::{
        rand_core::{OsRng, RngCore},
        PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
    },
    Scrypt,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, SqlitePool, Transaction};
use std::sync::Arc;
use tokio::sync::Semaphore;
use uuid::Uuid;

const PROTOCOL: &str = "1";
const PAIRING_TTL_SECONDS: i64 = 300;
const NODE_LEASE_SECONDS: i64 = 30;
const MAX_PAGE_SIZE: i64 = 100;
static PAIRING_HASH_ADMISSION: Semaphore = Semaphore::const_new(4);

struct NodeJson<T>(T);

impl<S, T> FromRequest<S> for NodeJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = NodeError;

    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        Json::<T>::from_request(request, state)
            .await
            .map(|Json(value)| Self(value))
            .map_err(|_| NodeError::bad_request())
    }
}

struct NodeQuery<T>(T);

impl<S, T> FromRequestParts<S> for NodeQuery<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = NodeError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        Query::<T>::from_request_parts(parts, state)
            .await
            .map(|Query(value)| Self(value))
            .map_err(|_| NodeError::bad_request())
    }
}

pub(crate) fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/v1/nodes/pairings", post(start_pairing))
        .route(
            "/api/v1/nodes/pairings/{pairing_id}/confirm",
            post(confirm_pairing),
        )
        .route(
            "/api/v1/nodes/pairings/{pairing_id}/complete",
            post(complete_pairing),
        )
        .route("/api/v1/nodes", get(list_nodes))
        .route(
            "/api/v1/nodes/{device_id}",
            get(get_node).delete(revoke_node),
        )
        .route("/api/v1/nodes/{device_id}/heartbeat", post(heartbeat))
        .route(
            "/api/v1/nodes/{device_id}/capabilities",
            get(get_capabilities),
        )
        .route("/api/v1/events", get(list_events))
}

pub(crate) fn start_presence_expiry(state: Arc<AppState>) {
    tokio::spawn(async move {
        loop {
            if let Err(error) = expire_node_leases(&state.pool).await {
                tracing::error!(%error, "failed to expire node leases");
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    });
}

#[derive(Debug)]
struct NodeError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
}

impl NodeError {
    fn new(status: StatusCode, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
        }
    }
    fn bad_request() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "INVALID_ARGUMENT",
            "request is invalid",
        )
    }
    fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "UNAUTHENTICATED",
            "valid credential required",
        )
    }
    fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "NOT_FOUND", "resource not found")
    }
    fn conflict(code: &'static str, message: &'static str) -> Self {
        Self::new(StatusCode::CONFLICT, code, message)
    }
    fn expired() -> Self {
        Self::new(StatusCode::GONE, "PAIRING_EXPIRED", "pairing has expired")
    }
    fn rate_limited() -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "rate limit exceeded",
        )
    }
}

impl From<sqlx::Error> for NodeError {
    fn from(error: sqlx::Error) -> Self {
        tracing::error!(%error, "node control database request failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "request could not be completed",
        )
    }
}

impl IntoResponse for NodeError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "error": self.code,
                "message": self.message,
                "requestId": Uuid::now_v7().to_string(),
                "retryable": self.status == StatusCode::TOO_MANY_REQUESTS || self.status.is_server_error(),
                "details": {}
            })),
        )
            .into_response()
    }
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeIdentity {
    display_name: String,
    platform: String,
    node_version: String,
}

impl NodeIdentity {
    fn validate(&self) -> Result<(), NodeError> {
        if self.display_name.trim().is_empty()
            || self.display_name.chars().count() > 128
            || self.platform.trim().is_empty()
            || self.platform.chars().count() > 64
            || self.node_version.trim().is_empty()
            || self.node_version.chars().count() > 64
        {
            return Err(NodeError::bad_request());
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartPairingRequest {
    protocol_version: String,
    node_identity: NodeIdentity,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StartPairingResponse {
    protocol_version: &'static str,
    pairing_id: String,
    pairing_secret: String,
    confirmation_code: String,
    target_node: NodeIdentity,
    expires_at: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfirmPairingRequest {
    confirmation_code: String,
    decision: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfirmPairingResponse {
    protocol_version: &'static str,
    pairing_id: String,
    status: &'static str,
    account_id: String,
    expires_at: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompletePairingRequest {
    pairing_secret: String,
    node_identity: NodeIdentity,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletePairingResponse {
    protocol_version: &'static str,
    device_id: String,
    account_id: String,
    device_credential: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Device {
    protocol_version: &'static str,
    device_id: String,
    account_id: String,
    display_name: String,
    platform: String,
    node_version: String,
    status: &'static str,
    created_at: String,
    last_seen_at: Option<String>,
    observed_at: String,
    revocation_version: i64,
    capabilities: Vec<Capability>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Capability {
    name: String,
    version: String,
    available: bool,
    risk: &'static str,
    constraints: Value,
    grant: &'static str,
    grant_expires_at: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NodesResponse {
    protocol_version: &'static str,
    nodes: Vec<Device>,
    next_cursor: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CapabilitiesResponse {
    protocol_version: &'static str,
    device_id: String,
    capabilities: Vec<Capability>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct NodeEvent {
    protocol_version: &'static str,
    event_id: String,
    device_id: String,
    sequence: i64,
    occurred_at: String,
    event_type: String,
    request_id: Option<String>,
    payload: Value,
    cursor: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EventsResponse {
    protocol_version: &'static str,
    events: Vec<NodeEvent>,
    next_cursor: Option<String>,
}

#[derive(Deserialize)]
struct PageQuery {
    cursor: Option<String>,
    after: Option<String>,
    limit: Option<i64>,
}

fn page_limit(limit: Option<i64>) -> Result<i64, NodeError> {
    let limit = limit.unwrap_or(MAX_PAGE_SIZE);
    if !(1..=MAX_PAGE_SIZE).contains(&limit) {
        return Err(NodeError::bad_request());
    }
    Ok(limit)
}

fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

fn confirmation_code_hash(code: &str) -> Result<String, NodeError> {
    let salt = SaltString::generate(&mut OsRng);
    Scrypt
        .hash_password(code.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| {
            NodeError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                "request could not be completed",
            )
        })
}

async fn confirmation_code_hash_blocking(code: String) -> Result<String, NodeError> {
    let permit = PAIRING_HASH_ADMISSION
        .try_acquire()
        .map_err(|_| NodeError::rate_limited())?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        confirmation_code_hash(&code)
    })
    .await
    .map_err(|_| {
        NodeError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "request could not be completed",
        )
    })?
}

fn verify_confirmation_code(code: &str, encoded: &str) -> bool {
    PasswordHash::new(encoded)
        .ok()
        .is_some_and(|hash| Scrypt.verify_password(code.as_bytes(), &hash).is_ok())
}

async fn verify_confirmation_code_blocking(
    code: String,
    encoded: String,
) -> Result<bool, NodeError> {
    let permit = PAIRING_HASH_ADMISSION
        .try_acquire()
        .map_err(|_| NodeError::rate_limited())?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        verify_confirmation_code(&code, &encoded)
    })
    .await
    .map_err(|_| {
        NodeError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "request could not be completed",
        )
    })
}

fn random_secret() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn confirmation_code() -> Result<String, NodeError> {
    let mut bytes = [0_u8; 4];
    OsRng.try_fill_bytes(&mut bytes).map_err(|_| {
        NodeError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "request could not be completed",
        )
    })?;
    let number = u32::from_ne_bytes(bytes) % 1_000_000;
    Ok(format!("{number:06}"))
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut difference = left.len() ^ right.len();
    for index in 0..left.len().max(right.len()) {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

fn now() -> DateTime<Utc> {
    Utc::now()
}

fn rfc3339(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}

async fn require_user(headers: &HeaderMap, state: &AppState) -> Result<String, NodeError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Session "))
        .filter(|value| !value.is_empty())
        .ok_or_else(NodeError::unauthorized)?;
    sqlx::query_scalar::<_, String>(
        "SELECT user_id FROM user_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?",
    )
    .bind(digest(token))
    .bind(rfc3339(now()))
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(NodeError::unauthorized)
}

async fn start_pairing(
    State(state): State<Arc<AppState>>,
    NodeJson(request): NodeJson<StartPairingRequest>,
) -> Result<Json<StartPairingResponse>, NodeError> {
    if request.protocol_version != PROTOCOL {
        return Err(NodeError::new(
            StatusCode::BAD_REQUEST,
            "UNSUPPORTED_VERSION",
            "protocol version is not supported",
        ));
    }
    request.node_identity.validate()?;
    let identity_json =
        serde_json::to_string(&request.node_identity).map_err(|_| NodeError::bad_request())?;
    // Reject known over-limit starts before spending CPU. The same limits are
    // rechecked under BEGIN IMMEDIATE before insertion to close races.
    let cutoff = rfc3339(now() - Duration::seconds(60));
    let identity_count = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM node_pairings WHERE identity_json=? AND created_at>? AND state IN ('pending_confirmation','confirmed')",
    ).bind(&identity_json).bind(&cutoff).fetch_one(&state.pool).await?;
    let pending_count = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM node_pairings WHERE state='pending_confirmation' AND expires_at>?",
    )
    .bind(rfc3339(now()))
    .fetch_one(&state.pool)
    .await?;
    let global_count =
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM node_pairings WHERE created_at>?")
            .bind(&cutoff)
            .fetch_one(&state.pool)
            .await?;
    if identity_count >= 3 || pending_count >= 100 || global_count >= 30 {
        return Err(NodeError::rate_limited());
    }
    let pairing_id = format!("pair_{}", Uuid::new_v4().simple());
    let pairing_secret = random_secret();
    let code = confirmation_code()?;
    // Scrypt is CPU-heavy; compute it on Tokio's blocking pool before opening
    // the SQLite writer transaction.
    let code_hash = confirmation_code_hash_blocking(code.clone()).await?;
    let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
    let cutoff = rfc3339(now() - Duration::seconds(60));
    let created = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM node_pairings WHERE identity_json=? AND created_at>? AND state IN ('pending_confirmation','confirmed')",
    )
    .bind(&identity_json)
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await?;
    let pending = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM node_pairings WHERE state='pending_confirmation' AND expires_at>?",
    )
    .bind(rfc3339(now()))
    .fetch_one(&mut *tx)
    .await?;
    let requests =
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM node_pairings WHERE created_at>?")
            .bind(rfc3339(now() - Duration::seconds(60)))
            .fetch_one(&mut *tx)
            .await?;
    if created >= 3 || pending >= 100 || requests >= 30 {
        return Err(NodeError::rate_limited());
    }
    let issued = now();
    let expires = issued + Duration::seconds(PAIRING_TTL_SECONDS);
    sqlx::query(
        "INSERT INTO node_pairings (pairing_id,pairing_secret_hash,confirmation_code_hash,identity_json,state,expires_at,created_at,updated_at)
         VALUES (?,?,?,?,'pending_confirmation',?,?,?)",
    )
    .bind(&pairing_id)
    .bind(digest(&pairing_secret))
    .bind(code_hash)
    .bind(identity_json)
    .bind(rfc3339(expires))
    .bind(rfc3339(issued))
    .bind(rfc3339(issued))
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(StartPairingResponse {
        protocol_version: PROTOCOL,
        pairing_id,
        pairing_secret,
        confirmation_code: code,
        target_node: request.node_identity,
        expires_at: rfc3339(expires),
    }))
}

async fn confirm_pairing(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(pairing_id): Path<String>,
    NodeJson(request): NodeJson<ConfirmPairingRequest>,
) -> Result<Json<ConfirmPairingResponse>, NodeError> {
    let account_id = require_user(&headers, &state).await?;
    if request.confirmation_code.len() != 6
        || !request
            .confirmation_code
            .bytes()
            .all(|byte| byte.is_ascii_digit())
        || !matches!(request.decision.as_str(), "confirm" | "reject")
    {
        return Err(NodeError::bad_request());
    }
    // Atomically claim one of ten attempts, then release the SQLite writer
    // lock before the intentionally expensive password-hash verification.
    let code_hash = {
        let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
        let row = sqlx::query_as::<_, (String, Option<String>, String, String, i64)>(
            "SELECT state, account_id, expires_at, confirmation_code_hash, confirm_attempts FROM node_pairings WHERE pairing_id=?",
        )
        .bind(&pairing_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(NodeError::not_found)?;
        if row.1.as_deref().is_some_and(|owner| owner != account_id) {
            return Err(NodeError::not_found());
        }
        if DateTime::parse_from_rfc3339(&row.2)
            .map(|value| value.with_timezone(&Utc))
            .unwrap_or(now())
            <= now()
            && matches!(row.0.as_str(), "pending_confirmation" | "confirmed")
        {
            sqlx::query("UPDATE node_pairings SET state='expired',updated_at=? WHERE pairing_id=? AND state IN ('pending_confirmation','confirmed')")
                .bind(rfc3339(now())).bind(&pairing_id).execute(&mut *tx).await?;
            tx.commit().await?;
            return Err(NodeError::expired());
        }
        if row.0 == "expired" {
            return Err(NodeError::expired());
        }
        if row.4 >= 10 {
            return Err(NodeError::rate_limited());
        }
        sqlx::query("UPDATE node_pairings SET confirm_attempts=confirm_attempts+1,updated_at=? WHERE pairing_id=?")
            .bind(rfc3339(now())).bind(&pairing_id).execute(&mut *tx).await?;
        tx.commit().await?;
        row.3
    };
    if !verify_confirmation_code_blocking(request.confirmation_code, code_hash).await? {
        return Err(NodeError::bad_request());
    }
    let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
    let row = sqlx::query_as::<_, (String, Option<String>, String, String)>(
        "SELECT state, account_id, expires_at, pairing_id FROM node_pairings WHERE pairing_id=?",
    )
    .bind(&pairing_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(NodeError::not_found)?;
    if row.1.as_deref() != Some(account_id.as_str()) && row.1.is_some() {
        return Err(NodeError::not_found());
    }
    if DateTime::parse_from_rfc3339(&row.2)
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or(now())
        <= now()
        && matches!(row.0.as_str(), "pending_confirmation" | "confirmed")
    {
        sqlx::query("UPDATE node_pairings SET state='expired',updated_at=? WHERE pairing_id=? AND state IN ('pending_confirmation','confirmed')")
            .bind(rfc3339(now())).bind(&pairing_id).execute(&mut *tx).await?;
        tx.commit().await?;
        return Err(NodeError::expired());
    }
    let expected_state = if request.decision == "confirm" {
        "confirmed"
    } else {
        "rejected"
    };
    if row.0 != "pending_confirmation" {
        let prior_decision_matches =
            row.0 == expected_state || (row.0 == "completed" && expected_state == "confirmed");
        if prior_decision_matches && row.1.as_deref() == Some(account_id.as_str()) {
            tx.commit().await?;
            return Ok(Json(ConfirmPairingResponse {
                protocol_version: PROTOCOL,
                pairing_id: row.3,
                status: if expected_state == "confirmed" {
                    "confirmed"
                } else {
                    "rejected"
                },
                account_id,
                expires_at: row.2,
            }));
        }
        return Err(NodeError::conflict(
            "PAIRING_DECISION_FINAL",
            "pairing decision is final",
        ));
    }
    sqlx::query("UPDATE node_pairings SET state=?,account_id=?,updated_at=? WHERE pairing_id=? AND state='pending_confirmation'")
        .bind(expected_state)
        .bind(&account_id)
        .bind(rfc3339(now()))
        .bind(&pairing_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(ConfirmPairingResponse {
        protocol_version: PROTOCOL,
        pairing_id: row.3,
        status: if expected_state == "confirmed" {
            "confirmed"
        } else {
            "rejected"
        },
        account_id,
        expires_at: row.2,
    }))
}

async fn complete_pairing(
    State(state): State<Arc<AppState>>,
    Path(pairing_id): Path<String>,
    NodeJson(request): NodeJson<CompletePairingRequest>,
) -> Result<Json<CompletePairingResponse>, NodeError> {
    request.node_identity.validate()?;
    let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
    let row = sqlx::query_as::<_, (String, String, String, String, Option<String>, i64)>(
        "SELECT state, pairing_secret_hash, identity_json, expires_at, account_id, complete_attempts FROM node_pairings WHERE pairing_id=?",
    )
    .bind(&pairing_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(NodeError::not_found)?;
    if row.0 == "completed" {
        return Err(NodeError::conflict(
            "PAIRING_ALREADY_COMPLETED",
            "pairing is already completed",
        ));
    }
    if row.0 == "expired" {
        return Err(NodeError::expired());
    }
    if DateTime::parse_from_rfc3339(&row.3)
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or(now())
        <= now()
        && matches!(row.0.as_str(), "pending_confirmation" | "confirmed")
    {
        sqlx::query("UPDATE node_pairings SET state='expired',updated_at=? WHERE pairing_id=? AND state IN ('pending_confirmation','confirmed')")
            .bind(rfc3339(now()))
            .bind(&pairing_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Err(NodeError::expired());
    }
    if row.5 >= 10 {
        return Err(NodeError::rate_limited());
    }
    if !constant_time_equal(&digest(&request.pairing_secret), &row.1) {
        sqlx::query("UPDATE node_pairings SET complete_attempts=complete_attempts+1,updated_at=? WHERE pairing_id=?")
            .bind(rfc3339(now())).bind(&pairing_id).execute(&mut *tx).await?;
        tx.commit().await?;
        return Err(NodeError::not_found());
    }
    if row.0 == "rejected" {
        return Err(NodeError::conflict(
            "PAIRING_REJECTED",
            "pairing was rejected",
        ));
    }
    if row.0 != "confirmed" {
        return Err(NodeError::conflict(
            "PAIRING_NOT_CONFIRMED",
            "pairing is not confirmed",
        ));
    }
    if serde_json::from_str::<NodeIdentity>(&row.2).ok().as_ref() != Some(&request.node_identity) {
        return Err(NodeError::bad_request());
    }
    let account_id = row.4.ok_or_else(NodeError::not_found)?;
    let device_id = format!("dev_{}", Uuid::new_v4().simple());
    let credential = random_secret();
    let created_at = rfc3339(now());
    sqlx::query(
        "INSERT INTO nodes (device_id,account_id,display_name,platform,node_version,credential_hash,created_at,presence_state)
         VALUES (?,?,?,?,?,?,?,'unknown')",
    )
    .bind(&device_id)
    .bind(&account_id)
    .bind(&request.node_identity.display_name)
    .bind(&request.node_identity.platform)
    .bind(&request.node_identity.node_version)
    .bind(digest(&credential))
    .bind(&created_at)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE node_pairings SET state='completed',device_id=?,updated_at=? WHERE pairing_id=? AND state='confirmed'")
        .bind(&device_id)
        .bind(&created_at)
        .bind(&pairing_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(CompletePairingResponse {
        protocol_version: PROTOCOL,
        device_id,
        account_id,
        device_credential: credential,
    }))
}

async fn list_nodes(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    NodeQuery(query): NodeQuery<PageQuery>,
) -> Result<Json<NodesResponse>, NodeError> {
    let account_id = require_user(&headers, &state).await?;
    let limit = page_limit(query.limit)?;
    let cursor = if let Some(cursor) = query.cursor.as_deref() {
        Some(
            sqlx::query_as::<_, (String, String)>(
                "SELECT device_id,created_at FROM nodes WHERE device_id=? AND account_id=?",
            )
            .bind(cursor)
            .bind(&account_id)
            .fetch_optional(&state.pool)
            .await?
            .ok_or_else(NodeError::not_found)?,
        )
    } else {
        None
    };
    let rows = if let Some((device_id, created_at)) = cursor {
        sqlx::query_as::<_, NodeRow>(
            "SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE account_id=? AND (created_at>? OR (created_at=? AND device_id>?)) ORDER BY created_at,device_id LIMIT ?",
        )
        .bind(&account_id).bind(created_at.clone()).bind(created_at).bind(device_id).bind(limit + 1)
        .fetch_all(&state.pool).await?
    } else {
        sqlx::query_as::<_, NodeRow>(
            "SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE account_id=? ORDER BY created_at,device_id LIMIT ?",
        )
        .bind(&account_id).bind(limit + 1).fetch_all(&state.pool).await?
    };
    let has_more = rows.len() as i64 > limit;
    let mut devices = Vec::new();
    for row in rows.into_iter().take(limit as usize) {
        devices.push(device_from_row(row, &state.pool).await?);
    }
    let next_cursor = if has_more {
        devices.last().map(|device| device.device_id.clone())
    } else {
        None
    };
    Ok(Json(NodesResponse {
        protocol_version: PROTOCOL,
        nodes: devices,
        next_cursor,
    }))
}

async fn get_node(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Device>, NodeError> {
    let account_id = match require_user(&headers, &state).await {
        Ok(account_id) => account_id,
        Err(_) => {
            authenticate_node(&headers, &state.pool, &device_id)
                .await?
                .account_id
        }
    };
    let row = load_device(&state.pool, &account_id, &device_id).await?;
    Ok(Json(device_from_row(row, &state.pool).await?))
}

async fn revoke_node(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Device>, NodeError> {
    let account_id = require_user(&headers, &state).await?;
    let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
    let row = load_device_tx(&mut tx, &account_id, &device_id).await?;
    if row.revoked_at.is_none() {
        let revoked_at = rfc3339(now());
        sqlx::query("UPDATE nodes SET revoked_at=?,revocation_version=revocation_version+1 WHERE device_id=? AND account_id=? AND revoked_at IS NULL")
            .bind(&revoked_at).bind(&device_id).bind(&account_id).execute(&mut *tx).await?;
        insert_event_tx(
            &mut tx,
            &account_id,
            &device_id,
            &revoked_at,
            "node.revoked",
            None,
            json!({"revocationVersion": row.revocation_version + 1}),
        )
        .await?;
    }
    tx.commit().await?;
    let row = load_device(&state.pool, &account_id, &device_id).await?;
    Ok(Json(device_from_row(row, &state.pool).await?))
}

async fn heartbeat(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    NodeJson(request): NodeJson<Value>,
) -> Result<Json<Device>, NodeError> {
    if request.as_object().is_none_or(|body| !body.is_empty()) {
        return Err(NodeError::bad_request());
    }
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Node "))
        .filter(|value| !value.is_empty())
        .ok_or_else(NodeError::unauthorized)?;
    let credential_hash = digest(token);
    let mut tx = state.pool.begin_with("BEGIN IMMEDIATE").await?;
    let row = sqlx::query_as::<_, NodeRow>(
        "SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE device_id=? AND credential_hash=?",
    )
    .bind(&device_id).bind(credential_hash).fetch_optional(&mut *tx).await?.ok_or_else(NodeError::unauthorized)?;
    if row.revoked_at.is_some() {
        return Err(NodeError::unauthorized());
    }
    let heartbeat_at = now();
    let heartbeat_at_text = rfc3339(heartbeat_at);
    let was_online = row.presence_state == "online"
        && row.last_seen_at.as_deref().is_some_and(|last| {
            DateTime::parse_from_rfc3339(last)
                .map(|parsed| {
                    heartbeat_at - parsed.with_timezone(&Utc)
                        < Duration::seconds(NODE_LEASE_SECONDS)
                })
                .unwrap_or(false)
        });
    if !was_online && row.presence_state == "online" {
        if let Some(last_seen) = row.last_seen_at.as_deref() {
            let transition_at = DateTime::parse_from_rfc3339(last_seen)
                .map(|parsed| parsed.with_timezone(&Utc) + Duration::seconds(NODE_LEASE_SECONDS))
                .unwrap_or(heartbeat_at);
            insert_event_tx(
                &mut tx,
                &row.account_id,
                &device_id,
                &rfc3339(transition_at),
                "node.presence_changed",
                None,
                json!({"status":"offline","observedAt":rfc3339(transition_at)}),
            )
            .await?;
        }
    }
    sqlx::query("UPDATE nodes SET last_seen_at=?,presence_state='online' WHERE device_id=? AND revoked_at IS NULL")
        .bind(&heartbeat_at_text).bind(&device_id).execute(&mut *tx).await?;
    if !was_online {
        insert_event_tx(
            &mut tx,
            &row.account_id,
            &device_id,
            &heartbeat_at_text,
            "node.presence_changed",
            None,
            json!({"status":"online","observedAt":heartbeat_at_text}),
        )
        .await?;
    }
    tx.commit().await?;
    let row = load_device(&state.pool, &row.account_id, &device_id).await?;
    Ok(Json(device_from_row(row, &state.pool).await?))
}

async fn get_capabilities(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<CapabilitiesResponse>, NodeError> {
    let account_id = match require_user(&headers, &state).await {
        Ok(account_id) => account_id,
        Err(_) => {
            authenticate_node(&headers, &state.pool, &device_id)
                .await?
                .account_id
        }
    };
    let row = load_device(&state.pool, &account_id, &device_id).await?;
    if row.revoked_at.is_some() {
        return Err(NodeError::not_found());
    }
    Ok(Json(CapabilitiesResponse {
        protocol_version: PROTOCOL,
        device_id,
        capabilities: capabilities(),
    }))
}

async fn list_events(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    NodeQuery(query): NodeQuery<PageQuery>,
) -> Result<Json<EventsResponse>, NodeError> {
    let account_id = require_user(&headers, &state).await?;
    let limit = page_limit(query.limit)?;
    let cursor = if let Some(after) = query.after.as_deref() {
        Some(
            sqlx::query_scalar::<_, i64>(
                "SELECT event_cursor FROM node_events WHERE event_id=? AND account_id=?",
            )
            .bind(after)
            .bind(&account_id)
            .fetch_optional(&state.pool)
            .await?
            .ok_or_else(NodeError::not_found)?,
        )
    } else {
        None
    };
    let rows = if let Some(cursor) = cursor {
        sqlx::query_as::<_, EventRow>("SELECT event_id,device_id,sequence,occurred_at,event_type,request_id,payload_json,event_cursor FROM node_events WHERE account_id=? AND event_cursor>? ORDER BY event_cursor LIMIT ?")
            .bind(&account_id).bind(cursor).bind(limit+1).fetch_all(&state.pool).await?
    } else {
        sqlx::query_as::<_, EventRow>("SELECT event_id,device_id,sequence,occurred_at,event_type,request_id,payload_json,event_cursor FROM node_events WHERE account_id=? ORDER BY event_cursor LIMIT ?")
            .bind(&account_id).bind(limit+1).fetch_all(&state.pool).await?
    };
    let events = rows
        .into_iter()
        .take(limit as usize)
        .map(event_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    let next_cursor = events
        .last()
        .map(|event| event.event_id.clone())
        .or(query.after);
    Ok(Json(EventsResponse {
        protocol_version: PROTOCOL,
        events,
        next_cursor,
    }))
}

#[derive(sqlx::FromRow)]
struct NodeRow {
    device_id: String,
    account_id: String,
    display_name: String,
    platform: String,
    node_version: String,
    created_at: String,
    last_seen_at: Option<String>,
    revoked_at: Option<String>,
    revocation_version: i64,
    presence_state: String,
}

async fn load_device(
    pool: &SqlitePool,
    account_id: &str,
    device_id: &str,
) -> Result<NodeRow, NodeError> {
    sqlx::query_as::<_, NodeRow>("SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE account_id=? AND device_id=?")
        .bind(account_id).bind(device_id).fetch_optional(pool).await?.ok_or_else(NodeError::not_found)
}

async fn load_device_tx(
    tx: &mut Transaction<'_, Sqlite>,
    account_id: &str,
    device_id: &str,
) -> Result<NodeRow, NodeError> {
    sqlx::query_as::<_, NodeRow>("SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE account_id=? AND device_id=?")
        .bind(account_id).bind(device_id).fetch_optional(&mut **tx).await?.ok_or_else(NodeError::not_found)
}

fn effective_status(row: &NodeRow) -> &'static str {
    if row.revoked_at.is_some() {
        return "revoked";
    }
    let Some(last_seen) = row.last_seen_at.as_deref() else {
        return "unknown";
    };
    let Ok(last_seen) = DateTime::parse_from_rfc3339(last_seen) else {
        return "unknown";
    };
    if now() - last_seen.with_timezone(&Utc) < Duration::seconds(NODE_LEASE_SECONDS) {
        "online"
    } else {
        "offline"
    }
}

async fn device_from_row(row: NodeRow, pool: &SqlitePool) -> Result<Device, NodeError> {
    let _ = pool;
    let status = effective_status(&row);
    Ok(Device {
        protocol_version: PROTOCOL,
        device_id: row.device_id,
        account_id: row.account_id,
        display_name: row.display_name,
        platform: row.platform,
        node_version: row.node_version,
        status,
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        observed_at: rfc3339(now()),
        revocation_version: row.revocation_version,
        capabilities: capabilities(),
    })
}

fn capabilities() -> Vec<Capability> {
    Vec::new()
}

#[derive(sqlx::FromRow)]
struct EventRow {
    event_id: String,
    device_id: String,
    sequence: i64,
    occurred_at: String,
    event_type: String,
    request_id: Option<String>,
    payload_json: String,
    event_cursor: i64,
}

fn event_from_row(row: EventRow) -> Result<NodeEvent, NodeError> {
    let _ = row.event_cursor;
    let cursor = row.event_id.clone();
    Ok(NodeEvent {
        protocol_version: PROTOCOL,
        event_id: row.event_id,
        device_id: row.device_id,
        sequence: row.sequence,
        occurred_at: row.occurred_at,
        event_type: row.event_type,
        request_id: row.request_id,
        payload: serde_json::from_str(&row.payload_json).map_err(|_| NodeError::bad_request())?,
        cursor: Some(cursor),
    })
}

async fn insert_event_tx(
    tx: &mut Transaction<'_, Sqlite>,
    account_id: &str,
    device_id: &str,
    occurred_at: &str,
    event_type: &str,
    request_id: Option<&str>,
    payload: Value,
) -> Result<(), NodeError> {
    let sequence = sqlx::query_scalar::<_, i64>(
        "SELECT coalesce(max(sequence),0)+1 FROM node_events WHERE device_id=?",
    )
    .bind(device_id)
    .fetch_one(&mut **tx)
    .await?;
    sqlx::query("INSERT INTO node_events (event_id,account_id,device_id,sequence,occurred_at,event_type,request_id,payload_json) VALUES (?,?,?,?,?,?,?,?)")
        .bind(format!("evt_{}", Uuid::new_v4().simple())).bind(account_id).bind(device_id).bind(sequence).bind(occurred_at).bind(event_type).bind(request_id).bind(payload.to_string()).execute(&mut **tx).await?;
    Ok(())
}

async fn authenticate_node(
    headers: &HeaderMap,
    pool: &SqlitePool,
    device_id: &str,
) -> Result<NodeRow, NodeError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Node "))
        .filter(|value| !value.is_empty())
        .ok_or_else(NodeError::unauthorized)?;
    let row = sqlx::query_as::<_, NodeRow>("SELECT device_id,account_id,display_name,platform,node_version,created_at,last_seen_at,revoked_at,revocation_version,presence_state FROM nodes WHERE device_id=? AND credential_hash=?")
        .bind(device_id).bind(digest(token)).fetch_optional(pool).await?.ok_or_else(NodeError::unauthorized)?;
    if row.revoked_at.is_some() {
        return Err(NodeError::unauthorized());
    }
    Ok(row)
}

async fn expire_node_leases(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    let cutoff = rfc3339(now() - Duration::seconds(NODE_LEASE_SECONDS));
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let rows = sqlx::query_as::<_, (String, String, String)>(
        "SELECT device_id,account_id,last_seen_at FROM nodes WHERE revoked_at IS NULL AND presence_state='online' AND last_seen_at IS NOT NULL AND last_seen_at<=?",
    ).bind(cutoff).fetch_all(&mut *tx).await?;
    for (device_id, account_id, last_seen) in rows {
        let expired_at = DateTime::parse_from_rfc3339(&last_seen)
            .map(|value| value.with_timezone(&Utc) + Duration::seconds(NODE_LEASE_SECONDS))
            .unwrap_or_else(|_| now());
        let affected = sqlx::query("UPDATE nodes SET presence_state='offline' WHERE device_id=? AND presence_state='online' AND last_seen_at=? AND revoked_at IS NULL")
            .bind(&device_id).bind(&last_seen).execute(&mut *tx).await?.rows_affected();
        if affected != 0 {
            insert_event_tx(
                &mut tx,
                &account_id,
                &device_id,
                &rfc3339(expired_at),
                "node.presence_changed",
                None,
                json!({"status":"offline","observedAt":rfc3339(expired_at)}),
            )
            .await
            .map_err(|NodeError { .. }| {
                sqlx::Error::Protocol("failed to persist node presence event".into())
            })?;
        }
    }
    tx.commit().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::HeaderValue;
    use sqlx::sqlite::SqlitePoolOptions;

    // These tests use independent databases but share the process-wide Scrypt
    // admission limit. Serialize scenarios so the load test cannot consume
    // another test's permits; concurrency within each scenario stays intact.
    static PAIRING_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    async fn test_state() -> (Arc<AppState>, String, String, std::path::PathBuf) {
        let database_path =
            std::env::temp_dir().join(format!("orialis-node-control-{}.db", Uuid::new_v4()));
        let database_url = format!("sqlite://{}?mode=rwc", database_path.display());
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect(&database_url)
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let account_id = "acct_test_1".to_owned();
        let other_account = "acct_test_2".to_owned();
        sqlx::query("INSERT INTO users (id,username,password_hash) VALUES (?,?,?)")
            .bind(&account_id)
            .bind("account1")
            .bind("not-used")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users (id,username,password_hash) VALUES (?,?,?)")
            .bind(&other_account)
            .bind("account2")
            .bind("not-used")
            .execute(&pool)
            .await
            .unwrap();
        for (id, token, owner) in [
            ("sess_a", "session_a", &account_id),
            ("sess_b", "session_b", &other_account),
        ] {
            sqlx::query(
                "INSERT INTO user_sessions (id,user_id,token_hash,expires_at) VALUES (?,?,?,?)",
            )
            .bind(id)
            .bind(owner)
            .bind(digest(token))
            .bind(rfc3339(now() + Duration::days(1)))
            .execute(&pool)
            .await
            .unwrap();
        }
        let state = Arc::new(AppState {
            metadata: orialis_core::metadata(
                "test",
                "test".to_owned(),
                "http://localhost".to_owned(),
            ),
            pool,
            agent: crate::agent_gateway::AgentRegistry::default(),
            mobile: crate::mobile_realtime::MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "http://localhost".to_owned(),
            upload_dir: std::env::temp_dir(),
        });
        (state, account_id, other_account, database_path)
    }

    fn session_headers(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            HeaderValue::from_str(&format!("Session {token}")).unwrap(),
        );
        headers
    }

    #[tokio::test]
    async fn persisted_pairing_is_account_bound_and_revocation_blocks_device_credential() {
        let _pairing_guard = PAIRING_TEST_LOCK.lock().await;
        let (state, _account_id, other_account, database_path) = test_state().await;
        let identity = NodeIdentity {
            display_name: "Office node".to_owned(),
            platform: "linux-x86_64".to_owned(),
            node_version: "1.0.0".to_owned(),
        };
        let start = start_pairing(
            State(state.clone()),
            NodeJson(StartPairingRequest {
                protocol_version: PROTOCOL.to_owned(),
                node_identity: identity.clone(),
            }),
        )
        .await
        .unwrap()
        .0;
        let stored_pairing_hashes = sqlx::query_as::<_, (String, String)>(
            "SELECT pairing_secret_hash,confirmation_code_hash FROM node_pairings WHERE pairing_id=?",
        ).bind(&start.pairing_id).fetch_one(&state.pool).await.unwrap();
        assert_eq!(stored_pairing_hashes.0, digest(&start.pairing_secret));
        assert!(stored_pairing_hashes.1.starts_with("$scrypt$"));
        assert!(!stored_pairing_hashes.1.contains(&start.confirmation_code));
        let wrong_account = confirm_pairing(
            State(state.clone()),
            session_headers("session_b"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(wrong_account.0.account_id, other_account);
        let other_account_replay = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await;
        assert_eq!(
            other_account_replay.err().unwrap().status,
            StatusCode::NOT_FOUND
        );
        let confirmed = confirm_pairing(
            State(state.clone()),
            session_headers("session_b"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(confirmed.0.account_id, other_account);
        let complete = complete_pairing(
            State(state.clone()),
            Path(start.pairing_id.clone()),
            NodeJson(CompletePairingRequest {
                pairing_secret: start.pairing_secret.clone(),
                node_identity: identity,
            }),
        )
        .await
        .unwrap()
        .0;
        let stored_hash =
            sqlx::query_scalar::<_, String>("SELECT credential_hash FROM nodes WHERE device_id=?")
                .bind(&complete.device_id)
                .fetch_one(&state.pool)
                .await
                .unwrap();
        assert_eq!(stored_hash, digest(&complete.device_credential));
        assert_ne!(stored_hash, complete.device_credential);

        let credential_headers = || {
            let mut headers = HeaderMap::new();
            headers.insert(
                "authorization",
                HeaderValue::from_str(&format!("Node {}", complete.device_credential)).unwrap(),
            );
            headers
        };
        assert_eq!(
            heartbeat(
                State(state.clone()),
                credential_headers(),
                Path(complete.device_id.clone()),
                NodeJson(json!({})),
            )
            .await
            .unwrap()
            .0
            .status,
            "online"
        );

        let node_as_session = require_user(&credential_headers(), &state).await;
        assert_eq!(
            node_as_session.err().unwrap().status,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            get_node(
                State(state.clone()),
                credential_headers(),
                Path(complete.device_id.clone())
            )
            .await
            .unwrap()
            .0
            .status,
            "online"
        );
        let cross_account = get_node(
            State(state.clone()),
            session_headers("session_a"),
            Path(complete.device_id.clone()),
        )
        .await;
        assert_eq!(cross_account.err().unwrap().status, StatusCode::NOT_FOUND);

        let stale_at = rfc3339(now() - Duration::seconds(NODE_LEASE_SECONDS + 1));
        sqlx::query("UPDATE nodes SET last_seen_at=?,presence_state='online' WHERE device_id=?")
            .bind(&stale_at)
            .bind(&complete.device_id)
            .execute(&state.pool)
            .await
            .unwrap();
        expire_node_leases(&state.pool).await.unwrap();
        assert_eq!(
            get_node(
                State(state.clone()),
                credential_headers(),
                Path(complete.device_id.clone())
            )
            .await
            .unwrap()
            .0
            .status,
            "offline"
        );
        assert_eq!(
            heartbeat(
                State(state.clone()),
                credential_headers(),
                Path(complete.device_id.clone()),
                NodeJson(json!({})),
            )
            .await
            .unwrap()
            .0
            .status,
            "online"
        );

        let revoked = revoke_node(
            State(state.clone()),
            session_headers("session_b"),
            Path(complete.device_id.clone()),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(revoked.status, "revoked");
        assert_eq!(revoked.revocation_version, 1);
        let retry_revoke = revoke_node(
            State(state.clone()),
            session_headers("session_b"),
            Path(complete.device_id.clone()),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(retry_revoke.revocation_version, 1);
        let heartbeat_after_revoke = heartbeat(
            State(state.clone()),
            credential_headers(),
            Path(complete.device_id.clone()),
            NodeJson(json!({})),
        )
        .await;
        assert_eq!(
            heartbeat_after_revoke.err().unwrap().status,
            StatusCode::UNAUTHORIZED
        );

        let events = list_events(
            State(state.clone()),
            session_headers("session_b"),
            NodeQuery(PageQuery {
                cursor: None,
                after: None,
                limit: None,
            }),
        )
        .await
        .unwrap()
        .0;
        assert!(events
            .events
            .iter()
            .any(|event| event.event_type == "node.presence_changed"));
        assert!(events
            .events
            .iter()
            .any(|event| event.event_type == "node.revoked"));
        drop(state);
        let reopened = SqlitePoolOptions::new()
            .max_connections(1)
            .connect(&format!("sqlite://{}?mode=rwc", database_path.display()))
            .await
            .unwrap();
        let persisted = sqlx::query_as::<_, (String, i64)>(
            "SELECT credential_hash,revocation_version FROM nodes WHERE device_id=?",
        )
        .bind(&complete.device_id)
        .fetch_one(&reopened)
        .await
        .unwrap();
        assert_eq!(persisted.0, digest(&complete.device_credential));
        assert_eq!(persisted.1, 1);
        reopened.close().await;
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn pairing_code_is_one_time_and_expiry_is_enforced() {
        let _pairing_guard = PAIRING_TEST_LOCK.lock().await;
        let (state, _, _, database_path) = test_state().await;
        let identity = NodeIdentity {
            display_name: "test".into(),
            platform: "linux".into(),
            node_version: "1.0.0".into(),
        };
        let start = start_pairing(
            State(state.clone()),
            NodeJson(StartPairingRequest {
                protocol_version: PROTOCOL.to_owned(),
                node_identity: identity.clone(),
            }),
        )
        .await
        .unwrap()
        .0;
        let wrong = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: "000000".to_owned(),
                decision: "confirm".to_owned(),
            }),
        )
        .await;
        assert_eq!(wrong.err().unwrap().status, StatusCode::BAD_REQUEST);
        let confirmed = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(confirmed.0.status, "confirmed");
        let _ = complete_pairing(
            State(state.clone()),
            Path(start.pairing_id.clone()),
            NodeJson(CompletePairingRequest {
                pairing_secret: start.pairing_secret.clone(),
                node_identity: identity.clone(),
            }),
        )
        .await
        .unwrap();
        let replay = complete_pairing(
            State(state.clone()),
            Path(start.pairing_id.clone()),
            NodeJson(CompletePairingRequest {
                pairing_secret: start.pairing_secret.clone(),
                node_identity: identity,
            }),
        )
        .await;
        assert_eq!(replay.err().unwrap().code, "PAIRING_ALREADY_COMPLETED");
        let confirmed_replay = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(confirmed_replay.0.status, "confirmed");
        let wrong_replay_code = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: "000000".to_owned(),
                decision: "confirm".to_owned(),
            }),
        )
        .await;
        assert_eq!(
            wrong_replay_code.err().unwrap().status,
            StatusCode::BAD_REQUEST
        );

        let expired = start_pairing(
            State(state.clone()),
            NodeJson(StartPairingRequest {
                protocol_version: PROTOCOL.to_owned(),
                node_identity: NodeIdentity {
                    display_name: "other".into(),
                    platform: "linux".into(),
                    node_version: "1.0.0".into(),
                },
            }),
        )
        .await
        .unwrap()
        .0;
        sqlx::query("UPDATE node_pairings SET expires_at=? WHERE pairing_id=?")
            .bind(rfc3339(now() - Duration::seconds(1)))
            .bind(&expired.pairing_id)
            .execute(&state.pool)
            .await
            .unwrap();
        let result = complete_pairing(
            State(state.clone()),
            Path(expired.pairing_id),
            NodeJson(CompletePairingRequest {
                pairing_secret: expired.pairing_secret,
                node_identity: NodeIdentity {
                    display_name: "other".into(),
                    platform: "linux".into(),
                    node_version: "1.0.0".into(),
                },
            }),
        )
        .await;
        assert_eq!(result.err().unwrap().status, StatusCode::GONE);
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn malformed_and_unknown_json_fields_use_stable_invalid_argument() {
        let (state, _, _, database_path) = test_state().await;
        for body in [
            r#"{"protocolVersion":"1","nodeIdentity":{"displayName":"node","platform":"linux","nodeVersion":"1.0.0"},"unexpected":true}"#,
            r#"{"protocolVersion":"1","nodeIdentity":"not-an-object"}"#,
        ] {
            let request = Request::builder()
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap();
            let error = NodeJson::<StartPairingRequest>::from_request(request, &state)
                .await
                .err()
                .unwrap();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.code, "INVALID_ARGUMENT");
        }
        let request = Request::builder()
            .uri("/api/v1/nodes?limit=not-a-number")
            .body(Body::empty())
            .unwrap();
        let (mut parts, _) = request.into_parts();
        let query_error = NodeQuery::<PageQuery>::from_request_parts(&mut parts, &state)
            .await
            .err()
            .unwrap();
        assert_eq!(query_error.status, StatusCode::BAD_REQUEST);
        assert_eq!(query_error.code, "INVALID_ARGUMENT");
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn concurrent_completions_are_one_time_and_revoke_serializes_with_heartbeat() {
        let _pairing_guard = PAIRING_TEST_LOCK.lock().await;
        let (state, _, _, database_path) = test_state().await;
        let identity = NodeIdentity {
            display_name: "race node".into(),
            platform: "linux".into(),
            node_version: "1.0.0".into(),
        };
        let start = start_pairing(
            State(state.clone()),
            NodeJson(StartPairingRequest {
                protocol_version: PROTOCOL.to_owned(),
                node_identity: identity.clone(),
            }),
        )
        .await
        .unwrap()
        .0;
        let _ = confirm_pairing(
            State(state.clone()),
            session_headers("session_a"),
            Path(start.pairing_id.clone()),
            NodeJson(ConfirmPairingRequest {
                confirmation_code: start.confirmation_code.clone(),
                decision: "confirm".to_owned(),
            }),
        )
        .await
        .unwrap();

        let completion_one = complete_pairing(
            State(state.clone()),
            Path(start.pairing_id.clone()),
            NodeJson(CompletePairingRequest {
                pairing_secret: start.pairing_secret.clone(),
                node_identity: identity.clone(),
            }),
        );
        let completion_two = complete_pairing(
            State(state.clone()),
            Path(start.pairing_id.clone()),
            NodeJson(CompletePairingRequest {
                pairing_secret: start.pairing_secret.clone(),
                node_identity: identity,
            }),
        );
        let (one, two) = tokio::join!(completion_one, completion_two);
        let (complete, rejected) = match (one, two) {
            (Ok(complete), Err(error)) | (Err(error), Ok(complete)) => (complete.0, error),
            _ => panic!("exactly one concurrent completion must succeed"),
        };
        assert_eq!(rejected.code, "PAIRING_ALREADY_COMPLETED");

        let mut node_headers = HeaderMap::new();
        node_headers.insert(
            "authorization",
            HeaderValue::from_str(&format!("Node {}", complete.device_credential)).unwrap(),
        );
        let (heartbeat_result, revoke_result) = tokio::join!(
            heartbeat(
                State(state.clone()),
                node_headers.clone(),
                Path(complete.device_id.clone()),
                NodeJson(json!({}))
            ),
            revoke_node(
                State(state.clone()),
                session_headers("session_a"),
                Path(complete.device_id.clone())
            ),
        );
        assert!(
            heartbeat_result.is_ok()
                || heartbeat_result
                    .as_ref()
                    .err()
                    .is_some_and(|error| error.status == StatusCode::UNAUTHORIZED)
        );
        assert_eq!(revoke_result.unwrap().0.revocation_version, 1);
        let after_race = heartbeat(
            State(state.clone()),
            node_headers,
            Path(complete.device_id),
            NodeJson(json!({})),
        )
        .await;
        assert_eq!(after_race.err().unwrap().status, StatusCode::UNAUTHORIZED);
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn global_pairing_creation_limit_cannot_be_raced_past() {
        let _pairing_guard = PAIRING_TEST_LOCK.lock().await;
        let (state, _, _, database_path) = test_state().await;
        let mut tasks = tokio::task::JoinSet::new();
        for index in 0..40 {
            let state = state.clone();
            tasks.spawn(async move {
                let request = StartPairingRequest {
                    protocol_version: PROTOCOL.to_owned(),
                    node_identity: NodeIdentity {
                        display_name: format!("node-{index}"),
                        platform: "test".to_owned(),
                        node_version: "1.0.0".to_owned(),
                    },
                };
                start_pairing(State(state), NodeJson(request)).await
            });
        }
        let mut success = 0;
        let mut limited = 0;
        while let Some(result) = tasks.join_next().await {
            match result.unwrap() {
                Ok(_) => success += 1,
                Err(error) if error.code == "RATE_LIMITED" => limited += 1,
                Err(error) => panic!("unexpected pairing creation error: {}", error.code),
            }
        }
        assert!(
            success <= 30,
            "the persistent global limit must never be exceeded"
        );
        assert!(
            limited >= 10,
            "the global limit or bounded CPU admission must reject excess starts"
        );
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn wrong_completion_secrets_are_persistently_limited() {
        let (state, account_id, _, database_path) = test_state().await;
        let identity = NodeIdentity {
            display_name: "limit node".into(),
            platform: "test".into(),
            node_version: "1".into(),
        };
        let pairing_id = "pair_complete_limit";
        sqlx::query("INSERT INTO node_pairings (pairing_id,pairing_secret_hash,confirmation_code_hash,identity_json,state,account_id,expires_at,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)")
            .bind(pairing_id).bind(digest("correct-secret")).bind("unused").bind(serde_json::to_string(&identity).unwrap())
            .bind("confirmed").bind(&account_id).bind(rfc3339(now() + Duration::minutes(5)))
            .bind(rfc3339(now())).bind(rfc3339(now())).execute(&state.pool).await.unwrap();
        for _ in 0..10 {
            let result = complete_pairing(
                State(state.clone()),
                Path(pairing_id.into()),
                NodeJson(CompletePairingRequest {
                    pairing_secret: "wrong-secret".into(),
                    node_identity: identity.clone(),
                }),
            )
            .await;
            assert_eq!(result.err().unwrap().status, StatusCode::NOT_FOUND);
        }
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT complete_attempts FROM node_pairings WHERE pairing_id=?"
            )
            .bind(pairing_id)
            .fetch_one(&state.pool)
            .await
            .unwrap(),
            10
        );
        let locked = complete_pairing(
            State(state.clone()),
            Path(pairing_id.into()),
            NodeJson(CompletePairingRequest {
                pairing_secret: "wrong-secret".into(),
                node_identity: identity,
            }),
        )
        .await;
        assert_eq!(locked.err().unwrap().status, StatusCode::TOO_MANY_REQUESTS);
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[tokio::test]
    async fn cursors_cannot_cross_account_boundaries() {
        let (state, account_id, other_account, database_path) = test_state().await;
        for (device_id, owner) in [("dev_a", &account_id), ("dev_b", &other_account)] {
            sqlx::query("INSERT INTO nodes (device_id,account_id,display_name,platform,node_version,credential_hash,created_at) VALUES (?,?,?,?,?,?,?)")
                .bind(device_id).bind(owner).bind("node").bind("test").bind("1").bind(digest(device_id)).bind(rfc3339(now()))
                .execute(&state.pool).await.unwrap();
        }
        let foreign_device_cursor = list_nodes(
            State(state.clone()),
            session_headers("session_a"),
            NodeQuery(PageQuery {
                cursor: Some("dev_b".into()),
                after: None,
                limit: None,
            }),
        )
        .await;
        assert_eq!(
            foreign_device_cursor.err().unwrap().status,
            StatusCode::NOT_FOUND
        );
        sqlx::query("INSERT INTO node_events (event_id,account_id,device_id,sequence,occurred_at,event_type,payload_json) VALUES (?,?,?,?,?,?,?)")
            .bind("evt_foreign").bind(&other_account).bind("dev_b").bind(1_i64).bind(rfc3339(now()))
            .bind("node.revoked").bind("{}").execute(&state.pool).await.unwrap();
        let foreign_event_cursor = list_events(
            State(state.clone()),
            session_headers("session_a"),
            NodeQuery(PageQuery {
                cursor: None,
                after: Some("evt_foreign".into()),
                limit: None,
            }),
        )
        .await;
        assert_eq!(
            foreign_event_cursor.err().unwrap().status,
            StatusCode::NOT_FOUND
        );

        sqlx::query("INSERT INTO node_events (event_id,account_id,device_id,sequence,occurred_at,event_type,payload_json) VALUES (?,?,?,?,?,?,?)")
            .bind("evt_own").bind(&account_id).bind("dev_a").bind(1_i64).bind(rfc3339(now()))
            .bind("node.revoked").bind("{}").execute(&state.pool).await.unwrap();
        let first_page = list_events(
            State(state.clone()),
            session_headers("session_a"),
            NodeQuery(PageQuery {
                cursor: None,
                after: None,
                limit: None,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(first_page.events.len(), 1);
        assert_eq!(first_page.next_cursor.as_deref(), Some("evt_own"));
        drop(state);
        let _ = std::fs::remove_file(&database_path);
    }

    #[test]
    fn credential_digests_are_stable_and_distinguish_inputs() {
        assert_eq!(digest("token"), digest("token"));
        assert_ne!(digest("token"), digest("other"));
    }

    #[test]
    fn constant_time_comparison_checks_content_and_length() {
        assert!(constant_time_equal("123456", "123456"));
        assert!(!constant_time_equal("123456", "123457"));
        assert!(!constant_time_equal("123456", "12345"));
    }

    #[test]
    fn pagination_limit_is_bounded() {
        assert_eq!(page_limit(None).unwrap(), MAX_PAGE_SIZE);
        assert_eq!(page_limit(Some(4)).unwrap(), 4);
        assert!(page_limit(Some(0)).is_err());
        assert!(page_limit(Some(MAX_PAGE_SIZE + 1)).is_err());
    }
}
