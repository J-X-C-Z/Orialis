# TASK-028 SDK delivery record

Date: 2026-10-02. Scope: `integrations/orialis_sdk/**` only.

## Delivered

- Standard-library HTTPS/loopback HTTP transport with explicit Session or Node
  auth scheme, request deadlines, JSON parsing, no redirects, bounded response
  size, and stable sanitized errors.
- Fail-closed capability discovery requiring the exact server capability
  string `multidevice.v1` before Node/event API requests.
- Client operations for pairing start, explicit confirm/reject, one-time
  completion, paginated list/events, get/capabilities, heartbeat, and revoke.
- `python3 -m integrations.orialis_sdk.cli` pairing, account management,
  heartbeat, and node-own-configuration commands. Node credentials are stored
  with owner-only POSIX permissions and omitted from CLI output.
- Explicit Node credential restriction in the CLI: only heartbeat and that
  node's own configuration reads use `Authorization: Node`; account operations
  require `Authorization: Session`.
- Pairing secrets and Node credentials require their pinned service URL and
  never fall back to a new ambient URL. POSIX credential reads reject a
  symlink, unowned, or non-private credential directory.
- Continuous `run` retries retryable network/service failures on a 10-second
  cadence; non-retryable authentication, revocation, and contract failures stop
  the process. Retry output contains only a stable error code.
- Pair-confirm responses must use wire major 1, and list/event cursors must be
  strings or null as declared by the HTTP schema.

## Verification

`python3 -m unittest integrations.orialis_sdk.tests.test_multidevice
integrations.orialis_sdk.tests.test_http -v` passed 18 tests, including a real
HTTP round trip against a local isolated responder for pairing, auth headers,
heartbeat, and listing. This demonstrates SDK transport interoperability with
the selected HTTP shapes only; it is not evidence of production server state,
authorization, durability, or multi-device E2E.

`uv run --no-project --with-requirements scripts/requirements-contracts.txt
python scripts/validate-contracts.py` validated 27 fixtures against 12 schemas.

`python3 -m integrations.orialis_sdk.cli --help` renders the CLI entry point.
An initial test invocation contained a misspelled import path and failed before
loading tests; the corrected invocation above passed.

## Real local integration and remaining joint acceptance

The independent SDK review is recorded in `manager/TASK-033-review.md`; its
local code findings have been addressed in the SDK. Against the local real
Node/Control service, a redacted smoke passed pairing, Session confirmation,
completion, Node heartbeat/own reads, second-account isolation, advancing and
empty event cursors, 31-second offline transition/event, heartbeat recovery,
Session revocation, and rejected revoked-node heartbeat. A controlled service
restart occurred during the lease wait; subsequent reads and operations passed.
The separate parent runner has the strict database/PID restart readback. The
isolated HTTP responder tests still demonstrate transport shapes only. This
local smoke does not prove production release, native phone/macOS acceptance,
or full multi-device product completion.
