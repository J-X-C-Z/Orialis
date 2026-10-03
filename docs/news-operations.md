# Orialis News operations

This runbook covers the local collection, analysis, audit, and Paperclip scheduling layer for Orialis News. It does not scan project repositories for project updates. Until a project secretary submits a report, Projects correctly has no project rows and its daily brief remains empty.

## Runtime pieces

- `integrations/news/pipeline.py` validates secretary reports, keeps a SQLite task ledger and user-scoped raw report inbox, invokes the configured Agent Runner, merges project reports, and publishes to the News API.
- `scripts/news_sources.py` is the shared source collector. GitHub daily and weekly runs independently fetch Githot ranking cards and each repository’s native detail sections, retaining their order, source copy, tags, statistics, trial commands, and ranking history. AIHOT collection is a source-only operation and never calls an Agent Runner.
- `integrations/news/paperclip_setup.py` uses Paperclip's real routine and schedule-trigger APIs. It previews by default. `--apply` creates missing routines and disabled schedule triggers after it can read current company agents, projects, and routines and validate explicitly supplied worker agents. Triggers remain disabled unless `--enable-triggers` is passed after the publisher, server, and durable runner route are ready.

GitHub and AIHot publish source content directly and never construct or invoke an Agent Runner. GitHub repository content uses `sourceTitle`, `sourceSummary`, `sourceTopics`, and `sourceContent` (safe Markdown converted from Githot’s visible detail sections). No fixed features/value/useCases fields are synthesized. `analysisStatus=not_required` identifies this successful source-only path. The period brief remains a compatibility envelope with a factual count and empty themes/highlights; the current client displays source attribution instead of an AI overview. A missing detail page preserves the ranking card and source link with `sourceDetailStatus=unavailable`.

Projects alone retains the configured Agent Runner for project report processing; `ORIALIS_NEWS_RUNNER_COMMAND` applies to that path.

The Nagi-specific, non-secret runner setting is recorded in `integrations/news/nagi-runner.env.example`. It uses the installed CLI's absolute path because `/home/JXCZ/.local/bin` is not in the observed non-interactive `PATH`; keep the Paperclip worker running as `JXCZ` so it uses that account's existing Codex login. The setting does not contain or read authentication data.

## Azure Hermes production execution

The user-requested Azure runner is the Aozora Linux host. News units run as the existing `hermes` service account. GitHub and AIHot execute Python collectors directly without invoking Hermes or another model; the existing `hermes-gateway.service` is not restarted. Secrets are loaded only from `/etc/orialis-news/worker.env` (root:hermes, mode 0640). AIHot uses `orialis-news-aihot.timer` every five minutes and has a successful scheduled production run.

GitHub daily and weekly use separate systemd services and Asia/Shanghai schedules (18:00 daily, Monday 18:15 weekly). Both GitHub timers are enabled after verified direct publications. Current direct-content evidence is `news/evidence/githot-direct-20261004.json`; the earlier Hermes rollout remains historical evidence in `news/evidence/realtime-azure-hermes-20261003.json`.

## Environment

Configure these values in the runtime that executes the job. Do not pass tokens as command-line arguments or put them in workflow descriptions.

```text
ORIALIS_NEWS_BASE_URL=https://<orialis-host>/api/v1/news
ORIALIS_NEWS_PUBLISHER_TOKEN=<dedicated news publisher token>
ORIALIS_NEWS_PUBLISHER_USER_ID=<user bound to that publisher token>
ORIALIS_NEWS_PROJECT_USER_ID=<user whose private project reports are aggregated>
ORIALIS_NEWS_DB=~/.local/share/orialis-news/pipeline.sqlite3
ORIALIS_NEWS_RUNNER_COMMAND=codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json -
PAPERCLIP_API_URL=http://127.0.0.1:3100
PAPERCLIP_COMPANY_ID=<Orialis company id>
PAPERCLIP_API_KEY=<optional Paperclip key when local-trusted access is unavailable>
```

`GITHUB_TOKEN` / `GH_TOKEN` are not required by the Githot direct collection path. The API client disables environment HTTP proxies for loopback-safe local calls. The publisher identity is separate from the Paperclip runtime identity; the backend binds agent publishers to their configured user and rejects identity mismatches.

The server process must load `ORIALIS_NEWS_PUBLISHER_TOKEN` and
`ORIALIS_NEWS_PUBLISHER_USER_ID` from its private EnvironmentFile (see
`deploy/orialis.env.example`). The user ID must already exist in that server's
database. Give the same dedicated publisher token to the worker that calls the
News API; do not reuse `ORIALIS_AGENT_DEVICE_TOKEN`, a Session token, or a
Paperclip key. The Codex Gateway uses `ORIALIS_NEWS_PUBLISHER_TOKEN` and may use
`ORIALIS_NEWS_API_URL` to override the HTTP base; otherwise it derives HTTP(S)
from `ORIALIS_SERVER_URL`. The server accepts only the configured publisher
identity and validates each category's source and payload.

The Codex Gateway's `news.publish` capability publishes GitHub daily or weekly
briefs through `POST /api/v1/news/publish/github/{period}`. A successful request
writes the shared news cache and a durable publish-task receipt that the signed-in
app can read through its Session-authenticated News API. This is a server cache
publication flow; it exposes Session-authenticated SSE cache invalidation for clients to re-read published data; OS notifications are a separate flow.

## GitHub runs

Run the two periods independently. Each execution creates a unique task ID; retries must pass the original task ID and unchanged source facts.

```text
python3 -m integrations.news.cli github daily --publish
python3 -m integrations.news.cli github weekly --publish
```

Daily collection fetches `https://githot.dev/`; weekly collection independently fetches `https://githot.dev/weekly` and never assembles a weekly result from daily briefs. Repository detail content now comes directly from Githot; this path does not make GitHub API calls or re-fetch README. Optional README fields in older payloads remain readable by the client. The publisher source is `githot.dev`; requests use `POST /api/v1/news/publish/github/daily` or `/weekly`, with `taskId`, `source`, `generatedAt`, `period`, `result={repositories: repos, brief: {title, summary, themes, highlights, analysisStatus, source}}`, `userId`, and `idempotencyKey`. The brief is returned by `GET /api/v1/news/github/briefs/daily` or `/weekly` as an object in the normal response envelope. Existing `GET /api/v1/news/github/daily` and `/weekly` ranking reads continue returning an array for older clients.

The GitHub ranking routes are `GET /api/v1/news/github/daily` and `/weekly`; they return a repository array inside `{data, updatedAt, stale, source, error}`. The additional `GET /api/v1/news/github/briefs/{period}` route returns the period brief object in that envelope. The client reads generated data; it does not start collection or Codex when a page opens.

## Project secretary intake

Each secretary submits only its own project summary using these required fields:

```yaml
project: Orialis
date: 2026-10-02
completed: []
in_progress: []
decisions: []
issues: []
next: []
important: []
```

The protocol rejects missing required keys, unknown fields, invalid dates, non-string bullet entries, blank project names, and an unscoped source. `contributors`, `metrics`, and `links` are accepted as optional extensions. A source name must use `orialis-project-report/<stable-source-name>`. `projectId` and `userId` accompany the report. The sender's configured identity must match `userId`; the server also checks that `projectId` belongs to that user. The example under `integrations/news/fixtures/` is sample-only and is never used as a real project update.

Submit one report from a file:

```text
python3 -m integrations.news.cli projects receive integrations/news/fixtures/secretary-report.example.json
```

The CLI checks the identity against `ORIALIS_NEWS_PROJECT_USER_ID`, saves the validated raw report locally, and posts it to `POST /api/v1/news/projects/publish` with `period=daily` and `reportDate`. A duplicate report is de-duplicated by report content plus user/project scope. Failed publishes are recorded as failed tasks and can be retried with the same `taskId`.

Create the per-user daily rollup after the real secretary feeds are configured:

```text
python3 -m integrations.news.cli projects daily 2026-10-02 --publish
```

The rollup queries only reports for the configured user and date. It groups by project, deduplicates repeated bullets within project scope, prioritizes issues and important decisions, and includes every raw secretary report. If the Runner fails, the deterministic rollup and raw report bodies remain publishable. If there are no reports, it records a successful empty result and does not overwrite the backend cache with fabricated project content.

## Paperclip schedules and apply boundary

This Paperclip version models scheduled work with **Routines** and `schedule` triggers; the verified endpoints are:

- `GET /api/companies/{companyId}/agents` and `GET /api/companies/{companyId}/org` for current company assignments and hierarchy.
- `GET /api/companies/{companyId}/routines` and `GET /api/routines/{id}` to inspect existing schedules.
- `POST /api/companies/{companyId}/routines` to create a routine.
- `POST /api/routines/{id}/triggers` to create a scheduled trigger.
- `GET /api/issues/{id}/documents/plan` to read the plan document on an issue.
- `POST /api/routines/{id}/run` to request an on-demand run.

The Org chart is the existing Paperclip `reportsTo` hierarchy. This setup script does not install catalog teams, hire agents, change reporting lines, or send user notifications. Existing group lead/worker identities must be classified inside the Orialis company and selected explicitly. The AIHOT source-only routine must use a dedicated agent with Paperclip's `process` adapter configured for the collector command; GitHub may use distinct daily/weekly process workers with exact `python3 -m integrations.news.cli github daily|weekly --publish` entrypoints; the GitHub CLI directly publishes source copy without invoking an Agent Runner. The older shared GitHub Runner is still supported. Projects uses its existing configured Agent Runner agent. Applying routines leaves all schedule triggers disabled unless `--enable-triggers` is explicitly passed.

Preview the intended routines. A service outage still leaves the local plan readable and reports that Paperclip could not be inspected:

```text
python3 -m integrations.news.paperclip_setup --company-id <company-id>
```

After reviewing IDs, schedules, company ownership, and runtime configuration, `--apply` re-reads current agents and routines, reuses routines with matching titles, and creates only missing routines/triggers. It refuses to apply when required agent IDs are absent or the AIHOT agent is not a process adapter.

```text
python3 -m integrations.news.paperclip_setup \
  --company-id <orialis-company-id> \
  --aihot-process-agent-id <process-agent-id> \
  --github-agent-id <github-runner-agent-id> \
  --projects-agent-id <projects-runner-agent-id> \
  --apply
```

Prepared schedules (Asia/Shanghai): AIHOT source refresh every 5 minutes, daily GitHub at 18:00, weekly GitHub every Monday at 18:15, and Projects daily at 19:00. The AIHOT interval is above the upstream 60-second cache TTL and runs the pure collector command through Paperclip's `process` adapter, without invoking Codex. GitHub period-specific process workers invoke the configured Agent Runner within the CLI; Projects schedules use their configured Agent Runner. Both produce task records with `taskId`, `status`, `startedAt`, `finishedAt`, `source`, `result`, and `error`.

The daily source collector itself can be run directly for a controlled refresh:

```text
python3 scripts/news_sources.py --refresh github-daily
python3 scripts/news_sources.py --refresh github-weekly
python3 scripts/news_sources.py --refresh aihot
```

## Task idempotency and retries

The SQLite task ledger is keyed by `taskId`. Replaying a succeeded task with the same input returns an idempotency error rather than publishing a second result. A failed task may be retried only with the original input and same `taskId`; a changed input requires a new task ID. The News backend enforces the same task ID idempotency. Each run stores its start/finish time, source, result/error, and attempt count. Raw secretary reports are retained in the same database even when analysis or publishing fails.

Before a publish request, the local ledger also persists the exact endpoint, request payload, and task result in `pending_publications`. If the server accepted a request but the client lost the response, retrying the same task ID replays those saved bytes and skips collection/analysis. Audit `phase` distinguishes collection, analysis degradation, publish failure, and completion; analysis degradation remains visible with the deterministic source data and raw secretary reports.

## Nagi and Paperclip execution evidence — 2026-10-02

A fresh source collection fetched 17 entries from the official GitHub daily Trending page and enriched the first ten with repository metadata, README excerpts, topics, and release information. A single grounded brief prompt ran on `Nagi-HK` through a one-off SSH reverse-forward to the local HTTPS proxy (`127.0.0.1:17891`). The installed runner is `/home/JXCZ/.local/bin/codex` version `0.160.0`, using its existing ChatGPT login. The invocation used `codex exec --ephemeral --sandbox read-only --skip-git-repo-check --model gpt-6-astra --json -`; it returned valid JSON with repository summaries for the exact ten supplied repositories and a complete daily brief. No News API call or publish was made. The one-shot SSH tunnel ended with the invocation and made no persistent proxy, auth, or global configuration changes. The output and supplied source facts are retained in `news/evidence/github-daily-brief-2026-10-02.json`.

The weekly run independently fetched `https://github.com/trending?since=weekly` and retained all 17 source rows. Its accepted read-only Nagi invocation received only ranking positions 1–10 and returned summaries covering those ten plus a weekly overview; the final result was checked against the exact supplied repository set. One earlier response that analyzed beyond the CLI's top-ten input scope was discarded, then the request was narrowed to match the pipeline. No News API call or publish was made. Source facts and the accepted response are retained in `news/evidence/github-weekly-brief-2026-10-02.json`.

Earlier direct outbound probes from Nagi received HTTP 403, so the one-shot tunnel demonstrates a working invocation route but does not establish a durable Paperclip worker egress path. Keep routine triggers disabled until an approved persistent route and publisher/server readiness are verified. Do not replace or reauthenticate the existing login. A fresh direct request to `http://127.0.0.1:3100/api/health` on the operations host failed immediately with connection refused; Paperclip company agents/routines therefore could not be read and no organization, agents, routines, triggers, or process configuration were changed. No secretary reports were supplied, so the Projects result remains empty: zero project rows, zero raw reports, no LLM call, and no cache publish.

### Current Paperclip configuration and one-shot runner — 2026-10-02

The connection-refused observation above is historical and has been superseded. A fresh read of `http://127.0.0.1:3100/api/health` reported `ok`, `local_trusted`, and `authReady=true`; the listener belongs to the Agent Workspace Paperclip checkout at `/Users/jxcz/Agent Workspace/Paperclip`, not the original Paperclip checkout. The selected company was verified as Orialis (`2ae03c21-9745-4209-b202-edf4ffa70a6a`) and the selected project as `运营支持` (`e07a41fc-febd-4655-8cf7-4d8f7817cd16`). No Paperclip开发 company records were changed.

The existing `运营部` and `运营小组` were read before changes and preserved. The department head is now the existing Orialis `运营组长`; `GitHub情报组` (运营组长 + existing `GitHub 资讯整理组员`) and `项目汇报组` (existing `秘书`) were added under that department and linked to `运营支持`. The Secretary was added as a non-project-lead member. These changes were made through the ready improvement-teams plugin actions and then read back from the Paperclip API. Exact object IDs and before/after membership are in `news/evidence/paperclip-organization-readback-2026-10-02.json`.

Four routines were created and read back with schedule triggers **disabled**: AIHOT refresh every 5 minutes, GitHub Daily (18:00 Asia/Shanghai), GitHub Weekly (Monday 18:15), and Projects Daily (19:00). They are assigned within Orialis to the dedicated process collector, existing GitHub researcher, or Secretary. The new `AIHOT 资讯采集器` uses only `python3 scripts/news_sources.py --refresh aihot`, reports to the existing Operations lead, and is scoped to the Orialis repository and project. Its refresh-state path is under that repository; its config has no publisher token or bound publisher identity, and the API readback redacts environment values. Paperclip's process adapter environment test passed for the configured command and workspace. The AIHOT routine description forbids manual execution until production publisher credentials and server readiness are configured and verified. No routine was manually run and no production publish occurred. Current IDs, assignees, schedules, disabled-state readback, process environment test, and the human-readable draft/config are in `news/evidence/paperclip-routines-readback-2026-10-02.json` and `news/evidence/paperclip-aihot-agent-hire-draft-2026-10-02.json`.

`integrations/news/nagi_runner.py` is a reusable one-shot wrapper for the already tested Nagi route. It forwards one stdin prompt to the existing remote Codex CLI using `--ephemeral --sandbox read-only`, opens one SSH reverse-forward to the local proxy only for that process, performs no retry that could duplicate a model call, and makes no persistent proxy or login changes. A real source-fact-only JSON probe completed through the wrapper and matched its supplied facts exactly; the raw invocation evidence is `news/evidence/nagi-runner-probe-2026-10-02.json`. This establishes that the wrapper works once, not that a long-running Paperclip worker has durable egress. The isolated API daily publish/readback check does not certify production publisher credentials or deployment. Keep all three routine triggers disabled until production publisher/server readiness and the approved durable worker route are verified.

News remains a feature of the existing Orialis computer application; this operations work does not create a separate Mac news app.

## Local checks and limitations

Mock/fault checks are in `integrations/news/tests/test_pipeline.py`. The 2026-10-02 Nagi evidence proves one real grounded analysis and JSON output without publishing; it does not prove persistent worker egress, publisher credentials, report feeds, or News API readiness. A Paperclip routine apply is not evidence that its assigned host command, runner login, publisher credentials, report feeds, or News API are ready; verify those at the Paperclip run/API readback before enabling a schedule.


## AIHot / GitHub realtime invalidation — 2026-10-03

`GET /api/v1/news/stream` requires the same Session authentication as News reads.
It returns SSE `news.updated` with `id=<revision>` and
`data={"channels":["aihot","github","projects"],"revision":"<revision>"}`.
The revision hashes persisted public cache metadata plus only the authenticated
user's project-report metadata. It includes failure/recovery state, contains no
article or project-report body, and survives process restart. The server checks
metadata and session validity every second, sends a 15-second keepalive, and sets
`X-Accel-Buffering: no`. Use the explicit SSE proxy location in the nginx template.

A new connection receives the current revision; a matching `Last-Event-ID`
suppresses a duplicate invalidation. After missed updates, the client fetches the
latest complete channel snapshots. This endpoint reconciles current state; it is
not a historical per-article event log. Publication continues to use the existing
cache/API contracts and requires no additional migration.

Visible News requests now listen to SSE and reload their published snapshots,
with 30-second polling for an older server or transient failure. Reconnect uses
bounded backoff and the last revision. Backgrounding cancels the subscription;
foregrounding reloads. Account/server changes clear displayed data before
reloading, and cancelled or obsolete responses cannot replace current content.
These are in-app updates. OS background notification delivery remains separate.

The collector accepts `ORIALIS_NEWS_PUBLISHER_USER_ID` (legacy
`ORIALIS_AGENT_USER_ID` remains a fallback). Each AIHot dataset fails independently;
empty or invalid data does not overwrite a previous cache. In `all` mode a failed
channel does not prevent collecting healthy channels, but the overall exit status
still reports failure. GitHub empty source rankings cannot trigger analysis or
publication. Use `integrations/news/local-worker.env.example` for the existing
local Codex Runner without overriding model/login settings. The historical Nagi
absolute executable path is no longer present and must not be treated as ready.

Verification commands: `cargo test -p orialis-server --bin orialis-server news::tests`,
`python3 -m unittest discover -s integrations/news/tests`, and
`python3 scripts/verify-news-realtime.py --sources <reviewed-source-facts.json>`.
The HTTP verifier creates a disposable local database, checks two live SSE
clients, publishes both periods, verifies ranking/brief readback, and restarts the
service to check persisted recovery. It never calls production.


For separate deterministic GitHub workers, pass `--github-daily-agent-id` and
`--github-weekly-agent-id` to `integrations.news.paperclip_setup`. The legacy
`--github-agent-id` remains supported for a shared Runner. Process workers must
match their exact period and include `--publish`; mismatches are rejected before
API writes. Existing routine assignments require an explicit reviewed reassignment
before setup can enable triggers. The three-channel rollout draft does not touch
the Projects schedule or change the existing Hermes researcher's role.
