"""CLI for pairing and keeping a local or remote generic Node online."""

from __future__ import annotations

import argparse
import json
import os
import signal
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .http import HttpTransport, HttpTransportError
from .multidevice import ContractError, MultiDeviceClient


class CredentialStore:
    """Atomic, owner-only storage for pending pairing secrets and node credentials."""

    def __init__(self, path: Path):
        self.path = path.expanduser()

    def read(self) -> dict[str, Any]:
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            return {}
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise RuntimeError("credential file must be a regular non-symlink file")
        if os.name != "nt":
            if info.st_uid != os.getuid():
                raise RuntimeError("credential file must be owned by the current user")
            if info.st_mode & 0o077:
                raise RuntimeError("credential file permissions are too broad; run chmod 600 on it")
            parent_info = self.path.parent.lstat()
            if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
                raise RuntimeError("credential directory must be a regular non-symlink directory")
            if parent_info.st_uid != os.getuid():
                raise RuntimeError("credential directory must be owned by the current user")
            if parent_info.st_mode & 0o077:
                raise RuntimeError("credential directory permissions are too broad; use a private directory")
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise RuntimeError("credential file is unreadable or malformed") from None
        if not isinstance(data, dict):
            raise RuntimeError("credential file must contain a JSON object")
        return data

    def write(self, data: dict[str, Any]) -> None:
        parent = self.path.parent
        missing = []
        cursor = parent
        while not cursor.exists():
            missing.append(cursor)
            cursor = cursor.parent
        for directory in reversed(missing):
            directory.mkdir(mode=0o700)
        if os.name != "nt":
            parent_info = parent.lstat()
            if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
                raise RuntimeError("credential directory must be a regular non-symlink directory")
            if parent_info.st_uid != os.getuid():
                raise RuntimeError("credential directory must be owned by the current user")
            if parent_info.st_mode & 0o077:
                raise RuntimeError("credential directory permissions are too broad; use a private directory")
        try:
            existing = self.path.lstat()
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode):
                raise RuntimeError("credential file must be a regular non-symlink file")
            if os.name != "nt" and existing.st_uid != os.getuid():
                raise RuntimeError("credential file must be owned by the current user")
        fd, temp_name = tempfile.mkstemp(prefix=".orialis-node-", dir=parent)
        try:
            if os.name != "nt":
                os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_name, self.path)
        except BaseException:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise


def _identity(args) -> dict[str, str]:
    return {"displayName": args.name, "platform": args.platform, "nodeVersion": args.node_version}


def _client(args, *, token: str | None = None, scheme: str = "Session", base_url_override: str | None = None) -> MultiDeviceClient:
    if base_url_override:
        if args.base_url and _normalized_service_url(args.base_url) != _normalized_service_url(base_url_override):
            raise RuntimeError("this pairing credential belongs to a different service; pair this node with the requested service first")
        # Persisted pairing secrets and Node credentials always stay pinned to
        # their original service; an ambient environment variable cannot redirect them.
        base_url = base_url_override
    else:
        base_url = args.base_url or os.environ.get("ORIALIS_BASE_URL")
    if not base_url:
        raise RuntimeError("set ORIALIS_BASE_URL or pass --base-url")
    return MultiDeviceClient(HttpTransport(base_url, token=token, auth_scheme=scheme, timeout=args.timeout))


def _pinned_client(args, record: dict[str, Any], *, token: str) -> MultiDeviceClient:
    base_url = record.get("baseUrl")
    if not isinstance(base_url, str) or not base_url.strip():
        raise RuntimeError("credential store is missing its pinned service URL; pair this node again")
    return _client(args, token=token, scheme="Node", base_url_override=base_url)


def _normalized_service_url(value: str) -> tuple[str, str, str, int | None]:
    parsed = urlsplit(value.rstrip("/"))
    scheme = parsed.scheme.lower()
    host = (parsed.hostname or "").lower()
    port = parsed.port
    if (scheme, port) in {("http", 80), ("https", 443)}:
        port = None
    return scheme, host, parsed.path.rstrip("/"), port


def _session_client(args) -> MultiDeviceClient:
    token = os.environ.get("ORIALIS_SESSION_TOKEN")
    if not token:
        raise RuntimeError("set ORIALIS_SESSION_TOKEN for account operations")
    return _client(args, token=token)


def _node_store(args) -> CredentialStore:
    return CredentialStore(Path(args.store))


def _emit(value: Any) -> None:
    # Callers only pass explicitly selected non-secret response fields.
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def run(args) -> int:
    store = _node_store(args)
    if args.command == "pair-start":
        client = _client(args)
        client.require_server_support()
        identity = _identity(args)
        response = client.start_pairing(identity)
        store.write({"baseUrl": args.base_url or os.environ.get("ORIALIS_BASE_URL"),
                     "identity": identity, "pairingId": response["pairingId"],
                     "pairingSecret": response["pairingSecret"], "expiresAt": response["expiresAt"]})
        _emit({"pairingId": response["pairingId"], "confirmationCode": response["confirmationCode"],
               "targetNode": response["targetNode"], "expiresAt": response["expiresAt"],
               "savedTo": str(store.path)})
        return 0
    if args.command == "pair-confirm":
        client = _session_client(args)
        client.require_server_support()
        result = client.confirm_pairing(args.pairing_id, args.code, args.decision)
        _emit({"pairingId": result["pairingId"], "status": result["status"], "expiresAt": result.get("expiresAt")})
        return 0
    if args.command == "pair-complete":
        pending = store.read()
        required = ("pairingId", "pairingSecret", "identity")
        if any(not pending.get(k) for k in required):
            raise RuntimeError("no pending pairing found in the credential store")
        base_url = pending.get("baseUrl")
        if not isinstance(base_url, str) or not base_url.strip():
            raise RuntimeError("pending pairing is missing its pinned service URL; start pairing again")
        client = _client(args, base_url_override=base_url)
        client.require_server_support()
        result = client.complete_pairing(pending["pairingId"], pending["pairingSecret"], pending["identity"])
        store.write({"baseUrl": pending.get("baseUrl"), "identity": pending["identity"],
                     "deviceId": result["deviceId"], "deviceCredential": result["deviceCredential"]})
        _emit({"deviceId": result["deviceId"], "accountId": result["accountId"], "status": "paired",
               "credentialSavedTo": str(store.path)})
        return 0
    if args.command in {"heartbeat", "run"}:
        node = store.read()
        if not node.get("deviceId") or not node.get("deviceCredential"):
            raise RuntimeError("node is not paired; run pair-start, confirm in an account session, then pair-complete")
        client = _pinned_client(args, node, token=node["deviceCredential"])
        if args.command == "heartbeat":
            result = client.heartbeat(node["deviceId"])
            if result.get("deviceId") != node["deviceId"]:
                raise ContractError("heartbeat response deviceId does not match this node")
            _emit({"deviceId": node["deviceId"], "status": result.get("status"),
                   "lastSeenAt": result.get("lastSeenAt"), "observedAt": result.get("observedAt")})
            return 0
        stopped = False
        def stop(_signum, _frame):
            nonlocal stopped
            stopped = True
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        next_heartbeat = time.monotonic()
        while not stopped:
            delay = next_heartbeat - time.monotonic()
            while delay > 0 and not stopped:
                time.sleep(min(delay, 0.1))
                delay = next_heartbeat - time.monotonic()
            if stopped:
                break
            attempt_started = time.monotonic()
            try:
                result = client.heartbeat(node["deviceId"])
                if result.get("deviceId") != node["deviceId"]:
                    raise ContractError("heartbeat response deviceId does not match this node")
                _emit({"deviceId": node["deviceId"], "status": result.get("status"),
                       "observedAt": result.get("observedAt")})
            except HttpTransportError as exc:
                if not exc.retryable:
                    raise
                _emit({"deviceId": node["deviceId"], "status": "retrying",
                       "error": exc.code, "retryInSeconds": 10})
            next_heartbeat = max(next_heartbeat + 10.0, attempt_started + 10.0)
        return 0
    if args.command in {"nodes", "events", "revoke"}:
        client = _session_client(args)
        client.require_server_support()
        if args.command == "nodes":
            _emit(client.list_devices(cursor=args.cursor, limit=args.limit))
        elif args.command == "events":
            _emit(client.events(after=args.after, limit=args.limit))
        else:
            result = client.revoke_device(args.device_id)
            _emit({"deviceId": result.get("deviceId", args.device_id), "status": result.get("status"),
                   "revocationVersion": result.get("revocationVersion")})
        return 0
    if args.command in {"node-info", "node-capabilities"}:
        node = store.read()
        if not node.get("deviceId") or not node.get("deviceCredential"):
            raise RuntimeError("node is not paired")
        client = _pinned_client(args, node, token=node["deviceCredential"])
        client.require_server_support()
        if args.command == "node-info":
            result = client.get_device(node["deviceId"])
            _emit({key: result.get(key) for key in ("protocolVersion", "deviceId", "displayName", "platform", "nodeVersion", "status", "observedAt", "revocationVersion")})
        else:
            result = client.get_capabilities(node["deviceId"])
            _emit(result)
        return 0
    raise RuntimeError("unknown command")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="orialis-node", description="Pair and run an Orialis multi-device node")
    p.add_argument("--base-url", help="Orialis service URL (or ORIALIS_BASE_URL)")
    p.add_argument("--store", default="~/.orialis/node-credentials.json", help="private local credential store")
    p.add_argument("--timeout", type=float, default=8.0, help="per-request timeout in seconds")
    sub = p.add_subparsers(dest="command", required=True)
    start = sub.add_parser("pair-start", help="create a node pairing challenge")
    start.add_argument("--name", required=True)
    start.add_argument("--platform", required=True)
    start.add_argument("--node-version", default="1.0.0")
    confirm = sub.add_parser("pair-confirm", help="confirm or reject from a logged-in account")
    confirm.add_argument("pairing_id")
    confirm.add_argument("--code", required=True)
    confirm.add_argument("--decision", choices=("confirm", "reject"), required=True)
    sub.add_parser("pair-complete", help="exchange the approved one-time pairing secret")
    sub.add_parser("heartbeat", help="send one authenticated Node heartbeat")
    sub.add_parser("run", help="keep this Node online with a 10-second heartbeat")
    sub.add_parser("node-info", help="read this Node's own configuration")
    sub.add_parser("node-capabilities", help="read this Node's own capabilities and grants")
    nodes = sub.add_parser("nodes", help="list account nodes")
    nodes.add_argument("--cursor")
    nodes.add_argument("--limit", type=int)
    events = sub.add_parser("events", help="read account events")
    events.add_argument("--after")
    events.add_argument("--limit", type=int)
    revoke = sub.add_parser("revoke", help="revoke a node from an account session")
    revoke.add_argument("device_id")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run(args)
    except (RuntimeError, ValueError, ContractError, HttpTransportError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
