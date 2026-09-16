# Orialis Agent Gateway protocol

Version 1 is the smallest text-only contract between Orialis Server and the Hermes
Orialis platform plugin. It supports `hello`, `hello_ack`, `ping`, `pong`,
`message.send`, `message.ack`, `message.reply`, and `error`.

The WebSocket endpoint is `/api/v1/agent/ws`. The development-only trigger is
`POST /api/v1/agent/debug/message` with:

```json
{
  "conversation_id": "conv_001",
  "content": "你好 Hermes"
}
```

`version` is always `1`. Unknown message types and malformed payloads produce
an `error` frame and must not terminate the process.

`message.ack` confirms receipt of a message identified by `message_id`; it does
not imply that Hermes has completed processing it.

## Server connection authentication

When the server is running outside development mode, configure
`ORIALIS_AGENT_DEVICE_TOKEN` on the server and `ORIALIS_DEVICE_TOKEN` in the Hermes
plugin with the same secret. The plugin sends it as:

```http
Authorization: Bearer <device-token>
```

Development mode permits an unauthenticated local connection only when the
server token is unset. The token must never be committed or written to logs.

## Multiple Agent devices

Each Hermes installation must use its own stable `ORIALIS_DEVICE_ID`. The
server records each device and keeps the selected device per Orialis account.
The authenticated mobile client can query and change the selection through:

```text
GET  /api/v1/agent/devices
POST /api/v1/agent/devices/{device_id}/select
```

When the database contains exactly one user, Agent devices are assigned to that
user automatically. If there are multiple users, configure
`ORIALIS_AGENT_USER_ID` on the server. Messages sent from mobile are routed to
the selected online device; devices with different IDs can remain connected at
the same time.
