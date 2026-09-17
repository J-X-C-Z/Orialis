# A01 — Task / Schedule Contract Alignment

Status: `DONE`

## Task board

| ID | Owner | Task | Dependency | Contract impact | Status | Acceptance |
|---|---|---|---|---|---|---|
| A01-INV | 总控 | Audit HEAD, current dirty diff, and publish inventory | None | Defines v1 scope | DONE | Inventory records every drift and classification |
| A01-S01 | 服务端_开发 | Align nullable priority, IDs, recurrence mapping, Schedule compatibility, and server tests | A01-INV | Server / DB / HTTP | IMPLEMENTED | New migration, no old migration edits, focused Rust tests |
| A01-M01 | 手机端_开发 | Align local Task/Schedule model and add persisted outbox | A01-INV | Mobile DB / Sync | IMPLEMENTED | Drift migration, durable mutation ID, retry and restart tests |
| A01-P01 | 插件_开发 | Audit and test Task/Schedule interpretation without inventing tools | A01-INV | Plugin validation | IMPLEMENTED | Python tests preserve null and Schedule naming |
| A01-X01 | 总控 | Cross-end fixture and compatibility verification | S01/M01/P01 | All three ends | IMPLEMENTED | Shared fixtures validate and no field is silently dropped |
| A01-R01 | 总控 | Independent acceptance and risk report | A01-X01 | Release gate | DONE | Diff, tests, migration, compatibility, and docs reviewed |

## Parallelism

`A01-S01`, `A01-M01`, and `A01-P01` may run in parallel because the A01 schema
and scope are frozen. They must stop and coordinate when discovering a shared
Contract change. `A01-X01` is serial after the three implementation reports.

The current X01 evidence is the repository contract validator, Rust fixture
tests, Hermes fixture tests, Flutter migration/outbox tests, and the full local
language test gates. R01 is closed. Production revalidation used a
compatibility build because the deployed historical 0001 migration contains a
different comment byte sequence; the repository migration and
`_sqlx_migrations` table were not modified.

## Coordination rule

Any cross-end discovery must be sent to the total-control task and the affected
peer task with:

```text
Task ID
Finding
Current Contract
Affected files / ends
Single decision needed
Migration / API impact
```

No child task may commit, push, rewrite an old migration, or change the A01
machine-readable schemas without a new total-control decision.
