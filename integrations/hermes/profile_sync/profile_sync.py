#!/usr/bin/env python3
"""Sync Hermes skills, curated memories and SOUL; execution stays on each device.

The SSH hub stores content-addressed versions. Every client compares its live
files with the last applied version, so an offline client cannot resurrect a
deletion. Conflicting edits keep both originals and never install conflict text.
Only the Python standard library is needed; git merge-file merges text edits.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

MEMORIES = {"memories/MEMORY.md", "memories/USER.md"}
SKIP_DIRS = {"node_modules", "__pycache__", "venv", "env"}
SKIP_SUFFIXES = {".pyc", ".pyo", ".lock", ".bak", ".tmp"}
MAX_REQUEST = 128 * 1024 * 1024


def stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalize(data):
    if b"\0" not in data:
        try:
            return data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
        except UnicodeDecodeError:
            pass
    return data


def allowed(path):
    if not isinstance(path, str) or "\\" in path or ":" in path:
        return False
    parts = PurePosixPath(path).parts
    if not parts or any(p in (".", "..") or p.startswith(".") for p in parts):
        return False
    if PurePosixPath(path).is_absolute() or str(PurePosixPath(path)) != path:
        return False
    if any(ord(c) < 32 for c in path):
        return False
    return path == "SOUL.md" or path in MEMORIES or (
        len(parts) > 1 and parts[0] == "skills" and
        not any(p in SKIP_DIRS for p in parts) and PurePosixPath(path).suffix not in SKIP_SUFFIXES)


def validate_paths(paths):
    seen = {}
    for path in paths:
        if not allowed(path):
            raise ValueError("Outside sync scope: " + str(path))
        folded = path.casefold()
        if folded in seen and seen[folded] != path:
            raise ValueError("Cross-platform filename collision: " + path)
        seen[folded] = path
    for folded, path in seen.items():
        if any(str(p) in seen for p in PurePosixPath(folded).parents if str(p) != "."):
            raise ValueError("File/directory collision: " + path)


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".sync_", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def json_read(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def json_write(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8"))


@contextlib.contextmanager
def file_lock(path, blocking=True):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if os.name == "nt":
            import msvcrt
            if os.fstat(fd).st_size == 0:
                os.write(fd, b"\0")
            os.lseek(fd, 0, 0)
            msvcrt.locking(fd, msvcrt.LK_LOCK if blocking else msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
    finally:
        os.close(fd)


def linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def link_target(path):
    target = os.readlink(path)
    if os.name == "nt" and target.startswith("\\\\?\\"):
        target = target[4:]
    p = Path(target)
    return p if p.is_absolute() else path.parent / p


def dereference(path):
    seen = set()
    while linked(path):
        key = os.path.normcase(os.path.abspath(path))
        if key in seen:
            raise ValueError("Cyclic skill link: " + str(path))
        seen.add(key)
        path = link_target(path)
    return path


def scan(profile):
    profile = Path(profile)
    if not profile.is_dir():
        raise ValueError("Missing Hermes profile: " + str(profile))
    contents = {}

    def visit(physical, rel, ancestors):
        if not allowed(rel) and rel != "skills":
            return
        physical = dereference(physical)
        key = os.path.normcase(os.path.abspath(physical))
        if key in ancestors:
            raise ValueError("Cyclic skill link: " + rel)
        if physical.is_dir():
            for entry in sorted(physical.iterdir(), key=lambda x: x.name):
                visit(entry, rel + "/" + entry.name, ancestors | {key})
        elif physical.is_file():
            contents[rel] = normalize(physical.read_bytes())
        else:
            raise ValueError("Unreadable sync file/link: " + str(physical))

    for rel in ["SOUL.md", "memories/MEMORY.md", "memories/USER.md", "skills"]:
        path = profile / rel
        if path.exists() or linked(path):
            visit(path, rel, set())
    validate_paths(contents)
    return contents


def manifest(contents):
    return {p: digest(b) for p, b in contents.items()}


def read_one(profile, rel):
    path = Path(profile)
    for part in PurePosixPath(rel).parts:
        path = path / part
        path = dereference(path)
    try:
        return normalize(path.read_bytes())
    except FileNotFoundError:
        return None


def blob_path(store, sha):
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        raise ValueError("Invalid content hash")
    return Path(store) / "objects" / sha


def put_blob(store, data):
    sha = digest(data)
    p = blob_path(store, sha)
    if not p.exists():
        atomic(p, data)
    return sha


def get_blob(store, sha):
    return blob_path(store, sha).read_bytes() if sha else b""


def memory_merge(base, ours, theirs):
    def entries(data):
        return list(dict.fromkeys(e.strip() for e in data.decode("utf-8").split("\n§\n") if e.strip()))
    b, o, t = entries(base), entries(ours), entries(theirs)
    removed = (set(b) - set(o)) | (set(b) - set(t))
    return "\n§\n".join(dict.fromkeys(e for e in b + t + o if e not in removed)).encode("utf-8")


def merge_content(path, base, ours, theirs):
    if path in MEMORIES:
        return memory_merge(base or b"", ours, theirs)
    if b"\0" in ours or b"\0" in theirs:
        return None
    try:
        ours.decode("utf-8")
        theirs.decode("utf-8")
        with tempfile.TemporaryDirectory(prefix="hermes_sync_merge_") as d:
            paths = [Path(d) / n for n in ("ours", "base", "theirs")]
            for p, data in zip(paths, (ours, base or b"", theirs)):
                p.write_bytes(data)
            proc = subprocess.run(["git", "merge-file", "-p", *map(str, paths)], capture_output=True, timeout=15)
            return proc.stdout if proc.returncode == 0 else None
    except (UnicodeError, OSError):
        return None


def exchange(store, request):
    store = Path(store)
    store.mkdir(parents=True, exist_ok=True)
    os.chmod(store, 0o700)
    with file_lock(store / "hub.lock"):
        state = json_read(store / "hub.json")
        if state is None:
            state = {"hub_id": str(uuid.uuid4()), "files": {}, "revision": 0}
        if request.get("hub_id") and request["hub_id"] != state["hub_id"]:
            raise ValueError("Hub identity changed; refusing to replace local files")
        base, live = request["base"], request["live"]
        validate_paths(set(base) | set(live) | set(state["files"]))
        for sha in list(base.values()) + list(live.values()):
            blob_path(store, sha)
        # Every newly observed version is retained even if a later merge conflicts.
        for p, encoded in request.get("payload", {}).items():
            if p not in live:
                raise ValueError("Unrequested payload")
            data = base64.b64decode(encoded, validate=True)
            if digest(data) != live[p]:
                raise ValueError("Content hash mismatch: " + p)
            put_blob(store, data)
        for sha in live.values():
            if not blob_path(store, sha).is_file():
                raise ValueError("Missing content object; resnapshot required")
        result = dict(state["files"])
        conflicts = []
        for p in sorted(set(base) | set(live) | set(result)):
            b, o, t = base.get(p), live.get(p), result.get(p)
            if o == b:
                continue
            if t == b or o == t:
                chosen = o
            elif o is not None and t is not None:
                merged = merge_content(p, get_blob(store, b), get_blob(store, o), get_blob(store, t))
                chosen = put_blob(store, merged) if merged is not None else None
                if merged is None:
                    conflicts.append(p)
                    continue
            else:
                conflicts.append(p)
                continue
            limit = state.get("memory_limits", {}).get(p)
            if chosen and limit and len(get_blob(store, chosen).decode("utf-8")) > limit:
                conflicts.append(p)
                continue
            if chosen is None:
                result.pop(p, None)
            else:
                result[p] = chosen
        validate_paths(result)
        if result != state["files"]:
            json_write(store / "history" / (stamp() + ".json"), state)
            state = {**state, "files": result, "revision": state["revision"] + 1}
        json_write(store / "hub.json", state)
        if conflicts:
            json_write(store / "conflicts" / (request["node"] + ".json"), {
                "time": stamp(), "base": base, "local": live, "hub": result, "paths": conflicts})
        else:
            (store / "conflicts" / (request["node"] + ".json")).unlink(missing_ok=True)
        changes = {p: (base64.b64encode(get_blob(store, result[p])).decode() if p in result else None)
                   for p in set(live) | set(result) if live.get(p) != result.get(p) and p not in conflicts}
        json_write(store / "nodes" / (request["node"] + ".json"), {
            "time": stamp(), "revision": state["revision"], "live": live, "conflicts": conflicts})
        return {"hub_id": state["hub_id"], "revision": state["revision"],
                "files": result, "changes": changes, "conflicts": conflicts}


def materialize(profile, rel, contents, backup):
    """Break profile skill links before writing; never modify a shared skill library."""
    current = Path(profile)
    prefix = []
    for part in PurePosixPath(rel).parts:
        current = current / part
        prefix.append(part)
        if not linked(current):
            continue
        vpath = "/".join(prefix)
        if prefix[0] != "skills":
            raise ValueError("Refusing to replace linked identity/memory file: " + rel)
        dst = Path(backup) / "links" / vpath
        dst.parent.mkdir(parents=True, exist_ok=True)
        json_write(dst.with_name(dst.name + ".link.json"), {"target": os.readlink(current)})
        os.replace(current, dst)
        children = {p: b for p, b in contents.items() if p == vpath or p.startswith(vpath + "/")}
        if vpath not in children:
            current.mkdir(parents=True, exist_ok=True)
        for p, b in children.items():
            atomic(Path(profile) / p, b, 0o700 if b.startswith(b"#!") else 0o600)


def run_sync(config):
    profile, local = Path(config["profile"]), Path(config["state_dir"])
    local.mkdir(parents=True, exist_ok=True)
    os.chmod(local, 0o700)
    with file_lock(local / "run.lock", blocking=False):
        previous = json_read(local / "client.json", {"base": {}})
        contents = scan(profile)
        live = manifest(contents)
        base = previous["base"]
        # Send changed objects; force_payload repairs an interrupted initial bootstrap.
        payload = {p: base64.b64encode(b).decode() for p, b in contents.items()
                   if live[p] != base.get(p) or config.get("force_payload")}
        request = {"node": config["node"], "hub_id": previous.get("hub_id"),
                   "base": base, "live": live, "payload": payload}
        if config.get("hub_store"):
            response = exchange(config["hub_store"], request)
        else:
            creation = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
            proc = subprocess.run(config["ssh"], input=(json.dumps(request) + "\n").encode("utf-8"),
                                  capture_output=True, timeout=600, **creation)
            if proc.returncode:
                raise RuntimeError("SSH exchange failed: " + proc.stderr.decode(errors="replace")[-700:])
            response = json.loads(proc.stdout)
            if "error" in response:
                raise RuntimeError(response["error"])
        validate_paths(set(response["files"]) | set(response["changes"]))
        backup = local / "backups" / stamp()
        conflicts = list(response["conflicts"])
        applied = 0
        next_base = dict(base)
        for p in sorted(set(live) | set(response["files"]) | set(base)):
            if p in conflicts:
                continue
            desired = response["files"].get(p)
            if p in response["changes"]:
                data = response["changes"][p]
                decoded = base64.b64decode(data, validate=True) if data is not None else None
                if decoded is not None and digest(decoded) != desired:
                    raise ValueError("Invalid hub response for " + p)
                path = profile / p
                # Hermes' own MemoryStore uses the same separate .md.lock file.
                lock = file_lock(path.with_suffix(path.suffix + ".lock")) if p in MEMORIES else contextlib.nullcontext()
                with lock:
                    current = read_one(profile, p)
                    if (digest(current) if current is not None else None) != live.get(p):
                        conflicts.append(p)
                        continue
                    if current is not None:
                        atomic(backup / "files" / p, current)
                    if any(linked(profile.joinpath(*PurePosixPath(p).parts[:i])) for i in range(1, len(PurePosixPath(p).parts) + 1)):
                        contents = scan(profile)
                    materialize(profile, p, contents, backup)
                    if decoded is None:
                        path.unlink(missing_ok=True)
                    else:
                        executable = decoded.startswith(b"#!") or (path.exists() and bool(path.stat().st_mode & 0o111))
                        atomic(path, decoded, 0o700 if executable else 0o600)
                    applied += 1
            if desired is None:
                next_base.pop(p, None)
            else:
                next_base[p] = desired
        status = {"time": stamp(), "node": config["node"], "hub_id": response["hub_id"],
                  "revision": response["revision"], "base": next_base, "conflicts": sorted(set(conflicts))}
        json_write(local / "client.json", status)
        json_write(local / "status.json", {k: v for k, v in status.items() if k != "base"})
        if conflicts:
            json_write(local / "conflicts.json", {"time": stamp(), "paths": sorted(set(conflicts)),
                       "local": live, "hub": response["files"]})
        else:
            (local / "conflicts.json").unlink(missing_ok=True)
        print(json.dumps({"node": config["node"], "revision": response["revision"],
                          "files": len(next_base), "applied": applied, "conflicts": sorted(set(conflicts))}))
        return 2 if conflicts else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    client = sub.add_parser("sync")
    client.add_argument("--config", required=True)
    hub = sub.add_parser("hub")
    hub.add_argument("--store", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        if args.command == "hub":
            # A frame lets the hub reply without waiting for SSH stdin to close.
            raw = sys.stdin.buffer.readline(MAX_REQUEST + 1)
            if len(raw) > MAX_REQUEST:
                raise ValueError("Sync request exceeds size limit")
            request = json.loads(raw)
            if not isinstance(request.get("node"), str) or not request["node"].replace("-", "").replace("_", "").isalnum():
                raise ValueError("Invalid node name")
            print(json.dumps(exchange(args.store, request)))
        elif args.command == "snapshot":
            contents = scan(args.profile)
            print(json.dumps({"files": manifest(contents),
                              "payload": {p: base64.b64encode(b).decode() for p, b in contents.items()}}))
        else:
            return run_sync(json_read(args.config))
        return 0
    except Exception as exc:
        message = str(exc)
        if args.command == "hub":
            print(json.dumps({"error": message}))
        else:
            if args.command == "sync":
                config = json_read(args.config, {})
                if config.get("state_dir"):
                    json_write(Path(config["state_dir"]) / "status.json", {"time": stamp(), "error": message})
            print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
