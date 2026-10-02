# Orialis Multi-device Contract v1

Status: **local implementation profile reconciled for TASK-025; independent review and deployment acceptance pending**. This is the common wire contract for Node, Control Plane, desktop, mobile and plugins. The earlier project-state label “frozen” did not settle the HTTP envelope and authentication details; the 1.0.1 profile below records those details explicitly. It does not claim that Node or Control Plane routes are deployed. No client may infer support from this document; it must discover `multidevice.v1` in capabilities.

Contract version: `1.0.1` (wire major `1`; additive optional fields are minor-compatible only after schema update and conformance review). Schemas use JSON Schema Draft 2020-12. All IDs and cursors are opaque strings. Timestamps are RFC 3339 UTC.

## Resources and schemas

- `device.schema.json`: account-bound installed node, lifecycle and observed presence.
- `capability.schema.json`: versioned capability descriptor; availability is not a grant.
- `event.schema.json`: resumable, deduplicable event envelope.
- `uri.schema.json`: `orialis://` resource identifier; arbitrary filesystem paths are invalid.
- `pairing.schema.json`: pairing challenge, explicit account confirmation, completion and failure fixtures.

## Node/Control HTTP v1

Base path: `/api/v1`. Account operations require an authenticated Orialis Session. An unpaired target starts a rate-limited challenge without account authentication and completes it with its short-lived pairing secret; only a logged-in account holder can confirm or reject. A paired target uses `Authorization: Node <deviceCredential>` for its heartbeat and reads of its own Device/capabilities only. The authenticated principal and device ownership are checked on every request.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/nodes/pairings` | Target Node creates a challenge; returns opaque `pairingId`, one-time secret, six-digit confirmation code, presented node identity and expiry |
| `POST` | `/nodes/pairings/{pairingId}/confirm` | Requires `Authorization: Session`; account holder submits the displayed code and `confirm` or `reject` decision |
| `POST` | `/nodes/pairings/{pairingId}/complete` | Target Node exchanges one-time secret after confirmed state; immutable presented identity must match; returns credential once |
| `GET` | `/nodes` | List caller's nodes, cursor-paginated |
| `GET` | `/nodes/{deviceId}` | Read node metadata, observed status and granted capabilities |
| `DELETE` | `/nodes/{deviceId}` | Revoke node; idempotent; increments `revocationVersion` |
| `POST` | `/nodes/{deviceId}/heartbeat` | Authenticated node lease renewal; server time is authoritative |
| `GET` | `/nodes/{deviceId}/capabilities` | Read node capability descriptors and effective grants |
| `GET` | `/events?after={cursor}` | Resume event stream; cursor is opaque and scoped to the account |

These paths define the v1 Node/Control API contract. The production readback on 2026-10-02 still shows no `multidevice.v1` advertisement and `/nodes` is absent; local implementation work must be reviewed and accepted separately. A route must not return success until the corresponding authorization and durable state transitions exist. File operations, agent execution, arbitrary shell, and writes are outside v1.

## Authentication, pairing and authorization

User calls use `Authorization: Session <accessToken>`; token storage is hash-only. The target Node starts a pairing challenge and displays its six-digit `confirmationCode` together with the `pairingId`-associated presented `displayName`, `platform`, and `nodeVersion`. The target retains the `pairingSecret`; it is never shown in the account UI. The account holder must be logged in and explicitly submit `{confirmationCode, decision}` to the `confirm` endpoint. This action binds the pending pairing record and its immutable target identity to the authenticated `accountId`; `complete` never performs or implies user consent. The server matches the path `pairingId`, displayed code, pending record, target identity and authenticated account before recording confirmation. `confirm` and `complete` are rejected for another account; account mismatch is returned as `404 NOT_FOUND` to avoid exposing pairing state. Codes and secrets expire at 5 minutes, are single-use, and are rate-limited. The server stores only a hash of the pairing secret and never logs it or the confirmation code. Completion verifies the secret and that the submitted node identity exactly matches the immutable identity recorded when the challenge was created, binds a newly issued opaque `deviceId` to the confirming account, and returns a device credential once; that credential is scoped to that device and may only renew its lease or read its own permitted configuration. It cannot act as the user Session.

Pairing transitions are `pending_confirmation → confirmed → completed`, or `pending_confirmation → rejected`; a non-terminal state becomes `expired` at `expiresAt`. Rejection is final. Repeating the same confirmation decision is idempotent (`200`, state unchanged); attempting to reverse it returns `409 PAIRING_DECISION_FINAL`. Completing before confirmation returns `409 PAIRING_NOT_CONFIRMED`; after rejection returns `409 PAIRING_REJECTED`; after expiry returns `410 PAIRING_EXPIRED`. Successful completion consumes the secret atomically. A repeated completion returns `409 PAIRING_ALREADY_COMPLETED` and never returns the credential again. A wrong code returns `400 INVALID_ARGUMENT` without changing state. Rate limits return `429 RATE_LIMITED`; invalid/expired Sessions return `401 UNAUTHENTICATED`. The failure fixture matrix records these stable status/code/state results. Fixture validation checks the documented matrix but does not execute a live server transition.

Every node operation requires all of: valid caller session (or that node's credential for heartbeat), same-account ownership, advertised server support, node capability, and an unexpired explicit grant. `ask` returns `APPROVAL_REQUIRED`; it never runs until the same request is resumed with an accepted approval. Missing policy or unavailable authorization fails closed. Capability advertisement is descriptive, never authorization.

Revocation is an atomic monotonic `revocationVersion` increment. API calls check it before work; connected nodes receive `node.revoked` and must stop work and discard credentials. Delivery is best-effort, so the control plane also rejects the old version on every authenticated operation. A disconnected node cannot act; reconnection with revoked credentials fails authentication and requires pairing again. Revocation cancels in-flight work at the next safe checkpoint; v1 exposes no arbitrary long-running execution.

## Presence and Session lifecycle

Node heartbeat interval is 10 seconds. Presence is `online` only while the latest authenticated heartbeat is no older than 30 seconds; at `lastSeenAt + 30s` it becomes `offline`, regardless of a stale websocket. `observedAt` is server time. Presence is advisory and does not guarantee a subsequent operation will succeed. Revoked is a lifecycle state and takes precedence over online/offline. Unknown is used when no observation exists. This lease applies to Node v1 only; existing mobile and Hermes websocket cadence is unchanged.

Orialis user Sessions keep the existing v1 rule: 30-day absolute expiry, no sliding extension, no eviction of other valid Sessions on login. Logout revokes the presented Session and subsequent requests fail; other logged-in devices remain valid. Expired/revoked credentials are rejected immediately. Storage cleanup may purge their records after 7 days, but cleanup must never extend credential validity. The current service implements the 30-day expiry and logout revocation; multi-session caps and record cleanup are not currently implemented.

## Errors and compatibility

Error body: `{ "error": "PERMISSION_DENIED", "message": "...", "requestId": "...", "retryable": false, "details": {} }`. Stable codes: `INVALID_ARGUMENT`, `UNAUTHENTICATED`, `PERMISSION_DENIED`, `APPROVAL_REQUIRED`, `NOT_FOUND`, `DEVICE_OFFLINE`, `CAPABILITY_UNAVAILABLE`, `CONFLICT`, `RATE_LIMITED`, `DEADLINE_EXCEEDED`, `CANCELLED`, `UNSUPPORTED_VERSION`, `PAIRING_NOT_CONFIRMED`, `PAIRING_REJECTED`, `PAIRING_EXPIRED`, `PAIRING_DECISION_FINAL`, `PAIRING_ALREADY_COMPLETED`, `INTERNAL`. Never include credentials, pairing secrets/codes, absolute paths or protected file contents in errors.

Major versions are negotiated explicitly in `protocolVersion`; unsupported major returns `UNSUPPORTED_VERSION`. Clients ignore unknown optional fields and event types, but must not treat unknown operations as success. Breaking field/meaning/removal changes require a new major and a dual-read migration; additive optional fields require a compatible schema revision and fixtures before rollout. All platforms use the same schema/version; OS adapters may not rename methods or alter authorization semantics.

## Existing implementation and verification boundary

The deployed service currently exposes the existing account APIs and `agent-devices`, not `/nodes` or `/events`. Existing `/api/v1/capabilities` does not list `multidevice.v1`. Hermes device records and Gateway heartbeat are not the generic node registry. Contract fixtures validate serialization shape and the documented pairing status/code/state table only; they do not execute server behavior. Real acceptance additionally requires Node and Control Plane implementations and live paired nodes. No mock is accepted as that evidence.

## HTTP implementation profile 1.0.1 — TASK-025 / 2026-10-02

Source: user instruction to progress to multi-device joint acceptance; integration reconciliation of the existing SDK fixture, pairing schema and endpoint table. See project ADR-007. This profile is an implementation decision pending independent review; it is not evidence of deployment.

- Start request: `{protocolVersion:"1",nodeIdentity:{displayName,platform,nodeVersion}}`, validated by `http.schema.json`. No account Session is required at start; admission and failed code/secret attempts are rate-limited. The immutable identity is retained until completion.
- `GET /nodes`: `{protocolVersion:"1",nodes:[Device],nextCursor:string|null}`. Query `cursor` and optional `limit` (default 100, maximum 100). Cursors are opaque persisted Device IDs scoped to the authenticated account; unknown or foreign cursors return 404. Stable ordering is creation time and Device ID.
- `GET /nodes/{deviceId}`: Device schema body. `GET /nodes/{deviceId}/capabilities`: `{protocolVersion:"1",deviceId,capabilities:[Capability]}`. Session ownership or that Device's valid Node credential is required.
- Heartbeat: `POST /nodes/{deviceId}/heartbeat` with `{}` and that Device's Node credential; response is Device body. Session cannot impersonate a node lease renewal. The server supplies all observation times.
- `DELETE /nodes/{deviceId}`: Session only, response is the revoked Device body. First revocation increments its version once; a repeated revoke returns the same final version. Old Node credentials cease working immediately.
- `GET /events?after={cursor}&limit=100`: Session only, `{protocolVersion:"1",events:[Event],nextCursor:string|null}`. Cursors are account-scoped persisted opaque Event IDs. `sequence` increases monotonically for each Device; the feed follows durable control event insertion order, and IDs are opaque. With events, `nextCursor` is the last returned event ID; an empty poll retains `after` (or null initially). Foreign/unknown cursors fail 404.
- Durable `node.presence_changed` records online/offline transitions including lease expiry; `node.revoked` records revocation. Observation-only reads cannot restore online presence. Capability advertisement describes available operations and never grants file access or execution.
- The 1.0.0 Device, Capability, Event, URI and pairing schemas remain shape compatible. Clients ignore optional additions but must discover server capability before using Node APIs.
