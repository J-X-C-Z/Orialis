"""Explicitly configured host workspaces, never an LLM/tool-command proxy."""
from __future__ import annotations

import asyncio
import base64
import codecs
import contextlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import signal
import stat
import subprocess
import time
import uuid

FILE_LIMIT = 1024 * 1024
TEXT_LIMIT = 256 * 1024
OUTPUT_LIMIT = 256 * 1024
TERMINAL_IDLE_SECONDS = 120


class WorkspaceError(ValueError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def configured_workspaces(value):
    """JSON array of {path,name?,terminal?}; absent configuration exposes nothing."""
    if isinstance(value, str):
        value = json.loads(value) if value.strip() else []
    if not isinstance(value, list) or len(value) > 32:
        raise ValueError("workspaces must be an array of at most 32 directories")
    result = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise ValueError("each workspace requires a path")
        path = Path(item["path"]).expanduser()
        if not path.is_absolute() or not path.is_dir():
            raise ValueError("workspace path must be an existing absolute directory")
        if not isinstance(item.get("terminal", False), bool):
            raise ValueError("workspace terminal must be true or false")
        result.append({"path": path.resolve(), "name": str(item.get("name") or path.name),
                       "terminal": item.get("terminal", False)})
    return result


def _parts(value):
    if not isinstance(value, str) or len(value) > 1024 or "\\" in value or ":" in value or "\x00" in value:
        raise WorkspaceError("invalid_path", "Use a workspace-relative path")
    parts = PurePosixPath(value).parts
    if PurePosixPath(value).is_absolute() or ".." in parts:
        raise WorkspaceError("invalid_path", "Path must stay inside the selected workspace")
    return parts


def _is_link(path):
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


@contextlib.contextmanager
def _safe_path(root, relative):
    """Reject links/junctions; pin parent directories against rename on Windows."""
    parts = _parts(relative)
    path = root
    handles = []
    try:
        for index, part in enumerate((None, *parts)):
            if part is not None:
                path = path / part
            if path.exists() or path.is_symlink():
                if _is_link(path):
                    raise WorkspaceError("invalid_path", "Symbolic links and junctions are not accessible")
                if os.name == "nt" and path.is_dir():
                    import ctypes
                    from ctypes import wintypes
                    create = ctypes.WinDLL("kernel32", use_last_error=True).CreateFileW
                    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
                    create.restype = wintypes.HANDLE
                    # Do not share DELETE: no ancestor can be swapped after validation.
                    handle = create(str(path), 0, 3, None, 3, 0x02200000, None)
                    if handle == wintypes.HANDLE(-1).value:
                        raise OSError(ctypes.get_last_error(), "Unable to lock workspace directory")
                    handles.append(handle)
                    if _is_link(path):
                        raise WorkspaceError("invalid_path", "Workspace directory changed")
            elif index < len(parts):
                raise FileNotFoundError("Parent directory does not exist")
        path.resolve().relative_to(root)
        yield path
    finally:
        if handles:
            import ctypes
            from ctypes import wintypes
            close = ctypes.WinDLL("kernel32").CloseHandle
            close.argtypes = [wintypes.HANDLE]
            for handle in reversed(handles):
                close(handle)


def _file_bytes(path, limit):
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    with os.fdopen(os.open(path, flags), "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise WorkspaceError("unsupported_file", "Only regular files can be opened")
        content = source.read(limit + 1)
    if len(content) > limit:
        raise WorkspaceError("file_too_large", f"File exceeds {limit} bytes")
    return content


class WorkspaceService:
    def __init__(self, workspaces=()):
        self.workspaces = list(workspaces)
        self.terminals = {}

    def terminal_available(self, workspace):
        return workspace["terminal"] and (os.name != "nt" or importlib.util.find_spec("winpty") is not None)

    async def handle(self, conversation_id, payload):
        try:
            if not isinstance(conversation_id, str) or not conversation_id:
                raise WorkspaceError("invalid_request", "A conversation is required")
            data = await self._execute(conversation_id, payload)
            return {"ok": True, "data": data}
        except WorkspaceError as error:
            return {"ok": False, "error": {"code": error.code, "message": str(error)}}
        except (OSError, ValueError, subprocess.SubprocessError):
            # Host paths and command diagnostics may contain private locations.
            return {"ok": False, "error": {"code": "operation_failed", "message": "Workspace operation failed"}}

    async def _execute(self, conversation, payload):
        op = payload.get("op")
        client = payload.get("_clientId", "")
        if op == "capabilities":
            return {"operations": ["list", "read", "download", "upload", "diff"],
                    "maxFileBytes": FILE_LIMIT, "maxTextBytes": TEXT_LIMIT,
                    "workspaces": [{"id": f"w{i}", "name": w["name"], "terminalEnabled": self.terminal_available(w),
                                    "terminalUnavailableReason": None if self.terminal_available(w) else
                                    ("Terminal is not explicitly enabled" if not w["terminal"] else "Install pywinpty on this Hermes host")}
                                   for i, w in enumerate(self.workspaces)]}
        if op == "terminal.close_client":
            for key, terminal in list(self.terminals.items()):
                if terminal.client == client:
                    await self._close_terminal(key)
            return {}
        if op in {"terminal.read", "terminal.write", "terminal.resize", "terminal.close"}:
            key = payload.get("terminalId")
            terminal = self.terminals.get(key)
            if terminal is None or terminal.conversation != conversation or terminal.client != client:
                raise WorkspaceError("terminal_not_found", "Terminal is closed or belongs to another conversation")
            terminal.last_active = time.monotonic()
            if op == "terminal.close":
                await self._close_terminal(key)
                return {}
            if op == "terminal.read":
                return terminal.read()
            if op == "terminal.resize":
                terminal.resize(*_dimensions(payload))
            else:
                value = payload.get("input")
                if not isinstance(value, str) or len(value.encode("utf-8")) > 8192:
                    raise WorkspaceError("invalid_input", "Terminal input exceeds 8192 bytes")
                await asyncio.to_thread(terminal.write, value)
            return {}
        workspace_id = payload.get("workspaceId")
        if not isinstance(workspace_id, str) or not workspace_id.startswith("w") or not workspace_id[1:].isdigit():
            raise WorkspaceError("workspace_not_found", "Select a configured workspace")
        index = int(workspace_id[1:])
        if index >= len(self.workspaces):
            raise WorkspaceError("workspace_not_found", "Workspace is not configured")
        workspace = self.workspaces[index]
        with _safe_path(workspace["path"], payload.get("path", "")) as path:
            if op == "list":
                entries = []
                for child in path.iterdir():
                    if len(entries) >= 1000:
                        raise WorkspaceError("too_many_entries", "Directory exceeds 1000 entries")
                    if _is_link(child):
                        continue
                    info = child.stat()
                    if not stat.S_ISDIR(info.st_mode) and not stat.S_ISREG(info.st_mode):
                        continue
                    entries.append({"name": child.name, "path": child.relative_to(workspace["path"]).as_posix(),
                                    "isDirectory": stat.S_ISDIR(info.st_mode), "size": info.st_size})
                return {"entries": sorted(entries, key=lambda e: (not e["isDirectory"], e["name"].lower()))}
            if op in {"read", "download"}:
                raw = await asyncio.to_thread(_file_bytes, path, TEXT_LIMIT if op == "read" else FILE_LIMIT)
                if op == "read":
                    try:
                        text = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        raise WorkspaceError("binary_file", "This file is not UTF-8 text")
                    if "\x00" in text:
                        raise WorkspaceError("binary_file", "Binary files cannot be previewed")
                    return {"path": payload.get("path", ""), "text": text, "truncated": False}
                return {"path": payload.get("path", ""), "name": path.name, "base64": base64.b64encode(raw).decode(), "size": len(raw)}
            if op == "upload":
                encoded = payload.get("base64")
                if not isinstance(encoded, str) or len(encoded) > (FILE_LIMIT + 2) // 3 * 4:
                    raise WorkspaceError("file_too_large", "Upload exceeds 1 MiB")
                raw = base64.b64decode(encoded, validate=True)
                if len(raw) > FILE_LIMIT:
                    raise WorkspaceError("file_too_large", "Upload exceeds 1 MiB")
                # Exclusive create preserves every existing file, including empty files.
                with path.open("xb") as target:
                    target.write(raw)
                return {"path": payload.get("path", ""), "size": len(raw)}
            if op == "diff":
                if path != workspace["path"]:
                    raise WorkspaceError("invalid_path", "Diff operates on the workspace root")
                return await asyncio.to_thread(_git_diff, path)
            if op == "terminal.open":
                if not self.terminal_available(workspace):
                    raise WorkspaceError("terminal_unavailable", "Explicit terminal permission and a host PTY are required")
                if len(self.terminals) >= 4:
                    raise WorkspaceError("terminal_limit", "Close an existing terminal first")
                columns, rows = _dimensions(payload)
                if not isinstance(client, str) or not client:
                    raise WorkspaceError("invalid_request", "Terminal requires a mobile connection identity")
                terminal = _Terminal(conversation, client, path, columns, rows)
                key = uuid.uuid4().hex
                self.terminals[key] = terminal
                terminal.task = asyncio.create_task(self._monitor_terminal(key, terminal))
                return {"terminalId": key}
        raise WorkspaceError("unsupported_operation", "Workspace operation is not supported")

    async def _monitor_terminal(self, key, terminal):
        try:
            while terminal.alive():
                if time.monotonic() - terminal.last_active > TERMINAL_IDLE_SECONDS:
                    break
                await asyncio.sleep(1)
            # Keep the exit output readable until explicit close or idle expiry.
            while time.monotonic() - terminal.last_active <= TERMINAL_IDLE_SECONDS:
                if terminal.alive():
                    break
                await asyncio.sleep(1)
        finally:
            if self.terminals.get(key) is terminal:
                self.terminals.pop(key, None)
            await terminal.close()

    async def _close_terminal(self, key):
        terminal = self.terminals.pop(key)
        await terminal.close()
        terminal.task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await terminal.task

    async def close(self):
        for key in list(self.terminals):
            await self._close_terminal(key)


def _dimensions(payload):
    columns, rows = payload.get("columns", 80), payload.get("rows", 24)
    if type(columns) is not int or type(rows) is not int or not (20 <= columns <= 300 and 5 <= rows <= 120):
        raise WorkspaceError("invalid_dimensions", "Terminal dimensions must be 20–300 columns and 5–120 rows")
    return columns, rows


def _git_diff(path):
    # An on-disk temporary buffer avoids retaining unbounded subprocess output.
    import tempfile
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(["git", "--no-pager", "-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", "."],
                                   cwd=path, stdout=output, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise WorkspaceError("diff_timeout", "Git diff timed out")
        if process.returncode:
            raise WorkspaceError("git_unavailable", "Workspace must be a Git repository with a HEAD commit")
        output.seek(0)
        raw = output.read(TEXT_LIMIT + 1)
        return {"text": raw[:TEXT_LIMIT].decode("utf-8", errors="replace"), "truncated": len(raw) > TEXT_LIMIT}


class _Terminal:
    def __init__(self, conversation, client, path, columns, rows):
        self.conversation = conversation
        self.client = client
        self.last_active = time.monotonic()
        self.output = ""
        self.truncated = False
        self.closed = False
        self.job = None
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.fd = None
        terminal_env = {**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor"}
        if os.name == "nt":
            from winpty import PtyProcess
            shell = os.environ.get("COMSPEC", "cmd.exe")
            self.process = PtyProcess.spawn([shell, "/D"], cwd=str(path), env=terminal_env, dimensions=(rows, columns))
            try:
                self.job = _WindowsJob(self.process.pid)
            except OSError:
                self.process.terminate(True)
                raise
        else:
            import pty
            shell = os.environ.get("SHELL", "/bin/sh")
            pid, master = pty.fork()
            if pid == 0:
                # fork establishes a controlling terminal, including job control
                # and terminal-generated Ctrl-C, before replacing the child.
                try:
                    os.chdir(path)
                    os.execvpe(shell, [shell, "-i"], terminal_env)
                finally:
                    os._exit(127)
            self.fd = master
            self.process = _PosixProcess(pid)
            self.resize(columns, rows)
            os.set_blocking(master, False)
        self.reader = asyncio.create_task(self._read_output())

    def alive(self):
        return not self.closed and (self.process.isalive() if os.name == "nt" else self.process.poll() is None)

    async def _read_output(self):
        try:
            while not self.closed:
                try:
                    if os.name == "nt":
                        text = await asyncio.to_thread(self.process.read, 4096)
                    else:
                        raw = os.read(self.fd, 4096)
                        if not raw:
                            break
                        text = self.decoder.decode(raw)
                except BlockingIOError:
                    await asyncio.sleep(0.03)
                    continue
                self.output += text
                encoded = self.output.encode("utf-8")
                if len(encoded) > OUTPUT_LIMIT:
                    self.output = encoded[-OUTPUT_LIMIT:].decode("utf-8", errors="ignore")
                    self.truncated = True
        except (EOFError, OSError):
            pass

    def read(self):
        output, self.output = self.output, ""
        truncated, self.truncated = self.truncated, False
        return {"output": output, "truncated": truncated, "exited": not self.alive(),
                "exitCode": self.process.exitstatus if os.name == "nt" else self.process.poll()}

    def write(self, value):
        if not self.alive():
            raise WorkspaceError("terminal_closed", "Terminal has exited")
        if os.name == "nt":
            self.process.write(value)
        else:
            os.write(self.fd, value.encode("utf-8"))

    def resize(self, columns, rows):
        if os.name == "nt":
            self.process.setwinsize(rows, columns)
        else:
            import fcntl
            import struct
            import termios
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    async def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if os.name == "nt":
                if self.job is not None:
                    self.job.close()
                    # The job already killed the tree; terminate() would signal a dead PID and race WinError 5.
                    await asyncio.wait_for(asyncio.to_thread(self.process.wait), timeout=2)
                else:
                    await asyncio.to_thread(self.process.terminate, True)
            else:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.process.pid, signal.SIGKILL)
                await asyncio.to_thread(self.process.wait)
                os.close(self.fd)
        finally:
            self.reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.reader


class _PosixProcess:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None

    def poll(self):
        if self.returncode is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self):
        if self.returncode is None:
            _, status = os.waitpid(self.pid, 0)
            self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode


class _WindowsJob:
    """The PTY shell and its descendants die together even after shell exit."""
    def __init__(self, pid):
        import ctypes
        from ctypes import wintypes as w

        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("flags", w.DWORD), ("min_working", ctypes.c_size_t),
                        ("max_working", ctypes.c_size_t), ("active_limit", w.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

        class Limits(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", IO), ("process_memory", ctypes.c_size_t),
                        ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.api.CreateJobObjectW.restype = w.HANDLE
        self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.api.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.api.OpenProcess.restype = w.HANDLE
        self.api.CloseHandle.argtypes = [w.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        process = self.api.OpenProcess(0x0101, False, pid)
        limits = Limits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        try:
            if not self.handle or not process or not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
                raise OSError(ctypes.get_last_error(), "Cannot initialize terminal process job")
            if not self.api.AssignProcessToJobObject(self.handle, process):
                raise OSError(ctypes.get_last_error(), "Cannot own terminal process tree")
        except OSError:
            self.close()
            raise
        finally:
            if process:
                self.api.CloseHandle(process)

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None
