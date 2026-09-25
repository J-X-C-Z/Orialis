use crate::AppState;
use axum::{extract::State, Json};
use orialis_core::{ServiceMetadata, API_VERSION, SERVICE_NAME};
use serde::Serialize;
use std::sync::Arc;

#[derive(Serialize)]
pub(crate) struct HealthResponse {
    ok: bool,
    service: &'static str,
    version: &'static str,
    environment: String,
}

#[derive(Serialize)]
pub(crate) struct CapabilitiesResponse {
    service: &'static str,
    api_version: &'static str,
    web: bool,
    capabilities: Vec<&'static str>,
}

pub(crate) async fn health(State(state): State<Arc<AppState>>) -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        service: SERVICE_NAME,
        version: env!("CARGO_PKG_VERSION"),
        environment: state.metadata.environment.clone(),
    })
}

pub(crate) async fn meta(State(state): State<Arc<AppState>>) -> Json<ServiceMetadata> {
    Json(state.metadata.clone())
}

pub(crate) async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        service: SERVICE_NAME,
        api_version: API_VERSION,
        web: false,
        capabilities: vec![
            "health",
            "metadata",
            "auth",
            "tasks",
            "projects",
            "calendar-events",
            "schedules",
            "incremental-sync",
            "messages",
            "conversations",
            "attachments",
            "agent-devices",
            "websocket",
            "task_children",
            "schedule_importance",
        ],
    })
}

#[cfg(test)]
mod tests {
    use super::capabilities;

    #[tokio::test]
    async fn advertises_task_children_and_schedule_importance() {
        let response = capabilities().await;
        assert!(response.0.capabilities.contains(&"task_children"));
        assert!(response.0.capabilities.contains(&"schedule_importance"));
    }
}
