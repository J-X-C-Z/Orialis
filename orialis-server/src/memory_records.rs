//! Account-owned source memories. Device paths never leave their originating device.
use crate::{authenticated_user, AppError, AppState};
use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::sync::Arc;

pub(crate) const MAX_IMAGE_BYTES: usize = 32 * 1024 * 1024;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PutRecord {
    record: Map<String, Value>,
    expected_version: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ListQuery {
    query: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    include_deleted: Option<bool>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DeleteQuery {
    expected_version: i64,
}
#[derive(sqlx::FromRow)]
struct Row {
    record_json: String,
    version: i64,
    updated_at: String,
    deleted_at: Option<String>,
}
impl Row {
    fn value(self) -> Result<Value, AppError> {
        let mut value: Value = serde_json::from_str(&self.record_json)
            .map_err(|_| AppError::ServiceUnavailable("stored memory is invalid".into()))?;
        value["version"] = json!(self.version);
        value["updatedAt"] = json!(self.updated_at);
        value["deletedAt"] = json!(self.deleted_at);
        Ok(value)
    }
}
fn bad(message: &str) -> AppError {
    AppError::BadRequest(message.into())
}
fn id_valid(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 160
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn hash_valid(hash: &str) -> bool {
    hash.len() == 64
        && hash
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn validate(id: &str, record: &Map<String, Value>) -> Result<(), AppError> {
    if !id_valid(id) || record.get("id").and_then(Value::as_str) != Some(id) {
        return Err(bad("invalid memory id"));
    }
    let allowed = [
        "id",
        "createdAt",
        "sourcePackage",
        "sourceLabel",
        "visibleText",
        "sharedText",
        "urls",
        "title",
        "summary",
        "notes",
        "category",
        "sourceUrl",
        "videoStatus",
        "videoSummary",
        "videoError",
        "analysisStatus",
        "analysisError",
        "analysisRequestId",
        "imageSha256",
    ];
    if record.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err(bad("unsupported memory field"));
    }
    if serde_json::to_vec(record)
        .map_err(|_| bad("invalid memory"))?
        .len()
        > 1024 * 1024
    {
        return Err(bad("memory is too large"));
    }
    for (key, value) in record {
        if key == "urls" {
            let links = value.as_array().ok_or_else(|| bad("invalid memory urls"))?;
            if links.len() > 64 || links.iter().any(|v| !v.as_str().is_some_and(web_url)) {
                return Err(bad("invalid memory urls"));
            }
        } else if !value.is_null() && !value.as_str().is_some_and(|s| s.len() <= 256_000) {
            return Err(bad("invalid memory text"));
        }
    }
    let created = record
        .get("createdAt")
        .and_then(Value::as_str)
        .ok_or_else(|| bad("createdAt is required"))?;
    DateTime::parse_from_rfc3339(created).map_err(|_| bad("invalid createdAt"))?;
    for key in ["category", "videoStatus", "analysisStatus"] {
        if let Some(value) = record.get(key).and_then(Value::as_str) {
            let valid = match key {
                "category" => ["ai", "other"].contains(&value),
                "videoStatus" => ["none", "analyzed", "unavailable"].contains(&value),
                _ => ["pending", "analyzing", "completed", "failed"].contains(&value),
            };
            if !valid {
                return Err(bad("invalid memory status"));
            }
        }
    }
    if let Some(s) = record.get("sourceUrl").and_then(Value::as_str) {
        if !web_url(s) {
            return Err(bad("invalid source URL"));
        }
    }
    if let Some(hash) = record.get("imageSha256").and_then(Value::as_str) {
        if !hash_valid(hash) {
            return Err(bad("invalid image hash"));
        }
    }
    Ok(())
}
fn web_url(s: &str) -> bool {
    s.len() <= 8192
        && url::Url::parse(s).is_ok_and(|u| {
            ["http", "https"].contains(&u.scheme())
                && u.host_str().is_some()
                && u.username().is_empty()
                && u.password().is_none()
        })
}
async fn read(state: &AppState, user: &str, id: &str) -> Result<Row, AppError> {
    sqlx::query_as::<_,Row>("SELECT record_json,version,updated_at,deleted_at FROM screen_memories WHERE user_id=? AND id=?").bind(user).bind(id).fetch_optional(&state.pool).await?.ok_or(AppError::NotFound)
}
pub(crate) async fn get_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    Ok(Json(read(&state, &user, &id).await?.value()?))
}
pub(crate) async fn list_records(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    let limit = query.limit.unwrap_or(100);
    let offset = query.offset.unwrap_or(0);
    if !(1..=200).contains(&limit)
        || offset < 0
        || query.query.as_ref().is_some_and(|q| q.len() > 1000)
    {
        return Err(bad("invalid memory page"));
    }
    let needle = query.query.unwrap_or_default().to_lowercase();
    // instr treats search text literally; user '%' and '_' are not SQL patterns.
    let rows=sqlx::query_as::<_,Row>("SELECT record_json,version,updated_at,deleted_at FROM screen_memories WHERE user_id=? AND (? OR deleted_at IS NULL) AND (?='' OR instr(lower(coalesce(json_extract(record_json,'$.title'),'')||char(10)||coalesce(json_extract(record_json,'$.visibleText'),'')||char(10)||coalesce(json_extract(record_json,'$.sharedText'),'')||char(10)||coalesce(json_extract(record_json,'$.summary'),'')||char(10)||coalesce(json_extract(record_json,'$.notes'),'')||char(10)||coalesce(json_extract(record_json,'$.videoSummary'),'')||char(10)||coalesce(json_extract(record_json,'$.sourceLabel'),'')||char(10)||coalesce(json_extract(record_json,'$.sourcePackage'),'')||char(10)||coalesce(json_extract(record_json,'$.sourceUrl'),'')||char(10)||coalesce(json_extract(record_json,'$.urls'),'')),?)>0) ORDER BY created_at,id LIMIT ? OFFSET ?")
        .bind(user).bind(query.include_deleted.unwrap_or(true)).bind(&needle).bind(&needle).bind(limit+1).bind(offset).fetch_all(&state.pool).await?;
    let more = rows.len() > limit as usize;
    let values = rows
        .into_iter()
        .take(limit as usize)
        .map(Row::value)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(json!({"items":values,"hasMore":more})))
}
pub(crate) async fn put_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<PutRecord>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate(&id, &input.record)?;
    if input.expected_version < 0 {
        return Err(bad("invalid expectedVersion"));
    }
    // Normalize through the same record type used by the MCP facade.
    let record: crate::screen_memories::Record =
        serde_json::from_value(json!(input.record)).map_err(|_| bad("invalid memory fields"))?;
    crate::screen_memories::validate(&record)?;
    let mut value = serde_json::to_value(record).map_err(|_| bad("invalid memory"))?;
    if let Some(hash) = value.get("imageSha256").and_then(Value::as_str) {
        if sqlx::query_scalar::<_, i64>("SELECT 1 FROM memory_images WHERE user_id=? AND sha256=?")
            .bind(&user)
            .bind(hash)
            .fetch_optional(&state.pool)
            .await?
            .is_none()
        {
            return Err(bad("upload the account image first"));
        }
    }
    let before = sqlx::query_as::<_,Row>("SELECT record_json,version,updated_at,deleted_at FROM screen_memories WHERE user_id=? AND id=?").bind(&user).bind(&id).fetch_optional(&state.pool).await?;
    let previous = before
        .as_ref()
        .map(|row| serde_json::from_str::<Value>(&row.record_json))
        .transpose()
        .map_err(|_| AppError::ServiceUnavailable("stored memory is invalid".into()))?;
    if let Some(row) = &before {
        if row.deleted_at.is_some() {
            return Err(AppError::Conflict(
                "deleted memory cannot be resurrected".into(),
            ));
        }
        let old = previous.as_ref().unwrap();
        if let (Some(stored), Some(incoming)) =
            (old["createdAt"].as_str(), value["createdAt"].as_str())
        {
            if crate::screen_memories::same_capture_time(stored, incoming) {
                value["createdAt"] = json!(stored);
            }
        }
        for field in [
            "id",
            "createdAt",
            "sourcePackage",
            "sourceLabel",
            "visibleText",
            "sharedText",
            "urls",
        ] {
            if old.get(field).unwrap_or(&Value::Null) != value.get(field).unwrap_or(&Value::Null) {
                return Err(AppError::Conflict(
                    "original capture evidence cannot be changed".into(),
                ));
            }
        }
        if old.get("imageSha256").and_then(Value::as_str).is_some()
            && old.get("imageSha256") != value.get("imageSha256")
        {
            return Err(AppError::Conflict(
                "original image cannot be replaced".into(),
            ));
        }
        if old == &value {
            return Ok(Json(read(&state, &user, &id).await?.value()?));
        }
        if row.version != input.expected_version {
            return Err(AppError::Conflict(
                "memory has changed; pull before updating".into(),
            ));
        }
    } else if input.expected_version != 0 {
        return Err(AppError::Conflict(
            "memory does not exist; initial version must be zero".into(),
        ));
    }
    let data = serde_json::to_string(&value).map_err(|_| bad("invalid memory"))?;
    let stamp = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let created = value["createdAt"].as_str().unwrap();
    let version = input.expected_version + 1;
    let mut tx = state.pool.begin().await?;
    let affected = if input.expected_version == 0 {
        sqlx::query("INSERT INTO screen_memories(user_id,id,record_json,created_at,version,updated_at) VALUES(?,?,?,?,1,?) ON CONFLICT(user_id,id) DO NOTHING").bind(&user).bind(&id).bind(&data).bind(created).bind(&stamp).execute(&mut *tx).await?.rows_affected()
    } else {
        sqlx::query("UPDATE screen_memories SET record_json=?,version=version+1,updated_at=? WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL").bind(&data).bind(&stamp).bind(&user).bind(&id).bind(input.expected_version).execute(&mut *tx).await?.rows_affected()
    };
    if affected != 1 {
        return Err(AppError::Conflict(
            "memory version changed; re-read before retrying".into(),
        ));
    }
    let fields: Vec<_> = value
        .as_object()
        .unwrap()
        .iter()
        .filter(|(key, value)| previous.as_ref().and_then(|v| v.get(*key)) != Some(*value))
        .map(|(key, _)| key.clone())
        .collect();
    sqlx::query("INSERT INTO screen_memory_history(user_id,memory_id,version,source,change_reason,changed_fields,created_at) VALUES(?,?,?,'device-sync','Device memory synchronization',?,?)").bind(&user).bind(&id).bind(version).bind(json!(fields).to_string()).bind(&stamp).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(read(&state, &user, &id).await?.value()?))
}
pub(crate) async fn delete_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<DeleteQuery>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    if query.expected_version <= 0 {
        return Err(bad("invalid expectedVersion"));
    }
    let stamp = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let mut tx = state.pool.begin().await?;
    let changed=sqlx::query("UPDATE screen_memories SET version=version+1,updated_at=?,deleted_at=? WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL").bind(&stamp).bind(&stamp).bind(&user).bind(&id).bind(query.expected_version).execute(&mut *tx).await?.rows_affected();
    if changed == 1 {
        sqlx::query("INSERT INTO screen_memory_history(user_id,memory_id,version,source,change_reason,changed_fields,created_at) VALUES(?,?,?,'device-sync','Device memory deletion','[\"deletedAt\"]',?)").bind(&user).bind(&id).bind(query.expected_version+1).bind(&stamp).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    let row = read(&state, &user, &id).await?;
    if changed == 0 && row.deleted_at.is_none() {
        return Err(AppError::Conflict(
            "memory has changed; pull before deleting".into(),
        ));
    }
    Ok(Json(row.value()?))
}
fn image_path(state: &AppState, user: &str, hash: &str) -> std::path::PathBuf {
    state
        .upload_dir
        .join("memory")
        .join(format!("{:x}", Sha256::digest(user.as_bytes())))
        .join(hash)
}
fn image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}
pub(crate) async fn put_image(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
    bytes: Bytes,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    if !hash_valid(&hash) || bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return Err(bad("invalid image size or hash"));
    }
    let mime = image_mime(&bytes)
        .ok_or_else(|| bad("only original PNG, JPEG and WebP images are supported"))?;
    if format!("{:x}", Sha256::digest(&bytes)) != hash {
        return Err(bad("image SHA-256 mismatch"));
    }
    let path = image_path(&state, &user, &hash);
    let parent = path.parent().unwrap();
    tokio::fs::create_dir_all(parent)
        .await
        .map_err(|_| AppError::ServiceUnavailable("memory image storage unavailable".into()))?;
    // An atomic, unique temporary file lets concurrent identical uploads safely converge.
    let temp = parent.join(format!("{}.tmp", uuid::Uuid::new_v4()));
    tokio::fs::write(&temp, &bytes)
        .await
        .map_err(|_| AppError::ServiceUnavailable("memory image write failed".into()))?;
    if let Err(_) = tokio::fs::rename(&temp, &path).await {
        let _ = tokio::fs::remove_file(&temp).await;
        return Err(AppError::ServiceUnavailable(
            "memory image commit failed".into(),
        ));
    }
    sqlx::query("INSERT INTO memory_images(user_id,sha256,size_bytes,mime_type) VALUES(?,?,?,?) ON CONFLICT(user_id,sha256) DO NOTHING").bind(&user).bind(&hash).bind(bytes.len() as i64).bind(mime).execute(&state.pool).await?;
    Ok(Json(
        json!({"sha256":hash,"size":bytes.len(),"mimeType":mime}),
    ))
}
pub(crate) async fn get_image(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
) -> Result<Response, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    if !hash_valid(&hash) {
        return Err(AppError::NotFound);
    }
    let mime = sqlx::query_scalar::<_, String>(
        "SELECT mime_type FROM memory_images WHERE user_id=? AND sha256=?",
    )
    .bind(&user)
    .bind(&hash)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::NotFound)?;
    let bytes = tokio::fs::read(image_path(&state, &user, &hash))
        .await
        .map_err(|_| AppError::ServiceUnavailable("memory original image unavailable".into()))?;
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (header::CACHE_CONTROL, "private, no-store".into()),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".into()),
        ],
        bytes,
    )
        .into_response())
}
#[cfg(test)]
mod tests;
