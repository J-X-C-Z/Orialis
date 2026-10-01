# Orialis multi-device SDK scaffold

This package is a transport-neutral Python client and MCP host adapter scaffold
for the frozen `multidevice-v1` Node/Control contract in
`protocol/contracts/multidevice-v1/README.md` (wire major `1`, contract `1.0.0`).
It currently implements only contract-declared `GET /nodes`,
`GET /nodes/{deviceId}`, `GET /nodes/{deviceId}/capabilities`, and
`DELETE /nodes/{deviceId}`. No production network transport or credential
storage is bundled: the integrating host injects a transport that adds the
user's `Authorization: Session …` header, TLS, timeouts, and safe error handling.

Every per-node method requires the caller to pass `deviceId`; it is escaped as
one opaque URL path segment and response identity is checked on `devices.get`.
Capability checks fail closed unless both `available: true` and `grant: allow`
are present. `ask`, `deny`, missing grants, and unavailable capabilities throw a
local `ContractError`; this scaffold does not implement an approval UI/flow.

The MCP adapter is host-neutral: it declares and dispatches only the three
read-only tools `devices.list`, `devices.get`, and `capabilities.get`. A host
must map these declarations into its MCP SDK. Revocation remains SDK-only and
is not exposed as an MCP tool. File access, file writes, agent execution,
pairing, heartbeat, and events are intentionally not exposed here.

## Local verification

From the repository root:

```sh
python -m unittest integrations.orialis_sdk.tests.test_multidevice -v
```

These tests use only isolated in-process fixtures; they prove SDK dispatch,
device routing, cursor encoding, and fail-closed capability behavior. They do
not prove a deployed Node API, authentication, MCP host interoperability, or
cross-platform operation.

## Migration and return-to-integration checklist

1. Preserve Hermes Gateway and `/api/v1/agent/devices` plus its legacy IDs as a
   separate compatibility surface. Do not map Hermes records to generic Nodes.
2. Once the real API is deployed, inject the production Session-authenticated
   HTTP transport and verify `/api/v1/capabilities` advertises `multidevice.v1`
   before any calls; current server baselines do not advertise it.
3. Confirm list pagination response envelope and capability response envelope
   against the server implementation; current v1 README specifies semantics
   and paths but not every JSON wrapper shape.
4. Add schema-validated fixtures from Node/Control owners; reconcile only via
   protocol owners if the frozen wire contract changes.
5. Validate real ownership filtering, grant changes/revocation, unsupported
   version errors, TLS/auth handling, and live MCP host registration. Report
   platform results separately from fixture results.

No platform-specific protocol assumptions were added. Fixture-only envelopes
are explicitly local and are not wire-contract proposals.
