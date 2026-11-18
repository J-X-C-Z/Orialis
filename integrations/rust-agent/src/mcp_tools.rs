//! Trusted MCP client bridge.
//!
//! The host may configure remote (streamable HTTP) or local (stdio) MCP
//! servers. Only `tools/list` results become model-callable tools; resources,
//! prompts and sampling remain out of scope. Configuration is trusted host
//! input, never model output, and credentials are never logged.
use anyhow::{Context, Result, bail, ensure};
use futures_util::future::BoxFuture;
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

use crate::tool_runtime::{ToolExecutor, TurnContext};

const PROTOCOL_VERSION: &str = "2025-06-18";
const MAX_TOOLS_PER_SERVER: usize = 128;
const MAX_TOOL_LIST_PAGES: usize = 16;
const MAX_SCHEMA_BYTES: usize = 256 * 1024;
const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_CALL_TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpConfig {
    #[serde(default)]
    pub mcp_servers: BTreeMap<String, McpServerConfig>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct McpServerConfig {
    pub url: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub headers: BTreeMap<String, String>,
    pub enabled: bool,
    pub required: bool,
    pub connect_timeout: Option<f64>,
    pub timeout: Option<f64>,
    pub tools: McpToolFilter,
}

impl Default for McpServerConfig {
    fn default() -> Self {
        Self {
            url: None,
            command: None,
            args: Vec::new(),
            env: BTreeMap::new(),
            headers: BTreeMap::new(),
            enabled: true,
            required: false,
            connect_timeout: None,
            timeout: None,
            tools: McpToolFilter::default(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct McpToolFilter {
    pub include: Vec<String>,
    pub exclude: Vec<String>,
}

impl McpToolFilter {
    fn permits(&self, name: &str) -> bool {
        (self.include.is_empty() || self.include.iter().any(|item| item == name))
            && !self.exclude.iter().any(|item| item == name)
    }
}

pub struct McpTools {
    servers: Vec<Server>,
    tools: Vec<Registered>,
}

struct Server {
    name: String,
    wire: Wire,
    timeout: Duration,
}

struct Registered {
    model_name: String,
    remote_name: String,
    server: usize,
    schema: Value,
}

enum Wire {
    Http(HttpWire),
    Stdio(StdioWire),
}

struct HttpWire {
    client: reqwest::Client,
    url: reqwest::Url,
    headers: BTreeMap<String, String>,
    session: Mutex<Option<String>>,
    next_id: AtomicU64,
    timeout: Duration,
}

struct StdioWire {
    state: Mutex<StdioState>,
    timeout: Duration,
}

struct StdioState {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl McpTools {
    /// Connect every enabled server and discover its tools. A server marked
    /// `required` aborts startup on failure; otherwise it is skipped so a
    /// memory or messaging sidecar cannot take the chat path down.
    pub async fn connect(raw: &str) -> Result<Self> {
        ensure!(
            raw.len() <= 64 * 1024,
            "MCP server configuration exceeds limit"
        );
        let config: McpConfig =
            serde_json::from_str(raw).context("invalid trusted MCP server configuration")?;
        let mut servers = Vec::new();
        let mut tools = Vec::new();
        for (name, entry) in config.mcp_servers {
            if !entry.enabled {
                continue;
            }
            ensure!(
                !name.is_empty() && name.len() <= 32,
                "invalid MCP server name"
            );
            let connect_timeout = seconds(entry.connect_timeout, 30.0, 1.0, 120.0)?;
            let call_timeout = seconds(
                entry.timeout,
                DEFAULT_CALL_TIMEOUT.as_secs_f64(),
                1.0,
                MAX_CALL_TIMEOUT.as_secs_f64(),
            )?;
            let wire = match open_wire(&name, &entry, connect_timeout).await {
                Ok(wire) => wire,
                Err(error) if !entry.required => {
                    #[cfg(unix)]
                    eprintln!("mcp server {name} unavailable: {error:#}");
                    continue;
                }
                Err(error) => {
                    return Err(error).with_context(|| format!("MCP server {name} unavailable"));
                }
            };
            let discovered = match discover(&name, &wire, call_timeout).await {
                Ok(discovered) => discovered,
                Err(error) if !entry.required => {
                    #[cfg(unix)]
                    eprintln!("mcp server {name} tool discovery failed: {error:#}");
                    continue;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("MCP server {name} tool discovery failed"));
                }
            };
            let index = servers.len();
            servers.push(Server {
                name: name.clone(),
                wire,
                timeout: call_timeout,
            });
            for tool in discovered {
                let Some(remote_name) = tool["name"].as_str() else {
                    continue;
                };
                if remote_name.is_empty() || !entry.tools.permits(remote_name) {
                    continue;
                }
                if tools
                    .iter()
                    .any(|existing: &Registered| existing.remote_name == remote_name
                        && existing.server == index)
                {
                    continue;
                }
                let schema = tool_schema(&name, &tool)?;
                tools.push(Registered {
                    model_name: model_name(&name, remote_name),
                    remote_name: remote_name.to_owned(),
                    server: index,
                    schema,
                });
                if tools.len() >= MAX_TOOLS_PER_SERVER * 8 {
                    bail!("MCP tool catalog exceeds limit");
                }
            }
        }
        Ok(Self { servers, tools })
    }

    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }
}

impl ToolExecutor for McpTools {
    fn schemas(&self) -> Vec<Value> {
        self.tools.iter().map(|tool| tool.schema.clone()).collect()
    }

    fn execute<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        _context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let registered = self
                .tools
                .iter()
                .find(|tool| tool.model_name == name)
                .context("unknown or disabled MCP tool")?;
            ensure!(arguments.is_object(), "MCP tool arguments must be an object");
            let server = &self.servers[registered.server];
            let result = tokio::time::timeout(
                server.timeout,
                server.wire.call(
                    "tools/call",
                    json!({"name": registered.remote_name, "arguments": arguments}),
                ),
            )
            .await
            .with_context(|| format!("MCP server {} timed out", server.name))??;
            map_result(result)
        })
    }
}

async fn open_wire(name: &str, entry: &McpServerConfig, timeout: Duration) -> Result<Wire> {
    match (&entry.url, &entry.command) {
        (Some(url), None) => {
            let url = validate_url(url)?;
            let client = reqwest::Client::builder()
                .connect_timeout(timeout)
                .build()?;
            Ok(Wire::Http(HttpWire {
                client,
                url,
                headers: entry.headers.clone(),
                session: Mutex::new(None),
                next_id: AtomicU64::new(1),
                timeout,
            }))
        }
        (None, Some(command)) => {
            let mut cmd = Command::new(command);
            cmd.args(&entry.args)
                .envs(&entry.env)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .kill_on_drop(true);
            let mut child = cmd
                .spawn()
                .with_context(|| format!("could not start MCP server {name}"))?;
            let stdin = child.stdin.take().context("MCP server stdin unavailable")?;
            let stdout = child.stdout.take().context("MCP server stdout unavailable")?;
            if let Some(stderr) = child.stderr.take() {
                tokio::spawn(async move {
                    let mut lines = BufReader::new(stderr).lines();
                    while let Ok(Some(_)) = lines.next_line().await {}
                });
            }
            Ok(Wire::Stdio(StdioWire {
                state: Mutex::new(StdioState {
                    child,
                    stdin,
                    stdout: BufReader::new(stdout),
                    next_id: 1,
                }),
                timeout,
            }))
        }
        (Some(_), Some(_)) => bail!("MCP server must set exactly one of url or command"),
        (None, None) => bail!("MCP server requires url or command"),
    }
}

fn validate_url(raw: &str) -> Result<reqwest::Url> {
    let url = reqwest::Url::parse(raw).context("invalid MCP server URL")?;
    ensure!(
        url.username().is_empty() && url.password().is_none() && url.fragment().is_none(),
        "MCP server URL must not contain credentials or a fragment"
    );
    let host = url.host_str().context("MCP server URL needs a host")?;
    let loopback = host == "localhost"
        || host == "::1"
        || host
            .parse::<std::net::IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false);
    ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && loopback),
        "MCP server URL requires HTTPS except for loopback"
    );
    Ok(url)
}

async fn discover(name: &str, wire: &Wire, timeout: Duration) -> Result<Vec<Value>> {
    let init = tokio::time::timeout(
        timeout,
        wire.call(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "hermes-rust-core", "version": env!("CARGO_PKG_VERSION")}
            }),
        ),
    )
    .await
    .with_context(|| format!("MCP server {name} initialize timed out"))??;
    ensure!(
        init.get("capabilities").is_some(),
        "MCP server {name} returned an invalid initialize result"
    );
    wire.notify("notifications/initialized", json!({})).await?;
    let mut tools = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..MAX_TOOL_LIST_PAGES {
        let params = match &cursor {
            Some(cursor) => json!({"cursor": cursor}),
            None => json!({}),
        };
        let page = tokio::time::timeout(timeout, wire.call("tools/list", params))
            .await
            .with_context(|| format!("MCP server {name} tools/list timed out"))??;
        let list = page
            .get("tools")
            .and_then(Value::as_array)
            .with_context(|| format!("MCP server {name} returned an invalid tools/list result"))?;
        tools.extend(list.iter().cloned());
        cursor = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if cursor.is_none() {
            break;
        }
    }
    ensure!(
        tools.len() <= MAX_TOOLS_PER_SERVER,
        "MCP server {name} exposes too many tools"
    );
    Ok(tools)
}

impl Wire {
    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        match self {
            Wire::Http(inner) => inner.call(method, params).await,
            Wire::Stdio(inner) => inner.call(method, params).await,
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        match self {
            Wire::Http(inner) => inner.notify(method, params).await,
            Wire::Stdio(inner) => inner.notify(method, params).await,
        }
    }
}

impl HttpWire {
    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let body = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let mut request = self
            .client
            .post(self.url.clone())
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", PROTOCOL_VERSION)
            .json(&body);
        if let Some(session) = self.session.lock().await.clone() {
            request = request.header("mcp-session-id", session);
        }
        for (key, value) in &self.headers {
            request = request.header(key, value);
        }
        let response = tokio::time::timeout(self.timeout, request.send())
            .await
            .context("MCP HTTP request timed out")??;
        if let Some(session) = response.headers().get("mcp-session-id") {
            let session = session
                .to_str()
                .context("invalid MCP session header")?
                .to_owned();
            *self.session.lock().await = Some(session);
        }
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            bail!(
                "MCP HTTP {}: {}",
                status.as_u16(),
                truncate(&body, 2_000)
            );
        }
        let event_stream = response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .map(|value| value.contains("text/event-stream"))
            .unwrap_or(false);
        let body = if event_stream {
            read_event_stream(response, id, self.timeout).await?
        } else {
            response.text().await.context("MCP response body failed")?
        };
        response_value(&body, id)
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let body = json!({"jsonrpc": "2.0", "method": method, "params": params});
        let mut request = self
            .client
            .post(self.url.clone())
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", PROTOCOL_VERSION)
            .json(&body);
        if let Some(session) = self.session.lock().await.clone() {
            request = request.header("mcp-session-id", session);
        }
        for (key, value) in &self.headers {
            request = request.header(key, value);
        }
        let response = tokio::time::timeout(self.timeout, request.send())
            .await
            .context("MCP notification timed out")??;
        ensure!(
            response.status().is_success(),
            "MCP notification rejected with {}",
            response.status().as_u16()
        );
        Ok(())
    }
}

impl StdioWire {
    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        let mut state = self.state.lock().await;
        let id = state.next_id;
        state.next_id = state.next_id.wrapping_add(1).max(1);
        let line = serde_json::to_string(
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
        )?;
        state
            .stdin
            .write_all(format!("{line}\n").as_bytes())
            .await
            .context("MCP server stdin write failed")?;
        state
            .stdin
            .flush()
            .await
            .context("MCP server stdin flush failed")?;
        let mut skipped = 0;
        loop {
            let mut line = String::new();
            let read = tokio::time::timeout(self.timeout, state.stdout.read_line(&mut line))
                .await
                .context("MCP server response timed out")??;
            ensure!(read > 0, "MCP server closed before responding");
            let text = line.trim();
            if text.is_empty() {
                continue;
            }
            let Ok(value) = serde_json::from_str::<Value>(text) else {
                skipped += 1;
                ensure!(skipped <= 64, "MCP server stdout is not JSON-RPC");
                continue;
            };
            if value.get("id") != Some(&json!(id)) {
                continue;
            }
            if let Some(error) = value.get("error") {
                bail!("MCP error: {}", truncate(&error.to_string(), 1_000));
            }
            return value
                .get("result")
                .cloned()
                .context("MCP response is missing result");
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let mut state = self.state.lock().await;
        let line = serde_json::to_string(&json!({
            "jsonrpc": "2.0", "method": method, "params": params
        }))?;
        state
            .stdin
            .write_all(format!("{line}\n").as_bytes())
            .await
            .context("MCP server stdin write failed")?;
        state
            .stdin
            .flush()
            .await
            .context("MCP server stdin flush failed")?;
        Ok(())
    }
}

impl Drop for StdioState {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

async fn read_event_stream(
    response: reqwest::Response,
    id: u64,
    timeout: Duration,
) -> Result<String> {
    let deadline = tokio::time::Instant::now() + timeout;
    let mut stream = response.bytes_stream();
    let mut buffer = Vec::new();
    loop {
        while let Some(block) = next_event(&mut buffer) {
            for data in event_data(&block) {
                if let Ok(value) = serde_json::from_str::<Value>(&data)
                    && value.get("id") == Some(&json!(id))
                {
                    return Ok(data);
                }
            }
        }
        let chunk = tokio::time::timeout_at(deadline, stream.next())
            .await
            .context("MCP event stream timed out")?;
        match chunk {
            Some(Ok(chunk)) => buffer.extend_from_slice(&chunk),
            Some(Err(error)) => return Err(error).context("MCP event stream failed"),
            None => {
                if let Some(block) = next_event(&mut buffer) {
                    for data in event_data(&block) {
                        if let Ok(value) = serde_json::from_str::<Value>(&data)
                            && value.get("id") == Some(&json!(id))
                        {
                            return Ok(data);
                        }
                    }
                }
                bail!("MCP event stream closed before the response arrived");
            }
        }
        ensure!(buffer.len() <= 4 * 1024 * 1024, "MCP response exceeds limit");
    }
}

fn next_event(buffer: &mut Vec<u8>) -> Option<String> {
    let lf = buffer.windows(2).position(|pair| pair == &b"\n\n"[..]);
    let crlf = buffer
        .windows(4)
        .position(|pair| pair == &b"\r\n\r\n"[..]);
    let (end, skip) = match (lf, crlf) {
        (Some(lf), Some(crlf)) if crlf < lf => (crlf, 4),
        (Some(lf), _) => (lf, 2),
        (None, Some(crlf)) => (crlf, 4),
        (None, None) => return None,
    };
    let block = String::from_utf8_lossy(&buffer[..end]).into_owned();
    buffer.drain(..end + skip);
    Some(block)
}

fn event_data(block: &str) -> Vec<String> {
    let mut data = Vec::new();
    for line in block.lines() {
        if let Some(rest) = line.strip_prefix("data:") {
            data.push(rest.strip_prefix(' ').unwrap_or(rest).to_owned());
        }
    }
    if data.is_empty() {
        Vec::new()
    } else {
        vec![data.join("\n")]
    }
}

fn response_value(body: &str, id: u64) -> Result<Value> {
    let value: Value = serde_json::from_str(body).context("invalid MCP JSON response")?;
    if let Some(error) = value.get("error") {
        bail!("MCP error: {}", truncate(&error.to_string(), 1_000));
    }
    ensure!(
        value.get("id") == Some(&json!(id)),
        "MCP response id mismatch"
    );
    value
        .get("result")
        .cloned()
        .context("MCP response is missing result")
}

fn tool_schema(server: &str, tool: &Value) -> Result<Value> {
    let name = tool["name"].as_str().context("MCP tool has no name")?;
    let description = tool["description"].as_str().unwrap_or("");
    let mut parameters = tool
        .get("inputSchema")
        .cloned()
        .unwrap_or_else(|| json!({"type": "object", "properties": {}}));
    if parameters.get("type").is_none() {
        parameters["type"] = json!("object");
    }
    ensure!(
        parameters["type"] == "object",
        "MCP tool parameters must be an object"
    );
    let schema = json!({
        "type": "function",
        "function": {
            "name": model_name(server, name),
            "description": truncate(&format!("[MCP {server}] {description}"), 2_000),
            "parameters": parameters
        }
    });
    ensure!(
        serde_json::to_vec(&schema)?.len() <= MAX_SCHEMA_BYTES,
        "MCP tool schema exceeds limit"
    );
    Ok(schema)
}

fn model_name(server: &str, tool: &str) -> String {
    let base = format!("mcp__{}__{}", sanitize(server), sanitize(tool));
    if base.len() <= 64 {
        return base;
    }
    let digest = format!("{:x}", Sha256::digest(tool.as_bytes()));
    let suffix = &digest[..8];
    format!("{}_{}", truncate(&base, 55), suffix)
}

fn sanitize(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('_');
    }
    out
}

fn map_result(result: Value) -> Result<Value> {
    let is_error = result
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if let Some(structured) = result.get("structuredContent") {
        if is_error {
            bail!("MCP tool error: {}", truncate(&structured.to_string(), 2_000));
        }
        return Ok(bound(structured.clone()));
    }
    let content = result.get("content").and_then(Value::as_array);
    let text = content
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    if is_error {
        bail!("MCP tool error: {}", truncate(&text, 2_000));
    }
    if let Some(items) = content
        && items.len() == 1
        && items[0].get("type").and_then(Value::as_str) == Some("text")
    {
        if let Ok(parsed) = serde_json::from_str::<Value>(&text) {
            return Ok(bound(parsed));
        }
        return Ok(Value::String(truncate(&text, 64 * 1024)));
    }
    Ok(bound(result))
}

fn bound(value: Value) -> Value {
    if serde_json::to_vec(&value)
        .map(|bytes| bytes.len() <= 512 * 1024)
        .unwrap_or(false)
    {
        value
    } else {
        Value::String(truncate(&value.to_string(), 64 * 1024))
    }
}

fn seconds(value: Option<f64>, default: f64, min: f64, max: f64) -> Result<Duration> {
    let seconds = value.unwrap_or(default);
    ensure!(
        seconds.is_finite() && (min..=max).contains(&seconds),
        "MCP timeout must be {min}..{max} seconds"
    );
    Ok(Duration::from_secs_f64(seconds))
}

fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_owned();
    }
    let mut end = limit;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}... [truncated]", &value[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hermes_style_config() {
        let config: McpConfig = serde_json::from_str(
            r#"{"mcp_servers":{
                "hindsight_shared":{"url":"http://127.0.0.1:8888/mcp/","tools":{"include":["retain","recall"]}},
                "local-message-hub":{"command":"ssh","args":["-T","windows-mcp"],"enabled":false}
            }}"#,
        )
        .unwrap();
        assert_eq!(config.mcp_servers.len(), 2);
        let hindsight = &config.mcp_servers["hindsight_shared"];
        assert!(hindsight.enabled);
        assert!(hindsight.tools.permits("recall"));
        assert!(!hindsight.tools.permits("reflect"));
        assert!(!config.mcp_servers["local-message-hub"].enabled);
    }

    #[test]
    fn names_are_stable_and_bounded() {
        assert_eq!(model_name("hindsight", "recall"), "mcp__hindsight__recall");
        let long = model_name("server", &"x".repeat(200));
        assert!(long.len() <= 64);
        assert!(long.starts_with("mcp__server__"));
    }

    #[test]
    fn parses_multiline_sse() {
        let mut buffer = b"event: message\ndata: {\"a\":1}\n\ndata: {\"b\":2}\n\n".to_vec();
        assert_eq!(next_event(&mut buffer).unwrap(), "event: message\ndata: {\"a\":1}");
        assert_eq!(event_data("event: message\ndata: {\"a\":1}"), vec!["{\"a\":1}"]);
        assert_eq!(next_event(&mut buffer).unwrap(), "data: {\"b\":2}");
        assert!(next_event(&mut buffer).is_none());
    }

    #[test]
    fn maps_structured_and_text_results() {
        let structured = json!({"structuredContent":{"ok":true},"content":[]});
        assert_eq!(map_result(structured).unwrap(), json!({"ok":true}));
        let text = json!({"content":[{"type":"text","text":"{\"id\":7}"}]});
        assert_eq!(map_result(text).unwrap(), json!({"id":7}));
        let error = json!({"isError":true,"content":[{"type":"text","text":"bad"}]});
        assert!(map_result(error).is_err());
    }
}
