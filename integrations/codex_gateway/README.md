# Orialis Codex CLI gateway

Text-only Agent Gateway v1 adapter for `JXCZ_AOZORA_Codex`. Python 3.11+ and
`websockets>=14,<17` are required; Codex must already be installed and logged in
under the dedicated `CODEX_HOME`. Do not copy sessions or project context from
another agent. Provider login and service supervision are deployment concerns.

Configure these values in a private service environment file, never in Git:

```sh
CODEX_HOME=/home/azureuser/.orialis-codex
ORIALIS_CODEX_CWD=/home/azureuser/orialis-workspace
ORIALIS_CODEX_BIN=/usr/bin/codex
ORIALIS_SERVER_URL=ws://127.0.0.1:18443/api/v1/agent/ws
ORIALIS_DEVICE_ID=JXCZ_AOZORA_Codex
ORIALIS_DEVICE_TOKEN=<server-agent-token>
# Optional: ORIALIS_CODEX_MODEL, ORIALIS_CODEX_TIMEOUT (seconds; default 180)
# ORIALIS_CODEX_DISABLED_MCP= (optional comma-separated existing managed server keys)
# ORIALIS_PLATFORM=macos (optional override: macos/linux/windows only)
# News publishing: configure the same dedicated publisher token on the server and
# this service; ORIALIS_NEWS_API_URL is optional and defaults from SERVER_URL.
ORIALIS_NEWS_PUBLISHER_TOKEN=<dedicated-news-publisher-token>
# Optional: ORIALIS_NEWS_API_URL=https://orialis.example
```

Install requirements into a dedicated virtual environment and run:

```sh
python -m pip install -r integrations/codex_gateway/requirements.txt
python integrations/codex_gateway/gateway.py
python -m unittest discover -s integrations/codex_gateway -p 'test_*.py'
```

Each conversation owns an explicit persisted CLI thread ID. Turns within that
conversation are serialized; different conversations may run concurrently.
The hello frame reports the host operating system (`Darwin` becomes `macos`);
`ORIALIS_PLATFORM` may override it with `macos`, `linux`, or `windows`.
The CLI always uses `--json`, read-only sandbox, approval `never`, and ignores
user config. Apps, hooks, plugins, remote plugins, skill search and skill MCP
installation are disabled; host skill discovery is skipped and project instructions
are disabled. Any managed MCP servers must be listed by their exact server keys
in `ORIALIS_CODEX_DISABLED_MCP`; its default is empty. List only existing server
keys: configuring an absent key creates an invalid MCP entry without a transport. Verify this
against the deployment's managed configuration before starting the service.
Only basic process/proxy environment variables reach Codex; the gateway bearer
token and other inherited provider secrets do not. The adapter never uses
`--last` or bypasses the sandbox.

SQLite records accepted request IDs before execution and caches each exact reply
before sending it. A duplicate request replays the cached reply. Gateway restart
during a running turn returns `EXECUTION_UNCERTAIN` and does not execute again;
the user can send a new message to continue the saved thread. Timeouts kill the
entire CLI process group and are cached as errors. CLI stderr and provider
credentials are never sent to clients.

The gateway advertises `messages` and `news.publish`. News publishing is a narrow
server-side adapter for GitHub daily and weekly briefs. When Codex returns one
JSON object with `type: "news.publish"`, the gateway posts it to the existing
authenticated News API and returns the server's publish receipt in the matching
`message.reply`. The publisher token stays in the gateway process and is removed
from the environment passed to Codex. Other JSON/text replies pass through as
ordinary messages.

The supported response shape is:

```json
{
  "type": "news.publish",
  "requestId": "stable-request-id",
  "payload": {
    "channel": "github",
    "kind": "daily",
    "taskId": "stable-task-id-for-retries",
    "generatedAt": "2026-10-03T00:00:00Z",
    "result": {
      "repositories": [],
      "brief": {
        "title": "GitHub Daily",
        "summary": "...",
        "themes": [],
        "highlights": [],
        "analysisStatus": "complete",
        "source": "githot.dev"
      }
    }
  }
}
```

`kind` may be `daily` or `weekly`. The gateway fixes the API route and source to
`githot.dev`; it does not accept an arbitrary URL, source, user ID, or
HTTP method from the model. Reuse the same `taskId` and unchanged payload after a
timeout so the server can return the idempotent result. The server must have
`ORIALIS_NEWS_PUBLISHER_TOKEN` set to the same private value and
`ORIALIS_NEWS_PUBLISHER_USER_ID` bound to an existing Orialis account. Keep the
publisher token separate from `ORIALIS_DEVICE_TOKEN`; never put either secret in
the workspace or a Codex prompt. The REST publisher is optional; without its
token, ordinary Gateway messaging still works and a publish request returns a
configuration error.

Attachments and Hermes commands return explicit unsupported errors. No model
command, attachment download, shell command forwarding, or Hermes execution is
implemented. Run one gateway process per state database; an exclusive process
lock enforces this. Do not share the database or `CODEX_HOME` across device agents.
