"""Run one read-only Codex CLI request on Nagi over a short-lived SSH tunnel.

The local proxy is forwarded only for this invocation. No proxy or login
configuration is written on either machine. The caller supplies one prompt on
stdin; stdout is the remote Codex JSON event stream.
"""
from __future__ import annotations

import argparse
import secrets
import shlex
import subprocess
import sys


DEFAULT_HOST = "nagi.jxcz.top"
DEFAULT_PROXY_HOST = "127.0.0.1"
DEFAULT_PROXY_PORT = 7890
DEFAULT_CODEX = "/home/JXCZ/.local/bin/codex"


def build_ssh_args(*, host: str, remote_port: int, proxy_host: str,
                   proxy_port: int, codex_path: str, model: str | None = None) -> list[str]:
    remote = [
        "env",
        f"HTTPS_PROXY=http://127.0.0.1:{remote_port}",
        f"HTTP_PROXY=http://127.0.0.1:{remote_port}",
        codex_path,
        "exec", "--ephemeral", "--sandbox", "read-only",
        "--skip-git-repo-check",
    ]
    if model:
        remote.extend(["--model", model])
    remote.extend(["--json", "-"])
    return [
        "ssh", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
        "-R", f"127.0.0.1:{remote_port}:{proxy_host}:{proxy_port}",
        host, shlex.join(remote),
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--proxy-host", default=DEFAULT_PROXY_HOST)
    parser.add_argument("--proxy-port", type=int, default=DEFAULT_PROXY_PORT)
    parser.add_argument("--codex-path", default=DEFAULT_CODEX)
    parser.add_argument("--model", help="optional override; omitted uses the remote Codex configuration")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args(argv)
    if args.timeout <= 0 or not (1 <= args.proxy_port <= 65535):
        parser.error("timeout and proxy port must be positive valid values")
    if sys.stdin.isatty():
        parser.error("provide exactly one prompt on stdin")
    # No retry: once SSH starts, a lost response must not silently repeat a
    # potentially billable model call. The tunnel dies with this SSH process.
    remote_port = secrets.randbelow(30000) + 30000
    command = build_ssh_args(
        host=args.host, remote_port=remote_port, proxy_host=args.proxy_host,
        proxy_port=args.proxy_port, codex_path=args.codex_path, model=args.model,
    )
    prompt = sys.stdin.buffer.read()
    if not prompt.strip():
        parser.error("prompt on stdin is empty")
    try:
        result = subprocess.run(command, input=prompt, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=args.timeout,
                                check=False)
    except FileNotFoundError:
        print("nagi runner requires ssh in PATH", file=sys.stderr)
        return 127
    except subprocess.TimeoutExpired:
        print(f"nagi runner timed out after {args.timeout}s; SSH tunnel closed", file=sys.stderr)
        return 124
    sys.stdout.buffer.write(result.stdout)
    sys.stdout.buffer.flush()
    if result.returncode:
        # Keep stderr out of the result stream: SSH/Codex diagnostics can
        # include machine-local details. The exit status remains actionable.
        print(f"nagi runner exited with status {result.returncode}", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
