# ORI-63 SDK/MCP framework delivery record

Date: 2026-10-01
Contract baseline: `protocol/contracts/multidevice-v1/README.md`, wire major 1,
contract 1.0.0.
Implementation boundary: local Python SDK + MCP-neutral adapter and isolated
fixtures only; no production service was called.

## Delivered

- Injectable transport API with the frozen Node v1 route paths for list/get,
  per-device capabilities, and revoke.
- Explicit `deviceId` on every per-node operation; URL path segment encoding,
  dot-segment rejection, and identity check on get response.
- Fail-closed capability helper (`available` and explicit `grant: allow` both
  required; `deny`, `ask`, absent and unconfigured grants stop locally).
- MCP-neutral declaration/dispatcher limited to read-only list/get/capabilities.
- Migration and return-to-integration checklist in `README.md`.

## Verification evidence

Command from repository root:

```sh
python3 -m unittest integrations.orialis_sdk.tests.test_multidevice -v
```

Result: 5 tests passed (0.002s). Coverage includes required/isolated device
routing, encoded IDs, cursor encoding, safe MCP exposure, revoke route selection,
and allow/deny/ask/unconfigured/unavailable capability cases. Fixtures are
in-process and local; no HTTP request was made.

The initial invocation with `python` failed because this environment has no
`python` executable; `python3` is available and the command above is the
reproducible command.

## Deferred integration and evidence limits

- Confirm deployed capability advertisement and actual endpoint/response
  envelopes with Node/Control owners; the v1 contract states routes but leaves
  list and capability wrapper JSON underspecified.
- Inject the approved real Session transport only after Node/Control deployment;
  verify authorization, account ownership, revocation and stable errors.
- Register declarations with the chosen MCP host and test actual host behavior.
- Coordinate any wire-contract changes with the protocol owners. Keep Hermes
  Gateway and legacy `agent-devices` distinct.
- Files, writes, agents, pairing, heartbeat, event streaming, Mac/Windows/NAS,
  authentication and end-to-end behavior are outside this fixture result.

## Assignment and resource note

The wake exposes no authorized team-member directory or task-assignment control
tool in this run, so member ownership could not be assigned here. Implementation
was kept within the new `integrations/orialis_sdk/` tree; the shared checkout
already contains extensive pre-existing changes. No existing source files or
migration records were rewritten. This delivery is ready for the designated
development-minister review once attached to ORI-63.
