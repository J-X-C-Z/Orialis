use super::*;

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
pub(super) struct CursorQuery {
    after: Option<i64>,
    limit: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SyncResponse {
    events: Vec<SyncEvent>,
    next_cursor: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SyncSnapshot {
    cursor: i64,
    tasks: Vec<Task>,
    projects: Vec<Project>,
    calendar_events: Vec<Schedule>,
    milestones: Vec<Milestone>,
}

pub(super) fn mutation_id(headers: &HeaderMap) -> Option<String> {
    headers
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

pub(super) async fn reject_replayed_mutation(
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

pub(super) struct AppendEvent<'a> {
    pub(super) user_id: &'a str,
    pub(super) entity_type: &'a str,
    pub(super) entity_id: &'a str,
    pub(super) operation: &'a str,
    pub(super) entity_version: i64,
    pub(super) payload_json: Option<String>,
    pub(super) mutation_id: Option<String>,
}

pub(super) async fn append_event<'e, E>(executor: E, event: AppendEvent<'_>) -> Result<(), AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    let timestamp = now();
    let tombstone = event.operation == "delete";
    sqlx::query(
        "INSERT INTO sync_events
         (id,user_id,cursor,entity_type,entity_id,operation,entity_version,tombstone,payload_json,mutation_id,deleted_at,created_at,updated_at,version)
         VALUES (?,?,(SELECT COALESCE(MAX(cursor),0)+1 FROM sync_events WHERE user_id=?),?,?,?,?,?,?,?,?,?,?,1)",
    )
    .bind(new_id())
    .bind(event.user_id)
    .bind(event.user_id)
    .bind(event.entity_type)
    .bind(event.entity_id)
    .bind(event.operation)
    .bind(event.entity_version)
    .bind(tombstone)
    .bind(event.payload_json)
    .bind(event.mutation_id)
    .bind(if tombstone { Some(timestamp.clone()) } else { None::<String> })
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(executor)
    .await?;
    Ok(())
}

pub(super) async fn notify_sync_change(state: &AppState, user_id: &str, entity: Option<&str>) {
    let cursor = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE(MAX(cursor), 0) FROM sync_events WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_one(&state.pool)
    .await;
    match cursor {
        Ok(cursor) if cursor > 0 || entity == Some("message") => state.mobile.notify(
            user_id,
            agent_gateway::protocol::mobile_sync_change_hint(cursor, entity),
        ),
        Ok(_) => {}
        Err(error) => {
            tracing::warn!(%error, "could not read sync cursor for realtime notification")
        }
    }
}

pub(super) async fn sync_events(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<CursorQuery>,
) -> Result<Json<SyncResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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

pub(super) async fn sync_snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<SyncSnapshot>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    let mut tx = state.pool.begin().await?;
    let tasks = sqlx::query_as::<_, TaskRow>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,
                created_at,updated_at,version,deleted_at
         FROM tasks WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at",
    )
    .bind(&user_id)
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .map(TaskRow::into_task)
    .collect();
    let projects = sqlx::query_as::<_, Project>(
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,manual_position,created_at,updated_at,version
         FROM projects WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at",
    ).bind(&user_id).fetch_all(&mut *tx).await?;
    let calendar_events = sqlx::query_as::<_, Schedule>(
        "SELECT id,title,description,location,start_at,end_at,all_day,important,reminder_minutes,created_at,updated_at,version,deleted_at
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
