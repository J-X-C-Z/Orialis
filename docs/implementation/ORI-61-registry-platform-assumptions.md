# ORI-61 Registry and platform implementation assumptions

Status: implementation preparation, based on the frozen `protocol/contracts/multidevice-v1` contract (1.0.0, wire major 1). This note does not create a second wire contract and does not claim route, pairing, authentication, or production-platform completion.

## Registry storage boundary

- Durable node metadata is account-owned and keyed by opaque `deviceId`; every query and mutation must scope by both authenticated `accountId` and `deviceId`.
- Persist protocol version, display name/platform/node version, lifecycle/revocation version, capabilities, and server-authored timestamps according to `device.schema.json`. Credentials should be stored as hashes only; one-time pairing secrets and raw device credentials must never be persisted or logged.
- Presence is derived from the latest authenticated heartbeat and the frozen 30-second lease; durable `lastSeenAt` is an observation, not a live connection registry. Revocation takes precedence over presence.
- Additive schema changes require a SQLx migration; no route is exposed until pairing/authentication and ownership checks are implemented end to end.

## Linux and Headless boundary

- Linux filesystem operations must canonicalize and constrain paths beneath an explicit configured root, reject traversal/symlink escapes, and use OS permissions as a second boundary. V1's generic Node contract does not authorize arbitrary file operations, shell, or agent execution.
- NAS must be headless and advertise only capabilities actually available. Linux file adapter and container experiments can validate isolation/build/mount behavior but do not prove live pairing or server authentication.
- The current execution host is macOS ARM64 and Docker CLI is unavailable, so this checkout cannot provide real Linux/Docker execution evidence. A Linux runner or Docker-enabled host is required for that acceptance item.

## Reconnection checklist

1. Verify account isolation in storage tests with two accounts and identical device identifiers where schema allows/denies them by contract.
2. Wire routes only to the ORI-50 contract; session identity is authoritative, never a request body account id.
3. Apply migration to a clean database and a copy of the current schema; verify rollback/restart behavior as supported by SQLx.
4. On Linux/Docker, record OS/architecture, image digest, build output, read-only/data mounts and permission tests.
5. Re-run the existing contract fixtures and preserve ORI-54/55 hard dependencies for real authenticated integration.
