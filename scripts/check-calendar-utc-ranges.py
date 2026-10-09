#!/usr/bin/env python3
"""Read-only preflight for migration 0018; never repair or remove legacy rows."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sqlite3
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    args = parser.parse_args()
    migration = (Path(__file__).resolve().parents[1] / "orialis-server" / "migrations"
                 / "0018_calendar_utc_range.sql").read_text(encoding="utf-8")
    match = re.search(
        r"-- BEGIN CALENDAR_UTC_RANGE_CHECK\s+"
        r"CONSTRAINT calendar_events_utc_range CHECK \((.*?)\),\s+"
        r"-- END CALENDAR_UTC_RANGE_CHECK", migration, re.DOTALL,
    )
    if match is None:
        print("Cannot locate the exact migration CHECK; refusing a partial preflight.", file=sys.stderr)
        return 2
    try:
        with sqlite3.connect(args.database.resolve().as_uri() + "?mode=ro", uri=True) as db:
            db.execute("PRAGMA query_only=ON")
            invalid = db.execute(
                "SELECT id FROM calendar_events WHERE NOT (" + match.group(1) + ") ORDER BY id"
            ).fetchall()
            print(f"Read-only calendar preflight (SQLite {sqlite3.sqlite_version})")
    except sqlite3.Error as error:
        print(f"Preflight could not complete: {error}", file=sys.stderr)
        return 2
    if invalid:
        print(f"BLOCKED: {len(invalid)} existing calendar row(s) fail migration 0018.")
        for (event_id,) in invalid:
            print(f"  {event_id!r}")
        print("No data changed. Review timestamp syntax and instant ordering before deployment.")
        return 1
    print("PASS: all existing calendar rows satisfy the exact migration CHECK. No data changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
