use super::*;

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub(super) struct Project {
    manual_position: Option<i64>,
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
pub(super) struct ProjectInput {
    id: Option<String>,
    manual_position: Option<i64>,
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
pub(super) struct ProjectPatch {
    #[serde(default, deserialize_with = "deserialize_patch")]
    manual_position: Option<PatchValue<i64>>,
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
pub(super) struct Milestone {
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
pub(super) struct MilestoneInput {
    title: String,
    due: Option<String>,
    completed: Option<bool>,
    position: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct MilestonePatch {
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
pub(super) struct ProjectSummary {
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
pub(super) struct ProjectListResponse {
    items: Vec<Project>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
pub(super) struct ProjectListQuery {
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
pub(super) struct MilestoneListResponse {
    items: Vec<Milestone>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Deserialize)]
pub(super) struct MilestoneListQuery {
    after: Option<String>,
    limit: Option<i64>,
}

#[derive(Serialize, Deserialize)]
struct MilestoneCursor {
    v: u8,
    position: i64,
    id: String,
}

pub(super) async fn list_projects(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ProjectListQuery>,
) -> Result<Json<ProjectListResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,manual_position,created_at,updated_at,version
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
        "SELECT id,name,goal,description,color,status,start_date,due,next_action_task_id,manual_position,created_at,updated_at,version
         FROM projects WHERE user_id=? AND id=? AND deleted_at IS NULL",
    ).bind(user_id).bind(id).fetch_optional(executor).await?.ok_or(AppError::NotFound)
}

pub(super) async fn create_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<ProjectInput>,
) -> Result<(StatusCode, Json<Project>), AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
    let id = input.id.unwrap_or_else(new_id);
    validate_entity_id("id", &id)?;
    let timestamp = now();
    let mut tx = state.pool.begin().await?;
    sqlx::query("INSERT INTO projects (id,user_id,name,goal,description,color,status,start_date,due,next_action_task_id,manual_position,created_at,updated_at,version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO NOTHING")
        .bind(&id).bind(&user_id).bind(input.name.trim()).bind(input.goal).bind(input.description).bind(input.color).bind(status).bind(input.start_date).bind(input.due).bind(None::<String>).bind(input.manual_position).bind(&timestamp).bind(&timestamp).execute(&mut *tx).await?;
    let project = fetch_project(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "project",
            entity_id: &id,
            operation: "upsert",
            entity_version: project.version,
            payload_json: Some(serde_json::to_string(&project).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project")).await;
    Ok((StatusCode::CREATED, Json(project)))
}

pub(super) async fn update_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<ProjectPatch>,
) -> Result<Json<Project>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    reject_replayed_mutation(&state.pool, &user_id, &headers).await?;
    let current = fetch_project(&state.pool, &user_id, &id).await?;
    if current.version != input.base_version {
        return Err(AppError::Conflict("project version changed".into()));
    }
    let manual_position = resolve_nullable(input.manual_position, current.manual_position);
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
    let result = sqlx::query("UPDATE projects SET name=?,goal=?,description=?,color=?,status=?,start_date=?,due=?,next_action_task_id=?,manual_position=?,updated_at=?,version=version+1 WHERE user_id=? AND id=? AND version=?")
        .bind(name.trim()).bind(goal).bind(description).bind(color).bind(status).bind(start_date).bind(due).bind(next_action_task_id).bind(manual_position).bind(now()).bind(&user_id).bind(&id).bind(input.base_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::Conflict("project version changed".into()));
    }
    let project = fetch_project(&mut *tx, &user_id, &id).await?;
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "project",
            entity_id: &id,
            operation: "upsert",
            entity_version: project.version,
            payload_json: Some(serde_json::to_string(&project).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project")).await;
    Ok(Json(project))
}

pub(super) async fn project_summary(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<ProjectSummary>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
    let next_action = sqlx::query_as::<_, TaskRow>(
        "SELECT id,title,notes,important,urgent,completed,completed_at,due,due_time,
                reminder_minutes,project_id,parent_task_id,schedule_id,manual_position,recurrence_rule,recurrence_until,
                created_at,updated_at,version,deleted_at
         FROM tasks
         WHERE user_id=? AND project_id=? AND deleted_at IS NULL AND completed=0
         ORDER BY due IS NULL,due,due_time IS NULL,due_time,created_at,id LIMIT 1",
    )
    .bind(&user_id)
    .bind(&id)
    .fetch_optional(&state.pool)
    .await?
    .map(TaskRow::into_task);
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

pub(super) async fn delete_project(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
    .bind(&timestamp)
    .bind(&id)
    .execute(&mut *tx)
    .await?;
    for (milestone_id, version) in milestones {
        append_event(
            &mut *tx,
            AppendEvent {
                user_id: &user_id,
                entity_type: "project_milestone",
                entity_id: &milestone_id,
                operation: "delete",
                entity_version: version + 1,
                payload_json: None,
                mutation_id: None,
            },
        )
        .await?;
    }
    append_event(
        &mut *tx,
        AppendEvent {
            user_id: &user_id,
            entity_type: "project",
            entity_id: &id,
            operation: "delete",
            entity_version: project.version + 1,
            payload_json: None,
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, None).await;
    Ok(StatusCode::NO_CONTENT)
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

pub(super) async fn ensure_project<'e, E>(
    executor: E,
    user_id: &str,
    project_id: &str,
) -> Result<(), AppError>
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

pub(super) async fn list_milestones(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(project_id): Path<String>,
    Query(query): Query<MilestoneListQuery>,
) -> Result<Json<MilestoneListResponse>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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

pub(super) async fn create_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(project_id): Path<String>,
    Json(input): Json<MilestoneInput>,
) -> Result<(StatusCode, Json<Milestone>), AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
        AppendEvent {
            user_id: &user_id,
            entity_type: "project_milestone",
            entity_id: &id,
            operation: "upsert",
            entity_version: milestone.version,
            payload_json: Some(serde_json::to_string(&milestone).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok((StatusCode::CREATED, Json(milestone)))
}

pub(super) async fn get_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
) -> Result<Json<Milestone>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    Ok(Json(
        fetch_milestone(&state.pool, &user_id, &project_id, &id).await?,
    ))
}

pub(super) async fn update_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
    Json(input): Json<MilestonePatch>,
) -> Result<Json<Milestone>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
        AppendEvent {
            user_id: &user_id,
            entity_type: "project_milestone",
            entity_id: &id,
            operation: "upsert",
            entity_version: milestone.version,
            payload_json: Some(serde_json::to_string(&milestone).unwrap()),
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok(Json(milestone))
}

pub(super) async fn delete_milestone(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((project_id, id)): Path<(String, String)>,
) -> Result<StatusCode, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
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
        AppendEvent {
            user_id: &user_id,
            entity_type: "project_milestone",
            entity_id: &id,
            operation: "delete",
            entity_version: current.version + 1,
            payload_json: None,
            mutation_id: mutation_id(&headers),
        },
    )
    .await?;
    tx.commit().await?;
    notify_sync_change(&state, &user_id, Some("project_milestone")).await;
    Ok(StatusCode::NO_CONTENT)
}
