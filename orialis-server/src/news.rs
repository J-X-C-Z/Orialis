use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use std::sync::Arc;

#[derive(Clone)]
struct NewsState {
    pool: SqlitePool,
    publisher_token: Option<String>,
    publisher_user_id: Option<String>,
}

pub(crate) fn router(
    pool: SqlitePool,
    publisher_token: Option<String>,
    publisher_user_id: Option<String>,
) -> Router {
    let state = Arc::new(NewsState {
        pool,
        publisher_token,
        publisher_user_id,
    });
    Router::new()
        .route("/api/v1/news/stream", get(news_stream))
        .route("/api/v1/news/aihot/hot", get(get_public_cache))
        .route("/api/v1/news/aihot/items", get(get_public_cache))
        .route("/api/v1/news/aihot/events/{id}", get(get_aihot_event))
        .route("/api/v1/news/aihot/reports/{period}", get(get_aihot_report))
        .route("/api/v1/news/github/daily", get(get_public_cache))
        .route("/api/v1/news/github/weekly", get(get_public_cache))
        .route("/api/v1/news/github/briefs/{period}", get(get_github_brief))
        .route(
            "/api/v1/news/github/repos/{owner}/{repo}",
            get(get_github_repo),
        )
        .route("/api/v1/news/projects/daily", get(get_projects_daily))
        .route("/api/v1/news/projects", get(get_projects))
        .route(
            "/api/v1/news/projects/{id}/reports",
            get(get_project_reports),
        )
        .route("/api/v1/news/projects/{id}", get(get_project))
        .route("/api/v1/news/publish/aihot/hot", post(publish_aihot))
        .route("/api/v1/news/publish/aihot/items", post(publish_aihot))
        .route("/api/v1/news/publish/aihot/events", post(publish_aihot))
        .route(
            "/api/v1/news/publish/aihot/reports/daily",
            post(publish_aihot),
        )
        .route(
            "/api/v1/news/publish/aihot/reports/weekly",
            post(publish_aihot),
        )
        .route(
            "/api/v1/news/publish/aihot/reports/monthly",
            post(publish_aihot),
        )
        .route("/api/v1/news/publish/github/{period}", post(publish_github))
        .route(
            "/api/v1/news/projects/publish",
            post(publish_project_report),
        )
        .route("/api/v1/news/publish/failure", post(publish_failure))
        .route(
            "/api/v1/news/publish/tasks/{task_id}",
            get(get_publish_task),
        )
        .with_state(state)
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublishInput {
    task_id: String,
    source: String,
    #[serde(default)]
    generated_at: Option<String>,
    #[serde(default)]
    result: Value,
    #[serde(default)]
    user_id: Option<String>,
    #[serde(default)]
    project_id: Option<String>,
    #[serde(default)]
    period: Option<String>,
    #[serde(default)]
    report_date: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    data: Value,
    updated_at: Option<String>,
    stale: bool,
    source: String,
    error: Option<String>,
}

#[derive(sqlx::FromRow)]
struct CacheRow {
    data_json: String,
    updated_at: String,
    source: String,
    stale: bool,
    error: Option<String>,
}

#[derive(sqlx::FromRow)]
struct ProjectReportRow {
    project_id: Option<String>,
    period: String,
    report_date: String,
    report_json: String,
    source: String,
    generated_at: String,
    updated_at: String,
}

fn api_error(status: StatusCode, code: &str, message: impl Into<String>) -> Response {
    (
        status,
        Json(json!({"error":{"code":code,"message":message.into()}})),
    )
        .into_response()
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn token_hash(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

fn session_token(headers: &HeaderMap) -> Option<String> {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Session "))
        .map(str::to_owned)
        .or_else(|| {
            headers
                .get("cookie")
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie.split(';').find_map(|part| {
                        part.trim()
                            .strip_prefix("orialis_session=")
                            .map(str::to_owned)
                    })
                })
        })
}

async fn session_user(state: &NewsState, headers: &HeaderMap) -> Result<String, Response> {
    let Some(token) = session_token(headers) else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "valid session required",
        ));
    };
    sqlx::query_scalar::<_, String>(
        "SELECT user_id FROM user_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?",
    )
    .bind(token_hash(&token))
    .bind(now())
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "news request failed"))?
    .ok_or_else(|| api_error(StatusCode::UNAUTHORIZED, "unauthorized", "valid session required"))
}

// Invalidation revisions come from persisted metadata. Reconnecting after a
// server restart reconciles the current snapshot rather than replaying articles.
// Project report metadata is included only for the authenticated account.
async fn news_revision(state: &NewsState, user: &str) -> Result<String, sqlx::Error> {
    let public = sqlx::query_as::<_, (String, String, Option<String>, bool, Option<String>)>(
        "SELECT cache_key,updated_at,task_id,stale,error FROM news_cache
         WHERE cache_key LIKE 'aihot:%' OR cache_key LIKE 'github:%' ORDER BY cache_key",
    )
    .fetch_all(&state.pool)
    .await?;
    let private = sqlx::query_as::<_, (String, String, String, String, String)>(
        "SELECT project_key,period,report_date,updated_at,task_id FROM news_project_reports
         WHERE user_id=? ORDER BY project_key,period,report_date",
    )
    .bind(user)
    .fetch_all(&state.pool)
    .await?;
    // These tuple types are infallibly serializable and contain no article body.
    Ok(token_hash(
        &serde_json::to_string(&(user, public, private)).unwrap(),
    ))
}

async fn news_stream(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
) -> Result<Response, Response> {
    let user = session_user(&state, &headers).await?;
    let previous = headers
        .get("last-event-id")
        .and_then(|v| v.to_str().ok())
        .filter(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_owned);
    let interval = tokio::time::interval(std::time::Duration::from_secs(1));
    let events = futures_util::stream::unfold(
        (state, headers, user, previous, interval),
        |(state, headers, user, mut previous, mut interval)| async move {
            loop {
                interval.tick().await;
                // Stop on logout/expiry. A long-lived stream must not outlive its session.
                if session_user(&state, &headers).await.ok().as_deref() != Some(user.as_str()) {
                    return None;
                }
                let revision = match news_revision(&state, &user).await {
                    Ok(value) => value,
                    Err(error) => {
                        tracing::warn!(%error, "news stream metadata read failed");
                        return None;
                    }
                };
                if previous.as_deref() == Some(&revision) {
                    continue;
                }
                previous = Some(revision.clone());
                let event = Event::default()
                    .event("news.updated")
                    .id(&revision)
                    .retry(std::time::Duration::from_secs(3))
                    .data(
                        json!({"channels":["aihot","github","projects"],"revision":revision})
                            .to_string(),
                    );
                return Some((
                    Ok::<_, std::convert::Infallible>(event),
                    (state, headers, user, previous, interval),
                ));
            }
        },
    );
    let mut response = Sse::new(events)
        .keep_alive(
            KeepAlive::new()
                .interval(std::time::Duration::from_secs(15))
                .text("keepalive"),
        )
        .into_response();
    response.headers_mut().insert(
        "x-accel-buffering",
        axum::http::HeaderValue::from_static("no"),
    );
    response.headers_mut().insert(
        "cache-control",
        axum::http::HeaderValue::from_static("no-cache, no-transform"),
    );
    Ok(response)
}

async fn publisher_user(state: &NewsState, headers: &HeaderMap) -> Result<String, Response> {
    let supplied = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split_once(' '))
        .filter(|(scheme, token)| scheme.eq_ignore_ascii_case("bearer") && !token.is_empty())
        .map(|(_, token)| token);
    if !supplied.is_some_and(|token| state.publisher_token.as_deref() == Some(token)) {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "publisher credentials required",
        ));
    }
    let Some(user_id) = state.publisher_user_id.as_deref() else {
        return Err(api_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "publisher user binding is not configured",
        ));
    };
    let exists = sqlx::query_scalar::<_, i64>("SELECT EXISTS(SELECT 1 FROM users WHERE id=?)")
        .bind(user_id)
        .fetch_one(&state.pool)
        .await
        .map_err(|_| {
            api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "database_error",
                "news request failed",
            )
        })?;
    (exists != 0).then(|| user_id.to_owned()).ok_or_else(|| {
        api_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "publisher user binding is invalid",
        )
    })
}

async fn project_publisher_user(
    state: &NewsState,
    headers: &HeaderMap,
    requested_user: Option<&str>,
) -> Result<String, Response> {
    let user_id = match session_user(state, headers).await {
        Ok(user_id) => user_id,
        Err(_) => publisher_user(state, headers).await?,
    };
    if requested_user.is_some_and(|requested| requested != user_id) {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "user_scope_mismatch",
            "userId must match the authenticated publisher",
        ));
    }
    Ok(user_id)
}

fn source_is_valid(source: &str, allowed: &[&str]) -> bool {
    allowed.iter().any(|candidate| source == *candidate)
}

fn valid_repo_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        && value != "."
        && value != ".."
}

fn github_repositories(value: &Value) -> Option<&Vec<Value>> {
    value.as_array().or_else(|| {
        value
            .get("repositories")
            .or_else(|| value.get("items"))
            .and_then(Value::as_array)
    })
}

fn github_brief(value: &Value) -> Value {
    value
        .get("brief")
        .filter(|brief| brief.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}))
}

fn github_repository(value: &Value, requested: &str) -> Option<Value> {
    github_repositories(value)?
        .iter()
        .find(|item| {
            item.get("repository")
                .or_else(|| item.get("fullName"))
                .and_then(Value::as_str)
                .is_some_and(|name| name.eq_ignore_ascii_case(requested))
        })
        .cloned()
}

fn github_list_view(value: Value) -> Value {
    match &value {
        Value::Array(_) => value,
        _ => github_repositories(&value)
            .cloned()
            .map(Value::Array)
            .unwrap_or_else(|| json!([])),
    }
}

fn valid_github_brief(value: &Value) -> bool {
    let Some(brief) = value.get("brief").and_then(Value::as_object) else {
        return false;
    };
    ["title", "summary", "analysisStatus", "source"]
        .iter()
        .all(|key| brief.get(*key).is_some_and(Value::is_string))
        && ["themes", "highlights"].iter().all(|key| {
            brief
                .get(*key)
                .and_then(Value::as_array)
                .is_some_and(|items| items.iter().all(Value::is_string))
        })
}

fn validate_repo_urls(value: &Value) -> bool {
    match value {
        Value::Object(object) => object.iter().all(|(key, value)| {
            if key == "repositoryUrl" || key == "htmlUrl" {
                return value.as_str().is_some_and(|url| {
                    let Some(rest) = url.strip_prefix("https://") else {
                        return false;
                    };
                    let Some((host, path)) = rest.split_once('/') else {
                        return false;
                    };
                    host.eq_ignore_ascii_case("github.com")
                        && !path.is_empty()
                        && !path.contains('\\')
                        && !path.contains('#')
                });
            }
            validate_repo_urls(value)
        }),
        Value::Array(items) => items.iter().all(validate_repo_urls),
        _ => true,
    }
}

async fn start_task(
    state: &NewsState,
    input: &PublishInput,
    owner_user_id: &str,
    operation: &str,
) -> Result<Option<Value>, Response> {
    if input.task_id.trim().is_empty() || input.task_id.len() > 128 {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_task",
            "taskId must be 1-128 characters",
        ));
    }
    let request_json = serde_json::to_vec(&(operation, input)).map_err(|_| {
        api_error(
            StatusCode::BAD_REQUEST,
            "invalid_result",
            "publish request must be valid JSON",
        )
    })?;
    let request_hash = token_hash(std::str::from_utf8(&request_json).unwrap_or_default());
    let started_at = now();
    let inserted = sqlx::query(
        "INSERT OR IGNORE INTO news_publish_tasks
         (task_id,owner_user_id,idempotency_key,status,started_at,source,request_hash)
         VALUES (?,?,?,'running',?,?,?)",
    )
    .bind(&input.task_id)
    .bind(owner_user_id)
    .bind(&input.idempotency_key)
    .bind(&started_at)
    .bind(&input.source)
    .bind(&request_hash)
    .execute(&state.pool)
    .await
    .map_err(|_| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "could not start publish task",
        )
    })?;
    if inserted.rows_affected() == 1 {
        return Ok(None);
    }
    let existing = sqlx::query_as::<_, (Option<String>, String, Option<String>, Option<String>, Option<String>, String, String, String)>(
        "SELECT owner_user_id,status,result_json,error,finished_at,source,started_at,request_hash FROM news_publish_tasks WHERE task_id=?",
    )
    .bind(&input.task_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read publish task"))?
    .ok_or_else(|| api_error(StatusCode::CONFLICT, "task_conflict", "task id already exists"))?;
    if existing.0.as_deref() != Some(owner_user_id) {
        return Err(api_error(
            StatusCode::CONFLICT,
            "task_conflict",
            "task id already exists",
        ));
    }
    if existing.7 != request_hash {
        return Err(api_error(
            StatusCode::CONFLICT,
            "task_conflict",
            "taskId was already used for a different publish request",
        ));
    }
    if existing.1 == "succeeded" {
        return Ok(Some(json!({
            "taskId": input.task_id,
            "status": existing.1,
            "startedAt": existing.6,
            "finishedAt": existing.4,
            "source": existing.5,
            "result": existing.2.and_then(|s| serde_json::from_str::<Value>(&s).ok()).unwrap_or(Value::Null),
            "error": existing.3
        })));
    }
    if existing.1 == "running" {
        return Err(api_error(
            StatusCode::CONFLICT,
            "task_in_progress",
            "publish task is already running",
        ));
    }
    sqlx::query("UPDATE news_publish_tasks SET status='running',started_at=?,finished_at=NULL,error=NULL,source=? WHERE task_id=? AND owner_user_id=?")
        .bind(&started_at)
        .bind(&input.source)
        .bind(&input.task_id)
        .bind(owner_user_id)
        .execute(&state.pool)
        .await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not retry publish task"))?;
    Ok(None)
}

async fn fail_task(state: &NewsState, task_id: &str, message: &str) {
    let _ = sqlx::query(
        "UPDATE news_publish_tasks SET status='failed',finished_at=?,error=? WHERE task_id=?",
    )
    .bind(now())
    .bind(message)
    .bind(task_id)
    .execute(&state.pool)
    .await;
}

async fn finish_task(
    state: &NewsState,
    input: &PublishInput,
    result: &Value,
) -> Result<Value, Response> {
    let finished_at = now();
    let result_json = serde_json::to_string(result).map_err(|_| {
        api_error(
            StatusCode::BAD_REQUEST,
            "invalid_result",
            "result must be valid JSON",
        )
    })?;
    sqlx::query("UPDATE news_publish_tasks SET status='succeeded',finished_at=?,result_json=?,error=NULL WHERE task_id=?")
        .bind(&finished_at)
        .bind(result_json)
        .bind(&input.task_id)
        .execute(&state.pool)
        .await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not finish publish task"))?;
    let started_at = sqlx::query_scalar::<_, String>(
        "SELECT started_at FROM news_publish_tasks WHERE task_id=?",
    )
    .bind(&input.task_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "could not read publish task",
        )
    })?;
    Ok(json!({
        "taskId": input.task_id,
        "status": "succeeded",
        "startedAt": started_at,
        "finishedAt": finished_at,
        "source": input.source,
        "result": result,
        "error": null
    }))
}

async fn get_cache(state: &NewsState, key: &str, empty: Value, max_age: Duration) -> Envelope {
    let row = sqlx::query_as::<_, CacheRow>(
        "SELECT data_json,updated_at,source,stale,error FROM news_cache WHERE cache_key=?",
    )
    .bind(key)
    .fetch_optional(&state.pool)
    .await
    .ok()
    .flatten();
    match row {
        Some(row) => {
            let too_old = DateTime::parse_from_rfc3339(&row.updated_at)
                .ok()
                .is_some_and(|updated| Utc::now() - updated.with_timezone(&Utc) > max_age);
            Envelope {
                data: serde_json::from_str(&row.data_json).unwrap_or(empty),
                updated_at: Some(row.updated_at),
                stale: row.stale || too_old,
                source: row.source,
                error: row.error,
            }
        }
        None => Envelope {
            data: empty,
            updated_at: None,
            stale: true,
            source: key.split(':').next().unwrap_or("unknown").to_owned(),
            error: Some("no published cache is available".into()),
        },
    }
}

async fn get_public_cache(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Result<Json<Envelope>, Response> {
    session_user(&state, &headers).await?;
    let mut key = uri
        .path()
        .trim_start_matches("/api/v1/news/")
        .replace('/', ":");
    if let Some(rest) = key.strip_prefix("aihot:reports:") {
        key = format!("aihot:report:{rest}");
    }
    let max_age = if key.starts_with("github:") {
        if key == "github:daily" {
            Duration::hours(36)
        } else {
            Duration::days(8)
        }
    } else if key.starts_with("aihot:report:") {
        Duration::days(40)
    } else {
        Duration::minutes(30)
    };
    let empty = if key.starts_with("aihot:report:") {
        Value::Null
    } else if key.ends_with("daily")
        || key.ends_with("weekly")
        || key.ends_with("items")
        || key.ends_with("hot")
    {
        json!([])
    } else {
        Value::Null
    };
    let mut cached = get_cache(&state, &key, empty, max_age).await;
    if key == "github:daily" || key == "github:weekly" {
        cached.data = github_list_view(cached.data);
    }
    Ok(Json(cached))
}

async fn get_github_brief(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(period): Path<String>,
) -> Result<Json<Envelope>, Response> {
    session_user(&state, &headers).await?;
    if !matches!(period.as_str(), "daily" | "weekly") {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_period",
            "period must be daily or weekly",
        ));
    }
    let mut cached = get_cache(
        &state,
        &format!("github:{period}"),
        json!({}),
        if period == "daily" {
            Duration::hours(36)
        } else {
            Duration::days(8)
        },
    )
    .await;
    cached.data = github_brief(&cached.data);
    Ok(Json(cached))
}

async fn get_aihot_event(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Envelope>, Response> {
    session_user(&state, &headers).await?;
    let story = get_cache(
        &state,
        &format!("aihot:event:{id}"),
        Value::Null,
        Duration::minutes(30),
    )
    .await;
    if story.data.is_null() {
        return Ok(Json(
            get_cache(
                &state,
                &format!("aihot:item:{id}"),
                Value::Null,
                Duration::minutes(30),
            )
            .await,
        ));
    }
    Ok(Json(story))
}

async fn get_aihot_report(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(period): Path<String>,
) -> Result<Json<Envelope>, Response> {
    session_user(&state, &headers).await?;
    if !matches!(period.as_str(), "daily" | "weekly" | "monthly") {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_period",
            "period must be daily, weekly, or monthly",
        ));
    }
    Ok(Json(
        get_cache(
            &state,
            &format!("aihot:report:{period}"),
            Value::Null,
            Duration::days(40),
        )
        .await,
    ))
}

async fn get_github_repo(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path((owner, repo)): Path<(String, String)>,
) -> Result<Json<Envelope>, Response> {
    session_user(&state, &headers).await?;
    if !valid_repo_name(&owner) || !valid_repo_name(&repo) {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_repository",
            "repository path is invalid",
        ));
    }
    let key = format!("github:repo:{owner}/{repo}");
    let cached = get_cache(&state, &key, Value::Null, Duration::days(8)).await;
    if !cached.data.is_null() {
        return Ok(Json(cached));
    }
    let requested = format!("{owner}/{repo}");
    for period in ["daily", "weekly"] {
        let ranking = get_cache(
            &state,
            &format!("github:{period}"),
            json!([]),
            if period == "daily" {
                Duration::hours(36)
            } else {
                Duration::days(8)
            },
        )
        .await;
        let Some(repository) = github_repository(&ranking.data, &requested) else {
            continue;
        };
        return Ok(Json(Envelope {
            data: repository,
            updated_at: ranking.updated_at,
            stale: ranking.stale,
            source: ranking.source,
            error: ranking.error,
        }));
    }
    Ok(Json(cached))
}

async fn publish_aihot(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(input): Json<PublishInput>,
) -> Result<Json<Value>, Response> {
    let kind = uri
        .path()
        .trim_start_matches("/api/v1/news/publish/aihot/")
        .replace('/', "/");
    let owner = publisher_user(&state, &headers).await?;
    let valid = matches!(
        kind.as_str(),
        "hot" | "items" | "events" | "reports/daily" | "reports/weekly" | "reports/monthly"
    );
    if !valid || !source_is_valid(&input.source, &["aihot.news"]) {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_source",
            "AIHOT publish requires source aihot.news and a supported dataset",
        ));
    }
    if input
        .user_id
        .as_deref()
        .is_some_and(|requested| requested != owner)
    {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "user_scope_mismatch",
            "userId must match the configured publisher user",
        ));
    }
    let shape_ok = if matches!(kind.as_str(), "hot" | "items") {
        input.result.is_array()
    } else {
        input.result.is_object()
    };
    if !shape_ok {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_result",
            "dataset result has the wrong JSON shape",
        ));
    }
    let key = match kind.as_str() {
        "reports/daily" => "aihot:report:daily".to_owned(),
        "reports/weekly" => "aihot:report:weekly".to_owned(),
        "reports/monthly" => "aihot:report:monthly".to_owned(),
        "events" => {
            let id = input
                .result
                .get("publicId")
                .or_else(|| input.result.get("id"))
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| {
                    api_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_event",
                        "event result must include its source id",
                    )
                })?;
            format!("aihot:event:{id}")
        }
        _ => format!("aihot:{kind}"),
    };
    if let Some(existing) = start_task(&state, &input, &owner, &format!("aihot/{kind}")).await? {
        return Ok(Json(existing));
    }
    let value = serde_json::to_string(&input.result).map_err(|_| {
        api_error(
            StatusCode::BAD_REQUEST,
            "invalid_result",
            "result must be valid JSON",
        )
    })?;
    let updated_at = input.generated_at.clone().unwrap_or_else(now);
    if DateTime::parse_from_rfc3339(&updated_at).is_err() {
        fail_task(&state, &input.task_id, "generatedAt must be RFC3339").await;
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_timestamp",
            "generatedAt must be RFC3339",
        ));
    }
    let write = sqlx::query(
        "INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale,error,task_id)
         VALUES (?,?,?,? ,0,NULL,?) ON CONFLICT(cache_key) DO UPDATE SET
         data_json=excluded.data_json,updated_at=excluded.updated_at,source=excluded.source,
         stale=0,error=NULL,task_id=excluded.task_id",
    )
    .bind(&key)
    .bind(value)
    .bind(&updated_at)
    .bind(&input.source)
    .bind(&input.task_id)
    .execute(&state.pool)
    .await;
    if write.is_err() {
        fail_task(&state, &input.task_id, "cache write failed").await;
        return Err(api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "cache write failed",
        ));
    }
    if kind == "hot" {
        if let Some(items) = input.result.as_array() {
            for item in items {
                if let Some(item_id) = item.get("itemId").and_then(Value::as_str) {
                    let _ = sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale,error,task_id) VALUES (?,?,?,? ,0,NULL,?) ON CONFLICT(cache_key) DO UPDATE SET data_json=excluded.data_json,updated_at=excluded.updated_at,source=excluded.source,stale=0,error=NULL,task_id=excluded.task_id")
                        .bind(format!("aihot:item:{item_id}"))
                        .bind(serde_json::to_string(item).unwrap_or_else(|_| "null".into()))
                        .bind(&updated_at)
                        .bind(&input.source)
                        .bind(&input.task_id)
                        .execute(&state.pool)
                        .await;
                }
            }
        }
    }
    Ok(Json(finish_task(&state, &input, &input.result).await?))
}

async fn publish_github(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(period): Path<String>,
    Json(input): Json<PublishInput>,
) -> Result<Json<Value>, Response> {
    let owner = publisher_user(&state, &headers).await?;
    let new_payload = input.result.get("repositories").is_some();
    if !matches!(period.as_str(), "daily" | "weekly")
        || !source_is_valid(&input.source, &["githot.dev"])
        || !validate_repo_urls(&input.result)
        || github_repositories(&input.result).is_none()
        || (new_payload && !valid_github_brief(&input.result))
    {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_source",
            "GitHub publish requires the Githot source and safe repository URLs",
        ));
    }
    if input
        .user_id
        .as_deref()
        .is_some_and(|requested| requested != owner)
    {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "user_scope_mismatch",
            "userId must match the configured publisher user",
        ));
    }
    if let Some(existing) = start_task(&state, &input, &owner, &format!("github/{period}")).await? {
        return Ok(Json(existing));
    }
    let key = format!("github:{period}");
    let data = if input.result.is_array() || new_payload {
        input.result.clone()
    } else {
        input
            .result
            .get("items")
            .cloned()
            .unwrap_or_else(|| json!([]))
    };
    let updated_at = input.generated_at.clone().unwrap_or_else(now);
    let write = sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale,error,task_id) VALUES (?,?,?,? ,0,NULL,?) ON CONFLICT(cache_key) DO UPDATE SET data_json=excluded.data_json,updated_at=excluded.updated_at,source=excluded.source,stale=0,error=NULL,task_id=excluded.task_id")
        .bind(key)
        .bind(serde_json::to_string(&data).unwrap_or_else(|_| "[]".into()))
        .bind(&updated_at)
        .bind(&input.source)
        .bind(&input.task_id)
        .execute(&state.pool)
        .await;
    if write.is_err() {
        fail_task(&state, &input.task_id, "cache write failed").await;
        return Err(api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "cache write failed",
        ));
    }
    let repositories = github_repositories(&data).cloned().unwrap_or_default();
    for item in &repositories {
        let Some(full_name) = item
            .get("repository")
            .or_else(|| item.get("fullName"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        let Some((owner_name, repo_name)) = full_name.split_once('/') else {
            continue;
        };
        if !valid_repo_name(owner_name) || !valid_repo_name(repo_name) {
            continue;
        }
        let repo_data = serde_json::to_string(item).unwrap_or_else(|_| "{}".into());
        let _ = sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale,error,task_id) VALUES (?,?,?,? ,0,NULL,?) ON CONFLICT(cache_key) DO UPDATE SET data_json=excluded.data_json,updated_at=excluded.updated_at,source=excluded.source,stale=0,error=NULL,task_id=excluded.task_id")
            .bind(format!("github:repo:{owner_name}/{repo_name}"))
            .bind(repo_data)
            .bind(&updated_at)
            .bind(&input.source)
            .bind(&input.task_id)
            .execute(&state.pool)
            .await;
    }
    Ok(Json(finish_task(&state, &input, &input.result).await?))
}

fn report_date(input: &PublishInput, period: &str) -> Result<String, Response> {
    let date = input
        .report_date
        .clone()
        .unwrap_or_else(|| Utc::now().format("%Y-%m-%d").to_string());
    let valid = if period == "weekly" {
        is_iso_week(&date)
    } else {
        chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d").is_ok()
    };
    if valid {
        Ok(date)
    } else {
        Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_report_date",
            "reportDate must be YYYY-MM-DD (daily) or ISO week (weekly)",
        ))
    }
}

fn is_iso_week(value: &str) -> bool {
    let Some((year, week)) = value.split_once("-W") else {
        return false;
    };
    if year.len() != 4
        || week.len() != 2
        || !year.bytes().all(|b| b.is_ascii_digit())
        || !week.bytes().all(|b| b.is_ascii_digit())
    {
        return false;
    }
    let (Ok(year), Ok(week)) = (year.parse::<i32>(), week.parse::<u32>()) else {
        return false;
    };
    chrono::NaiveDate::from_isoywd_opt(year, week, chrono::Weekday::Mon).is_some()
}

async fn publish_project_report(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Json(input): Json<PublishInput>,
) -> Result<Json<Value>, Response> {
    let owner = project_publisher_user(&state, &headers, input.user_id.as_deref()).await?;
    let period = input.period.as_deref().unwrap_or("daily");
    if !matches!(period, "daily" | "weekly") || input.result.is_null() || !input.result.is_object()
    {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_report",
            "project report result must be an object and period daily or weekly",
        ));
    }
    let date = report_date(&input, period)?;
    let project_id = input.project_id.as_deref();
    if let Some(project_id) = project_id {
        let belongs = sqlx::query_scalar::<_, i64>(
            "SELECT EXISTS(SELECT 1 FROM projects WHERE id=? AND user_id=? AND deleted_at IS NULL)",
        )
        .bind(project_id)
        .bind(&owner)
        .fetch_one(&state.pool)
        .await
        .map_err(|_| {
            api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "database_error",
                "could not check project ownership",
            )
        })?;
        if belongs == 0 {
            return Err(api_error(
                StatusCode::NOT_FOUND,
                "project_not_found",
                "project not found for authenticated user",
            ));
        }
    }
    if !input.source.starts_with("orialis-project-report/") || input.source.len() > 128 {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_source",
            "source must identify the Orialis project-report publisher",
        ));
    }
    if let Some(existing) = start_task(&state, &input, &owner, "projects/report").await? {
        return Ok(Json(existing));
    }
    let generated_at = input.generated_at.clone().unwrap_or_else(now);
    if DateTime::parse_from_rfc3339(&generated_at).is_err() {
        fail_task(&state, &input.task_id, "generatedAt must be RFC3339").await;
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_timestamp",
            "generatedAt must be RFC3339",
        ));
    }
    let project_key = project_id.unwrap_or("");
    let normalized_report = normalize_project_report(&input.result, &date);
    let result_json = serde_json::to_string(&normalized_report).unwrap_or_else(|_| "{}".into());
    let insert = sqlx::query("INSERT INTO news_project_reports(user_id,project_key,project_id,period,report_date,report_json,source,task_id,generated_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,project_key,period,report_date) DO UPDATE SET report_json=excluded.report_json,source=excluded.source,task_id=excluded.task_id,generated_at=excluded.generated_at,updated_at=excluded.updated_at")
        .bind(&owner)
        .bind(project_key)
        .bind(project_id)
        .bind(period)
        .bind(&date)
        .bind(result_json)
        .bind(&input.source)
        .bind(&input.task_id)
        .bind(&generated_at)
        .bind(now())
        .execute(&state.pool)
        .await;
    if insert.is_err() {
        fail_task(&state, &input.task_id, "project report write failed").await;
        return Err(api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "project report write failed",
        ));
    }
    Ok(Json(finish_task(&state, &input, &input.result).await?))
}

async fn publish_failure(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Json(input): Json<PublishInput>,
) -> Result<Json<Value>, Response> {
    let owner = publisher_user(&state, &headers).await?;
    if !source_is_valid(
        &input.source,
        &["aihot.news", "github.com/trending", "githot.dev"],
    ) || input.task_id.trim().is_empty()
        || input.task_id.len() > 128
    {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_failure",
            "failure task requires a known source and valid taskId",
        ));
    }
    if input
        .user_id
        .as_deref()
        .is_some_and(|requested| requested != owner)
    {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "user_scope_mismatch",
            "userId must match the configured publisher user",
        ));
    }
    let message = input.error.as_deref().unwrap_or("source refresh failed");
    if message.trim().is_empty() || message.len() > 2048 {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_failure",
            "error must be 1-2048 characters",
        ));
    }
    if let Some(existing) = start_task(&state, &input, &owner, "publish/failure").await? {
        return Ok(Json(existing));
    }
    let keys = input
        .result
        .get("cacheKeys")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let keys = if keys.is_empty() && input.source == "aihot.news" {
        [
            "aihot:hot",
            "aihot:items",
            "aihot:report:daily",
            "aihot:report:weekly",
            "aihot:report:monthly",
        ]
        .into_iter()
        .map(|key| json!(key))
        .collect()
    } else {
        keys
    };
    if keys.is_empty() {
        fail_task(
            &state,
            &input.task_id,
            "cacheKeys must identify a source cache",
        )
        .await;
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            "invalid_failure",
            "cacheKeys must identify a source cache",
        ));
    }
    for key in keys {
        let Some(key) = key.as_str() else {
            fail_task(&state, &input.task_id, "cacheKeys must be strings").await;
            return Err(api_error(
                StatusCode::BAD_REQUEST,
                "invalid_failure",
                "cacheKeys must be strings",
            ));
        };
        let allowed = if input.source == "aihot.news" {
            matches!(
                key,
                "aihot:hot"
                    | "aihot:items"
                    | "aihot:report:daily"
                    | "aihot:report:weekly"
                    | "aihot:report:monthly"
            ) || key.starts_with("aihot:event:")
        } else {
            matches!(key, "github:daily" | "github:weekly")
        };
        if !allowed {
            fail_task(&state, &input.task_id, "cache key is outside source scope").await;
            return Err(api_error(
                StatusCode::BAD_REQUEST,
                "invalid_failure",
                "cache key is outside source scope",
            ));
        }
        sqlx::query("UPDATE news_cache SET stale=1,error=? WHERE cache_key=?")
            .bind(message)
            .bind(key)
            .execute(&state.pool)
            .await
            .map_err(|_| {
                api_error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "database_error",
                    "could not mark source cache stale",
                )
            })?;
    }
    let finished_at = now();
    let result_json = serde_json::to_string(&input.result).unwrap_or_else(|_| "{}".into());
    sqlx::query("UPDATE news_publish_tasks SET status='failed',finished_at=?,result_json=?,error=? WHERE task_id=? AND owner_user_id=?")
        .bind(&finished_at)
        .bind(result_json)
        .bind(message)
        .bind(&input.task_id)
        .bind(&owner)
        .execute(&state.pool)
        .await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not finish failed task"))?;
    let started_at = sqlx::query_scalar::<_, String>(
        "SELECT started_at FROM news_publish_tasks WHERE task_id=?",
    )
    .bind(&input.task_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "could not read failed task",
        )
    })?;
    Ok(Json(
        json!({"taskId":input.task_id,"status":"failed","startedAt":started_at,"finishedAt":finished_at,"source":input.source,"result":input.result,"error":message}),
    ))
}

async fn get_projects_daily(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
) -> Result<Json<Envelope>, Response> {
    let owner = session_user(&state, &headers).await?;
    let rows = sqlx::query_as::<_, ProjectReportRow>("SELECT project_id,period,report_date,report_json,source,generated_at,updated_at FROM news_project_reports WHERE user_id=? AND project_key='' AND period='daily' ORDER BY report_date DESC LIMIT 30")
        .bind(&owner)
        .fetch_all(&state.pool)
        .await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read project reports"))?;
    let Some(row) = rows.into_iter().next() else {
        return Ok(Json(Envelope {
            data: json!({}),
            updated_at: None,
            stale: false,
            source: "orialis-project-report".into(),
            error: None,
        }));
    };
    let mut data = serde_json::from_str::<Value>(&row.report_json).unwrap_or_else(|_| json!({}));
    if let Some(object) = data.as_object_mut() {
        object
            .entry("reportDate")
            .or_insert_with(|| json!(row.report_date.clone()));
        object
            .entry("generatedAt")
            .or_insert_with(|| json!(row.generated_at.clone()));
    }
    Ok(Json(Envelope {
        data,
        updated_at: Some(row.updated_at),
        stale: false,
        source: row.source,
        error: None,
    }))
}

async fn get_projects(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
) -> Result<Json<Envelope>, Response> {
    let owner = session_user(&state, &headers).await?;
    let projects = sqlx::query_as::<_, (String,String,Option<String>,Option<String>,String,Option<String>,String)>("SELECT id,name,goal,description,status,start_date,updated_at FROM projects WHERE user_id=? AND deleted_at IS NULL ORDER BY updated_at DESC,id")
        .bind(&owner)
        .fetch_all(&state.pool)
        .await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read projects"))?;
    let mut data = Vec::with_capacity(projects.len());
    for project in projects {
        let reports = sqlx::query_as::<_, ProjectReportRow>("SELECT project_id,period,report_date,report_json,source,generated_at,updated_at FROM news_project_reports WHERE user_id=? AND project_key=? ORDER BY report_date DESC LIMIT 1")
            .bind(&owner)
            .bind(&project.0)
            .fetch_optional(&state.pool)
            .await
            .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read project report"))?;
        let update_count = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM news_project_reports WHERE user_id=? AND project_key=?",
        )
        .bind(&owner)
        .bind(&project.0)
        .fetch_one(&state.pool)
        .await
        .map_err(|_| {
            api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "database_error",
                "could not count project reports",
            )
        })?;
        let latest = reports.map(project_report_json);
        let report = latest.as_ref().and_then(|wrapper| wrapper.get("report"));
        let summary = report
            .and_then(|value| value.get("summary"))
            .cloned()
            .unwrap_or(Value::Null);
        let completed = report
            .and_then(|value| value.get("completed"))
            .cloned()
            .unwrap_or_else(|| json!([]));
        let in_progress = report
            .and_then(|value| value.get("inProgress"))
            .cloned()
            .unwrap_or_else(|| json!([]));
        let issues = report
            .and_then(|value| value.get("issues"))
            .cloned()
            .unwrap_or_else(|| json!([]));
        data.push(json!({
            "id":project.0,
            "name":project.1,
            "goal":project.2,
            "description":project.3,
            "status":project.4,
            "startDate":project.5,
            "updatedAt":project.6,
            "latestReport":latest,
            "summary":summary,
            "updateCount":update_count,
            "completed":completed,
            "inProgress":in_progress,
            "issues":issues
        }));
    }
    Ok(Json(Envelope {
        data: json!(data),
        updated_at: Some(now()),
        stale: false,
        source: "orialis-projects".into(),
        error: None,
    }))
}

async fn get_project(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Envelope>, Response> {
    let owner = session_user(&state, &headers).await?;
    let project = sqlx::query_as::<_, (String,String,Option<String>,Option<String>,String,Option<String>,String)>("SELECT id,name,goal,description,status,start_date,updated_at FROM projects WHERE user_id=? AND id=? AND deleted_at IS NULL")
        .bind(&owner).bind(&id).fetch_optional(&state.pool).await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read project"))?;
    let Some(project) = project else {
        return Err(api_error(
            StatusCode::NOT_FOUND,
            "not_found",
            "project not found",
        ));
    };
    let latest = sqlx::query_as::<_, ProjectReportRow>("SELECT project_id,period,report_date,report_json,source,generated_at,updated_at FROM news_project_reports WHERE user_id=? AND project_key=? ORDER BY report_date DESC LIMIT 1")
        .bind(&owner).bind(&id).fetch_optional(&state.pool).await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read project report"))?;
    let stale = latest.is_none();
    let updated_at = project.6.clone();
    let data = json!({"project":{"id":project.0,"name":project.1,"goal":project.2,"description":project.3,"status":project.4,"startDate":project.5,"updatedAt":project.6},"latestReport":latest.map(project_report_json)});
    Ok(Json(Envelope {
        data,
        updated_at: Some(updated_at),
        stale,
        source: "orialis-projects".into(),
        error: None,
    }))
}

async fn get_project_reports(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Envelope>, Response> {
    let owner = session_user(&state, &headers).await?;
    let belongs = sqlx::query_scalar::<_, i64>(
        "SELECT EXISTS(SELECT 1 FROM projects WHERE id=? AND user_id=? AND deleted_at IS NULL)",
    )
    .bind(&id)
    .bind(&owner)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| {
        api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database_error",
            "could not verify project",
        )
    })?;
    if belongs == 0 {
        return Err(api_error(
            StatusCode::NOT_FOUND,
            "not_found",
            "project not found",
        ));
    }
    let rows = sqlx::query_as::<_, ProjectReportRow>("SELECT project_id,period,report_date,report_json,source,generated_at,updated_at FROM news_project_reports WHERE user_id=? AND project_key=? ORDER BY report_date DESC LIMIT 100")
        .bind(owner).bind(id).fetch_all(&state.pool).await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read project reports"))?;
    let data = rows
        .into_iter()
        .map(project_report_json)
        .collect::<Vec<_>>();
    let updated_at = data
        .first()
        .and_then(|v| v.get("updatedAt"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    Ok(Json(Envelope {
        stale: data.is_empty(),
        data: json!(data),
        updated_at,
        source: "orialis-project-report".into(),
        error: None,
    }))
}

fn project_report_json(row: ProjectReportRow) -> Value {
    json!({"projectId":row.project_id,"period":row.period,"reportDate":row.report_date,"report":serde_json::from_str::<Value>(&row.report_json).unwrap_or(Value::Null),"source":row.source,"generatedAt":row.generated_at,"updatedAt":row.updated_at})
}

fn normalize_project_report(value: &Value, fallback_date: &str) -> Value {
    let Some(object) = value.as_object() else {
        return Value::Null;
    };
    let mut normalized = object.clone();
    if !normalized.contains_key("reportDate") {
        let date = normalized
            .remove("date")
            .unwrap_or_else(|| json!(fallback_date));
        normalized.insert("reportDate".into(), date);
    }
    if !normalized.contains_key("inProgress") {
        if let Some(in_progress) = normalized.remove("in_progress") {
            normalized.insert("inProgress".into(), in_progress);
        }
    } else {
        normalized.remove("in_progress");
    }
    Value::Object(normalized)
}

async fn get_publish_task(
    State(state): State<Arc<NewsState>>,
    headers: HeaderMap,
    Path(task_id): Path<String>,
) -> Result<Json<Value>, Response> {
    let user = session_user(&state, &headers).await?;
    let row = sqlx::query_as::<_, (String,String,String,Option<String>,Option<String>,String)>("SELECT task_id,status,started_at,finished_at,source,error FROM news_publish_tasks WHERE task_id=? AND owner_user_id=?")
        .bind(task_id).bind(user).fetch_optional(&state.pool).await
        .map_err(|_| api_error(StatusCode::INTERNAL_SERVER_ERROR, "database_error", "could not read publish task"))?;
    let Some(task) = row else {
        return Err(api_error(
            StatusCode::NOT_FOUND,
            "not_found",
            "publish task not found",
        ));
    };
    let result = sqlx::query_scalar::<_, Option<String>>(
        "SELECT result_json FROM news_publish_tasks WHERE task_id=?",
    )
    .bind(&task.0)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(None);
    Ok(Json(
        json!({"taskId":task.0,"status":task.1,"startedAt":task.2,"finishedAt":task.3,"source":task.4,"result":result.and_then(|s|serde_json::from_str::<Value>(&s).ok()),"error":task.5}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;
    use sqlx::sqlite::SqlitePoolOptions;

    #[test]
    fn publisher_sources_are_exact_allowlist_values() {
        assert!(source_is_valid("aihot.news", &["aihot.news"]));
        assert!(source_is_valid("githot.dev", &["githot.dev"]));
        assert!(!source_is_valid("github.com/trending", &["githot.dev"]));
        assert!(!source_is_valid(
            "https://127.0.0.1/latest",
            &["aihot.news"]
        ));
        assert!(!source_is_valid(
            "https://169.254.169.254/",
            &["githot.dev"]
        ));
    }

    #[test]
    fn repo_urls_reject_non_github_and_credential_urls() {
        assert!(validate_repo_urls(
            &json!({"repositoryUrl":"https://github.com/owner/repo"})
        ));
        assert!(!validate_repo_urls(
            &json!({"repositoryUrl":"http://127.0.0.1/"})
        ));
        assert!(!validate_repo_urls(
            &json!({"repositoryUrl":"https://user@github.com/owner/repo"})
        ));
        assert!(!validate_repo_urls(
            &json!({"nested":[{"htmlUrl":"https://github.com.evil.test/owner/repo"}]})
        ));
        assert!(!validate_repo_urls(
            &json!({"repositoryUrl":"https://github.com@127.0.0.1/owner/repo"})
        ));
    }

    #[test]
    fn github_path_parts_cannot_escape_repo_cache_keys() {
        assert!(valid_repo_name("oriole"));
        assert!(!valid_repo_name("../secret"));
        assert!(!valid_repo_name("owner/repo"));
        assert!(!valid_repo_name("."));
    }

    #[test]
    fn github_cached_shape_projects_list_brief_and_repo_views() {
        let repositories = json!([{"repository":"owner/repo","ranking":1}]);
        let brief = json!({
            "title":"Daily brief",
            "summary":"A short source-grounded summary",
            "themes":["runtime"],
            "highlights":["owner/repo"],
            "analysisStatus":"complete",
            "source":"codex"
        });
        let combined = json!({"repositories":repositories,"brief":brief});
        assert_eq!(github_list_view(combined.clone()), repositories);
        assert_eq!(github_brief(&combined), brief);
        assert_eq!(
            github_repository(&combined, "OWNER/repo"),
            Some(json!({"repository":"owner/repo","ranking":1}))
        );

        let legacy = json!([{"repository":"owner/legacy","ranking":2}]);
        assert_eq!(github_list_view(legacy.clone()), legacy);
        assert_eq!(github_brief(&legacy), json!({}));
        assert_eq!(
            github_repository(&legacy, "owner/legacy"),
            Some(json!({"repository":"owner/legacy","ranking":2}))
        );
    }

    #[test]
    fn project_report_uses_camel_case_and_keeps_report_fields() {
        let value = normalize_project_report(
            &json!({"project":"Orialis","date":"2026-10-02","in_progress":["news"],"completed":[],"decisions":[],"issues":[],"next":[],"important":[]}),
            "2026-10-02",
        );
        assert_eq!(value["reportDate"], "2026-10-02");
        assert_eq!(value["inProgress"][0], "news");
        assert!(value.get("in_progress").is_none());
        assert!(value.get("completed").is_some());
    }

    #[test]
    fn report_read_route_uses_same_key_as_publisher() {
        let key = "/api/v1/news/aihot/reports/daily"
            .trim_start_matches("/api/v1/news/")
            .replace('/', ":");
        let mapped = key
            .strip_prefix("aihot:reports:")
            .map(|rest| format!("aihot:report:{rest}"))
            .unwrap_or(key);
        assert_eq!(mapped, "aihot:report:daily");
    }

    #[test]
    fn weekly_report_date_requires_a_real_iso_week() {
        assert!(is_iso_week("2026-W40"));
        assert!(!is_iso_week("2026-W00"));
        assert!(!is_iso_week("2026-W54"));
        assert!(!is_iso_week("2026-week-40"));
    }

    async fn test_state() -> NewsState {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        for user in ["user-a", "user-b"] {
            sqlx::query("INSERT INTO users(id,username,password_hash) VALUES (?,?,?)")
                .bind(user)
                .bind(user)
                .bind("test")
                .execute(&pool)
                .await
                .unwrap();
        }
        for (user, token) in [("user-a", "session-a"), ("user-b", "session-b")] {
            sqlx::query(
                "INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES (?,?,?,?)",
            )
            .bind(format!("session-{user}"))
            .bind(user)
            .bind(token_hash(token))
            .bind("2999-01-01T00:00:00Z")
            .execute(&pool)
            .await
            .unwrap();
        }
        NewsState {
            pool,
            publisher_token: Some("publisher-token".into()),
            publisher_user_id: Some("user-a".into()),
        }
    }

    #[tokio::test]
    async fn stream_reconciles_persisted_changes_and_honors_resume_revision() {
        use futures_util::StreamExt;
        let state = Arc::new(test_state().await);
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            HeaderValue::from_static("Session session-a"),
        );
        let response = news_stream(State(state.clone()), headers.clone())
            .await
            .unwrap();
        assert_eq!(response.headers()["x-accel-buffering"], "no");
        let mut body = response.into_body().into_data_stream();
        let first = body.next().await.unwrap().unwrap();
        let text = String::from_utf8(first.to_vec()).unwrap();
        assert!(text.contains("event: news.updated"));
        assert!(text.contains("aihot"));
        let revision = news_revision(&state, "user-a").await.unwrap();
        assert!(text.contains(&format!("id: {revision}")));
        headers.insert("last-event-id", HeaderValue::from_str(&revision).unwrap());
        let resumed = news_stream(State(state.clone()), headers).await.unwrap();
        let mut resumed = resumed.into_body().into_data_stream();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), resumed.next())
                .await
                .is_err()
        );
        sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,task_id) VALUES ('github:daily','[]',?,'githot.dev','new-task')")
            .bind(now()).execute(&state.pool).await.unwrap();
        let event = tokio::time::timeout(std::time::Duration::from_secs(2), resumed.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let updated = news_revision(&state, "user-a").await.unwrap();
        assert_ne!(revision, updated);
        assert!(String::from_utf8(event.to_vec())
            .unwrap()
            .contains(&updated));
        // A reconstructed stream/state retains the same cursor after restart.
        let recreated = NewsState {
            pool: state.pool.clone(),
            publisher_token: None,
            publisher_user_id: None,
        };
        assert_eq!(news_revision(&recreated, "user-a").await.unwrap(), updated);
    }

    #[tokio::test]
    async fn stream_rejects_anonymous_and_stops_after_session_revocation() {
        use futures_util::StreamExt;
        let state = Arc::new(test_state().await);
        assert_eq!(
            news_stream(State(state.clone()), HeaderMap::new())
                .await
                .unwrap_err()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            HeaderValue::from_static("Session session-a"),
        );
        let mut body = news_stream(State(state.clone()), headers)
            .await
            .unwrap()
            .into_body()
            .into_data_stream();
        body.next().await.unwrap().unwrap();
        sqlx::query("UPDATE user_sessions SET revoked_at=? WHERE user_id='user-a'")
            .bind(now())
            .execute(&state.pool)
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(2), body.next())
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn stream_revision_isolates_private_projects_and_tracks_source_failure() {
        let state = test_state().await;
        let a = news_revision(&state, "user-a").await.unwrap();
        let b = news_revision(&state, "user-b").await.unwrap();
        assert_ne!(a, b);
        sqlx::query("INSERT INTO news_project_reports(user_id,project_key,period,report_date,report_json,source,task_id,generated_at,updated_at) VALUES ('user-a','p','daily','2026-10-03','{}','test','task',?,?)")
            .bind(now()).bind(now()).execute(&state.pool).await.unwrap();
        assert_ne!(news_revision(&state, "user-a").await.unwrap(), a);
        assert_eq!(news_revision(&state, "user-b").await.unwrap(), b);
        sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale,error) VALUES ('aihot:hot','[]',?,'aihot.news',1,'source timeout')")
            .bind(now()).execute(&state.pool).await.unwrap();
        let failed = news_revision(&state, "user-b").await.unwrap();
        assert_ne!(failed, b);
        sqlx::query("UPDATE news_cache SET stale=0,error=NULL WHERE cache_key='aihot:hot'")
            .execute(&state.pool)
            .await
            .unwrap();
        assert_ne!(news_revision(&state, "user-b").await.unwrap(), failed);
    }

    #[tokio::test]
    async fn project_publish_user_is_bound_to_session_or_configured_publisher() {
        let state = test_state().await;
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            HeaderValue::from_static("Session session-a"),
        );
        assert_eq!(session_user(&state, &headers).await.unwrap(), "user-a");
        assert_eq!(
            project_publisher_user(&state, &headers, Some("user-a"))
                .await
                .unwrap(),
            "user-a"
        );
        assert_eq!(
            project_publisher_user(&state, &headers, Some("user-b"))
                .await
                .unwrap_err()
                .status(),
            StatusCode::FORBIDDEN
        );

        headers.insert(
            "authorization",
            HeaderValue::from_static("Bearer publisher-token"),
        );
        assert_eq!(publisher_user(&state, &headers).await.unwrap(), "user-a");
        assert_eq!(
            project_publisher_user(&state, &headers, Some("user-b"))
                .await
                .unwrap_err()
                .status(),
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn cached_daily_weekly_and_stale_fallback_keep_source_data() {
        let state = test_state().await;
        for (key, payload) in [("github:daily", "[1,2]"), ("github:weekly", "[3,4]")] {
            sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale) VALUES (?,?,?, ?,0)")
                .bind(key)
                .bind(payload)
                .bind(now())
                .bind("githot.dev")
                .execute(&state.pool)
                .await
                .unwrap();
        }
        let daily = get_cache(&state, "github:daily", json!([]), Duration::hours(36)).await;
        let weekly = get_cache(&state, "github:weekly", json!([]), Duration::days(8)).await;
        assert_eq!(daily.data, json!([1, 2]));
        assert_eq!(weekly.data, json!([3, 4]));
        assert!(!daily.stale);
        assert!(!weekly.stale);
        sqlx::query(
            "UPDATE news_cache SET stale=1,error='source timeout' WHERE cache_key='github:daily'",
        )
        .execute(&state.pool)
        .await
        .unwrap();
        let fallback = get_cache(&state, "github:daily", json!([]), Duration::hours(36)).await;
        assert_eq!(fallback.data, json!([1, 2]));
        assert!(fallback.stale);
        assert_eq!(fallback.error.as_deref(), Some("source timeout"));
    }

    #[tokio::test]
    async fn github_combined_cache_projects_legacy_and_brief_responses() {
        let state = test_state().await;
        let combined = json!({
            "repositories":[{"repository":"owner/repo"}],
            "brief":{"title":"Daily","summary":"Summary","themes":[],"highlights":[],"analysisStatus":"complete","source":"codex"}
        });
        sqlx::query("INSERT INTO news_cache(cache_key,data_json,updated_at,source,stale) VALUES ('github:daily',?,?,?,0)")
            .bind(serde_json::to_string(&combined).unwrap())
            .bind(now())
            .bind("githot.dev")
            .execute(&state.pool)
            .await
            .unwrap();
        let cached = get_cache(&state, "github:daily", json!([]), Duration::hours(36)).await;
        assert_eq!(
            github_list_view(cached.data.clone()),
            json!([{"repository":"owner/repo"}])
        );
        assert_eq!(github_brief(&cached.data)["title"], "Daily");

        sqlx::query("UPDATE news_cache SET data_json=? WHERE cache_key='github:daily'")
            .bind(r#"[{"repository":"owner/legacy"}]"#)
            .execute(&state.pool)
            .await
            .unwrap();
        let legacy = get_cache(&state, "github:daily", json!([]), Duration::hours(36)).await;
        assert_eq!(
            github_list_view(legacy.data.clone()),
            json!([{"repository":"owner/legacy"}])
        );
        assert_eq!(github_brief(&legacy.data), json!({}));
    }

    #[tokio::test]
    async fn successful_publish_is_idempotent_and_rejects_payload_reuse() {
        let state = test_state().await;
        let input = PublishInput {
            task_id: "publish-1".into(),
            source: "githot.dev".into(),
            generated_at: None,
            result: json!([{"repository":"owner/repo"}]),
            user_id: None,
            project_id: None,
            period: None,
            report_date: None,
            idempotency_key: Some("publish-1".into()),
            error: None,
        };
        assert!(start_task(&state, &input, "user-a", "github/daily")
            .await
            .unwrap()
            .is_none());
        finish_task(&state, &input, &input.result).await.unwrap();
        assert_eq!(
            start_task(&state, &input, "user-a", "github/daily")
                .await
                .unwrap()
                .unwrap()["status"],
            "succeeded"
        );
        let mut different = input;
        different.result = json!([{"repository":"other/repo"}]);
        assert_eq!(
            start_task(&state, &different, "user-a", "github/daily")
                .await
                .unwrap_err()
                .status(),
            StatusCode::CONFLICT
        );
    }

    #[tokio::test]
    async fn failed_publish_can_retry_only_with_the_same_request() {
        let state = test_state().await;
        let input = PublishInput {
            task_id: "retry-1".into(),
            source: "githot.dev".into(),
            generated_at: None,
            result: json!([{"repository":"owner/repo"}]),
            user_id: None,
            project_id: None,
            period: Some("daily".into()),
            report_date: None,
            idempotency_key: Some("retry-1".into()),
            error: None,
        };
        assert!(start_task(&state, &input, "user-a", "github/daily")
            .await
            .unwrap()
            .is_none());
        sqlx::query("UPDATE news_publish_tasks SET status='failed',finished_at=?,error='temporary write failure' WHERE task_id=?")
            .bind(now())
            .bind(&input.task_id)
            .execute(&state.pool)
            .await
            .unwrap();
        assert!(start_task(&state, &input, "user-a", "github/daily")
            .await
            .unwrap()
            .is_none());
        let mut changed = input;
        changed.source = "attacker.example".into();
        assert_eq!(
            start_task(&state, &changed, "user-a", "github/daily")
                .await
                .unwrap_err()
                .status(),
            StatusCode::CONFLICT
        );
    }
}
