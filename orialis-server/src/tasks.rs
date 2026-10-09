use super::*;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Task {
    pub(super) manual_position: Option<i64>,
    pub(super) id: String,
    pub(super) title: String,
    pub(super) notes: Option<String>,
    pub(super) important: Option<bool>,
    pub(super) urgent: Option<bool>,
    pub(super) completed: bool,
    pub(super) completed_at: Option<String>,
    pub(super) due: Option<String>,
    pub(super) due_time: Option<String>,
    pub(super) reminder_minutes: Option<i64>,
    pub(super) project_id: Option<String>,
    pub(super) parent_task_id: Option<String>,
    pub(super) schedule_id: Option<String>,
    pub(super) recurrence: Option<Recurrence>,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    pub(super) version: i64,
    pub(super) deleted_at: Option<String>,
}

#[derive(sqlx::FromRow)]
pub(super) struct TaskRow {
    pub(super) manual_position: Option<i64>,
    pub(super) id: String,
    pub(super) title: String,
    pub(super) notes: Option<String>,
    pub(super) important: Option<bool>,
    pub(super) urgent: Option<bool>,
    pub(super) completed: bool,
    pub(super) completed_at: Option<String>,
    pub(super) due: Option<String>,
    pub(super) due_time: Option<String>,
    pub(super) reminder_minutes: Option<i64>,
    pub(super) project_id: Option<String>,
    pub(super) parent_task_id: Option<String>,
    pub(super) schedule_id: Option<String>,
    pub(super) recurrence_rule: Option<String>,
    pub(super) recurrence_until: Option<String>,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    pub(super) version: i64,
    pub(super) deleted_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) struct Recurrence {
    pub(super) rule: String,
    pub(super) until: String,
}

impl TaskRow {
    pub(super) fn into_task(self) -> Task {
        Task {
            manual_position: self.manual_position,
            id: self.id,
            title: self.title,
            notes: self.notes,
            important: self.important,
            urgent: self.urgent,
            completed: self.completed,
            completed_at: self.completed_at,
            due: self.due,
            due_time: self.due_time,
            reminder_minutes: self.reminder_minutes,
            project_id: self.project_id,
            parent_task_id: self.parent_task_id,
            schedule_id: self.schedule_id,
            recurrence: match (self.recurrence_rule, self.recurrence_until) {
                (Some(rule), Some(until)) => Some(Recurrence { rule, until }),
                _ => None,
            },
            created_at: self.created_at,
            updated_at: self.updated_at,
            version: self.version,
            deleted_at: self.deleted_at,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TaskInput {
    pub(super) manual_position: Option<i64>,
    pub(super) id: Option<String>,
    pub(super) title: String,
    pub(super) notes: Option<String>,
    pub(super) important: Option<bool>,
    pub(super) urgent: Option<bool>,
    pub(super) completed: Option<bool>,
    pub(super) completed_at: Option<String>,
    pub(super) due: Option<String>,
    pub(super) due_time: Option<String>,
    pub(super) reminder_minutes: Option<i64>,
    pub(super) project_id: Option<String>,
    #[serde(alias = "parent_task_id")]
    pub(super) parent_task_id: Option<String>,
    #[serde(alias = "schedule_id")]
    pub(super) schedule_id: Option<String>,
    pub(super) recurrence: Option<Recurrence>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TaskPatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) manual_position: Option<PatchValue<i64>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) title: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) notes: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) important: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) urgent: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) completed: Option<PatchValue<bool>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) completed_at: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) due: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) due_time: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) reminder_minutes: Option<PatchValue<i64>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) project_id: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    #[serde(alias = "parent_task_id")]
    pub(super) parent_task_id: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    #[serde(alias = "schedule_id")]
    pub(super) schedule_id: Option<PatchValue<String>>,
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub(super) recurrence: Option<PatchValue<Recurrence>>,
    pub(super) base_version: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TaskListResponse {
    pub(super) items: Vec<Task>,
    pub(super) next_cursor: Option<String>,
    pub(super) has_more: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TaskListQuery {
    pub(super) after: Option<String>,
    pub(super) limit: Option<i64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TaskCursor {
    pub(super) v: u8,
    pub(super) due_is_null: bool,
    pub(super) due: Option<String>,
    pub(super) due_time_is_null: bool,
    pub(super) due_time: Option<String>,
    pub(super) created_at: String,
    pub(super) id: String,
}

pub(super) async fn list_tasks(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<TaskListQuery>,
) -> Result<Json<TaskListResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(AppError::BadRequest(
            "limit must be between 1 and 100".into(),
        ));
    }
    let cursor = query.after.map(decode_task_cursor).transpose()?;
    let fetch_limit = limit + 1;
    let task_rows = if let Some(cursor) = cursor {
        sqlx::query_as::<_, TaskRow>(
            "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                    reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,
                    created_at,updated_at,version,deleted_at
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
        sqlx::query_as::<_, TaskRow>(
            "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                    reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,
                    created_at,updated_at,version,deleted_at
             FROM tasks WHERE user_id=? AND deleted_at IS NULL
             ORDER BY due IS NULL,due,due_time IS NULL,due_time,created_at,id
             LIMIT ?",
        )
        .bind(&user_id)
        .bind(fetch_limit)
        .fetch_all(&state.pool)
        .await?
    };
    let mut tasks: Vec<Task> = task_rows.into_iter().map(TaskRow::into_task).collect();
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

pub(super) fn task_cursor(task: &Task) -> TaskCursor {
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

pub(super) fn encode_task_cursor(cursor: TaskCursor) -> Result<String, AppError> {
    let payload = serde_json::to_vec(&cursor)
        .map_err(|_| AppError::BadRequest("invalid task cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(payload))
}

pub(super) fn decode_task_cursor(value: String) -> Result<TaskCursor, AppError> {
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

pub(super) async fn fetch_task<'e, E>(
    executor: E,
    user_id: &str,
    id: &str,
) -> Result<Task, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    let row = sqlx::query_as::<_, TaskRow>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,
                created_at,updated_at,version,deleted_at
         FROM tasks WHERE user_id=? AND id=? AND deleted_at IS NULL",
    )
    .bind(user_id)
    .bind(id)
    .fetch_optional(executor)
    .await?
    .ok_or(AppError::NotFound)?;
    Ok(row.into_task())
}

pub(super) async fn validate_task_attachments(
    pool: &SqlitePool,
    user_id: &str,
    task_id: &str,
    parent_task_id: Option<&str>,
    schedule_id: Option<&str>,
) -> Result<(), AppError> {
    if parent_task_id.is_some() && schedule_id.is_some() {
        return Err(AppError::BadRequest(
            "a task cannot have both a parent task and a schedule".into(),
        ));
    }
    if let Some(parent_id) = parent_task_id {
        if parent_id == task_id {
            return Err(AppError::BadRequest("a task cannot parent itself".into()));
        }
        let parent = sqlx::query_as::<_, (Option<String>, Option<String>)>(
            "SELECT parent_task_id,schedule_id FROM tasks
             WHERE id=? AND user_id=? AND deleted_at IS NULL",
        )
        .bind(parent_id)
        .bind(user_id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| AppError::BadRequest("parent task is unavailable".into()))?;
        if parent.0.is_some() || parent.1.is_some() {
            return Err(AppError::BadRequest(
                "child tasks cannot have children or schedules".into(),
            ));
        }
        let has_children = sqlx::query_scalar::<_, i64>(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE parent_task_id=? AND deleted_at IS NULL)",
        )
        .bind(task_id)
        .fetch_one(pool)
        .await?;
        if has_children != 0 {
            return Err(AppError::BadRequest(
                "a task with child tasks cannot become a child".into(),
            ));
        }
    }
    if let Some(event_id) = schedule_id {
        let has_children = sqlx::query_scalar::<_, i64>(
            "SELECT EXISTS(SELECT 1 FROM tasks
             WHERE user_id=? AND parent_task_id=? AND deleted_at IS NULL)",
        )
        .bind(user_id)
        .bind(task_id)
        .fetch_one(pool)
        .await?;
        if has_children != 0 {
            return Err(AppError::BadRequest(
                "a task with child tasks cannot be assigned to a schedule".into(),
            ));
        }
        let exists = sqlx::query_scalar::<_, i64>(
            "SELECT EXISTS(SELECT 1 FROM calendar_events
             WHERE id=? AND user_id=? AND deleted_at IS NULL)",
        )
        .bind(event_id)
        .bind(user_id)
        .fetch_one(pool)
        .await?;
        if exists == 0 {
            return Err(AppError::BadRequest("schedule is unavailable".into()));
        }
    }
    Ok(())
}

pub(super) async fn update_child_completion(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    task: &Task,
    was_completed: bool,
) -> Result<(), AppError> {
    let timestamp = now();
    if let Some(parent_id) = task.parent_task_id.as_deref() {
        reconcile_parent_completion(tx, user_id, parent_id, &timestamp).await?;
    } else if was_completed != task.completed && task.completed {
        let children = sqlx::query_as::<_, (String, i64)>(
            "SELECT id,version FROM tasks
             WHERE user_id=? AND parent_task_id=? AND deleted_at IS NULL AND completed=0",
        )
        .bind(user_id)
        .bind(&task.id)
        .fetch_all(&mut **tx)
        .await?;
        for (child_id, version) in children {
            sqlx::query(
                "UPDATE tasks SET completed=1,completed_at=?,updated_at=?,version=version+1
                 WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL",
            )
            .bind(&timestamp)
            .bind(&timestamp)
            .bind(user_id)
            .bind(&child_id)
            .bind(version)
            .execute(&mut **tx)
            .await?;
            let child = fetch_task(&mut **tx, user_id, &child_id).await?;
            append_event(
                &mut **tx,
                AppendEvent {
                    user_id,
                    entity_type: "task",
                    entity_id: &child_id,
                    operation: "upsert",
                    entity_version: child.version,
                    payload_json: Some(serde_json::to_string(&child).unwrap()),
                    mutation_id: None,
                },
            )
            .await?;
        }
    }
    Ok(())
}

pub(super) async fn reconcile_parent_completion(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    parent_id: &str,
    timestamp: &str,
) -> Result<(), AppError> {
    let children = sqlx::query_as::<_, (i64, i64)>(
        "SELECT COUNT(*),COALESCE(SUM(completed),0) FROM tasks
         WHERE user_id=? AND parent_task_id=? AND deleted_at IS NULL",
    )
    .bind(user_id)
    .bind(parent_id)
    .fetch_one(&mut **tx)
    .await?;
    if children.0 == 0 {
        return Ok(());
    }
    let parent_completed = children.0 > 0 && children.0 == children.1;
    let parent = fetch_task(&mut **tx, user_id, parent_id).await?;
    if parent.completed != parent_completed {
        sqlx::query(
            "UPDATE tasks SET completed=?,completed_at=?,updated_at=?,version=version+1
             WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL",
        )
        .bind(parent_completed)
        .bind(if parent_completed {
            Some(timestamp.to_owned())
        } else {
            None
        })
        .bind(timestamp)
        .bind(user_id)
        .bind(parent_id)
        .bind(parent.version)
        .execute(&mut **tx)
        .await?;
        let updated_parent = fetch_task(&mut **tx, user_id, parent_id).await?;
        append_event(
            &mut **tx,
            AppendEvent {
                user_id,
                entity_type: "task",
                entity_id: parent_id,
                operation: "upsert",
                entity_version: updated_parent.version,
                payload_json: Some(serde_json::to_string(&updated_parent).unwrap()),
                mutation_id: None,
            },
        )
        .await?;
    }
    Ok(())
}

pub(super) async fn soft_delete_children(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    relation_column: &str,
    relation_id: &str,
    timestamp: &str,
) -> Result<(), AppError> {
    // relation_column is selected only by server code, never by a request.
    let query = format!(
        "SELECT id,version FROM tasks WHERE user_id=? AND {relation_column}=? AND deleted_at IS NULL"
    );
    let children = sqlx::query_as::<_, (String, i64)>(&query)
        .bind(user_id)
        .bind(relation_id)
        .fetch_all(&mut **tx)
        .await?;
    for (child_id, version) in children {
        sqlx::query(
            "UPDATE tasks SET deleted_at=?,updated_at=?,version=version+1
             WHERE user_id=? AND id=? AND version=? AND deleted_at IS NULL",
        )
        .bind(timestamp)
        .bind(timestamp)
        .bind(user_id)
        .bind(&child_id)
        .bind(version)
        .execute(&mut **tx)
        .await?;
        append_event(
            &mut **tx,
            AppendEvent {
                user_id,
                entity_type: "task",
                entity_id: &child_id,
                operation: "delete",
                entity_version: version + 1,
                payload_json: None,
                mutation_id: None,
            },
        )
        .await?;
    }
    Ok(())
}

pub(super) async fn create_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<TaskInput>,
) -> Result<(StatusCode, Json<Task>), AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
    validate_recurrence(input.recurrence.as_ref())?;
    if let Some(project_id) = input.project_id.as_deref() {
        ensure_project(&state.pool, &user_id, project_id).await?;
    }
    let id = input.id.unwrap_or_else(new_id);
    validate_entity_id("id", &id)?;
    validate_task_attachments(
        &state.pool,
        &user_id,
        &id,
        input.parent_task_id.as_deref(),
        input.schedule_id.as_deref(),
    )
    .await?;
    ensure_client_id_available(&state.pool, &user_id, "tasks", &id).await?;
    let timestamp = now();
    let completed = input.completed.unwrap_or(false);
    if !completed && input.completed_at.is_some() {
        return Err(AppError::BadRequest(
            "completedAt requires completed=true".into(),
        ));
    }
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
          reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,created_at,updated_at,version)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
         ON CONFLICT(id) DO NOTHING",
    )
    .bind(&id)
    .bind(&user_id)
    .bind(input.title.trim())
    .bind(input.notes)
    .bind(input.important)
    .bind(input.urgent)
    .bind(completed)
    .bind(completed_at)
    .bind(input.due)
    .bind(input.due_time)
    .bind(input.reminder_minutes)
    .bind(input.project_id)
    .bind(input.parent_task_id)
    .bind(input.schedule_id)
    .bind(input.manual_position)
    .bind(input.recurrence.as_ref().map(|value| value.rule.clone()))
    .bind(input.recurrence.as_ref().map(|value| value.until.clone()))
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
    update_child_completion(&mut tx, &user_id, &task, false).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "task",
            entity_id: &id,
            operation: "upsert",
            entity_version: task.version,
            payload_json: Some(serde_json::to_string(&task).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok((StatusCode::CREATED, Json(task)))
}

pub(super) async fn update_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<TaskPatch>,
) -> Result<Json<Task>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_task(&state.pool, &user_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("task version changed".into()));
    }
    let was_completed = current.completed;
    let previous_parent_task_id = current.parent_task_id.clone();
    let title = resolve_required(input.title, current.title, "title")?;
    let notes = resolve_nullable(input.notes, current.notes);
    let important = resolve_nullable(input.important, current.important);
    let urgent = resolve_nullable(input.urgent, current.urgent);
    let completed = resolve_required(input.completed, current.completed, "completed")?;
    if !completed && matches!(input.completed_at, Some(PatchValue::Value(_))) {
        return Err(AppError::BadRequest(
            "completedAt requires completed=true".into(),
        ));
    }
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
    let manual_position = resolve_nullable(input.manual_position, current.manual_position);
    let reminder_minutes = resolve_nullable(input.reminder_minutes, current.reminder_minutes);
    let project_id = resolve_nullable(input.project_id, current.project_id);
    let parent_task_id = resolve_nullable(input.parent_task_id, current.parent_task_id);
    let schedule_id = resolve_nullable(input.schedule_id, current.schedule_id);
    let recurrence = match input.recurrence {
        None => current.recurrence,
        Some(PatchValue::Value(value)) => Some(value),
        Some(PatchValue::Null(())) => None,
    };
    validate_date("due", due.as_deref())?;
    validate_time("dueTime", due_time.as_deref())?;
    validate_reminder(reminder_minutes)?;
    if due.is_none() && due_time.is_some() {
        return Err(AppError::BadRequest("due_time requires due".into()));
    }
    validate_recurrence(recurrence.as_ref())?;
    if let Some(project_id) = project_id.as_deref() {
        ensure_project(&state.pool, &user_id, project_id).await?;
    }
    validate_task_attachments(
        &state.pool,
        &user_id,
        &id,
        parent_task_id.as_deref(),
        schedule_id.as_deref(),
    )
    .await?;
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE tasks SET title=?,notes=?,important=?,urgent=?,completed=?,completed_at=?,due=?,due_time=?,
         reminder_minutes=?,project_id=?,parent_task_id=?,schedule_id=?,manual_position=?,recurrence_rule=?,recurrence_until=?,updated_at=?,version=version+1
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
    .bind(parent_task_id)
    .bind(schedule_id)
    .bind(manual_position)
    .bind(recurrence.as_ref().map(|value| value.rule.clone()))
    .bind(recurrence.as_ref().map(|value| value.until.clone()))
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
    if let Some(previous_parent_id) = previous_parent_task_id.as_deref() {
        if task.parent_task_id.as_deref() != Some(previous_parent_id) {
            reconcile_parent_completion(&mut tx, &user_id, previous_parent_id, &now()).await?;
        }
    }
    update_child_completion(&mut tx, &user_id, &task, was_completed).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "task",
            entity_id: &id,
            operation: "upsert",
            entity_version: task.version,
            payload_json: Some(serde_json::to_string(&task).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok(Json(task))
}

pub(super) async fn delete_task(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<VersionedDeleteInput>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let task = fetch_task(&state.pool, &user_id, &id).await?;
    if task.version != input.base_version {
        return Err(AppError::Conflict("task version changed".into()));
    }
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    let result = sqlx::query(
        "UPDATE tasks SET deleted_at=?,updated_at=?,version=version+1
         WHERE user_id=? AND id=? AND version=?",
    )
    .bind(&timestamp)
    .bind(&timestamp)
    .bind(&user_id)
    .bind(&id)
    .bind(input.base_version)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("task version changed".into()));
    }
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "task",
            entity_id: &id,
            operation: "delete",
            entity_version: task.version + 1,
            payload_json: None,
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    if let Some(parent_id) = task.parent_task_id.as_deref() {
        reconcile_parent_completion(&mut tx, &user_id, parent_id, &timestamp).await?;
    }
    // Publish the owning tombstone first. Clients can acknowledge pending
    // child mutations as they cascade locally, then apply each child's newer
    // version from the following child tombstone event.
    soft_delete_children(&mut tx, &user_id, "parent_task_id", &id, &timestamp).await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("task")).await;
    Ok(StatusCode::NO_CONTENT)
}
