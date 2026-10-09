"""Read-only legacy-data preflight regression tests."""
from pathlib import Path
import hashlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-calendar-utc-ranges.py"


class CalendarUtcPreflightTests(unittest.TestCase):
    def test_exact_constraint_read_only_and_missing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "legacy.sqlite"
            missing = subprocess.run([sys.executable, str(SCRIPT), "--database", str(database)], capture_output=True, text=True)
            self.assertEqual(missing.returncode, 2)
            self.assertFalse(database.exists())
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE calendar_events(id TEXT, start_at TEXT, end_at TEXT)")
                db.execute("INSERT INTO calendar_events VALUES ('valid', '2026-10-09T09:00:00+08:00', '2026-10-09T02:00:00Z')")
            for expected in (0, 1):
                before = hashlib.sha256(database.read_bytes()).hexdigest()
                result = subprocess.run([sys.executable, str(SCRIPT), "--database", str(database)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(hashlib.sha256(database.read_bytes()).hexdigest(), before)
                if expected:
                    self.assertIn("'nonstandard'", result.stdout)
                    self.assertIn("'reverse'", result.stdout)
                else:
                    with sqlite3.connect(database) as db:
                        db.execute("INSERT INTO calendar_events VALUES ('nonstandard','2026-10-09T09:00:00+0800','2026-10-09T10:00:00+0800')")
                        db.execute("INSERT INTO calendar_events VALUES ('reverse','2026-10-09T09:00:00Z','2026-10-09T09:30:00+08:00')")


if __name__ == "__main__":
    unittest.main()
