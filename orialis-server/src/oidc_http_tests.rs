use super::*;
use crate::{metadata, mobile_realtime::MobileRegistry, AgentRegistry};
use axum::{
    extract::{Form, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Redirect, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use openidconnect::{
    core::{
        CoreGenderClaim, CoreHmacKey, CoreJweContentEncryptionAlgorithm, CoreJwsSigningAlgorithm,
    },
    Audience, IdToken, IdTokenClaims, StandardClaims, SubjectIdentifier,
};
use sha2::{Digest, Sha256};
use sqlx::sqlite::SqlitePoolOptions;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use url::Url;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
struct FixtureClaims {
    #[serde(skip_serializing_if = "Option::is_none")]
    legacy_military_id: Option<u64>,
}
impl openidconnect::AdditionalClaims for FixtureClaims {}
type FixtureToken = IdToken<
    FixtureClaims,
    CoreGenderClaim,
    CoreJweContentEncryptionAlgorithm,
    CoreJwsSigningAlgorithm,
>;
type FixtureTokenClaims = IdTokenClaims<FixtureClaims, CoreGenderClaim>;

const CLIENT: &str = "isolated-client";
const SECRET: &str = "isolated-secret-not-a-production-credential";
#[derive(Clone)]
struct FakeProvider {
    issuer: String,
    callback: String,
    codes: Arc<Mutex<HashMap<String, (String, String, String, bool)>>>,
}

async fn discovery(State(fake): State<FakeProvider>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "issuer": fake.issuer, "authorization_endpoint": format!("{}/authorize", fake.issuer),
        "token_endpoint": format!("{}/token", fake.issuer), "jwks_uri": format!("{}/jwks", fake.issuer),
        "response_types_supported": ["code"], "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["HS256"],
        "token_endpoint_auth_methods_supported": ["client_secret_basic"],
        "code_challenge_methods_supported": ["S256"]
    }))
}
async fn jwks() -> Json<serde_json::Value> {
    Json(serde_json::json!({"keys": []}))
}
async fn authorize(
    State(fake): State<FakeProvider>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    if q.get("client_id").map(String::as_str) != Some(CLIENT)
        || q.get("redirect_uri") != Some(&fake.callback)
        || q.get("response_type").map(String::as_str) != Some("code")
        || q.get("code_challenge_method").map(String::as_str) != Some("S256")
        || !q
            .get("scope")
            .is_some_and(|s| s.split_whitespace().any(|x| x == "openid"))
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let (Some(state), Some(nonce), Some(challenge)) =
        (q.get("state"), q.get("nonce"), q.get("code_challenge"))
    else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let code = random();
    fake.codes.lock().unwrap().insert(
        code.clone(),
        (
            nonce.clone(),
            challenge.clone(),
            q.get("test_subject")
                .cloned()
                .unwrap_or_else(|| "subject-alice".into()),
            q.contains_key("bad_nonce"),
        ),
    );
    let mut redirect = Url::parse(&fake.callback).unwrap();
    redirect
        .query_pairs_mut()
        .append_pair("code", &code)
        .append_pair("state", state);
    Redirect::to(redirect.as_str()).into_response()
}
async fn token(
    State(fake): State<FakeProvider>,
    headers: HeaderMap,
    Form(form): Form<HashMap<String, String>>,
) -> Response {
    let expected = format!("Basic {}", STANDARD.encode(format!("{CLIENT}:{SECRET}")));
    if headers
        .get(header::AUTHORIZATION)
        .and_then(|x| x.to_str().ok())
        != Some(expected.as_str())
        || form.get("grant_type").map(String::as_str) != Some("authorization_code")
        || form.get("redirect_uri") != Some(&fake.callback)
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let Some((nonce, challenge, subject, bad_nonce)) = form
        .get("code")
        .and_then(|c| fake.codes.lock().unwrap().remove(c))
    else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    let Some(verifier) = form.get("code_verifier") else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    if URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())) != challenge {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let legacy_id = match subject.as_str() {
        "auto-ok" | "auto-conflict" | "auto-denied" | "auto-nonce" => Some(7),
        "auto-wrong" => Some(8),
        _ => None,
    };
    let reduced_scope = subject == "auto-denied";
    let claims = FixtureTokenClaims::new(
        IssuerUrl::new(fake.issuer.clone()).unwrap(),
        vec![Audience::new(CLIENT.into())],
        Utc::now() + Duration::minutes(5),
        Utc::now(),
        StandardClaims::new(SubjectIdentifier::new(subject)),
        FixtureClaims {
            legacy_military_id: legacy_id,
        },
    )
    .set_nonce(Some(Nonce::new(if bad_nonce {
        "wrong-nonce".into()
    } else {
        nonce
    })));
    let id_token = FixtureToken::new(
        claims,
        &CoreHmacKey::new(SECRET.as_bytes()),
        CoreJwsSigningAlgorithm::HmacSha256,
        None,
        None,
    )
    .unwrap();
    let mut response = serde_json::json!({"access_token":"fixture-access-token", "token_type":"Bearer", "id_token": id_token.to_string()});
    if reduced_scope {
        response["scope"] = serde_json::json!("openid");
    }
    Json(response).into_response()
}
fn cookie_pair(response: &reqwest::Response, name: &str) -> String {
    let raw = response
        .headers()
        .get(header::SET_COOKIE)
        .unwrap()
        .to_str()
        .unwrap();
    assert!(raw.starts_with(&format!("{name}=")), "cookie name");
    for attribute in [
        "Path=/api/v1/auth/oidc",
        "Secure",
        "HttpOnly",
        "SameSite=Lax",
    ] {
        assert!(raw.contains(attribute), "missing {attribute}: {raw}");
    }
    let pair = raw.split(';').next().unwrap();
    assert!(raw.contains(if pair.ends_with('=') {
        "Max-Age=0"
    } else {
        "Max-Age=600"
    }));
    assert_eq!(
        response.headers().get(header::CACHE_CONTROL).unwrap(),
        "no-store"
    );
    pair.to_owned()
}
async fn start(
    http: &reqwest::Client,
    base: &str,
    session: Option<&str>,
    bind: bool,
) -> (String, Url) {
    let mut request = http
        .post(format!("{base}/api/v1/auth/oidc/start"))
        .header(header::ORIGIN, base)
        .header(header::CONTENT_TYPE, "application/json")
        .body(serde_json::json!({"bind": bind}).to_string());
    if let Some(session) = session {
        request = request.header(header::AUTHORIZATION, format!("Session {session}"));
    }
    let response = request.send().await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let cookie = cookie_pair(&response, "orialis_oidc");
    let json: serde_json::Value = serde_json::from_slice(&response.bytes().await.unwrap()).unwrap();
    (cookie, Url::parse(json["url"].as_str().unwrap()).unwrap())
}
async fn authorization(
    http: &reqwest::Client,
    mut url: Url,
    subject: &str,
    bad_nonce: bool,
) -> Url {
    url.query_pairs_mut().append_pair("test_subject", subject);
    if bad_nonce {
        url.query_pairs_mut().append_pair("bad_nonce", "1");
    }
    let response = http.get(url).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    Url::parse(
        response
            .headers()
            .get(header::LOCATION)
            .unwrap()
            .to_str()
            .unwrap(),
    )
    .unwrap()
}
async fn callback(http: &reqwest::Client, url: Url, cookie: &str, success: bool) -> Option<String> {
    let response = http
        .get(url)
        .header(header::COOKIE, cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        response.headers().get(header::LOCATION).unwrap(),
        if success {
            "/#oidc-complete"
        } else {
            "/#oidc-error"
        }
    );
    if success {
        Some(cookie_pair(&response, "orialis_oidc_exchange"))
    } else {
        assert!(response.headers().get(header::SET_COOKIE).is_none());
        None
    }
}
async fn exchange_session(http: &reqwest::Client, base: &str, cookie: &str) -> (String, String) {
    let response = http
        .post(format!("{base}/api/v1/auth/oidc/exchange"))
        .header(header::ORIGIN, base)
        .header(header::COOKIE, cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let cleared = cookie_pair(&response, "orialis_oidc_exchange");
    assert_eq!(cleared, "orialis_oidc_exchange=");
    let body: serde_json::Value = serde_json::from_slice(&response.bytes().await.unwrap()).unwrap();
    (
        body["userId"].as_str().unwrap().into(),
        body["accessToken"].as_str().unwrap().into(),
    )
}

#[tokio::test]
async fn real_http_binding_login_and_rejection_paths() {
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
            .bind("fixture")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES (?,?,?,?)")
            .bind(format!("session-{user}"))
            .bind(user)
            .bind(auth::hash_token(&format!("{user}-session")))
            .bind(expires())
            .execute(&pool)
            .await
            .unwrap();
    }
    sqlx::query("INSERT INTO projects(id,user_id,name) VALUES ('project-a','alice','fixture')")
        .execute(&pool)
        .await
        .unwrap();
    let app_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", app_listener.local_addr().unwrap());
    let idp_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let issuer = format!("http://{}", idp_listener.local_addr().unwrap());
    TEST_PROVIDER
        .set((issuer.clone(), CLIENT.into(), SECRET.into()))
        .unwrap();
    let fake = FakeProvider {
        issuer: issuer.clone(),
        callback: format!("{base}{CALLBACK}"),
        codes: Arc::new(Mutex::new(HashMap::new())),
    };
    let provider_router = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/jwks", get(jwks))
        .route("/authorize", get(authorize))
        .route("/token", post(token))
        .with_state(fake);
    let idp_task = tokio::spawn(async move {
        axum::serve(idp_listener, provider_router).await.unwrap();
    });
    let state = Arc::new(AppState {
        metadata: metadata("test", "test", &base),
        pool: pool.clone(),
        agent: AgentRegistry::default(),
        mobile: MobileRegistry::default(),
        agent_device_token: None,
        agent_user_id: None,
        public_url: base.clone(),
        upload_dir: PathBuf::from("/tmp"),
    });
    let app = crate::auth_router()
        .route("/api/v1/health", get(crate::health::health))
        .route("/api/v1/capabilities", get(crate::health::capabilities))
        .with_state(state);
    let app_task = tokio::spawn(async move {
        axum::serve(app_listener, app).await.unwrap();
    });
    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();

    let health = http
        .get(format!("{base}/api/v1/health"))
        .send()
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    let capabilities = http
        .get(format!("{base}/api/v1/capabilities"))
        .send()
        .await
        .unwrap();
    assert_eq!(capabilities.status(), StatusCode::OK);
    let values: serde_json::Value =
        serde_json::from_slice(&capabilities.bytes().await.unwrap()).unwrap();
    assert_eq!(
        values["response_ui"]["block_types"]
            .as_array()
            .unwrap()
            .len(),
        26
    );
    assert_eq!(
        values["response_ui"]["plot_kinds"]
            .as_array()
            .unwrap()
            .len(),
        6
    );

    let no_session = http
        .post(format!("{base}/api/v1/auth/oidc/start"))
        .header(header::ORIGIN, &base)
        .header(header::CONTENT_TYPE, "application/json")
        .body(serde_json::json!({"bind":true}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(no_session.status(), StatusCode::UNAUTHORIZED);
    let (browser, url) = start(&http, &base, Some("alice-session"), true).await;
    let redirect = authorization(&http, url, "subject-alice", false).await;
    let mut wrong_state = redirect.clone();
    let code = redirect
        .query_pairs()
        .find(|(k, _)| k == "code")
        .unwrap()
        .1
        .to_string();
    wrong_state.set_query(None);
    wrong_state
        .query_pairs_mut()
        .append_pair("code", &code)
        .append_pair("state", "invalid");
    callback(&http, wrong_state, &browser, false).await;
    let exchange_cookie = callback(&http, redirect.clone(), &browser, true)
        .await
        .unwrap();
    callback(&http, redirect, &browser, false).await;
    let (id, new_session) = exchange_session(&http, &base, &exchange_cookie).await;
    assert_eq!(id, "alice");
    let replay = http
        .post(format!("{base}/api/v1/auth/oidc/exchange"))
        .header(header::ORIGIN, &base)
        .header(header::COOKIE, &exchange_cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::UNAUTHORIZED);
    for token in ["alice-session", new_session.as_str()] {
        let response = http
            .get(format!("{base}/api/v1/auth/session"))
            .header(header::AUTHORIZATION, format!("Session {token}"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&response.bytes().await.unwrap()).unwrap()
                ["userId"],
            "alice"
        );
    }
    let (browser, url) = start(&http, &base, None, false).await;
    let redirect = authorization(&http, url, "subject-alice", false).await;
    let cookie = callback(&http, redirect, &browser, true).await.unwrap();
    assert_eq!(exchange_session(&http, &base, &cookie).await.0, "alice");

    for (local_session, subject, bad_nonce) in [
        ("bob-session", "subject-alice", false),
        ("alice-session", "subject-other", false),
        ("bob-session", "subject-bob", true),
    ] {
        let (browser, url) = start(&http, &base, Some(local_session), true).await;
        let redirect = authorization(&http, url, subject, bad_nonce).await;
        callback(&http, redirect, &browser, false).await;
    }
    let mappings: Vec<(String, String)> =
        sqlx::query_as("SELECT subject,user_id FROM oidc_identities")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(mappings, vec![("subject-alice".into(), "alice".into())]);
    let owner: String = sqlx::query_scalar("SELECT user_id FROM projects WHERE id='project-a'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(owner, "alice");
    let bob = http
        .get(format!("{base}/api/v1/auth/session"))
        .header(header::AUTHORIZATION, "Session bob-session")
        .send()
        .await
        .unwrap();
    assert_eq!(bob.status(), StatusCode::OK);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&bob.bytes().await.unwrap()).unwrap()["userId"],
        "bob"
    );
    use std::os::unix::fs::PermissionsExt;
    let target = "00000000-0000-4000-8000-000000000007";
    sqlx::query("INSERT INTO users(id,username,password_hash) VALUES (?,?,?)")
        .bind(target)
        .bind("auto-fixture")
        .bind("fixture")
        .execute(&pool)
        .await
        .unwrap();
    let mapping_file =
        std::env::temp_dir().join(format!("orialis-approved-{}.json", Uuid::new_v4()));
    std::fs::write(
        &mapping_file,
        serde_json::json!({"enabled":true,"legacy_military_id":7,"user_id":target}).to_string(),
    )
    .unwrap();
    std::fs::set_permissions(&mapping_file, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::env::set_var("ORIALIS_OIDC_APPROVED_MAPPING_FILE", &mapping_file);
    for (subject, bad_nonce) in [
        ("auto-wrong", false),
        ("auto-denied", false),
        ("auto-nonce", true),
    ] {
        let (browser, url) = start(&http, &base, None, false).await;
        assert!(url
            .query_pairs()
            .any(|(k, v)| k == "scope" && v.split_whitespace().any(|s| s == "study_identity")));
        assert!(url
            .query_pairs()
            .any(|(k, v)| k == "claims" && v.contains("legacy_military_id")));
        let redirect = authorization(&http, url, subject, bad_nonce).await;
        callback(&http, redirect, &browser, false).await;
    }
    let (browser, url) = start(&http, &base, None, false).await;
    let redirect = authorization(&http, url, "auto-ok", false).await;
    let code = callback(&http, redirect, &browser, true).await.unwrap();
    assert_eq!(exchange_session(&http, &base, &code).await.0, target);
    let (browser, url) = start(&http, &base, None, false).await;
    let redirect = authorization(&http, url, "auto-conflict", false).await;
    callback(&http, redirect, &browser, false).await;
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM users")
            .fetch_one(&pool)
            .await
            .unwrap(),
        3
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM oidc_identities WHERE user_id=?")
            .bind(target)
            .fetch_one(&pool)
            .await
            .unwrap(),
        1
    );
    std::env::remove_var("ORIALIS_OIDC_APPROVED_MAPPING_FILE");
    std::fs::remove_file(mapping_file).unwrap();
    app_task.abort();
    idp_task.abort();
}
