#!/usr/bin/env python3
"""Run the non-voice roadmap black-box and protocol checks.

The default mode targets an already-running loopback service. ``--start-server``
uses a temporary SQLite database and upload directory, then tears the service
down when the checks finish. No repository files are changed by this runner.
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def healthy(base_url: str) -> bool:
    try:
        with urllib.request.urlopen(f"{base_url}/api/v1/health", timeout=1.0) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def start_server() -> tuple[subprocess.Popen[str], tempfile.TemporaryDirectory[str], str]:
    temp = tempfile.TemporaryDirectory(prefix="orialis-roadmap-e2e-")
    temp_root = Path(temp.name)
    port = free_port()
    base_url = f"http://127.0.0.1:{port}"
    env = os.environ.copy()
    env.update({
        "ORIALIS_HOST": "127.0.0.1",
        "ORIALIS_PORT": str(port),
        "ORIALIS_ENV": "development",
        "ORIALIS_PUBLIC_URL": base_url,
        "ORIALIS_DATABASE_URL": f"sqlite://{temp_root / 'roadmap.db'}?mode=rwc",
        "ORIALIS_UPLOAD_DIR": str(temp_root / "uploads"),
        "ORIALIS_DEV_DEVICE_AUTH": "false",
    })
    process = subprocess.Popen(
        ["cargo", "run", "-q", "-p", "orialis-server"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if healthy(base_url):
            return process, temp, base_url
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            temp.cleanup()
            raise RuntimeError(f"Orialis server exited before health check: {output[-4000:]}")
        time.sleep(0.25)
    process.terminate()
    process.wait(timeout=5)
    output = process.stdout.read() if process.stdout else ""
    temp.cleanup()
    raise RuntimeError(f"timed out starting Orialis server: {output[-4000:]}")


def run_python(base_url: str) -> int:
    env = os.environ.copy()
    env["ORIALIS_ROADMAP_BASE_URL"] = base_url
    return subprocess.call(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests/roadmap", "-t", ".", "-p", "test_*.py", "-v"],
        cwd=ROOT,
        env=env,
    )


def run_rust() -> int:
    if shutil.which("cargo") is None:
        print("SKIP Rust protocol boundary: cargo is not installed")
        return 0
    statuses = []
    for command in (
        ["cargo", "test", "-p", "orialis-server", "--no-fail-fast"],
        ["cargo", "test", "-p", "orialis-server", "--test", "agent_gateway_protocol_test", "--no-fail-fast"],
    ):
        statuses.append(subprocess.call(command, cwd=ROOT))
    return 1 if any(statuses) else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("ORIALIS_ROADMAP_BASE_URL"))
    parser.add_argument("--start-server", action="store_true")
    parser.add_argument("--skip-rust", action="store_true")
    args = parser.parse_args()

    process = None
    temp = None
    base_url = args.base_url or "http://127.0.0.1:18443"
    start_error = False
    try:
        if args.start_server:
            try:
                process, temp, base_url = start_server()
                print(f"Running live checks against temporary server {base_url}")
            except RuntimeError as error:
                start_error = True
                print(f"Live server could not start; live tests will report explicit skips: {error}")
        elif not healthy(base_url):
            print(f"Live server unavailable at {base_url}; live tests will report explicit skips")
        python_status = run_python(base_url)
        rust_status = 0 if args.skip_rust else run_rust()
        return 1 if start_error or python_status or rust_status else 0
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if temp is not None:
            temp.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
