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
    response_ui: serde_json::Value,
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
            "multidevice.v1",
            "cron_delivery",
            "proactive_delivery",
            "response_ui.v1",
        ],
        // UI is opaque assistant content: clients validate and fall back to text.
        response_ui: serde_json::json!({
            "format": "orialis-ui", "version": 1, "transport": "content_fence",
            "block_types": ["metrics", "chart", "tabs", "checklist", "choices", "svg", "diagram", "math", "plot", "timeline", "simulation", "form", "table", "sources", "diff", "media", "actions", "progress", "heatmap", "accordion"],
            "plot_kinds": ["line", "scatter", "pie", "area", "bar", "radar"],
            "limits": {
                "json_bytes": 32768, "blocks": 12, "items": 12, "title": 80,
                "fallback": 4000, "label": 120, "value": 120, "detail": 240,
                "content": 4000, "prompt": 1000, "unit": 32, "source": 16000,
                "math_source": 4000, "points": 120, "edges": 24, "columns": 8,
            },
        }),
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
        assert!(response.0.capabilities.contains(&"multidevice.v1"));
        assert!(response.0.capabilities.contains(&"cron_delivery"));
        assert!(response.0.capabilities.contains(&"proactive_delivery"));
    }

    #[tokio::test]
    async fn response_ui_discovery_describes_bounded_content_format() {
        let response = capabilities().await;
        assert!(response.0.capabilities.contains(&"response_ui.v1"));
        let ui = response.0.response_ui;
        assert_eq!(ui["format"], "orialis-ui");
        assert_eq!(ui["version"], 1);
        assert_eq!(ui["transport"], "content_fence");
        assert_eq!(
            ui["block_types"],
            serde_json::json!([
                "metrics",
                "chart",
                "tabs",
                "checklist",
                "choices",
                "svg",
                "diagram",
                "math",
                "plot",
                "timeline",
                "simulation",
                "form",
                "table",
                "sources",
                "diff",
                "media",
                "actions",
                "progress",
                "heatmap",
                "accordion"
            ])
        );
        assert_eq!(
            ui["plot_kinds"],
            serde_json::json!(["line", "scatter", "pie", "area", "bar", "radar"])
        );
        assert_eq!(ui["limits"]["json_bytes"], 32768);
        assert_eq!(ui["limits"]["blocks"], 12);
        assert_eq!(ui["limits"]["items"], 12);
        assert_eq!(ui["limits"]["fallback"], 4000);
        assert_eq!(ui["limits"]["source"], 16000);
    }
}
