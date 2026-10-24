"""Windowless Windows task runner; one summary per run, no per-file tracing."""
from pathlib import Path
import datetime
import os
import runpy
import sys
import time
import traceback

root = Path(__file__).resolve().parent
logpath = root / "sync.log"
if logpath.exists() and logpath.stat().st_size > 2 * 1024 * 1024:
    os.replace(logpath, root / "sync.previous.log")

with logpath.open("a", encoding="utf-8", buffering=1) as log:
    sys.stdout = sys.stderr = log
    started = time.monotonic()
    print(datetime.datetime.now().isoformat(timespec="seconds"), "sync start", os.getpid())
    code = 0
    try:
        sys.argv[0] = str(root / "profile_sync.py")
        runpy.run_path(sys.argv[0], run_name="__main__")
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else (0 if exc.code is None else 1)
    except Exception:
        traceback.print_exc()
        code = 1
    print(datetime.datetime.now().isoformat(timespec="seconds"), "sync exit", code,
          "seconds", round(time.monotonic() - started, 3))
raise SystemExit(code)
