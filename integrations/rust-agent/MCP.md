# MCP bridge

`orialis_agent --mcp-servers-json '<json>'` reuses trusted MCP servers without
the Python Hermes runtime. The JSON shape matches Hermes' `mcp_servers` map, so
an existing profile section can be copied with minimal edits.

Only `tools/list` is consumed. Resources, prompts, sampling, elicitation and
OAuth discovery are not implemented. Configuration is host input; model output
can never add, remove or repoint a server.

## Configuration

```json
{
  "mcp_servers": {
    "hindsight_shared": {
      "url": "http://127.0.0.1:8888/mcp/",
      "tools": {"include": ["retain", "recall", "reflect"]},
      "timeout": 120
    },
    "local-message-hub": {
      "command": "ssh",
      "args": ["-T", "windows-mcp",
               "C:\\Users\\Example\\.local\\bin\\local-message-hub-mcp.cmd"],
      "enabled": true,
      "required": false
    }
  }
}
```

Fields per server:

- `url` or `command` — exactly one. `url` is streamable HTTP; `command` is a
  long-lived stdio child process.
- `args`, `env` — stdio only. `env` is merged into the child environment.
- `headers` — HTTP only. Values are never logged.
- `enabled` — default `true`.
- `required` — default `false`. A missing or broken optional server is skipped
  with a stderr warning; a required server aborts startup.
- `connect_timeout` — seconds, default `30`, range `1..120`.
- `timeout` — per request, seconds, default `120`, range `1..600`.
- `tools.include` / `tools.exclude` — exact remote tool names. Empty include
  means every discovered tool.

HTTP requires HTTPS unless the host is loopback. URLs with credentials in
userinfo or a fragment are rejected. The session id returned by
`initialize` (`Mcp-Session-Id`) is reused for later requests.

## Tool names

Remote tool `recall` on server `hindsight_shared` is exposed to the model as:

```
mcp__hindsight_shared__recall
```

Non-alphanumeric characters become `_`. Names longer than 64 bytes are
truncated with an 8-hex digest suffix. Collisions with host tools are rejected
by the existing tool router.

Descriptions are prefixed with `[MCP <server>]`; input schemas come from the
server unchanged and must be JSON objects. The model never sees the transport
or credentials.

## Results

- `structuredContent` is returned as JSON.
- A single text item is parsed as JSON when possible, otherwise returned as a
  string.
- `isError: true` becomes a tool error, so the model can react.
- Oversized results are truncated with an explicit marker.

## Lifecycle

- HTTP: one `initialize`, one `notifications/initialized`, then paginated
  `tools/list` (bounded to 16 pages and 128 tools).
- stdio: the child is started once, kept for the process lifetime, serialized
  behind one mutex and killed on drop. Stdout lines that are not JSON-RPC are
  skipped with a bounded budget.
- Tool calls are bounded by `timeout`; cancellation drops the HTTP response or
  the stdio lock but cannot preempt an already-running remote side effect.

## Failure policy

Optional servers (`required: false`) are skipped at startup, so a memory or
messaging sidecar cannot take the chat path down. Their tools are absent rather
than failing at call time. Set `required: true` for a dependency that must
exist before serving traffic.

## Verification

The HTTP path is verified against Hindsight (`initialize`, `tools/list`,
`retain`, `recall`) and the stdio path against a local JSON-RPC fixture. A
successful `retain` only means Hindsight accepted the operation; its worker
indexes asynchronously, so an immediate `recall` may not see the new fact.
