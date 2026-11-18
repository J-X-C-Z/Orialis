"""Small cell runner. Rust owns isolation, approval, quotas and lifecycle.

This is not an in-Python security boundary: code can inspect or corrupt this
protocol. The Rust side fences every request, pauses the owned process before
callbacks/completion and validates its own authority independently.
"""
import io
import json
import os
import shlex
import sys
import time
import traceback
import types

_wire = os.fdopen(os.dup(1), "wb", buffering=0)
_input = sys.stdin.buffer
# Ordinary and raw stdout share this pipe; random sentinel frames are parsed by
# Rust. Stderr remains a separate native pipe, never mixed into stdout capture.
sys.stdin = io.StringIO("")
_SENTINEL = sys.argv[2].encode()
_specs = json.loads(sys.argv[1])
_globals = {"__name__": "__main__", "__builtins__": __builtins__}
_cell = ""
_sequence = 0

def _send(value):
    body = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode()
    _wire.write(_SENTINEL + str(len(body)).encode() + b"\n" + body)

def _call(name, arguments):
    global _sequence
    _sequence += 1
    _send({"kind": "call", "id": _cell, "sequence": _sequence, "name": name, "arguments": arguments})
    response = json.loads(_input.readline())
    if response.get("id") != _cell or response.get("sequence") != _sequence:
        raise RuntimeError("Agent callback protocol lost synchronization; do not retry effects")
    return response["result"]

def _stub(name, positional):
    def call(*args, **kwargs):
        if len(args) > len(positional):
            raise TypeError("Too many positional arguments for " + name)
        for key, value in zip(positional, args):
            if key in kwargs:
                raise TypeError("Duplicate argument: " + key)
            kwargs[key] = value
        return _call(name, kwargs)
    call.__name__ = name
    return call

_tools = types.ModuleType("hermes_tools")
_tools.__file__ = "<host-authorized hermes_tools bridge>"
for _name, _positional in _specs.items():
    setattr(_tools, _name, _stub(_name, _positional))

def json_parse(text):
    return json.loads(text.lstrip("\ufeff") if isinstance(text, str) else text, strict=False)

def retry(fn, max_attempts=3, delay=2):
    if not isinstance(max_attempts, int) or not 1 <= max_attempts <= 10 or not 0 <= delay <= 60:
        raise ValueError("retry requires 1..10 attempts and 0..60 seconds delay")
    for attempt in range(max_attempts):
        try:
            return fn()
        except Exception:
            if attempt + 1 == max_attempts:
                raise
            time.sleep(delay * 2 ** attempt)

_tools.json_parse = json_parse
_tools.shell_quote = shlex.quote
_tools.retry = retry
sys.modules["hermes_tools"] = _tools
_module_records = {}
def _edited_modules(report):
    edited = []
    for name, module in list(sys.modules.items())[:4096]:
        try:
            fields = object.__getattribute__(module, "__dict__")
            path, spec = fields.get("__file__"), fields.get("__spec__")
            if not isinstance(name, str) or not isinstance(path, str) or not path.startswith("/work/") or not path.endswith(".py"):
                continue
            mtime = os.stat(path).st_mtime_ns
        except BaseException:
            continue
        seen = _module_records.get(name)
        if report and seen is not None and seen[0] != mtime and seen[1] is spec:
            edited.append(name)
        if report or seen is None or seen[1] is not spec:
            if len(_module_records) < 512 or name in _module_records:
                _module_records[name] = (mtime, spec)
    return sorted(edited)[:32]

def _scan_modules(report):
    try:
        return _edited_modules(report)
    except BaseException:
        return []

_send({"kind": "ready"})
for _line in _input:
    _request = json.loads(_line)
    _cell = _request["id"]
    _sequence = 0
    _status = "ok"
    _error = ""
    _stale = _scan_modules(True)
    try:
        exec(compile(_request["code"], "<cell>", "exec"), _globals)
    except SystemExit as exc:
        _status = "exit"
        _error = "SystemExit: " + repr(exc.code)[:2048]
    except BaseException:
        _status = "error"
        # Do not construct a multi-megabyte exception representation in the host.
        _error = traceback.format_exc()[-8192:]
    _scan_modules(False)
    sys.stdout.flush()
    sys.stderr.flush()
    _send({"kind": "complete", "id": _cell, "status": _status, "error": _error, "stale_modules": _stale})
    if _status == "exit":
        # Rust freezes and reaps this exact process after accepting the frame.
        time.sleep(3600)
