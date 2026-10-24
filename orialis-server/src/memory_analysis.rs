//! User-scoped background analysis, independent of chat history and sync.
use crate::{agent_gateway::protocol::GatewayMessage, authenticated_user, AppError, AppState};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};

const TARGET_DEVICE: &str = "JXCZ_AOZORA_Hermes";
const TIMEOUT_SECONDS: i64 = 300;
const FAILED: &str = "Azure Hermes 暂未完成理解，原始记忆已保留，可稍后重试";
const TIMED_OUT: &str = "Azure Hermes 理解超时，原始记忆已保留，可稍后重试";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AnalysisInput {
    content: String,
    image_base64: Option<String>,
    #[serde(default)]
    source_urls: Vec<String>,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Analysis {
    id: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    source_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    video_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    video_summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    video_error: Option<String>,
}

pub(crate) fn validate_input(content: &str, image: Option<&str>) -> Result<(), AppError> {
    if content.trim().is_empty() || content.len() > 100_000 {
        return Err(AppError::BadRequest(
            "analysis content must contain 1-100000 bytes".into(),
        ));
    }
    if let Some(image) = image {
        if image.len() > 900 * 1024 * 4 / 3 {
            return Err(AppError::BadRequest("screenshot exceeds 900 KiB".into()));
        }
        let decoded = STANDARD
            .decode(image)
            .map_err(|_| AppError::BadRequest("invalid screenshot encoding".into()))?;
        if decoded.len() > 900 * 1024
            || !decoded.starts_with(&[0xff, 0xd8, 0xff])
            || !decoded.ends_with(&[0xff, 0xd9])
        {
            return Err(AppError::BadRequest(
                "a JPEG screenshot up to 900 KiB is required".into(),
            ));
        }
    }
    Ok(())
}

fn valid_web_url(value: &str) -> bool {
    if value.is_empty()
        || value.trim() != value
        || value.len() > 8192
        || value.chars().any(char::is_control)
    {
        return false;
    }
    url::Url::parse(value).is_ok_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.has_host()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

pub(crate) fn validate_source_urls(urls: &[String]) -> Result<(), AppError> {
    if urls.len() > 32 || urls.iter().any(|url| !valid_web_url(url)) {
        return Err(AppError::BadRequest(
            "sourceUrls must contain up to 32 HTTP(S) URLs".into(),
        ));
    }
    Ok(())
}

pub(crate) fn valid_metadata(
    category: Option<&str>,
    source_url: Option<&str>,
    video_status: Option<&str>,
    video_summary: Option<&str>,
    video_error: Option<&str>,
) -> bool {
    category.is_none_or(|value| matches!(value, "ai" | "other"))
        && source_url.is_none_or(valid_web_url)
        && video_status.is_none_or(|value| matches!(value, "none" | "analyzed" | "unavailable"))
        && video_summary.is_none_or(|value| !value.trim().is_empty() && value.len() <= 100_000)
        && video_error.is_none_or(|value| !value.trim().is_empty() && value.len() <= 4000)
        && (video_status != Some("analyzed") || video_summary.is_some())
}

fn valid_summary(content: &str) -> bool {
    let mut lines = content.trim().lines();
    lines
        .next()
        .and_then(|line| line.trim().strip_prefix("# "))
        .is_some_and(|title| !title.trim().is_empty())
        && lines.any(|line| !line.trim().is_empty())
}

fn validate_id(id: &str) -> Result<(), AppError> {
    if id.is_empty()
        || id.len() > 160
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
    {
        return Err(AppError::BadRequest("invalid analysis id".into()));
    }
    Ok(())
}

async fn expire(state: &AppState, user: &str, id: &str) -> Result<(), AppError> {
    sqlx::query("UPDATE memory_analyses SET status='failed',error=? WHERE user_id=? AND id=? AND status='analyzing' AND started_at<=?")
        .bind(TIMED_OUT).bind(user).bind(id).bind(Utc::now().timestamp() - TIMEOUT_SECONDS)
        .execute(&state.pool).await?;
    Ok(())
}

async fn read(state: &AppState, user: &str, id: &str) -> Result<Analysis, AppError> {
    sqlx::query_as::<_, Analysis>(
        "SELECT id,status,content,error,category,source_url,video_status,video_summary,video_error FROM memory_analyses WHERE user_id=? AND id=?",
    )
    .bind(user)
    .bind(id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::NotFound)
}

pub(crate) async fn get_analysis(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Analysis>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    expire(&state, &user, &id).await?;
    Ok(Json(read(&state, &user, &id).await?))
}

pub(crate) async fn start_analysis(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<AnalysisInput>,
) -> Result<Json<Analysis>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    validate_input(&input.content, input.image_base64.as_deref())?;
    validate_source_urls(&input.source_urls)?;
    let mut hash = Sha256::new();
    hash.update(input.content.len().to_be_bytes());
    hash.update(input.content.as_bytes());
    hash.update(input.image_base64.as_deref().unwrap_or("").as_bytes());
    // Preserve the original fingerprint for legacy callers without sourceUrls.
    for url in &input.source_urls {
        hash.update((url.len() as u64).to_be_bytes());
        hash.update(url.as_bytes());
    }
    let fingerprint = format!("{:x}", hash.finalize());
    expire(&state, &user, &id).await?;
    let prior = sqlx::query_as::<_, (String, String)>(
        "SELECT fingerprint,status FROM memory_analyses WHERE user_id=? AND id=?",
    )
    .bind(&user)
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?;
    if let Some((previous, status)) = prior {
        if previous != fingerprint {
            return Err(AppError::Conflict(
                "analysis id already belongs to different evidence".into(),
            ));
        }
        if status != "failed" {
            return Ok(Json(read(&state, &user, &id).await?));
        }
    }
    if !state
        .agent
        .supports_for_user(&user, TARGET_DEVICE, "memory.analyze")
        .await
    {
        return Err(AppError::ServiceUnavailable(
            "Azure Hermes background analysis is unavailable".into(),
        ));
    }
    let request_id = format!("memory-{}", uuid::Uuid::new_v4());
    let claimed = sqlx::query("INSERT INTO memory_analyses (user_id,id,fingerprint,request_id,status,started_at) VALUES (?,?,?,?,'analyzing',?) ON CONFLICT(user_id,id) DO UPDATE SET request_id=excluded.request_id,status='analyzing',content=NULL,error=NULL,category=NULL,source_url=NULL,video_status=NULL,video_summary=NULL,video_error=NULL,started_at=excluded.started_at WHERE memory_analyses.status='failed' AND memory_analyses.fingerprint=excluded.fingerprint")
        .bind(&user).bind(&id).bind(&fingerprint).bind(&request_id).bind(Utc::now().timestamp())
        .execute(&state.pool).await?.rows_affected();
    if claimed == 0 {
        // A concurrent first submission owns this ID; do not duplicate its run.
        let stored: String =
            sqlx::query_scalar("SELECT fingerprint FROM memory_analyses WHERE user_id=? AND id=?")
                .bind(&user)
                .bind(&id)
                .fetch_one(&state.pool)
                .await?;
        if stored != fingerprint {
            return Err(AppError::Conflict(
                "analysis id already belongs to different evidence".into(),
            ));
        }
        return Ok(Json(read(&state, &user, &id).await?));
    }
    let response = read(&state, &user, &id).await?;
    tokio::spawn(async move {
        let frame = GatewayMessage::MemoryAnalyze {
            version: 1,
            request_id: request_id.clone(),
            content: input.content,
            image_base64: input.image_base64,
            source_urls: input.source_urls,
        };
        let result = async {
            let receiver = state
                .agent
                .send_request_for_user(&user, Some(TARGET_DEVICE), frame)
                .await
                .ok()?;
            receiver.await.ok()
        };
        let (content, error, category, source_url, video_status, video_summary, video_error) =
            match tokio::time::timeout(Duration::from_secs(TIMEOUT_SECONDS as u64), result).await {
                Ok(Some(GatewayMessage::MemoryResult {
                    content: Some(content),
                    error: None,
                    category,
                    source_url,
                    video_status,
                    video_summary,
                    video_error,
                    ..
                })) if valid_summary(&content)
                    && content.len() <= 100_000
                    && valid_metadata(
                        category.as_deref(),
                        source_url.as_deref(),
                        video_status.as_deref(),
                        video_summary.as_deref(),
                        video_error.as_deref(),
                    ) =>
                {
                    (
                        Some(content),
                        None,
                        category,
                        source_url,
                        video_status,
                        video_summary,
                        video_error,
                    )
                }
                Err(_) => (None, Some(TIMED_OUT), None, None, None, None, None),
                _ => (None, Some(FAILED), None, None, None, None, None),
            };
        state.agent.cancel_request(&request_id).await;
        let status = if content.is_some() {
            "completed"
        } else {
            "failed"
        };
        if let Err(error) = sqlx::query("UPDATE memory_analyses SET status=?,content=?,error=?,category=?,source_url=?,video_status=?,video_summary=?,video_error=? WHERE user_id=? AND id=? AND request_id=? AND status='analyzing'")
            .bind(status).bind(content).bind(error).bind(category).bind(source_url).bind(video_status).bind(video_summary).bind(video_error).bind(&user).bind(&id).bind(&request_id).execute(&state.pool).await {
            tracing::error!(%error, "could not save background memory analysis");
        }
    });
    Ok(Json(response))
}

#[cfg(test)]
mod tests;
