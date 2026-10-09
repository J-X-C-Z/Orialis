use super::*;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Attachment {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) mime_type: String,
    pub(super) size: i64,
    pub(super) download_url: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AttachmentInput {
    id: String,
}

#[derive(Deserialize)]
pub(super) struct DownloadQuery {
    token: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AttachmentUploadResponse {
    pub(super) items: Vec<Attachment>,
}

pub(super) const MAX_ATTACHMENT_BYTES: usize = 20 * 1024 * 1024;
pub(super) const MAX_ATTACHMENT_COUNT: usize = 10;
pub(super) const MAX_TOTAL_ATTACHMENT_BYTES: usize = 48 * 1024 * 1024;
pub(super) const MAX_ATTACHMENT_REQUEST_BYTES: usize = 50 * 1024 * 1024;

pub(super) async fn upload_attachments(
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
            .rsplit(['/', '\\'])
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

pub(super) async fn canonical_attachment(
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

#[cfg(test)]
pub(super) fn attachment_download_token<'a>(
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

pub(super) async fn download_attachment(
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
