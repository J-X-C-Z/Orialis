use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use oris_core::{metadata, ServiceMetadata, API_VERSION, SERVICE_NAME};
use serde::Serialize;
use std::{env, net::SocketAddr, sync::Arc};
use tracing::info;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone)]
struct AppState {
    metadata: ServiceMetadata,
}

#[derive(Clone)]
struct Config {
    host: String,
    port: u16,
    environment: String,
    public_url: String,
}

impl Config {
    fn from_env() -> Result<Self, String> {
        let port = env::var("ORIS_PORT")
            .unwrap_or_else(|_| "18443".into())
            .parse::<u16>()
            .map_err(|_| "ORIS_PORT must be a valid port number".to_string())?;

        Ok(Self {
            host: env::var("ORIS_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
            port,
            environment: env::var("ORIS_ENV").unwrap_or_else(|_| "development".into()),
            public_url: env::var("ORIS_PUBLIC_URL")
                .unwrap_or_else(|_| "https://orialis.jxcz.top".into()),
        })
    }

    fn address(&self) -> Result<SocketAddr, String> {
        format!("{}:{}", self.host, self.port)
            .parse()
            .map_err(|_| "ORIS_HOST and ORIS_PORT do not form a valid socket address".into())
    }
}

#[derive(Serialize)]
struct HealthResponse {
    ok: bool,
    service: &'static str,
    version: &'static str,
    environment: String,
}

#[derive(Serialize)]
struct CapabilitiesResponse {
    service: &'static str,
    api_version: &'static str,
    web: bool,
    capabilities: Vec<&'static str>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "oris_server=info".into()))
        .init();

    let config = Config::from_env().unwrap_or_else(|error| panic!("configuration error: {error}"));
    let address = config.address().unwrap_or_else(|error| panic!("configuration error: {error}"));
    let state = Arc::new(AppState {
        metadata: metadata(VERSION, config.environment.clone(), config.public_url.clone()),
    });

    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/v1/meta", get(meta))
        .route("/api/v1/capabilities", get(capabilities))
        .fallback(not_found)
        .with_state(state);

    info!(service = SERVICE_NAME, %address, public_url = %config.public_url, "Oris server listening");

    let listener = tokio::net::TcpListener::bind(address)
        .await
        .unwrap_or_else(|error| panic!("failed to bind {address}: {error}"));
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("Oris server failed");
}

async fn health(State(state): State<Arc<AppState>>) -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        service: SERVICE_NAME,
        version: VERSION,
        environment: state.metadata.environment.clone(),
    })
}

async fn meta(State(state): State<Arc<AppState>>) -> Json<ServiceMetadata> {
    Json(state.metadata.clone())
}

async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        service: SERVICE_NAME,
        api_version: API_VERSION,
        web: false,
        capabilities: vec!["health", "metadata", "capabilities"],
    })
}

async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({
            "error": "route_not_found",
            "service": SERVICE_NAME,
        })),
    )
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => info!("received Ctrl+C, shutting down"),
        _ = terminate => info!("received SIGTERM, shutting down"),
    }
}

