# Calendar instant-range validation (migration 0018)

The HTTP API and SQLite now compare calendar start/end instants rather than the
lexical order of their timestamp strings. Mixed-offset valid ranges no longer
fail the historical range CHECK. Equal instants remain accepted.

## Compatibility boundary

- Timestamp strings are stored and returned unchanged. Existing list ordering,
  range filtering, indexes and version-1 cursors remain lexical; this change does
  **not** normalize UTC storage or repair chronological pagination.
- Inputs use four-digit-year RFC 3339 syntax, ASCII numeric offsets through
  `±23:59`, `T`/`t`/space separators, and `Z`/`z`. Leap-second representation
  follows chrono; it does not independently verify an IERS leap-second table.
- Fractional seconds retain every supplied digit. Nanoseconds and longer
  fractions are compared exactly; trailing zeros denote equal fractions.
- Previously accidental acceptance of expanded/signed years, unpadded fields,
  compact offsets, surrounding whitespace and Unicode minus signs is removed.
  These inputs return HTTP 400. Subnanosecond reversed ranges also return 400
  instead of passing chrono's nine-digit truncation.
- No historical migration or dependency lockfile changes. Permission, version,
  transaction, idempotency, outbox and commit-before-notify paths are unchanged.

## Upgrade preflight and failure handling

Run against a backup or the intended SQLite database before starting the updated
server:

```sh
python3 scripts/check-calendar-utc-ranges.py --database /path/to/orialis.sqlite
```

This opens SQLite read-only and evaluates the exact CHECK extracted from migration
0018. Exit 0 means all rows satisfy it, 1 means deployment is blocked by listed
rows, and 2 means preflight could not complete. This is a point-in-time check;
concurrent legacy writers can introduce another offending row afterward.

Nonstandard legacy timestamps or ranges that were lexically valid but reversed
in UTC block the migration. The migration never rewrites or deletes such rows.
SQLx rolls back the complete table rebuild, both task-link triggers and its
migration record. Stop deployment, review the reported rows, and obtain an
explicit data-repair decision. Do not edit `_sqlx_migrations`, disable constraints
or replace the historical migration to bypass this block.

For compliant rows the migration copies every value unchanged, restores both
calendar indexes and both task-link triggers, and preserves foreign keys. The
range CHECK works for independent SQLite writers without a registered function;
those writers must also provide compliant timestamps and non-reversed ranges.
