# Multi-device v1 contract delivery and verification

Date: 2026-10-01 (UTC)

## Deliverable

Contract version `multidevice-v1` / wire major `1`, schema revision `1.0.0`:

- `protocol/contracts/multidevice-v1/README.md`
- Device, Capability, Event and URI JSON Schemas in the same directory
- Representative Device, Event and URI fixtures integrated into `scripts/validate-contracts.py`

ORI-48's plugin inventory is applied: current Hermes `agent-devices`, Gateway heartbeat, and HTTP capabilities are explicitly not treated as the generic Node registry or authorization grant. No Mac/Windows/NAS-specific protocol variants are introduced. File writes and agent execution are excluded from v1.

## Reproduction and results

From the repository root:

```sh
uv run --with-requirements scripts/requirements-contracts.txt python scripts/validate-contracts.py
```

Result: `validated 17 contract fixtures against 12 schemas` (exit 0). `git diff --check` was also run on the repository-owned contract files without whitespace errors. The validator currently emits an upstream `jsonschema.RefResolver` deprecation warning.

Read-only production checks against `https://orialis.jxcz.top` on 2026-10-01:

- `GET /api/v1/health` → `200`, `{"ok":true,"service":"orialis","version":"0.1.0","environment":"production"}`.
- `GET /api/v1/meta` → `200`, service/API version `orialis`/`v1`, deployment version `0.1.0`.
- `GET /api/v1/capabilities` → `200`; lists current service capabilities but does not include `multidevice.v1`.
- `GET /api/v1/nodes` → `404`, `{"error":"route_not_found","service":"orialis"}`.
- Local `127.0.0.1:8080` health endpoint → connection refused; no local Node/Control service was available.

These checks confirm the deployed service's current boundary. They do not verify live pairing, node presence, capability authorization, revocation propagation, or any paired desktop/mobile/NAS node. No mock or fixture is counted as platform implementation evidence. Existing production behavior observed in source remains Session hard expiry at 30 days and logout revocation; mobile websocket heartbeat is 20 seconds. The new Node lease rule (heartbeat every 10s, offline at 30s) is contract-only until its owner implements it.

## Repository baseline and limits

Authoritative checkout: `projects/orialis/repo`, branch `Lumina-UI`, starting HEAD `bdc03801dd7fa6fbf417dd1254d8fbe12a62186a`. The working tree already contained many unrelated modified and untracked files before this delivery; they were preserved. No server route, database migration, auth behavior, client implementation or deployment was changed. No code commit was created because this checkout has concurrent uncommitted work; this Paperclip work product is the review submission identifier.
