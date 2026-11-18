//! Fixed-origin, account-scoped Orialis HTTP tools.
//!
//! The embedded upstream contract is copied from Orialis f9a064bf05b18265afd26905e7240777d4ce355c.
//! It is data, never executable code. Runtime schemas repair upstream metadata mismatches
//! (calendar alias name, create IDs, nullable patches and the server's 100-item page limit).
//! No tool accepts a URL, authorization header, account override, or arbitrary HTTP route.
//! Mutations are sent once, without HTTP retries; ambiguous outcomes are explicitly marked.
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, NaiveDate, Weekday};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use regex::Regex;
use reqwest::{Client, Method, Url, header::HeaderValue};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    sync::{Arc, LazyLock},
    time::Duration,
};
use tokio::sync::Semaphore;
use uuid::Uuid;

pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;
pub const MAX_ARGUMENT_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_NEWS_RESULT_BYTES: usize = 1024 * 1024;
pub const MAX_BATCH_ITEMS: usize = 200;
const MAX_SCHEDULE_PAGES: usize = 1_000;
const PATH_SEGMENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');
static CONTRACT: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("domain_tools/upstream_contract.json"))
        .expect("embedded contract is valid JSON")
});
static SCHEMAS: LazyLock<Vec<Value>> = LazyLock::new(build_schemas);
static AGENDA: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(concat!(
        r"(?m)(?:^|[\n;；])\s*(?:[-*•]\s*)?(?:",
        r"(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[/月]\d{1,2}日?)",
        r"\s*(?:[（(](?:周|星期)[一二三四五六日天][）)])?\s*[:：]",
        r"|(?:[01]?\d|2[0-3])[:：][0-5]\d",
        r"(?:\s*[-—–~～至到]\s*(?:[01]?\d|2[0-3])[:：][0-5]\d)?",
        r"|(?:清晨|早晨|早上|上午|中午|午后|下午|傍晚|晚上|夜间|凌晨)",
        r")\s*[:：]?\s*[^\s:：;；\n]"
    ))
    .expect("agenda expression is valid")
});

#[derive(Clone, Copy)]
struct Route {
    method: &'static str,
    path: &'static str,
    kind: &'static str,
}
fn route(name: &str) -> Option<Route> {
    let (method, path, kind) = match name {
        "list_tasks" => ("GET", "/api/v1/tasks", "task"),
        "create_task" => ("POST", "/api/v1/tasks", "task"),
        "update_task" => ("PATCH", "/api/v1/tasks/{id}", "task"),
        "delete_task" => ("DELETE", "/api/v1/tasks/{id}", "task"),
        "list_projects" => ("GET", "/api/v1/projects", "project"),
        "create_project" => ("POST", "/api/v1/projects", "project"),
        "update_project" => ("PATCH", "/api/v1/projects/{id}", "project"),
        "delete_project" => ("DELETE", "/api/v1/projects/{id}", "project"),
        "get_project_summary" => ("GET", "/api/v1/projects/{id}/summary", "project"),
        "list_milestones" => (
            "GET",
            "/api/v1/projects/{projectId}/milestones",
            "milestone",
        ),
        "create_milestone" => (
            "POST",
            "/api/v1/projects/{projectId}/milestones",
            "milestone",
        ),
        "get_milestone" => (
            "GET",
            "/api/v1/projects/{projectId}/milestones/{id}",
            "milestone",
        ),
        "update_milestone" => (
            "PATCH",
            "/api/v1/projects/{projectId}/milestones/{id}",
            "milestone",
        ),
        "delete_milestone" => (
            "DELETE",
            "/api/v1/projects/{projectId}/milestones/{id}",
            "milestone",
        ),
        "list_schedules" | "get_schedule" => ("GET", "/api/v1/schedules", "schedule"),
        "create_schedule" => ("POST", "/api/v1/schedules", "schedule"),
        "update_schedule" => ("PATCH", "/api/v1/schedules/{id}", "schedule"),
        "delete_schedule" => ("DELETE", "/api/v1/schedules/{id}", "schedule"),
        "list_calendar_events" | "get_calendar_event" => {
            ("GET", "/api/v1/calendar-events", "schedule")
        }
        "create_calendar_event" => ("POST", "/api/v1/calendar-events", "schedule"),
        "update_calendar_event" => ("PATCH", "/api/v1/calendar-events/{id}", "schedule"),
        "delete_calendar_event" => ("DELETE", "/api/v1/calendar-events/{id}", "schedule"),
        "list_conversations" => ("GET", "/api/v1/conversations", "conversation"),
        "create_conversation" => ("POST", "/api/v1/conversations", "conversation"),
        "update_conversation" => ("PATCH", "/api/v1/conversations/{id}", "conversation"),
        "delete_conversation" => ("DELETE", "/api/v1/conversations/{id}", "conversation"),
        "list_messages" => (
            "GET",
            "/api/v1/conversations/{conversationId}/messages",
            "message",
        ),
        "create_message" => (
            "POST",
            "/api/v1/conversations/{conversationId}/messages",
            "message",
        ),
        _ => return None,
    };
    Some(Route { method, path, kind })
}
fn batch_single(name: &str) -> Option<&'static str> {
    Some(match name {
        "create_tasks" => "create_task",
        "create_projects" => "create_project",
        "create_milestones" => "create_milestone",
        "create_schedules" => "create_schedule",
        "create_calendar_events" => "create_calendar_event",
        "create_conversations" => "create_conversation",
        "create_messages" => "create_message",
        _ => return None,
    })
}

/// OpenAI function-tool descriptors. Cached construction avoids rebuilding 39 schemas per turn.
pub fn schemas() -> Vec<Value> {
    SCHEMAS.clone()
}
pub fn contains(name: &str) -> bool {
    schema(name).is_some()
}
pub fn tool_names() -> Vec<&'static str> {
    CONTRACT["tool_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect()
}
fn schema(name: &str) -> Option<&'static Value> {
    SCHEMAS
        .iter()
        .find(|s| s["function"]["name"].as_str() == Some(name))
        .map(|s| &s["function"])
}
fn nullable(spec: &mut Value) {
    if let Some(t) = spec["type"].as_str() {
        spec["type"] = json!([t, "null"]);
    }
}
fn build_schemas() -> Vec<Value> {
    let mut result = Vec::new();
    for name in CONTRACT["tool_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
    {
        let mut s = CONTRACT["schemas"][name].clone();
        s["name"] = json!(name); // Upstream create_calendar_event incorrectly names create_schedule.
        if let Some(r) = route(name) {
            let props = s["parameters"]["properties"].as_object_mut().unwrap();
            if r.method == "POST" && r.kind != "milestone" {
                props.insert(
                    "id".into(),
                    json!({"type":"string","minLength":1,"maxLength":128}),
                );
            }
            if name.starts_with("list_") && name != "list_messages" && props.contains_key("limit") {
                props.get_mut("limit").unwrap()["maximum"] = json!(100);
            }
            if r.method == "PATCH" {
                let fields: &[&str] = match r.kind {
                    "task" => &[
                        "notes",
                        "important",
                        "urgent",
                        "completedAt",
                        "due",
                        "dueTime",
                        "reminderMinutes",
                        "projectId",
                        "parentTaskId",
                        "scheduleId",
                        "recurrence",
                        "manualPosition",
                    ],
                    "project" => &[
                        "goal",
                        "description",
                        "color",
                        "startDate",
                        "due",
                        "nextActionTaskId",
                        "manualPosition",
                    ],
                    "milestone" => &["due"],
                    "schedule" => &["description", "location", "reminderMinutes"],
                    "conversation" => &["manualPosition"],
                    _ => &[],
                };
                for field in fields {
                    if let Some(spec) = props.get_mut(*field) {
                        nullable(spec);
                    }
                }
            }
            if let Some(spec) = props.get_mut("reminderMinutes") {
                spec["minimum"] = json!(0);
            }
            if let Some(spec) = props.get_mut("position") {
                spec["minimum"] = json!(0);
            }
            for field in ["title", "name"] {
                if let Some(spec) = props.get_mut(field) {
                    spec["minLength"] = json!(1);
                    if r.kind == "task" || r.kind == "project" {
                        spec["maxLength"] = json!(120);
                    }
                    if r.kind == "milestone" {
                        spec["maxLength"] = json!(200);
                    }
                }
            }
            if let Some(spec) = props.get_mut("attachments") {
                spec["maxItems"] = json!(10);
                spec["items"] = json!({"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":128}},"required":["id"],"additionalProperties":false});
                spec["description"] = json!(
                    "References to existing attachments owned by this account and conversation. Uploading/downloading files is not performed by this tool."
                );
            }
        }
        result.push(json!({"type":"function","function":s}));
    }
    // Batch item contracts must reflect exactly the corrected single-item contracts.
    for i in 0..result.len() {
        let name = result[i]["function"]["name"].as_str().unwrap();
        if let Some(single) = batch_single(name) {
            let parameters = result
                .iter()
                .find(|s| s["function"]["name"] == single)
                .unwrap()["function"]["parameters"]
                .clone();
            result[i]["function"]["parameters"]["properties"]["items"]["items"] = parameters;
        }
    }
    result
}

/// Account-scoped pooled HTTP client. Clone shares connection pool and concurrency budget.
/// Debug intentionally omits credentials. `server_url` must be administrator-configured, not model output.
#[derive(Clone)]
pub struct DomainClient {
    http: Client,
    origin: Url,
    display_url: String,
    device_auth: Option<HeaderValue>,
    device_id: HeaderValue,
    publisher_auth: Option<HeaderValue>,
    permits: Arc<Semaphore>,
}
impl std::fmt::Debug for DomainClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DomainClient")
            .field("origin", &self.origin.as_str())
            .finish_non_exhaustive()
    }
}
impl DomainClient {
    pub fn new(
        server_url: &str,
        device_id: &str,
        device_token: &str,
        news_publisher_token: Option<&str>,
    ) -> Result<Self> {
        let mut origin = Url::parse(server_url.trim()).map_err(|_| {
            anyhow::anyhow!("ORIALIS_SERVER_URL must be an absolute ws/wss or http/https URL")
        })?;
        ensure!(
            matches!(origin.scheme(), "ws" | "wss" | "http" | "https")
                && origin.host_str().is_some(),
            "invalid Orialis server origin"
        );
        ensure!(
            origin.username().is_empty() && origin.password().is_none(),
            "Orialis server URL must not contain credentials"
        );
        ensure!(
            origin.fragment().is_none(),
            "Orialis server URL must not contain a fragment"
        );
        origin.set_query(None);
        let display_url = origin.as_str().to_owned();
        let scheme = if matches!(origin.scheme(), "wss" | "https") {
            "https"
        } else {
            "http"
        };
        origin
            .set_scheme(scheme)
            .map_err(|_| anyhow::anyhow!("invalid Orialis URL scheme"))?;
        origin.set_path("/");
        ensure!(
            !device_id.trim().is_empty(),
            "ORIALIS_DEVICE_ID is required"
        );
        let device_id =
            HeaderValue::from_str(device_id).context("invalid ORIALIS_DEVICE_ID header")?;
        let http = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .pool_max_idle_per_host(4)
            .pool_idle_timeout(Duration::from_secs(30))
            .user_agent("orialis-hermes-rust/0.1.0")
            .build()
            .context("could not build Orialis HTTP client")?;
        Ok(Self {
            http,
            origin,
            display_url,
            device_auth: bearer(device_token)?,
            device_id,
            publisher_auth: bearer(news_publisher_token.unwrap_or_default())?,
            permits: Arc::new(Semaphore::new(4)),
        })
    }

    /// Dispatch a registered tool. Validation errors are returned as tool results, never panics.
    /// The caller owns user authorization; this method never fabricates approval or retries mutations.
    pub async fn execute(&self, name: &str, args: Value) -> Value {
        if !contains(name) {
            return error("unknown Orialis tool");
        }
        if serde_json::to_vec(&args).map_or(true, |v| v.len() > MAX_ARGUMENT_BYTES) {
            return error("tool arguments exceed 2 MiB");
        }
        let _permit = match self.permits.acquire().await {
            Ok(p) => p,
            Err(_) => return error("Orialis client is closed"),
        };
        if let Some(single) = batch_single(name) {
            return self.execute_batch(single, args).await;
        }
        if let Err(e) = validate_schema(&args, &schema(name).unwrap()["parameters"], "arguments") {
            return error(&e.to_string());
        }
        match name {
            "orialis_capabilities" => return self.capabilities().await,
            "news.publish" => return self.publish_news(args).await,
            "get_schedule" | "get_calendar_event" => {
                if let Err(e) = identifier(args["id"].as_str().unwrap(), "id") {
                    return error(&e.to_string());
                }
                return self
                    .get_schedule(route(name).unwrap().path, args["id"].as_str().unwrap())
                    .await;
            }
            _ => {}
        }
        match prepare(name, args, false) {
            Ok(request) => self.execute_prepared(name, request).await,
            Err(e) => error(&e.to_string()),
        }
    }

    async fn execute_prepared(&self, name: &str, prepared: Prepared) -> Value {
        let mut result = self
            .request(prepared.route.method, &prepared.path, &prepared.body, false)
            .await;
        if name == "create_schedule" && result["ok"] == true {
            result =
                json!({"ok":true,"schedule":result.get("result").cloned().unwrap_or(Value::Null)});
        }
        result
    }

    async fn execute_batch(&self, single: &str, args: Value) -> Value {
        let Some(object) = args
            .as_object()
            .filter(|v| v.len() == 1 && v.contains_key("items"))
        else {
            return json!({"ok":false,"error":"arguments must contain only items","written":0});
        };
        let Some(items) = object["items"]
            .as_array()
            .filter(|v| (1..=MAX_BATCH_ITEMS).contains(&v.len()))
        else {
            return json!({"ok":false,"error":"items must contain 1 to 200 objects","written":0});
        };
        let mut prepared = Vec::with_capacity(items.len());
        let mut ids = HashSet::new();
        for (index, item) in items.iter().enumerate() {
            let value = (|| -> Result<Prepared> {
                validate_schema(item, &schema(single).unwrap()["parameters"], "item")?;
                let p = prepare(single, item.clone(), true)?;
                if let Some(id) = p.submitted.get("id").and_then(Value::as_str) {
                    ensure!(ids.insert(id.to_owned()), "duplicate id in batch");
                }
                Ok(p)
            })();
            match value {
                Ok(value) => prepared.push(value),
                Err(e) => {
                    return json!({"ok":false,"error":e.to_string(),"validationIndex":index,"written":0});
                }
            }
        }
        if self.device_auth.is_none() {
            return json!({"ok":false,"error":"ORIALIS_DEVICE_TOKEN is required","written":0});
        }
        let mut results = Vec::with_capacity(prepared.len());
        let mut succeeded = 0;
        for (index, request) in prepared.into_iter().enumerate() {
            let submitted = request.submitted.clone();
            let mut response = self.execute_prepared(single, request).await;
            if response["ok"] == true {
                succeeded += 1;
            }
            response["index"] = json!(index);
            response["submitted"] = submitted;
            results.push(response);
        }
        json!({"ok":succeeded == results.len(),"atomic":false,"total":results.len(),"succeeded":succeeded,"failed":results.len()-succeeded,"results":results})
    }

    async fn get_schedule(&self, root: &str, id: &str) -> Value {
        let mut query = json!({"limit":100});
        let mut seen = HashSet::new();
        for _ in 0..MAX_SCHEDULE_PAGES {
            let response = self.request("GET", root, &query, false).await;
            if response["ok"] != true {
                return response;
            }
            let data = &response["result"];
            let Some(items) = data["items"].as_array() else {
                return error("invalid schedule collection response");
            };
            if let Some(item) = items.iter().find(|item| item["id"].as_str() == Some(id)) {
                return json!({"ok":true,"status":200,"result":item});
            }
            match data["hasMore"].as_bool() {
                Some(false) => return json!({"ok":false,"status":404,"error":"Schedule not found"}),
                Some(true) => {}
                None => return error("invalid schedule pagination response"),
            }
            let Some(cursor) = data["nextCursor"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= MAX_RESPONSE_BYTES)
            else {
                return error("invalid pagination cursor");
            };
            if !seen.insert(cursor.to_owned()) {
                return error("invalid pagination cursor");
            }
            query["after"] = json!(cursor);
        }
        error("schedule lookup page limit reached; narrow the lookup with list_schedules")
    }

    async fn capabilities(&self) -> Value {
        let mut discovery = self
            .request("GET", "/api/v1/capabilities", &json!({}), false)
            .await;
        if let Some(value) = discovery.as_object_mut().and_then(|v| v.remove("result")) {
            discovery["data"] = value;
        }
        let mut result = json!({"ok":true,"plugin":{"name":"orialis-hermes","version":"0.2.0","implementation":"rust","operations":CONTRACT["operations"],"tools":CONTRACT["tool_names"],"domain_contracts":CONTRACT["domain_contracts"],"response_ui":CONTRACT["response_ui"]},"server":{"url":self.display_url,"discovery":discovery}});
        if result["server"]["discovery"]["ok"] == true {
            let data = result["server"]["discovery"]["data"].clone();
            result["server"]["capabilities"] =
                data.get("capabilities").cloned().unwrap_or(json!([]));
            result["server"]["api_version"] =
                data.get("api_version").cloned().unwrap_or(Value::Null);
            if let Some(ui) = data.get("response_ui") {
                result["server"]["response_ui"] = ui.clone();
            }
        }
        result
    }

    async fn publish_news(&self, args: Value) -> Value {
        let (path, payload) = match news_payload(args) {
            Ok(v) => v,
            Err(e) => return error(&e.to_string()),
        };
        self.request("POST", path, &payload, true).await
    }

    async fn request(&self, method: &str, path: &str, body: &Value, news: bool) -> Value {
        let auth = if news {
            &self.publisher_auth
        } else {
            &self.device_auth
        };
        let Some(auth) = auth else {
            // Capabilities discovery is intentionally public; no token is substituted.
            if path != "/api/v1/capabilities" {
                return error(if news {
                    "ORIALIS_NEWS_PUBLISHER_TOKEN is required to publish news"
                } else {
                    "ORIALIS_DEVICE_TOKEN is required"
                });
            }
            return self.send(method, path, body, None, news).await;
        };
        self.send(method, path, body, Some(auth.clone()), news)
            .await
    }

    async fn send(
        &self,
        method: &str,
        path: &str,
        body: &Value,
        auth: Option<HeaderValue>,
        news: bool,
    ) -> Value {
        // `path` is constructed exclusively from the route table and percent-encoded IDs.
        if !path.starts_with("/api/v1/")
            || path.contains('?')
            || path.contains('#')
            || path.contains('\\')
        {
            return error("invalid Orialis API route");
        }
        let mut url = self.origin.clone();
        url.set_path(path);
        if method == "GET" {
            for (key, value) in body.as_object().into_iter().flatten() {
                if value.is_null() {
                    continue;
                }
                let value = value
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| value.to_string());
                url.query_pairs_mut().append_pair(key, &value);
            }
        }
        if url.origin() != self.origin.origin() {
            return error("Orialis origin mismatch");
        }
        let method_value = match Method::from_bytes(method.as_bytes()) {
            Ok(v) => v,
            Err(_) => return error("invalid HTTP method"),
        };
        let mut request = self
            .http
            .request(method_value, url)
            .header("Accept", "application/json");
        if let Some(auth) = auth {
            request = request.header("Authorization", auth);
        }
        if !news {
            request = request.header("X-Orialis-Device-Id", self.device_id.clone());
        }
        if method != "GET" {
            request = request.json(body);
        }
        let mutation = method != "GET";
        let mut response = match request.send().await {
            Ok(v) => v,
            Err(_) => {
                return outcome_error(
                    "Orialis server request failed; the server could not be reached",
                    None,
                    mutation,
                );
            }
        };
        let status = response.status().as_u16();
        // Do not follow redirects or reflect server errors (which could contain credentials/HTML).
        if !(200..300).contains(&status) {
            return outcome_error(
                &format!("server returned HTTP {status}"),
                Some(status),
                mutation && status >= 500,
            );
        }
        if response
            .content_length()
            .is_some_and(|len| len > MAX_RESPONSE_BYTES as u64)
        {
            return outcome_error("server response is too large", Some(status), mutation);
        }
        let mut bytes = Vec::new();
        loop {
            match response.chunk().await {
                Ok(Some(chunk))
                    if bytes.len().saturating_add(chunk.len()) <= MAX_RESPONSE_BYTES =>
                {
                    bytes.extend_from_slice(&chunk)
                }
                Ok(Some(_)) => {
                    return outcome_error("server response is too large", Some(status), mutation);
                }
                Ok(None) => break,
                Err(_) => {
                    return outcome_error(
                        "Orialis response could not be read",
                        Some(status),
                        mutation,
                    );
                }
            }
        }
        if status == 204 || bytes.is_empty() {
            return json!({"ok":true,"status":status});
        }
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(data) => json!({"ok":true,"status":status,"result":data}),
            Err(_) => outcome_error("server returned invalid JSON", Some(status), mutation),
        }
    }
}
fn bearer(token: &str) -> Result<Option<HeaderValue>> {
    let token = token.trim();
    if token.is_empty() {
        return Ok(None);
    }
    ensure!(
        !token.chars().any(char::is_whitespace),
        "bearer token must not contain whitespace"
    );
    let mut value = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| anyhow::anyhow!("invalid bearer token"))?;
    value.set_sensitive(true);
    Ok(Some(value))
}
fn error(message: &str) -> Value {
    json!({"ok":false,"error":message})
}
fn outcome_error(message: &str, status: Option<u16>, unknown: bool) -> Value {
    let mut result = json!({"ok":false,"error":message,"outcomeUnknown":unknown});
    if let Some(status) = status {
        result["status"] = json!(status);
    }
    result
}

struct Prepared {
    route: Route,
    path: String,
    body: Value,
    submitted: Value,
}
fn prepare(name: &str, mut args: Value, batch: bool) -> Result<Prepared> {
    let route = route(name).context("unknown route")?;
    validate_domain(route.kind, route.method, &args)?;
    if route.method == "POST"
        && (batch || name == "create_schedule")
        && route.kind != "milestone"
        && args.get("id").is_none()
    {
        args["id"] = json!(Uuid::new_v4().to_string());
    }
    if name == "create_schedule" {
        args["title"] = json!(args["title"].as_str().unwrap().trim());
    }
    let submitted = args.clone();
    let mut path = route.path.to_owned();
    for field in ["id", "projectId", "conversationId"] {
        let key = format!("{{{field}}}");
        if path.contains(&key) {
            let id = args[field]
                .as_str()
                .context("resource identifier is required")?;
            identifier(id, field)?;
            path = path.replace(&key, &utf8_percent_encode(id, PATH_SEGMENT).to_string());
            args.as_object_mut().unwrap().remove(field);
        }
    }
    Ok(Prepared {
        route,
        path,
        body: args,
        submitted,
    })
}

fn validate_schema(value: &Value, spec: &Value, field: &str) -> Result<()> {
    let type_matches = |kind: &str| match kind {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "integer" => value.as_i64().is_some(),
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        _ => false,
    };
    let matches = match &spec["type"] {
        Value::String(kind) => type_matches(kind),
        Value::Array(kinds) => kinds.iter().filter_map(Value::as_str).any(type_matches),
        _ => true,
    };
    ensure!(matches, "{field} has an invalid type");
    if let Some(choices) = spec["enum"].as_array() {
        ensure!(choices.contains(value), "{field} has an unsupported value");
    }
    if let Some(text) = value.as_str() {
        let length = text.trim().chars().count();
        if let Some(min) = spec["minLength"].as_u64() {
            ensure!(length >= min as usize, "{field} must not be empty");
        }
        if let Some(max) = spec["maxLength"].as_u64() {
            ensure!(text.chars().count() <= max as usize, "{field} is too long");
        }
    }
    if let Some(number) = value.as_i64() {
        if let Some(min) = spec["minimum"].as_i64() {
            ensure!(number >= min, "{field} must be at least {min}");
        }
        if let Some(max) = spec["maximum"].as_i64() {
            ensure!(number <= max, "{field} must be at most {max}");
        }
    }
    if let Some(object) = value.as_object() {
        let properties = spec["properties"].as_object();
        if let Some(required) = spec["required"].as_array() {
            for key in required.iter().filter_map(Value::as_str) {
                ensure!(object.contains_key(key), "{key} is required");
            }
        }
        for (key, child) in object {
            if let Some(child_spec) = properties.and_then(|p| p.get(key)) {
                validate_schema(child, child_spec, key)?;
            } else {
                ensure!(
                    spec["additionalProperties"] != false,
                    "arguments contain unsupported field {key}"
                );
            }
        }
    }
    if let Some(array) = value.as_array() {
        if let Some(min) = spec["minItems"].as_u64() {
            ensure!(array.len() >= min as usize, "{field} has too few items");
        }
        if let Some(max) = spec["maxItems"].as_u64() {
            ensure!(array.len() <= max as usize, "{field} has too many items");
        }
        if let Some(item_spec) = spec.get("items") {
            for child in array {
                validate_schema(child, item_spec, field)?;
            }
        }
    }
    Ok(())
}
fn identifier(value: &str, field: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.trim() == value
            && value.chars().count() <= 128
            && !value.chars().any(char::is_control)
            && !matches!(value, "." | ".."),
        "{field} must be a non-empty opaque identifier of at most 128 characters (not a dot segment)"
    );
    Ok(())
}
fn date(value: &str, field: &str) -> Result<NaiveDate> {
    ensure!(
        value.len() == 10 && value.is_ascii(),
        "{field} must be YYYY-MM-DD"
    );
    let parsed = NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .with_context(|| format!("{field} must be YYYY-MM-DD"))?;
    ensure!(
        parsed.format("%Y-%m-%d").to_string() == value,
        "{field} must be YYYY-MM-DD"
    );
    Ok(parsed)
}
/// Preserve fractional digits beyond chrono's nanosecond resolution for exact comparisons.
fn instant(value: &str, field: &str) -> Result<(i64, bool, String)> {
    ensure!(
        value.is_ascii(),
        "{field} must be an RFC 3339 timestamp with timezone"
    );
    let parsed = DateTime::parse_from_rfc3339(value)
        .with_context(|| format!("{field} must be an RFC 3339 timestamp with timezone"))?;
    let timezone_len = if matches!(value.as_bytes().last(), Some(b'Z' | b'z')) {
        1
    } else {
        6
    };
    let fraction = if value.as_bytes().get(19) == Some(&b'.') {
        value[20..value.len() - timezone_len].trim_end_matches('0')
    } else {
        ""
    };
    Ok((
        parsed.timestamp(),
        &value[17..19] == "60",
        fraction.to_owned(),
    ))
}
fn validate_domain(kind: &str, method: &str, args: &Value) -> Result<()> {
    for field in [
        "id",
        "projectId",
        "parentTaskId",
        "scheduleId",
        "conversationId",
        "replyToMessageId",
        "nextActionTaskId",
    ] {
        if let Some(value) = args.get(field).filter(|v| !v.is_null()) {
            identifier(
                value
                    .as_str()
                    .with_context(|| format!("{field} must be a string"))?,
                field,
            )?;
        }
    }
    for field in ["title", "name"] {
        if let Some(value) = args.get(field) {
            ensure!(
                value.as_str().is_some_and(|v| !v.trim().is_empty()),
                "{field} must be a non-empty string"
            );
        }
    }
    for field in ["due", "startDate"] {
        if let Some(value) = args.get(field).and_then(Value::as_str) {
            date(value, field)?;
        }
    }
    for field in ["startAt", "endAt", "completedAt", "from", "to"] {
        if let Some(value) = args.get(field).and_then(Value::as_str) {
            instant(value, field)?;
        }
    }
    for (start, end, strict) in [("startAt", "endAt", true), ("from", "to", false)] {
        if let (Some(a), Some(b)) = (args[start].as_str(), args[end].as_str()) {
            let (a, b) = (instant(a, start)?, instant(b, end)?);
            ensure!(
                if strict { a < b } else { a <= b },
                "{start} must be earlier than {end}"
            );
        }
    }
    if method == "GET" || method == "DELETE" {
        if kind == "project" {
            validate_status(args)?;
        }
        return Ok(());
    }
    if kind == "task" {
        if let Some(value) = args["dueTime"].as_str() {
            let b = value.as_bytes();
            ensure!(
                b.len() == 5
                    && b[2] == b':'
                    && b[0..2].iter().chain(&b[3..5]).all(u8::is_ascii_digit)
                    && value[0..2].parse::<u8>()? < 24
                    && value[3..5].parse::<u8>()? < 60,
                "dueTime must be HH:MM"
            );
            ensure!(
                !(method == "POST" && args["due"].is_null())
                    && args.get("due") != Some(&Value::Null),
                "dueTime requires due"
            );
        }
        if !args["completedAt"].is_null() {
            ensure!(
                args["completed"] != false && (method != "POST" || args["completed"] == true),
                "completedAt requires completed=true"
            );
        }
        if !args["parentTaskId"].is_null() {
            ensure!(
                args["parentTaskId"] != args["id"],
                "a task cannot parent itself"
            );
        }
        if !args["parentTaskId"].is_null() && !args["scheduleId"].is_null() {
            bail!("a task cannot have both parentTaskId and scheduleId");
        }
        if let Some(recurrence) = args.get("recurrence").filter(|v| !v.is_null()) {
            let Some(rec) = recurrence.as_object() else {
                bail!("recurrence must be an object");
            };
            ensure!(
                rec.keys().all(|k| matches!(k.as_str(), "rule" | "until")),
                "recurrence contains unsupported fields"
            );
            let rule = recurrence["rule"]
                .as_str()
                .context("recurrence.rule is required")?;
            ensure!(
                !rule.is_empty() && !rule.chars().any(char::is_whitespace),
                "recurrence.rule must be an RFC 5545 RRULE"
            );
            let mut frequency = false;
            for component in rule.split(';') {
                let (key, value) = component
                    .split_once('=')
                    .filter(|(_, v)| !v.is_empty())
                    .context("recurrence.rule must be an RFC 5545 RRULE")?;
                if key.eq_ignore_ascii_case("FREQ") {
                    frequency = true;
                    ensure!(
                        matches!(
                            value.to_ascii_uppercase().as_str(),
                            "SECONDLY"
                                | "MINUTELY"
                                | "HOURLY"
                                | "DAILY"
                                | "WEEKLY"
                                | "MONTHLY"
                                | "YEARLY"
                        ),
                        "invalid recurrence FREQ"
                    );
                }
            }
            ensure!(frequency, "recurrence.rule must include FREQ");
            date(
                recurrence["until"]
                    .as_str()
                    .context("recurrence.until is required")?,
                "recurrence.until",
            )?;
        }
    }
    if kind == "project" {
        validate_status(args)?;
        ensure!(
            method != "POST" || args["nextActionTaskId"].is_null(),
            "nextActionTaskId must be null when creating a project"
        );
    }
    if kind == "conversation" && !args["manualPosition"].is_null() {
        ensure!(
            args["pinned"] != false && (method != "POST" || args["pinned"] == true),
            "only pinned conversations can have manualPosition"
        );
    }
    if kind == "message" {
        ensure!(
            args["content"]
                .as_str()
                .is_some_and(|s| !s.trim().is_empty())
                || args["attachments"]
                    .as_array()
                    .is_some_and(|a| !a.is_empty()),
            "content is required unless attachments are present"
        );
        if let Some(attachments) = args["attachments"].as_array() {
            for a in attachments {
                identifier(
                    a["id"].as_str().context("attachment id is required")?,
                    "attachment id",
                )?;
            }
        }
    }
    if kind == "schedule"
        && let Some(description) = args["description"].as_str()
    {
        ensure!(
            AGENDA.find_iter(description).take(2).count() < 2,
            "split_required: description contains multiple date/time agenda entries. Create one event per activity and time slot, each with its own title, startAt/endAt and location; keep only that event's details in description. Ask for missing times; do not invent them."
        );
    }
    Ok(())
}
fn validate_status(args: &Value) -> Result<()> {
    if let Some(status) = args["status"].as_str() {
        ensure!(
            matches!(status, "active" | "completed" | "archived"),
            "status must be active, completed, or archived"
        );
    }
    Ok(())
}

fn news_payload(args: Value) -> Result<(&'static str, Value)> {
    let dataset = args["dataset"].as_str().context("dataset is required")?;
    let (path, source) = match dataset {
        "aihot.hot" => ("/api/v1/news/publish/aihot/hot", "aihot.news"),
        "aihot.items" => ("/api/v1/news/publish/aihot/items", "aihot.news"),
        "aihot.events" => ("/api/v1/news/publish/aihot/events", "aihot.news"),
        "aihot.reports.daily" => ("/api/v1/news/publish/aihot/reports/daily", "aihot.news"),
        "aihot.reports.weekly" => ("/api/v1/news/publish/aihot/reports/weekly", "aihot.news"),
        "aihot.reports.monthly" => ("/api/v1/news/publish/aihot/reports/monthly", "aihot.news"),
        "github.daily" => ("/api/v1/news/publish/github/daily", "githot.dev"),
        "github.weekly" => ("/api/v1/news/publish/github/weekly", "githot.dev"),
        "projects.daily" | "projects.weekly" => (
            "/api/v1/news/projects/publish",
            "orialis-project-report/hermes",
        ),
        _ => bail!("unsupported news.publish dataset"),
    };
    let result = &args["result"];
    ensure!(
        result.is_array() || result.is_object(),
        "result must be a JSON object or array"
    );
    ensure!(
        canonical_json(result)?.len() <= MAX_NEWS_RESULT_BYTES,
        "result must be no larger than 1 MiB"
    );
    if matches!(dataset, "aihot.hot" | "aihot.items") {
        ensure!(
            result.is_array(),
            "this AIHOT dataset requires result to be an array"
        );
    } else if !dataset.starts_with("github.") {
        ensure!(
            result.is_object(),
            "this dataset requires result to be an object"
        );
    }
    if dataset == "aihot.events" {
        ensure!(
            result
                .get("publicId")
                .or_else(|| result.get("id"))
                .and_then(Value::as_str)
                .is_some_and(|s| !s.trim().is_empty()),
            "AIHOT events require result.publicId or result.id"
        );
    }
    if dataset.starts_with("github.") {
        ensure!(
            result.is_array()
                || result
                    .get("repositories")
                    .or_else(|| result.get("items"))
                    .is_some_and(Value::is_array),
            "GitHub result must be an array or contain a repositories array"
        );
    }
    if dataset.starts_with("projects.") {
        if let Some(project) = args["projectId"].as_str() {
            identifier(project, "projectId")?;
        }
        if let Some(report_date) = args["reportDate"].as_str() {
            if dataset == "projects.weekly" {
                let (year, week) = report_date
                    .split_once("-W")
                    .context("reportDate must be YYYY-Www")?;
                ensure!(
                    year.len() == 4
                        && week.len() == 2
                        && year.bytes().chain(week.bytes()).all(|c| c.is_ascii_digit()),
                    "reportDate must be YYYY-Www"
                );
                ensure!(
                    NaiveDate::from_isoywd_opt(year.parse()?, week.parse()?, Weekday::Mon)
                        .is_some(),
                    "reportDate must be a valid ISO week"
                );
            } else {
                date(report_date, "reportDate")?;
            }
        }
    } else {
        ensure!(
            args.get("projectId").is_none() && args.get("reportDate").is_none(),
            "projectId and reportDate are only supported for project reports"
        );
    }
    if let Some(value) = args.get("generatedAt") {
        instant(
            value.as_str().context("generatedAt must be a timestamp")?,
            "generatedAt",
        )?;
    }
    let mut payload = json!({"source":source,"result":result});
    if dataset.starts_with("projects.") {
        payload["period"] = json!(dataset.rsplit('.').next().unwrap());
    }
    for key in ["projectId", "reportDate", "generatedAt"] {
        if let Some(value) = args.get(key) {
            payload[key] = value.clone();
        }
    }
    // serde_json maps are ordered lexically without preserve_order, matching Python sort_keys.
    // Python's float serialization differs from Rust; canonical_json handles that difference.
    let stable = canonical_json(&json!([dataset, payload]))?;
    let digest = format!("{:x}", Sha256::digest(stable.as_bytes()));
    let key = format!("hermes-news-{digest}");
    payload["taskId"] = json!(key);
    payload["idempotencyKey"] = payload["taskId"].clone();
    Ok((path, payload))
}

// Python json.dumps(ensure_ascii=False, sort_keys=True, separators=(",",":")) compatible
// JSON encoding, including exponent zero-padding and retaining integral floating point .0.
fn canonical_json(value: &Value) -> Result<String> {
    fn write(value: &Value, out: &mut String) -> Result<()> {
        match value {
            Value::Array(values) => {
                out.push('[');
                for (i, v) in values.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write(v, out)?;
                }
                out.push(']');
            }
            Value::Object(values) => {
                let mut keys: Vec<_> = values.keys().collect();
                keys.sort();
                out.push('{');
                for (i, k) in keys.into_iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&serde_json::to_string(k)?);
                    out.push(':');
                    write(&values[k], out)?;
                }
                out.push('}');
            }
            Value::Number(number) if number.to_string().contains(['.', 'e', 'E']) => {
                let n = number
                    .as_f64()
                    .context("result must contain finite JSON numbers")?;
                let rust = serde_json::Number::from_f64(n)
                    .context("result must contain finite JSON numbers")?
                    .to_string();
                // CPython switches to scientific notation at exponents <-4 or >=16.
                let scientific = n != 0.0 && (n.abs() < 0.0001 || n.abs() >= 1e16);
                if scientific {
                    let s = if rust.contains('e') {
                        rust
                    } else {
                        format!("{n:e}")
                    };
                    let (mantissa, exponent) = s.split_once('e').context("invalid exponent")?;
                    let exp: i32 = exponent.parse()?;
                    out.push_str(mantissa.strip_suffix(".0").unwrap_or(mantissa));
                    out.push('e');
                    out.push(if exp < 0 { '-' } else { '+' });
                    out.push_str(&format!("{:02}", exp.unsigned_abs()));
                } else if rust.contains('e') {
                    // Display expands decimal exponents and is shortest round-trip.
                    let plain = n.to_string();
                    out.push_str(&plain);
                    if !plain.contains('.') {
                        out.push_str(".0");
                    }
                } else {
                    out.push_str(&rust);
                }
            }
            Value::Number(number) if number.to_string() == "-0" => out.push('0'),
            _ => out.push_str(&serde_json::to_string(value)?),
        }
        Ok(())
    }
    let mut output = String::new();
    write(value, &mut output)?;
    Ok(output)
}

#[cfg(test)]
#[path = "domain_tools/tests.rs"]
mod tests;
