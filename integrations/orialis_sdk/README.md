# Orialis Multi-device Node SDK

This package provides a Python HTTP client and CLI for the `multidevice.v1`
Node/Control API. Before any Node or event request it reads
`GET /api/v1/capabilities` and requires the exact advertised string
`multidevice.v1`; it fails closed when the service does not advertise it.
Account actions use `Authorization: Session …`. The target Node uses
`Authorization: Node …` only for heartbeat and reads of its own node record or
capabilities. It cannot list/revoke devices or act as the account holder.

## Pair and run a node

Set the real service URL and the account Session token in the environment. Use
HTTPS for non-local hosts; HTTP is accepted only for loopback development.

```sh
export ORIALIS_BASE_URL=http://127.0.0.1:18444
export ORIALIS_SESSION_TOKEN='your-session-token'

python3 -m integrations.orialis_sdk.cli pair-start \
  --name 'Office node' --platform macos --node-version 1.0.0
```

`pair-start` prints the intended six-digit confirmation code and opaque pairing
ID, while saving the one-time pairing secret in the private local store at
`~/.orialis/node-credentials.json` (new credential directories use mode 0700,
file mode 0600 on POSIX). Existing directories are never chmodded; the CLI
requires the selected credential directory to be private. Confirm or reject explicitly from the account session:

```sh
python3 -m integrations.orialis_sdk.cli pair-confirm PAIRING_ID \
  --code 123456 --decision confirm
```

Then on the target node, exchange the stored one-time secret for its
device-scoped credential and start its 10-second heartbeat loop. The loop
retries retryable network/service failures on the same cadence; authentication,
revocation, and contract errors stop it:

```sh
python3 -m integrations.orialis_sdk.cli pair-complete
python3 -m integrations.orialis_sdk.cli run
```

The credential store remembers the service URL, so the target may be remote as
long as it can reach the same service. The account holder can list, inspect,
read events, and revoke nodes from a separate logged-in shell:

```sh
python3 -m integrations.orialis_sdk.cli nodes --limit 100
python3 -m integrations.orialis_sdk.cli events --limit 100
python3 -m integrations.orialis_sdk.cli revoke DEVICE_ID
```

`node-info`, `node-capabilities`, and `heartbeat` use only this installation's
Node credential. `run` sends no user data and exposes no file, shell, or agent
execution surface. Stop it with Ctrl+C.

The credential store is unencrypted and protected by local filesystem
permissions; choose a private user account and back it up only through an
approved secret store. POSIX reads and writes require an owner-only credential
file in a private, owner-owned, non-symlink directory. CLI output omits pairing
secrets and node credentials.
Session tokens are read from `ORIALIS_SESSION_TOKEN`, not command arguments.
For `pair-confirm`, set a Session belonging to the account that should own this
node; the CLI cannot infer the Session's account identity. The server enforces
the account binding. Pairing secrets and Node credentials are pinned to the
service URL saved at pairing time; a conflicting `--base-url` is rejected before
any request is sent. A credential record missing its pinned URL is rejected;
the CLI will not fall back to an ambient service URL for an existing credential.

## Python API

```python
from integrations.orialis_sdk.http import HttpTransport
from integrations.orialis_sdk.multidevice import MultiDeviceClient

client = MultiDeviceClient(HttpTransport(
    "https://orialis.example",
    token=session_token,
    auth_scheme="Session",
    timeout=8,
))
nodes = client.list_devices(limit=100)
```

The injected transport constructor remains supported for tests and embedding.
Capabilities fail closed unless `available` is true and `grant` is explicitly
`allow`; `ask`, `deny`, missing grants, and unavailable capabilities are not
converted into approval. The MCP-neutral adapter still exposes only the
read-only list/get/capabilities tools.

## Contract status and verification boundary

The local implementation profile is contract 1.0.1 / wire major 1, recorded in
`protocol/contracts/multidevice-v1/README.md` and `http.schema.json`. Implemented
routes are the v1 capability discovery, pairing start/confirm/complete, node
list/get/revoke/heartbeat/capabilities, and account events routes. Their
selected JSON envelopes match the response fixtures in
`protocol/contracts/fixtures/`. Independent review and live server acceptance
remain separate gates; profile documentation and fixtures are not evidence of
deployed support.

Local verification:

```sh
python3 -m unittest integrations.orialis_sdk.tests.test_multidevice \
  integrations.orialis_sdk.tests.test_http -v
```

`test_http` makes actual HTTP requests to an isolated local responder and
checks request paths and auth schemes. It does not test Orialis server
authorization, persistence, expiry, account isolation, revocation, or a
deployed service. Such acceptance requires the real Node/Control service and
separately paired client/node evidence. No fixture or local responder is
reported as end-to-end acceptance.
