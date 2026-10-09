use super::*;

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub(super) struct Schedule {
    pub(super) id: String,
    title: String,
    description: Option<String>,
    location: Option<String>,
    start_at: String,
    end_at: String,
    all_day: bool,
    important: bool,
    reminder_minutes: Option<i64>,
    created_at: String,
    updated_at: String,
    pub(super) version: i64,
    deleted_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ScheduleInput {
    pub(super) id: Option<String>,
    pub(super) title: String,
    pub(super) description: Option<String>,
    pub(super) location: Option<String>,
    pub(super) start_at: String,
    pub(super) end_at: String,
    pub(super) all_day: Option<bool>,
    pub(super) important: Option<bool>,
    pub(super) reminder_minutes: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SchedulePatch {
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
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) important: Option<PatchValue<bool>>,
    base_version: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ScheduleListResponse {
    items: Vec<Schedule>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
pub(super) struct ScheduleListQuery {
    after: Option<String>,
    limit: Option<i64>,
    from: Option<String>,
    to: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct ScheduleCursor {
    v: u8,
    start_at: String,
    id: String,
}

// Match the database's RFC 3339 shape, keeping the caller's original string.
// Chrono accepts Unicode minus even in its RFC parser and truncates fractions
// after nine digits, so validate ASCII and compare the original fractional digits.
fn calendar_instant<'a>(value: &'a str, field: &str) -> Result<(i64, bool, &'a str), AppError> {
    let invalid = || AppError::BadRequest(format!("{field} must be a valid RFC 3339 timestamp"));
    if !value.is_ascii() {
        return Err(invalid());
    }
    let parsed = DateTime::<FixedOffset>::parse_from_rfc3339(value).map_err(|_| invalid())?;
    let timezone_len = if matches!(value.as_bytes().last(), Some(b'Z' | b'z')) {
        1
    } else {
        6
    };
    let fraction = if value.as_bytes().get(19) == Some(&b'.') {
        value[20..value.len() - timezone_len].trim_end_matches('0')
    } else {
        ""
    };
    Ok((parsed.timestamp(), &value[17..19] == "60", fraction))
}

fn validate_calendar_range(start: &str, end: &str) -> Result<(), AppError> {
    let start = calendar_instant(start, "startAt")?;
    let end = calendar_instant(end, "endAt")?;
    if end < start {
        return Err(AppError::BadRequest(
            "endAt must not precede startAt".into(),
        ));
    }
    Ok(())
}

pub(super) async fn list_events(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ScheduleListQuery>,
) -> Result<Json<ScheduleListResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    for (field, value) in [("from", query.from.as_deref()), ("to", query.to.as_deref())] {
        if let Some(value) = value {
            calendar_instant(value, field)?;
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
    let cursor = query.after.map(decode_schedule_cursor).transpose()?;
    let mut events = sqlx::query_as::<_, Schedule>(
        "SELECT id,title,description,location,start_at,end_at,all_day,important,reminder_minutes,created_at,updated_at,version,deleted_at
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
                .map(schedule_cursor)
                .map(encode_schedule_cursor)
        })
        .flatten()
        .transpose()?;
    Ok(Json(ScheduleListResponse {
        items: events,
        next_cursor,
        has_more,
    }))
}

fn schedule_cursor(event: &Schedule) -> ScheduleCursor {
    ScheduleCursor {
        v: 1,
        start_at: event.start_at.clone(),
        id: event.id.clone(),
    }
}

fn encode_schedule_cursor(cursor: ScheduleCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

fn decode_schedule_cursor(value: String) -> Result<ScheduleCursor, AppError> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    let cursor: ScheduleCursor = serde_json::from_slice(&payload)
        .map_err(|_| AppError::BadRequest("invalid calendar cursor".into()))?;
    if cursor.v != 1 || cursor.start_at.is_empty() || cursor.id.is_empty() {
        return Err(AppError::BadRequest("invalid calendar cursor".into()));
    }
    Ok(cursor)
}

async fn fetch_event<'e, E>(executor: E, user_id: &str, id: &str) -> Result<Schedule, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, Schedule>(
        "SELECT id,title,description,location,start_at,end_at,all_day,important,reminder_minutes,created_at,updated_at,version,deleted_at
         FROM calendar_events WHERE user_id=? AND id=? AND deleted_at IS NULL",
    ).bind(user_id).bind(id).fetch_optional(executor).await?.ok_or(AppError::NotFound)
}

pub(super) async fn create_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<ScheduleInput>,
) -> Result<(StatusCode, Json<Schedule>), AppError> {
    // The configured Hermes Agent may create a Schedule through this existing
    // API route. All other Schedule reads and mutations remain session-only.
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    if input.title.trim().is_empty() {
        return Err(AppError::BadRequest("title is required".into()));
    }
    validate_calendar_range(&input.start_at, &input.end_at)?;
    validate_reminder(input.reminder_minutes)?;
    let id = input.id.unwrap_or_else(new_id);
    validate_entity_id("id", &id)?;
    ensure_client_id_available(&state.pool, &user_id, "calendar_events", &id).await?;
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("INSERT INTO calendar_events (id,user_id,title,description,location,start_at,end_at,all_day,important,reminder_minutes,created_at,updated_at,version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO NOTHING")
        .bind(&id).bind(&user_id).bind(input.title.trim()).bind(input.description).bind(input.location).bind(input.start_at).bind(input.end_at).bind(input.all_day.unwrap_or(false)).bind(input.important.unwrap_or(false)).bind(input.reminder_minutes).bind(&timestamp).bind(&timestamp).execute(&mut *tx).await?;
    if result.rows_affected() == 0 {
        let existing = fetch_event(&mut *tx, &user_id, &id).await?;
        tx.rollback().await?;
        return Ok((StatusCode::OK, Json(existing)));
    }
    let event = fetch_event(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "calendar_event",
            entity_id: &id,
            operation: "upsert",
            entity_version: event.version,
            payload_json: Some(serde_json::to_string(&event).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok((StatusCode::CREATED, Json(event)))
}

pub(super) async fn update_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<SchedulePatch>,
) -> Result<Json<Schedule>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
    let important = resolve_required(input.important, current.important, "important")?;
    let reminder_minutes = resolve_nullable(input.reminder_minutes, current.reminder_minutes);
    validate_calendar_range(&start_at, &end_at)?;
    validate_reminder(reminder_minutes)?;
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("UPDATE calendar_events SET title=?,description=?,location=?,start_at=?,end_at=?,all_day=?,important=?,reminder_minutes=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND version=?")
        .bind(title.trim()).bind(description).bind(location).bind(start_at).bind(end_at).bind(all_day).bind(important).bind(reminder_minutes).bind(now()).bind(&user_id).bind(&id).bind(input.base_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    let event = fetch_event(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "calendar_event",
            entity_id: &id,
            operation: "upsert",
            entity_version: event.version,
            payload_json: Some(serde_json::to_string(&event).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok(Json(event))
}

pub(super) async fn delete_event(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<VersionedDeleteInput>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let event = fetch_event(&state.pool, &user_id, &id).await?;
    if event.version != input.base_version {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query("UPDATE calendar_events SET deleted_at=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND version=?")
        .bind(&timestamp).bind(&timestamp).bind(&user_id).bind(&id).bind(input.base_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("calendar event version changed".into()));
    }
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "calendar_event",
            entity_id: &id,
            operation: "delete",
            entity_version: event.version + 1,
            payload_json: None,
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    // Keep the schedule tombstone ahead of its child tombstones for clients
    // that acknowledge pending child outbox rows during local cascade.
    soft_delete_children(&mut tx, &user_id, "schedule_id", &id, &timestamp).await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("calendar_event")).await;
    Ok(StatusCode::NO_CONTENT)
}
