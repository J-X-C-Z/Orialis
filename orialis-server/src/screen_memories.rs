//! Account-scoped text mirrors of screen captures; original evidence is immutable.
use crate::{authenticated_user, AppError, AppState};
use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};
use std::sync::Arc;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Record {
    id: String,
    created_at: String,
    source_package: String,
    source_label: String,
    visible_text: String,
    shared_text: Option<String>,
    #[serde(default)]
    urls: Vec<String>,
    title: String,
    summary: Option<String>,
    #[serde(default)]
    notes: String,
    category: Option<String>,
    source_url: Option<String>,
    video_status: Option<String>,
    video_summary: Option<String>,
    video_error: Option<String>,
    analysis_status: Option<String>,
    analysis_error: Option<String>,
    analysis_request_id: Option<String>,
    image_sha256: Option<String>,
}

pub(crate) struct PutRecord {
    record: Record,
    base_version: Option<i64>,
}
impl<'de> Deserialize<'de> for PutRecord {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let mut value = Value::deserialize(deserializer)?;
        let object = value
            .as_object_mut()
            .ok_or_else(|| serde::de::Error::custom("memory must be an object"))?;
        let base_version = object
            .remove("baseVersion")
            .map(serde_json::from_value::<i64>)
            .transpose()
            .map_err(serde::de::Error::custom)?;
        let record = serde_json::from_value(value).map_err(serde::de::Error::custom)?;
        Ok(Self {
            record,
            base_version,
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PatchRecord {
    base_version: i64,
    change_reason: String,
    #[serde(default, deserialize_with = "crate::deserialize_patch")]
    title: Option<crate::PatchValue<String>>,
    #[serde(default, deserialize_with = "crate::deserialize_patch")]
    summary: Option<crate::PatchValue<String>>,
    #[serde(default, deserialize_with = "crate::deserialize_patch")]
    notes: Option<crate::PatchValue<String>>,
    #[serde(default, deserialize_with = "crate::deserialize_patch")]
    category: Option<crate::PatchValue<String>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SavedRecord {
    #[serde(flatten)]
    record: Record,
    version: i64,
    updated_at: String,
    deleted_at: Option<String>,
}
#[derive(FromRow)]
struct Row {
    record_json: String,
    version: i64,
    updated_at: String,
    deleted_at: Option<String>,
}
impl Row {
    fn decode(self) -> Result<SavedRecord, AppError> {
        let record = serde_json::from_str(&self.record_json)
            .map_err(|_| AppError::ServiceUnavailable("stored memory is invalid".into()))?;
        Ok(SavedRecord {
            record,
            version: self.version,
            updated_at: self.updated_at,
            deleted_at: self.deleted_at,
        })
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ListQuery {
    query: Option<String>,
    after: Option<String>,
    limit: Option<i64>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HistoryQuery {
    limit: Option<i64>,
}

fn bad(message: &str) -> AppError {
    AppError::BadRequest(message.into())
}
fn validate_id(id: &str) -> Result<(), AppError> {
    if id.is_empty()
        || id.len() > 160
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
    {
        return Err(bad("invalid memory id"));
    }
    Ok(())
}
fn limit(value: Option<i64>) -> Result<i64, AppError> {
    let value = value.unwrap_or(50);
    if !(1..=100).contains(&value) {
        return Err(bad("limit must be between 1 and 100"));
    }
    Ok(value)
}
fn text(value: &str, max: usize, required: bool) -> Result<(), AppError> {
    if value.len() > max || (required && value.trim().is_empty()) || value.contains('\0') {
        return Err(bad("invalid memory text length or content"));
    }
    Ok(())
}
fn web_url(value: &str) -> bool {
    value.len() <= 8192
        && value.trim() == value
        && !value.chars().any(char::is_control)
        && url::Url::parse(value).is_ok_and(|url| {
            matches!(url.scheme(), "http" | "https")
                && url.has_host()
                && url.username().is_empty()
                && url.password().is_none()
        })
}
pub(crate) fn validate(record: &Record) -> Result<(), AppError> {
    validate_id(&record.id)?;
    let time = DateTime::parse_from_rfc3339(&record.created_at)
        .map_err(|_| bad("createdAt must be a UTC RFC 3339 timestamp"))?;
    if !record.created_at.is_ascii() || time.offset().local_minus_utc() != 0 {
        return Err(bad("createdAt must be a UTC RFC 3339 timestamp"));
    }
    text(&record.title, 500, true)?;
    text(&record.source_package, 512, false)?;
    text(&record.source_label, 512, false)?;
    for value in [&record.visible_text, &record.notes] {
        text(value, 256_000, false)?;
    }
    if let Some(value) = &record.shared_text {
        text(value, 256_000, false)?;
    }
    for value in [&record.summary, &record.video_summary]
        .into_iter()
        .flatten()
    {
        text(value, 100_000, false)?;
    }
    if let Some(value) = &record.video_error {
        text(value, 4000, false)?;
    }
    if record
        .category
        .as_deref()
        .is_some_and(|v| !matches!(v, "ai" | "other"))
    {
        return Err(bad("category must be ai, other or null"));
    }
    if record.urls.len() > 32
        || record.urls.iter().any(|v| !web_url(v))
        || record.source_url.as_deref().is_some_and(|v| !web_url(v))
    {
        return Err(bad("memory URLs must be HTTP(S) URLs without credentials"));
    }
    if record
        .video_status
        .as_deref()
        .is_some_and(|v| !matches!(v, "none" | "analyzed" | "unavailable"))
    {
        return Err(bad("invalid videoStatus"));
    }
    if record.video_status.as_deref() == Some("analyzed")
        && record
            .video_summary
            .as_deref()
            .is_none_or(|v| v.trim().is_empty())
    {
        return Err(bad("analyzed video requires videoSummary"));
    }
    if let Some(value) = &record.analysis_error {
        text(value, 4000, false)?;
    }
    if let Some(value) = &record.analysis_request_id {
        text(value, 500, false)?;
    }
    if record
        .analysis_status
        .as_deref()
        .is_some_and(|s| !["pending", "analyzing", "completed", "failed"].contains(&s))
    {
        return Err(bad("invalid analysisStatus"));
    }
    if record.image_sha256.as_deref().is_some_and(|s| {
        s.len() != 64
            || !s
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }) {
        return Err(bad("invalid imageSha256"));
    }
    Ok(())
}
pub(crate) fn same_capture_time(a: &str, b: &str) -> bool {
    matches!((DateTime::parse_from_rfc3339(a), DateTime::parse_from_rfc3339(b)), (Ok(a), Ok(b)) if a == b)
}
fn same_evidence(a: &Record, b: &Record) -> bool {
    a.id == b.id
        && a.created_at == b.created_at
        && a.source_package == b.source_package
        && a.source_label == b.source_label
        && a.visible_text == b.visible_text
        && a.shared_text == b.shared_text
        && a.urls == b.urls
}
fn changed(before: Option<&Record>, after: &Record) -> Vec<String> {
    let after = serde_json::to_value(after).expect("record serialization");
    let before = before.map(|v| serde_json::to_value(v).expect("record serialization"));
    after
        .as_object()
        .expect("record object")
        .iter()
        .filter(|(key, value)| before.as_ref().and_then(|v| v.get(*key)) != Some(*value))
        .map(|(key, _)| key.clone())
        .collect()
}
async fn read(pool: &SqlitePool, user: &str, id: &str) -> Result<SavedRecord, AppError> {
    sqlx::query_as::<_, Row>(
        "SELECT record_json,version,updated_at,deleted_at FROM screen_memories WHERE user_id=? AND id=?",
    )
    .bind(user)
    .bind(id)
    .fetch_optional(pool)
    .await?
    .ok_or(AppError::NotFound)?
    .decode()
}
async fn save(
    pool: &SqlitePool,
    user: &str,
    before: Option<&SavedRecord>,
    record: Record,
    source: &str,
    reason: &str,
) -> Result<SavedRecord, AppError> {
    let version = before.map_or(1, |v| v.version + 1);
    let now = Utc::now().to_rfc3339();
    let fields = changed(before.map(|v| &v.record), &record);
    let payload = serde_json::to_string(&record).expect("record serialization");
    let mut tx = pool.begin().await?;
    let affected = if let Some(before) = before {
        sqlx::query("UPDATE screen_memories SET record_json=?,version=?,updated_at=? WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL")
            .bind(payload).bind(version).bind(&now).bind(user).bind(&record.id).bind(before.version).execute(&mut *tx).await?.rows_affected()
    } else {
        sqlx::query("INSERT INTO screen_memories (user_id,id,record_json,version,updated_at,created_at) VALUES (?,?,?,?,?,?) ON CONFLICT(user_id,id) DO NOTHING")
            .bind(user).bind(&record.id).bind(payload).bind(version).bind(&now).bind(&record.created_at).execute(&mut *tx).await?.rows_affected()
    };
    if affected != 1 {
        return Err(AppError::Conflict(
            "memory version changed; re-read before retrying".into(),
        ));
    }
    sqlx::query("INSERT INTO screen_memory_history (user_id,memory_id,version,source,change_reason,changed_fields,created_at) VALUES (?,?,?,?,?,?,?)")
        .bind(user).bind(&record.id).bind(version).bind(source).bind(reason).bind(serde_json::to_string(&fields).expect("fields serialization")).bind(&now).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(SavedRecord {
        record,
        version,
        updated_at: now,
        deleted_at: None,
    })
}

pub(crate) async fn get_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<SavedRecord>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    let record = read(&state.pool, &user, &id).await?;
    if record.deleted_at.is_some() {
        return Err(AppError::NotFound);
    }
    Ok(Json(record))
}
pub(crate) async fn put_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(mut input): Json<PutRecord>,
) -> Result<Json<SavedRecord>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    validate(&input.record)?;
    if id != input.record.id {
        return Err(bad("body id must match path id"));
    }
    let before = match read(&state.pool, &user, &id).await {
        Ok(v) => Some(v),
        Err(AppError::NotFound) => None,
        Err(e) => return Err(e),
    };
    if let Some(before) = &before {
        // Clients serialize UTC fractions differently; retain the original capture spelling.
        if same_capture_time(&before.record.created_at, &input.record.created_at) {
            input
                .record
                .created_at
                .clone_from(&before.record.created_at);
        }
        if before.deleted_at.is_some()
            || input.base_version != Some(before.version)
            || !same_evidence(&before.record, &input.record)
        {
            return Err(AppError::Conflict(
                "baseVersion or original evidence differs; re-read before retrying".into(),
            ));
        }
    } else if input.base_version.is_some() {
        return Err(AppError::Conflict(
            "memory does not exist; initial sync must omit baseVersion".into(),
        ));
    }
    if let Some(hash) = input.record.image_sha256.as_deref() {
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
    if before
        .as_ref()
        .and_then(|v| v.record.image_sha256.as_ref())
        .is_some_and(|old| Some(old) != input.record.image_sha256.as_ref())
    {
        return Err(AppError::Conflict(
            "original image cannot be replaced".into(),
        ));
    }
    Ok(Json(
        save(
            &state.pool,
            &user,
            before.as_ref(),
            input.record,
            "device-sync",
            "Device text synchronization",
        )
        .await?,
    ))
}
pub(crate) async fn patch_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<PatchRecord>,
) -> Result<Json<SavedRecord>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    text(&input.change_reason, 2000, true)?;
    if input.base_version < 1 {
        return Err(bad("baseVersion must be positive"));
    }
    if input.title.is_none()
        && input.summary.is_none()
        && input.notes.is_none()
        && input.category.is_none()
    {
        return Err(bad("supply at least one editable field"));
    }
    let before = read(&state.pool, &user, &id).await?;
    if before.deleted_at.is_some() || before.version != input.base_version {
        return Err(AppError::Conflict(
            "memory version changed; re-read before retrying".into(),
        ));
    }
    let mut record = before.record.clone();
    for (field, patch) in [
        (&mut record.title, input.title),
        (&mut record.notes, input.notes),
    ] {
        match patch {
            Some(crate::PatchValue::Value(value)) => *field = value,
            Some(crate::PatchValue::Null(())) => return Err(bad("title and notes cannot be null")),
            None => {}
        }
    }
    for (field, patch) in [
        (&mut record.summary, input.summary),
        (&mut record.category, input.category),
    ] {
        match patch {
            Some(crate::PatchValue::Value(value)) => *field = Some(value),
            Some(crate::PatchValue::Null(())) => *field = None,
            None => {}
        }
    }
    validate(&record)?;
    Ok(Json(
        save(
            &state.pool,
            &user,
            Some(&before),
            record,
            "mcp",
            &input.change_reason,
        )
        .await?,
    ))
}
pub(crate) async fn list_records(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    let size = limit(query.limit)?;
    if let Some(after) = &query.after {
        validate_id(after)?;
    }
    let needle = query.query.unwrap_or_default();
    text(&needle, 1000, false)?;
    let rows = sqlx::query_as::<_, Row>("SELECT record_json,version,updated_at,deleted_at FROM screen_memories WHERE user_id=? AND deleted_at IS NULL AND (? IS NULL OR id>?) AND instr(lower(coalesce(json_extract(record_json,'$.title'),'') || ' ' || coalesce(json_extract(record_json,'$.summary'),'') || ' ' || coalesce(json_extract(record_json,'$.notes'),'') || ' ' || coalesce(json_extract(record_json,'$.visibleText'),'') || ' ' || coalesce(json_extract(record_json,'$.sharedText'),'') || ' ' || coalesce(json_extract(record_json,'$.sourceLabel'),'') || ' ' || coalesce(json_extract(record_json,'$.sourcePackage'),'') || ' ' || coalesce(json_extract(record_json,'$.videoSummary'),'') || ' ' || coalesce(json_extract(record_json,'$.sourceUrl'),'') || ' ' || coalesce(json_extract(record_json,'$.urls'),'')), lower(?))>0 ORDER BY id LIMIT ?")
        .bind(user).bind(&query.after).bind(&query.after).bind(&needle).bind(size+1).fetch_all(&state.pool).await?;
    let mut records = rows
        .into_iter()
        .map(Row::decode)
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = records.len() > size as usize;
    records.truncate(size as usize);
    let cursor = if has_more {
        records.last().map(|v| v.record.id.clone())
    } else {
        None
    };
    let items: Vec<Value> = records.into_iter().map(|v| json!({"id":v.record.id,"title":v.record.title,"createdAt":v.record.created_at,"sourceLabel":v.record.source_label,"category":v.record.category,"version":v.version,"updatedAt":v.updated_at,"summaryPreview":v.record.summary.as_deref().unwrap_or("").chars().take(300).collect::<String>()})).collect();
    Ok(Json(
        json!({"items":items,"nextCursor":cursor,"hasMore":has_more}),
    ))
}
pub(crate) async fn history(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<Value>, AppError> {
    let user = authenticated_user(&headers, &state.pool).await?;
    validate_id(&id)?;
    let size = limit(query.limit)?;
    read(&state.pool, &user, &id).await?;
    let rows = sqlx::query_as::<_, (i64,String,String,String,String)>("SELECT version,source,change_reason,changed_fields,created_at FROM screen_memory_history WHERE user_id=? AND memory_id=? ORDER BY version DESC LIMIT ?")
        .bind(user).bind(&id).bind(size).fetch_all(&state.pool).await?;
    let items: Vec<Value> = rows.into_iter().map(|(version,source,reason,fields,time)| json!({"version":version,"source":source,"changeReason":reason,"changedFields":serde_json::from_str::<Vec<String>>(&fields).unwrap_or_default(),"createdAt":time})).collect();
    Ok(Json(json!({"items":items})))
}

#[cfg(test)]
mod tests;
