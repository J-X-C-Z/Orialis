use super::{config, new_id, now, AppError, AppState};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{Duration, Utc};
use scrypt::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Scrypt,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use std::sync::Arc;
use tokio::sync::Semaphore;
use uuid::Uuid;

pub(crate) static AUTH_HASH_ADMISSION: Semaphore = Semaphore::const_new(4);

#[derive(Deserialize)]
pub(crate) struct Credentials {
    username: String,
    password: String,
}

#[derive(Serialize)]
pub(crate) struct SessionResponse {
    #[serde(rename = "userId")]
    user_id: String,
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "expiresAt")]
    expires_at: String,
}

pub(crate) fn hash_token(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

pub(crate) fn validate_credentials(username: &str, password: &str) -> Result<(), AppError> {
    if !(3..=32).contains(&username.chars().count()) {
        return Err(AppError::BadRequest(
            "username must be 3-32 characters".into(),
        ));
    }
    if !(8..=128).contains(&password.chars().count()) {
        return Err(AppError::BadRequest(
            "password must be 8-128 characters".into(),
        ));
    }
    Ok(())
}

pub(crate) fn password_hash(password: &str) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut OsRng);
    Scrypt
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| AppError::BadRequest("password could not be hashed".into()))
}

pub(crate) fn verify_password(password: &str, encoded: &str) -> bool {
    PasswordHash::new(encoded)
        .ok()
        .map(|parsed| Scrypt.verify_password(password.as_bytes(), &parsed).is_ok())
        .unwrap_or(false)
}

pub(crate) async fn password_hash_blocking(password: String) -> Result<String, AppError> {
    let permit = AUTH_HASH_ADMISSION
        .try_acquire()
        .map_err(|_| AppError::ServiceUnavailable("authentication capacity is busy".into()))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        password_hash(&password)
    })
    .await
    .map_err(|_| {
        AppError::ServiceUnavailable("authentication work could not be completed".into())
    })?
}

pub(crate) async fn verify_password_blocking(
    password: String,
    encoded: String,
) -> Result<bool, AppError> {
    let permit = AUTH_HASH_ADMISSION
        .try_acquire()
        .map_err(|_| AppError::ServiceUnavailable("authentication capacity is busy".into()))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        verify_password(&password, &encoded)
    })
    .await
    .map_err(|_| AppError::ServiceUnavailable("authentication work could not be completed".into()))
}

pub(crate) async fn authenticated_user(
    headers: &HeaderMap,
    pool: &SqlitePool,
) -> Result<String, AppError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Session "))
        .or_else(|| {
            headers
                .get("cookie")
                .and_then(|value| value.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .find_map(|item| item.trim().strip_prefix("orialis_session="))
                })
        });
    if let Some(token) = token {
        return sqlx::query_scalar::<_, String>(
            "SELECT user_id FROM user_sessions
             WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?",
        )
        .bind(hash_token(token))
        .bind(now())
        .fetch_optional(pool)
        .await?
        .ok_or(AppError::Unauthorized);
    }
    if !config::development_device_auth_enabled() {
        return Err(AppError::Unauthorized);
    }
    let device_id = headers
        .get("x-orialis-device-id")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(AppError::Unauthorized)?;
    let digest = format!("{:x}", Sha256::digest(device_id.as_bytes()));
    let username = format!("device_{}", &digest[..24]);
    if let Some(user_id) = sqlx::query_scalar::<_, String>("SELECT id FROM users WHERE username=?")
        .bind(&username)
        .fetch_optional(pool)
        .await?
    {
        return Ok(user_id);
    }
    let user_id = new_id();
    sqlx::query(
        "INSERT OR IGNORE INTO users (id,username,password_hash,created_at,updated_at)
         VALUES (?,?,?,?,?)",
    )
    .bind(&user_id)
    .bind(&username)
    .bind("device-auth-only")
    .bind(now())
    .bind(now())
    .execute(pool)
    .await?;
    sqlx::query_scalar::<_, String>("SELECT id FROM users WHERE username=?")
        .bind(username)
        .fetch_one(pool)
        .await
        .map_err(AppError::from)
}

/// Accept the configured Agent token for HTTP attachment operations. The
/// WebSocket uses the same token, but upload/download also need an owner so
/// an Agent cannot access another user's files.
pub(crate) async fn authenticated_user_or_agent(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<String, AppError> {
    if let Ok(user_id) = authenticated_user(headers, &state.pool).await {
        return Ok(user_id);
    }
    let valid_agent_token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split_once(' '))
        .is_some_and(|(scheme, token)| {
            scheme.eq_ignore_ascii_case("bearer")
                && state.agent_device_token.as_deref() == Some(token)
                && !token.is_empty()
        });
    if !valid_agent_token {
        return Err(AppError::Unauthorized);
    }
    if let Some(user_id) = state.agent_user_id.as_deref() {
        let exists = sqlx::query_scalar::<_, i64>("SELECT EXISTS(SELECT 1 FROM users WHERE id=?)")
            .bind(user_id)
            .fetch_one(&state.pool)
            .await?;
        return (exists != 0)
            .then(|| user_id.to_owned())
            .ok_or(AppError::Unauthorized);
    }
    let users =
        sqlx::query_scalar::<_, String>("SELECT id FROM users ORDER BY created_at,id LIMIT 2")
            .fetch_all(&state.pool)
            .await?;
    if users.len() == 1 {
        Ok(users[0].clone())
    } else {
        Err(AppError::Unauthorized)
    }
}

pub(crate) async fn register(
    State(state): State<Arc<AppState>>,
    Json(input): Json<Credentials>,
) -> Result<(StatusCode, Json<SessionResponse>), AppError> {
    validate_credentials(&input.username, &input.password)?;
    let id = new_id();
    let timestamp = now();
    let result = sqlx::query(
        "INSERT INTO users (id,username,password_hash,created_at,updated_at)
         VALUES (?,?,?,?,?)",
    )
    .bind(&id)
    .bind(input.username.trim())
    .bind(password_hash_blocking(input.password.clone()).await?)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&state.pool)
    .await;
    if let Err(sqlx::Error::Database(error)) = &result {
        if error.is_unique_violation() {
            return Err(AppError::Conflict("username already exists".into()));
        }
    }
    result?;
    Ok((
        StatusCode::CREATED,
        Json(create_session(&state.pool, &id).await?),
    ))
}

pub(crate) async fn login(
    State(state): State<Arc<AppState>>,
    Json(input): Json<Credentials>,
) -> Result<Json<SessionResponse>, AppError> {
    let row = sqlx::query_as::<_, (String, String)>(
        "SELECT id,password_hash FROM users WHERE username = ?",
    )
    .bind(input.username.trim())
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::Unauthorized)?;
    if !verify_password_blocking(input.password, row.1).await? {
        return Err(AppError::Unauthorized);
    }
    Ok(Json(create_session(&state.pool, &row.0).await?))
}

pub(crate) async fn create_session(
    pool: &SqlitePool,
    user_id: &str,
) -> Result<SessionResponse, AppError> {
    let token = format!("{}{}", Uuid::now_v7().simple(), Uuid::new_v4().simple());
    let expires_at = (Utc::now() + Duration::days(30)).to_rfc3339();
    sqlx::query(
        "INSERT INTO user_sessions
         (id,user_id,token_hash,expires_at,created_at,updated_at)
         VALUES (?,?,?,?,?,?)",
    )
    .bind(new_id())
    .bind(user_id)
    .bind(hash_token(&token))
    .bind(&expires_at)
    .bind(now())
    .bind(now())
    .execute(pool)
    .await?;
    Ok(SessionResponse {
        user_id: user_id.into(),
        access_token: token,
        expires_at,
    })
}

pub(crate) async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<StatusCode, AppError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Session "))
        .ok_or(AppError::Unauthorized)?;
    sqlx::query("UPDATE user_sessions SET revoked_at=?,updated_at=? WHERE token_hash=?")
        .bind(now())
        .bind(now())
        .bind(hash_token(token))
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn current_session(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AppError> {
    let user_id = authenticated_user_or_agent(&headers, &state).await?;
    let row = sqlx::query_as::<_, (String, String)>("SELECT id,username FROM users WHERE id = ?")
        .bind(&user_id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(AppError::Unauthorized)?;
    Ok(Json(
        serde_json::json!({ "userId": row.0, "username": row.1 }),
    ))
}
