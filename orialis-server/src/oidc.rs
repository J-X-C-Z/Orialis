use super::{auth, now, AppError, AppState};
use axum::{
    extract::{Query, State},
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Redirect, Response},
    Json,
};
use chrono::{Duration, Utc};
use openidconnect::{
    core::{
        CoreAuthenticationFlow, CoreClient, CoreIdToken, CoreIdTokenVerifier, CoreProviderMetadata,
    },
    reqwest, AuthorizationCode, ClientId, ClientSecret, CsrfToken, IssuerUrl, Nonce,
    OAuth2TokenResponse, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope, TokenResponse,
};
use serde::Deserialize;
use std::sync::Arc;
use uuid::Uuid;

const ISSUER: &str = "https://auth.jxcz.top";
#[cfg(test)]
static TEST_PROVIDER: std::sync::OnceLock<(String, String, String)> = std::sync::OnceLock::new();

fn issuer() -> String {
    #[cfg(test)]
    if let Some((issuer, _, _)) = TEST_PROVIDER.get() {
        return issuer.clone();
    }
    ISSUER.to_owned()
}

const CALLBACK: &str = "/api/v1/auth/oidc/callback";
const COOKIE_PATH: &str = "/api/v1/auth/oidc";

fn unavailable() -> AppError {
    AppError::ServiceUnavailable("统一登录暂不可用".into())
}
fn random() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}
fn expires() -> String {
    (Utc::now() + Duration::minutes(10)).to_rfc3339()
}
fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|item| {
            let (key, value) = item.trim().split_once('=')?;
            (key == name).then(|| value.to_owned())
        })
}
fn set_cookie(name: &str, value: &str, age: u32) -> Result<HeaderValue, AppError> {
    HeaderValue::from_str(&format!(
        "{name}={value}; Path={COOKIE_PATH}; Max-Age={age}; Secure; HttpOnly; SameSite=Lax"
    ))
    .map_err(|_| unavailable())
}
fn same_origin(headers: &HeaderMap, state: &AppState) -> Result<(), AppError> {
    let origin = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok());
    if origin != Some(state.public_url.trim_end_matches('/')) {
        return Err(AppError::Unauthorized);
    }
    Ok(())
}
async fn provider() -> Result<(CoreProviderMetadata, reqwest::Client, String, String), AppError> {
    #[cfg(test)]
    if let Some((issuer, client_id, secret)) = TEST_PROVIDER.get() {
        let http = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|_| unavailable())?;
        let metadata = CoreProviderMetadata::discover_async(
            IssuerUrl::new(issuer.clone()).map_err(|_| unavailable())?,
            &http,
        )
        .await
        .map_err(|_| unavailable())?;
        return Ok((metadata, http, client_id.clone(), secret.clone()));
    }
    let client_id = std::env::var("ORIALIS_OIDC_CLIENT_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(unavailable)?;
    let secret = std::env::var("ORIALIS_OIDC_CLIENT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(unavailable)?;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|_| unavailable())?;
    let metadata = CoreProviderMetadata::discover_async(
        IssuerUrl::new(ISSUER.to_owned()).map_err(|_| unavailable())?,
        &http,
    )
    .await
    .map_err(|_| unavailable())?;
    Ok((metadata, http, client_id, secret))
}

#[derive(Deserialize)]
pub(crate) struct Start {
    bind: bool,
}

pub(crate) async fn start(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(input): Json<Start>,
) -> Result<Response, AppError> {
    same_origin(&headers, &state)?;
    let session_hash = if input.bind {
        auth::authenticated_user(&headers, &state.pool).await?;
        let token = headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.strip_prefix("Session "))
            .ok_or(AppError::Unauthorized)?;
        Some(auth::hash_token(token))
    } else {
        None
    };
    let (metadata, _, client_id, secret) = provider().await?;
    let client = CoreClient::from_provider_metadata(
        metadata,
        ClientId::new(client_id),
        Some(ClientSecret::new(secret)),
    )
    .set_redirect_uri(
        RedirectUrl::new(format!(
            "{}{CALLBACK}",
            state.public_url.trim_end_matches('/')
        ))
        .map_err(|_| unavailable())?,
    );
    let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
    let request_study_identity = !input.bind && approved_mapping()?.is_some();
    let request = client
        .authorize_url(
            CoreAuthenticationFlow::AuthorizationCode,
            CsrfToken::new_random,
            Nonce::new_random,
        )
        .set_pkce_challenge(challenge);
    let request = if request_study_identity {
        request
            .add_scope(Scope::new("study_identity".into()))
            .add_extra_param("claims", r#"{"id_token":{"legacy_military_id":null}}"#)
    } else {
        request
    };
    let (url, csrf, nonce) = request.url();
    let stored_verifier = if request_study_identity {
        format!("study:{}", verifier.secret())
    } else {
        verifier.secret().to_owned()
    };
    let browser = random();
    sqlx::query("DELETE FROM oidc_transactions WHERE expires_at <= ?")
        .bind(now())
        .execute(&state.pool)
        .await?;
    sqlx::query("INSERT INTO oidc_transactions(state_hash,browser_hash,nonce,verifier,session_hash,expires_at) VALUES (?,?,?,?,?,?)")
        .bind(auth::hash_token(csrf.secret())).bind(auth::hash_token(&browser)).bind(nonce.secret()).bind(stored_verifier).bind(session_hash).bind(expires()).execute(&state.pool).await?;
    let mut response = Json(serde_json::json!({"url": url.to_string()})).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        set_cookie("orialis_oidc", &browser, 600)?,
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

#[derive(Deserialize)]
pub(crate) struct Callback {
    state: Option<String>,
    code: Option<String>,
}

pub(crate) async fn callback(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<Callback>,
) -> Response {
    match callback_inner(&state, &headers, query).await {
        Ok(code) => {
            let mut response = Redirect::to("/#oidc-complete").into_response();
            if let Ok(value) = set_cookie("orialis_oidc_exchange", &code, 600) {
                response.headers_mut().insert(header::SET_COOKIE, value);
            }
            response
                .headers_mut()
                .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
            response
        }
        Err(_) => Redirect::to("/#oidc-error").into_response(),
    }
}
async fn callback_inner(
    state: &AppState,
    headers: &HeaderMap,
    query: Callback,
) -> Result<String, AppError> {
    let browser = cookie(headers, "orialis_oidc").ok_or(AppError::Unauthorized)?;
    let csrf = query.state.ok_or(AppError::Unauthorized)?;
    let code = query.code.ok_or(AppError::Unauthorized)?;
    let row: (String, String, Option<String>) = sqlx::query_as("DELETE FROM oidc_transactions WHERE state_hash=? AND browser_hash=? AND expires_at>? RETURNING nonce,verifier,session_hash")
        .bind(auth::hash_token(&csrf)).bind(auth::hash_token(&browser)).bind(now()).fetch_optional(&state.pool).await?.ok_or(AppError::Unauthorized)?;
    let (metadata, http, client_id, secret) = provider().await?;
    let client = CoreClient::from_provider_metadata(
        metadata,
        ClientId::new(client_id),
        Some(ClientSecret::new(secret)),
    )
    .set_redirect_uri(
        RedirectUrl::new(format!(
            "{}{CALLBACK}",
            state.public_url.trim_end_matches('/')
        ))
        .map_err(|_| unavailable())?,
    );
    let study_requested = row.1.starts_with("study:");
    let verifier = row.1.strip_prefix("study:").unwrap_or(&row.1).to_owned();
    let tokens = client
        .exchange_code(AuthorizationCode::new(code))
        .map_err(|_| unavailable())?
        .set_pkce_verifier(PkceCodeVerifier::new(verifier))
        .request_async(&http)
        .await
        .map_err(|_| AppError::Unauthorized)?;
    let id_token = tokens.id_token().ok_or(AppError::Unauthorized)?;
    let subject = verified_subject(id_token, &client.id_token_verifier(), &Nonce::new(row.0))?;
    let granted = study_scope_granted(study_requested, tokens.scopes());
    let mapping = if row.2.is_none() && granted {
        approved_mapping()?
            .filter(|mapping| signed_legacy_id(id_token) == Some(mapping.legacy_military_id))
    } else {
        None
    };
    let user_id = if let Some(mapping) = mapping {
        resolve_approved_identity(&state.pool, &issuer(), &subject, &mapping.user_id).await?
    } else {
        resolve_identity(&state.pool, &issuer(), &subject, row.2.as_deref()).await?
    };
    let exchange = random();
    sqlx::query("DELETE FROM oidc_exchanges WHERE expires_at <= ?")
        .bind(now())
        .execute(&state.pool)
        .await?;
    sqlx::query("INSERT INTO oidc_exchanges(code_hash,user_id,expires_at) VALUES (?,?,?)")
        .bind(auth::hash_token(&exchange))
        .bind(user_id)
        .bind(expires())
        .execute(&state.pool)
        .await?;
    Ok(exchange)
}

fn verified_subject(
    token: &CoreIdToken,
    verifier: &CoreIdTokenVerifier,
    nonce: &Nonce,
) -> Result<String, AppError> {
    let claims = token
        .claims(verifier, nonce)
        .map_err(|_| AppError::Unauthorized)?;
    Ok(claims.subject().as_str().to_owned())
}

fn study_scope_granted(requested: bool, scopes: Option<&Vec<Scope>>) -> bool {
    requested
        && scopes.map_or(true, |scopes| {
            scopes
                .iter()
                .any(|scope| scope.as_str() == "study_identity")
        })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovedMapping {
    enabled: bool,
    legacy_military_id: u64,
    user_id: String,
}

fn approved_mapping() -> Result<Option<ApprovedMapping>, AppError> {
    let Some(path) = std::env::var_os("ORIALIS_OIDC_APPROVED_MAPPING_FILE") else {
        return Ok(None);
    };
    read_approved_mapping(std::path::Path::new(&path))
}

fn read_approved_mapping(path: &std::path::Path) -> Result<Option<ApprovedMapping>, AppError> {
    if !path.is_absolute() {
        return Err(unavailable());
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| unavailable())?;
    if !metadata.file_type().is_file() {
        return Err(unavailable());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(unavailable());
        }
    }
    let bytes = std::fs::read(path).map_err(|_| unavailable())?;
    let mapping: ApprovedMapping = serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
    if !mapping.enabled {
        return Ok(None);
    }
    if mapping.legacy_military_id == 0 || Uuid::parse_str(&mapping.user_id).is_err() {
        return Err(unavailable());
    }
    Ok(Some(mapping))
}

// The caller must verify the ID token signature and claims before reading its payload.
fn signed_legacy_id(token: &CoreIdToken) -> Option<u64> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    let encoded = token.to_string();
    let payload = encoded.split('.').nth(1)?;
    let json: serde_json::Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
    let value = json.get("legacy_military_id")?;
    let id = value.as_u64().or_else(|| {
        value.as_str().and_then(|s| {
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            s.parse().ok()
        })
    })?;
    (id > 0).then_some(id)
}

async fn resolve_approved_identity(
    pool: &sqlx::SqlitePool,
    issuer: &str,
    subject: &str,
    user_id: &str,
) -> Result<String, AppError> {
    if subject.is_empty() {
        return Err(AppError::Unauthorized);
    }
    let existing: Option<String> =
        sqlx::query_scalar("SELECT user_id FROM oidc_identities WHERE issuer=? AND subject=?")
            .bind(issuer)
            .bind(subject)
            .fetch_optional(pool)
            .await?;
    if let Some(owner) = existing {
        return if owner == user_id {
            Ok(owner)
        } else {
            Err(AppError::Conflict("统一身份已绑定其他账号".into()))
        };
    }
    sqlx::query("INSERT INTO oidc_identities(issuer,subject,user_id) SELECT ?,?,id FROM users WHERE id=? ON CONFLICT DO NOTHING")
        .bind(issuer).bind(subject).bind(user_id).execute(pool).await?;
    let owner: Option<String> =
        sqlx::query_scalar("SELECT user_id FROM oidc_identities WHERE issuer=? AND subject=?")
            .bind(issuer)
            .bind(subject)
            .fetch_optional(pool)
            .await?;
    if owner.as_deref() == Some(user_id) {
        Ok(user_id.to_owned())
    } else {
        Err(AppError::Conflict("账号不存在或已绑定其他统一身份".into()))
    }
}

async fn resolve_identity(
    pool: &sqlx::SqlitePool,
    issuer: &str,
    subject: &str,
    session_hash: Option<&str>,
) -> Result<String, AppError> {
    if subject.is_empty() {
        return Err(AppError::Unauthorized);
    }
    if let Some(hash) = session_hash {
        let user: String = sqlx::query_scalar("SELECT user_id FROM user_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?")
            .bind(hash).bind(now()).fetch_optional(pool).await?.ok_or(AppError::Unauthorized)?;
        let inserted = sqlx::query("INSERT INTO oidc_identities(issuer,subject,user_id) VALUES (?,?,?) ON CONFLICT DO NOTHING")
            .bind(issuer).bind(subject).bind(&user).execute(pool).await?.rows_affected();
        if inserted == 0 {
            let owner: Option<String> = sqlx::query_scalar(
                "SELECT user_id FROM oidc_identities WHERE issuer=? AND subject=?",
            )
            .bind(issuer)
            .bind(subject)
            .fetch_optional(pool)
            .await?;
            if owner.as_deref() != Some(&user) {
                return Err(AppError::Conflict(
                    "统一账号已绑定其他账号，或此账号已绑定另一统一账号".into(),
                ));
            }
        }
        Ok(user)
    } else {
        sqlx::query_scalar("SELECT user_id FROM oidc_identities WHERE issuer=? AND subject=?")
            .bind(issuer)
            .bind(subject)
            .fetch_optional(pool)
            .await?
            .ok_or(AppError::Unauthorized)
    }
}

pub(crate) async fn exchange(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    same_origin(&headers, &state)?;
    let code = cookie(&headers, "orialis_oidc_exchange").ok_or(AppError::Unauthorized)?;
    let user: String = sqlx::query_scalar(
        "DELETE FROM oidc_exchanges WHERE code_hash=? AND expires_at>? RETURNING user_id",
    )
    .bind(auth::hash_token(&code))
    .bind(now())
    .fetch_optional(&state.pool)
    .await?
    .ok_or(AppError::Unauthorized)?;
    let session = auth::create_session(&state.pool, &user).await?;
    let mut response = Json(session).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        set_cookie("orialis_oidc_exchange", "", 0)?,
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{metadata, mobile_realtime::MobileRegistry, AgentRegistry};
    use sqlx::sqlite::SqlitePoolOptions;
    use std::path::PathBuf;

    async fn setup() -> (sqlx::SqlitePool, AppState) {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        for user in ["alice", "bob"] {
            sqlx::query("INSERT INTO users(id,username,password_hash) VALUES (?,?,?)")
                .bind(user)
                .bind(user)
                .bind("test")
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES ('s1','alice',?,?),('s2','bob',?,?)")
            .bind(auth::hash_token("alice-token")).bind(expires()).bind(auth::hash_token("bob-token")).bind(expires()).execute(&pool).await.unwrap();
        let state = AppState {
            metadata: metadata("test", "test", "https://orialis.jxcz.top"),
            pool: pool.clone(),
            agent: AgentRegistry::default(),
            mobile: MobileRegistry::default(),
            agent_device_token: None,
            agent_user_id: None,
            public_url: "https://orialis.jxcz.top".into(),
            upload_dir: PathBuf::from("/tmp"),
        };
        (pool, state)
    }

    #[tokio::test]
    async fn binding_requires_live_local_session_and_rejects_identity_conflicts() {
        let (pool, _) = setup().await;
        sqlx::query(
            "INSERT INTO projects(id,user_id,name) VALUES ('existing-project','alice','unchanged')",
        )
        .execute(&pool)
        .await
        .unwrap();
        let alice = auth::hash_token("alice-token");
        let bob = auth::hash_token("bob-token");
        assert!(resolve_identity(&pool, ISSUER, "subject-a", None)
            .await
            .is_err());
        assert!(resolve_identity(&pool, ISSUER, "subject-a", Some("bad"))
            .await
            .is_err());
        assert_eq!(
            resolve_identity(&pool, ISSUER, "subject-a", Some(&alice))
                .await
                .unwrap(),
            "alice"
        );
        assert_eq!(
            resolve_identity(&pool, ISSUER, "subject-a", None)
                .await
                .unwrap(),
            "alice"
        );
        assert_eq!(
            resolve_identity(&pool, ISSUER, "subject-a", Some(&alice))
                .await
                .unwrap(),
            "alice"
        );
        assert!(matches!(
            resolve_identity(&pool, ISSUER, "subject-a", Some(&bob)).await,
            Err(AppError::Conflict(_))
        ));
        assert!(matches!(
            resolve_identity(&pool, ISSUER, "subject-b", Some(&alice)).await,
            Err(AppError::Conflict(_))
        ));
        sqlx::query("UPDATE user_sessions SET revoked_at=? WHERE token_hash=?")
            .bind(now())
            .bind(&bob)
            .execute(&pool)
            .await
            .unwrap();
        assert!(resolve_identity(&pool, ISSUER, "subject-b", Some(&bob))
            .await
            .is_err());
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM oidc_identities")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
        let owner: String =
            sqlx::query_scalar("SELECT user_id FROM projects WHERE id='existing-project'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(owner, "alice");
    }

    #[tokio::test]
    async fn callback_rejects_wrong_browser_and_exchange_is_one_time() {
        let (pool, state) = setup().await;
        sqlx::query("INSERT INTO oidc_transactions VALUES (?,?,?,?,?,?)")
            .bind(auth::hash_token("state"))
            .bind(auth::hash_token("browser"))
            .bind("nonce")
            .bind("verifier")
            .bind::<Option<String>>(None)
            .bind(expires())
            .execute(&pool)
            .await
            .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(header::COOKIE, "orialis_oidc=wrong".parse().unwrap());
        assert!(callback_inner(
            &state,
            &headers,
            Callback {
                state: Some("state".into()),
                code: Some("code".into())
            }
        )
        .await
        .is_err());
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM oidc_transactions")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
        sqlx::query("INSERT INTO oidc_exchanges VALUES (?,?,?)")
            .bind(auth::hash_token("exchange"))
            .bind("alice")
            .bind(expires())
            .execute(&pool)
            .await
            .unwrap();
        headers.insert(
            header::COOKIE,
            "orialis_oidc_exchange=exchange".parse().unwrap(),
        );
        headers.insert(header::ORIGIN, "https://evil.example".parse().unwrap());
        assert!(exchange(State(Arc::new(state.clone())), headers.clone())
            .await
            .is_err());
        headers.insert(header::ORIGIN, "https://orialis.jxcz.top".parse().unwrap());
        assert!(exchange(State(Arc::new(state.clone())), headers.clone())
            .await
            .is_ok());
        assert!(exchange(State(Arc::new(state)), headers).await.is_err());
    }

    #[tokio::test]
    async fn approved_binding_is_one_to_one_and_never_creates_users() {
        let (pool, _) = setup().await;
        assert!(
            resolve_approved_identity(&pool, ISSUER, "subject-0", "missing")
                .await
                .is_err()
        );
        assert_eq!(
            resolve_approved_identity(&pool, ISSUER, "subject-a", "alice")
                .await
                .unwrap(),
            "alice"
        );
        assert_eq!(
            resolve_approved_identity(&pool, ISSUER, "subject-a", "alice")
                .await
                .unwrap(),
            "alice"
        );
        assert!(matches!(
            resolve_approved_identity(&pool, ISSUER, "subject-a", "bob").await,
            Err(AppError::Conflict(_))
        ));
        assert!(matches!(
            resolve_approved_identity(&pool, ISSUER, "subject-b", "alice").await,
            Err(AppError::Conflict(_))
        ));
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM users")
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM oidc_identities")
                .fetch_one(&pool)
                .await
                .unwrap(),
            1
        );
        assert!(!study_scope_granted(false, None));
        assert!(study_scope_granted(true, None));
        assert!(!study_scope_granted(
            true,
            Some(&vec![Scope::new("openid".into())])
        ));
        assert!(study_scope_granted(
            true,
            Some(&vec![Scope::new("study_identity".into())])
        ));
    }

    #[test]
    #[cfg(unix)]
    fn private_mapping_requires_explicit_enable_and_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("orialis-map-test-{}", Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let file = dir.join("map.json");
        std::fs::write(&file, r#"{"enabled":true,"legacy_military_id":7,"user_id":"00000000-0000-4000-8000-000000000001"}"#).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            read_approved_mapping(&file)
                .unwrap()
                .unwrap()
                .legacy_military_id,
            7
        );
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_approved_mapping(&file).is_err());
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&file, r#"{"enabled":false,"legacy_military_id":7,"user_id":"00000000-0000-4000-8000-000000000001"}"#).unwrap();
        assert!(read_approved_mapping(&file).unwrap().is_none());
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }

    #[tokio::test]
    #[ignore = "requires the live identity service"]
    async fn live_discovery_is_compatible() {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        let result =
            CoreProviderMetadata::discover_async(IssuerUrl::new(ISSUER.into()).unwrap(), &http)
                .await;
        assert!(result.is_ok(), "discovery failed: {:?}", result.err());
    }
    #[tokio::test]
    async fn signed_oidc_identity_and_local_session_are_both_required_for_binding() {
        use chrono::TimeZone;
        use openidconnect::core::{
            CoreIdTokenVerifier, CoreJsonWebKeySet, CoreJwsSigningAlgorithm,
        };
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOlsibXlfY2xpZW50Il0sImlzcyI6Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJzdWIiOiJzdWJqZWN0IiwiZXhwIjoxNTQ0OTMyMTQ5LCJpYXQiOjE1NDQ5Mjg1NDksIm5vbmNlIjoidGhlX25vbmNlIn0.xUnSwSbcHsHWyJxwKGg69BIo_CktcyN5BVulGDb_QzE";
        let token: CoreIdToken = serde_json::from_value(serde_json::json!(jwt)).unwrap();
        let verifier = CoreIdTokenVerifier::new_confidential_client(
            ClientId::new("my_client".into()),
            ClientSecret::new("my_secret".into()),
            IssuerUrl::new("https://example.com".into()).unwrap(),
            CoreJsonWebKeySet::new(vec![]),
        )
        .set_allowed_algs(vec![CoreJwsSigningAlgorithm::HmacSha256])
        .set_time_fn(|| Utc.timestamp_opt(1544932148, 0).unwrap());
        let (pool, _) = setup().await;
        assert!(verified_subject(&token, &verifier, &Nonce::new("wrong".into())).is_err());
        let subject = verified_subject(&token, &verifier, &Nonce::new("the_nonce".into())).unwrap();
        assert!(
            resolve_identity(&pool, "https://example.com", &subject, Some("invalid"))
                .await
                .is_err()
        );
        assert_eq!(
            resolve_identity(
                &pool,
                "https://example.com",
                &subject,
                Some(&auth::hash_token("alice-token"))
            )
            .await
            .unwrap(),
            "alice"
        );
        assert!(verified_subject(
            &token,
            &verifier
                .clone()
                .set_time_fn(|| Utc.timestamp_opt(1544932150, 0).unwrap()),
            &Nonce::new("the_nonce".into())
        )
        .is_err());
        let wrong = CoreIdTokenVerifier::new_confidential_client(
            ClientId::new("my_client".into()),
            ClientSecret::new("wrong".into()),
            IssuerUrl::new("https://example.com".into()).unwrap(),
            CoreJsonWebKeySet::new(vec![]),
        )
        .set_allowed_algs(vec![CoreJwsSigningAlgorithm::HmacSha256])
        .set_time_fn(|| Utc.timestamp_opt(1544932148, 0).unwrap());
        assert!(verified_subject(&token, &wrong, &Nonce::new("the_nonce".into())).is_err());
        let wrong_audience = CoreIdTokenVerifier::new_confidential_client(
            ClientId::new("different-client".into()),
            ClientSecret::new("my_secret".into()),
            IssuerUrl::new("https://example.com".into()).unwrap(),
            CoreJsonWebKeySet::new(vec![]),
        )
        .set_allowed_algs(vec![CoreJwsSigningAlgorithm::HmacSha256])
        .set_time_fn(|| Utc.timestamp_opt(1544932148, 0).unwrap());
        assert!(
            verified_subject(&token, &wrong_audience, &Nonce::new("the_nonce".into())).is_err()
        );
        let wrong_issuer = CoreIdTokenVerifier::new_confidential_client(
            ClientId::new("my_client".into()),
            ClientSecret::new("my_secret".into()),
            IssuerUrl::new("https://other.example".into()).unwrap(),
            CoreJsonWebKeySet::new(vec![]),
        )
        .set_allowed_algs(vec![CoreJwsSigningAlgorithm::HmacSha256])
        .set_time_fn(|| Utc.timestamp_opt(1544932148, 0).unwrap());
        assert!(verified_subject(&token, &wrong_issuer, &Nonce::new("the_nonce".into())).is_err());
    }
}

#[cfg(test)]
#[path = "oidc_http_tests.rs"]
mod http_tests;
