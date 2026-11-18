# Orialis HTTP domain tools

`DomainClient::new(server_url, device_id, device_token, optional_news_token)` creates one cloneable asynchronous client. `schemas()` returns all 39 OpenAI function descriptors; `contains()` and `tool_names()` use registered names, including the compatibility calendar aliases and `news.publish`. `execute(name, serde_json::Value)` returns the Python plugin's tool-result JSON shapes, including the special `create_schedule` → `schedule` response and per-item non-atomic batch results. The caller is responsible for authorization and cancellation. The main agent translates provider-invalid punctuation in tool names before presenting schemas to a model.

## Contract and deliberate fixes

`upstream_contract.json` is an unmodified snapshot of the registered schema dictionary, operation/domain metadata and response UI metadata at Orialis commit `f9a064bf05b18265afd26905e7240777d4ce355c`. It records its source SHA-256. Regenerate it and the publisher golden vectors with:

    python tests/fixtures/generate_domain_fixtures.py ../orialis

Runtime schemas correct known metadata mismatches rather than reproduce broken calls: registered `create_calendar_event` retains its own function name; create IDs and nullable patch fields are exposed; collection limits are 100 except messages (500); title/reminder/position and existing attachment-ID shapes follow the actual server. Schedule readers scan the real collection routes because this server has no single-schedule GET route. Client-unknown relational constraints and ownership remain authoritative on the server.

All seven batch tools validate the complete batch first, use client UUIDs where the API accepts IDs, preserve sequential parent-reference ordering, continue with per-item failure results, and never retry writes. Messages can reference existing server-owned attachments, but this layer does not upload, download or follow attachment URLs.

News publishing uses only the separately supplied publisher credential and fixed dataset route/source mappings. Its SHA-256 idempotency keys match Python's sorted compact UTF-8 JSON, including exponent formatting, negative zero and integers larger than u64. Both `serde_json` features `float_roundtrip` and `arbitrary_precision` are required to preserve source values; non-finite exponents are rejected.

## Transport boundaries

Only the configured origin is reachable. Credentials in URL userinfo are rejected; WS schemes map to their HTTP counterparts and endpoint query parameters are not forwarded. Resource IDs are encoded as single path segments, including literal percent signs. Redirects, automatic retry policy and environment proxies are disabled. Device bearer and device ID are sent only on ordinary API requests; publisher calls carry only their separate bearer. Credentials are not logged or included in Debug/error messages. Public capabilities discovery can run without a token, but it never substitutes publisher credentials for device credentials.

Requests use a shared bounded pool, four in-flight tool operations, 5-second connect timeout and 10-second complete HTTP timeout. Responses are streamed with a 64 KiB cap, arguments are capped at 2 MiB, publisher result JSON at 1 MiB, and batches at 200. Schedule lookup detects cursor cycles and reports an explicit error after 1,000 pages. These limits fail visibly, never silently truncate a result. An interrupted/invalid/oversize response or server 5xx marks any mutation `outcomeUnknown`; callers must check committed state before retrying.

## Verification

Normal tests use real loopback HTTP transport with deterministic fake endpoints, covering all schemas/routes, every batch and publisher dataset, exact request bodies, nullable fields, path/query escaping, scoped headers, no redirected credential leakage, partial response failures, byte limits, schedule granularity, unknown write outcomes, concurrency and Python numeric canonicalization.

    cargo test --lib domain_tools
    cargo clippy --lib --tests -- -D warnings

An opt-in test starts the actual pinned `orialis-server` binary itself, with `env_clear`, an isolated temporary SQLite database, two synthetic owners, synthetic tokens and development device auth disabled. No production address or secret is used. It exercises every one of the 39 tools, all ten news datasets twice for idempotency, real persistence/readback, optimistic concurrency and account/token isolation:

    ORIALIS_REAL_SERVER_BIN=/absolute/path/to/orialis/target/debug/orialis-server \
      cargo test --lib domain_tools::tests::real_server_all_39 -- --ignored --nocapture

The ordinary test suite intentionally ignores only this test when no real-server executable is explicitly supplied. The real-server test was also run and passed during implementation; it is not a mock-server claim. End-to-end gateway/model routing belongs to the host integration tests.
