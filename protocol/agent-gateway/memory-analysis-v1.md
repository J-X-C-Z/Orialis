# Background screen-memory analysis v1

A signed-in client submits `POST /api/v1/memory/analyses/{id}` with JSON
`{ "content": "prompt and original evidence", "imageBase64": "optional JPEG bytes", "sourceUrls": ["observed original URL"] }`.
`GET` on the same path returns `{id,status,content?,error?,category?,sourceUrl?,videoStatus?,videoSummary?,videoError?}`. Status is
`analyzing`, `completed`, or `failed`. IDs and results are scoped to the signed-in
user. Repeating the same ID/evidence reuses its run/result; failed runs can be
retried. Different evidence under an existing ID returns conflict.

The server routes only to `JXCZ_AOZORA_Hermes` advertising `memory.analyze`:

```json
{"version":1,"type":"memory.analyze","request_id":"unique-attempt-id","content":"prompt","image_base64":"optional JPEG bytes"}
```

The agent returns one correlated frame, with either content or a safe error:

```json
{"version":1,"type":"memory.result","request_id":"unique-attempt-id","content":"# Title\n\nSummary"}
```

This channel creates no conversation, chat message, attachment, or sync event.
The worker uses background completions without chat/session history. Its dedicated video path may read accessible captions and video frame evidence; unavailable media is reported explicitly. Request and
result text each allow 100000 UTF-8 bytes; JPEG screenshots allow 900 KiB decoded.
The server stores the evidence fingerprint and final result, never the submitted
screenshot/prompt. Work continues after the initiating HTTP request ends, with a
300-second limit. Interrupted server work expires on read or resubmission and can
be retried; an old attempt cannot overwrite a newer attempt's result.


`sourceUrls` defaults to an empty array for older clients. It preserves at most 32
observed HTTP(S) URLs, each at most 8192 UTF-8 bytes, including original query
parameters. The gateway receives these as `source_urls` and they contribute to
the idempotency fingerprint. Empty `sourceUrls` preserves the legacy fingerprint.

A newer worker may return `category` (`ai` or `other`), `source_url`,
`video_status` (`none`, `analyzed`, `unavailable`), `video_summary`, and
`video_error` on `memory.result`. All are optional for older workers. An analyzed
video requires a nonempty `video_summary`. The original source URL must come from
observed input or a verified resolution, never from a guessed title or identifier.
The server validates syntax and persists worker metadata; the worker verifies
provenance and media accessibility. Summary text allows 100000 UTF-8 bytes,
video errors 4000 bytes. HTTP responses expose the same fields in camelCase.
Migration 0020 adds these nullable columns without rewriting existing results.
