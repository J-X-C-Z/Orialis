"""Text-only Orialis gateway backed by isolated Codex CLI threads."""
from __future__ import annotations

import asyncio
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import signal
import sqlite3
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


def frame(kind, **values):
    return {"version": 1, "type": kind, **values}


def failure(message_id, code, message):
    return frame("error", code=code, message=message, reply_to=message_id)


def device_platform():
    override = os.environ.get("ORIALIS_PLATFORM")
    if override is not None:
        if override not in {"macos", "linux", "windows"}:
            raise ValueError("ORIALIS_PLATFORM must be macos, linux, or windows.")
        return override
    name = platform.system().lower()
    return "macos" if name == "darwin" else name


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS threads(conversation TEXT PRIMARY KEY, thread TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
                response TEXT, state TEXT NOT NULL);
        """)
        # An interrupted CLI may already have executed its turn. Never rerun it.
        for (request_id,) in self.db.execute("SELECT id FROM requests WHERE state='running'").fetchall():
            self.finish(request_id, failure(request_id, "EXECUTION_UNCERTAIN",
                "Gateway restarted during this turn; the turn was not executed again."))

    def thread(self, conversation):
        row = self.db.execute("SELECT thread FROM threads WHERE conversation=?", (conversation,)).fetchone()
        return row[0] if row else None

    def set_thread(self, conversation, thread):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO threads VALUES (?,?)", (conversation, thread))

    def claim(self, message):
        fingerprint = hashlib.sha256(json.dumps(message, sort_keys=True).encode()).hexdigest()
        row = self.db.execute("SELECT fingerprint,response FROM requests WHERE id=?",
                              (message["message_id"],)).fetchone()
        if row:
            if row[0] != fingerprint:
                return False, failure(message["message_id"], "MESSAGE_ID_CONFLICT", "Message ID was reused with different content.")
            return False, json.loads(row[1]) if row[1] else None
        with self.db:
            self.db.execute("INSERT INTO requests VALUES (?,?,NULL,'running')", (message["message_id"], fingerprint))
        return True, None

    def finish(self, request_id, response):
        with self.db:
            self.db.execute("UPDATE requests SET response=?,state='done' WHERE id=?",
                            (json.dumps(response), request_id))


class Codex:
    def __init__(self, home, cwd, executable="codex", timeout=180, model=None):
        self.home, self.cwd = str(Path(home).resolve()), str(Path(cwd).resolve())
        self.executable, self.timeout, self.model = executable, timeout, model

    def command(self, thread):
        command = [self.executable, "exec", "--json", "--skip-git-repo-check",
                   "--ignore-user-config", "-c", 'sandbox_mode="read-only"',
                   "-c", 'approval_policy="never"', "-c", "project_doc_max_bytes=0",
                   "--enable", "skip_host_skill_discovery"]
        for feature in ("apps", "hooks", "plugins", "remote_plugin", "skill_search", "skill_mcp_dependency_install"):
            command += ["--disable", feature]
        # Managed MCP configurations can load independently of user config.
        for name in os.environ.get("ORIALIS_CODEX_DISABLED_MCP", "").split(","):
            if name.strip():
                command += ["-c", f'mcp_servers.{json.dumps(name.strip())}.enabled=false']
        if self.model:
            command += ["--model", self.model]
        if thread:
            command += ["resume", thread]
        return command + ["-"]

    async def run(self, content, thread, on_thread):
        allowed = {"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR",
                   "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                   "http_proxy", "https_proxy", "all_proxy", "no_proxy"}
        environment = {k: v for k, v in os.environ.items() if k in allowed}
        environment["CODEX_HOME"] = self.home
        process = await asyncio.create_subprocess_exec(*self.command(thread), cwd=self.cwd,
            env=environment, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, start_new_session=True,
            limit=2 ** 20)
        async def collect():
            process.stdin.write(content.encode())
            await process.stdin.drain()
            process.stdin.close()
            final = None
            async for line in process.stdout:
                try:
                    event = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if event.get("type") == "thread.started" and event.get("thread_id"):
                    on_thread(event["thread_id"])
                if event.get("type") == "item.completed":
                    item = event.get("item", {})
                    if item.get("type") == "agent_message":
                        final = item.get("text")
                if event.get("type") in {"turn.failed", "error"}:
                    raise RuntimeError("Codex could not complete this turn.")
            if await process.wait() != 0 or not final:
                raise RuntimeError("Codex exited without a completed text reply.")
            return final
        try:
            return await asyncio.wait_for(collect(), self.timeout)
        finally:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                await process.wait()


class NewsPublisher:
    """Publish a narrowly-scoped GitHub brief without exposing its token to Codex."""

    def __init__(self, api_url=None, token=None, timeout=15):
        self.api_url = (api_url or os.environ.get("ORIALIS_NEWS_API_URL", "")).strip()
        if not self.api_url:
            gateway_url = os.environ.get("ORIALIS_SERVER_URL", "").strip()
            if gateway_url:
                parts = urlsplit(gateway_url)
                scheme = {"ws": "http", "wss": "https"}.get(parts.scheme)
                if scheme:
                    self.api_url = urlunsplit((scheme, parts.netloc, parts.path, "", ""))
        self.token = (token or os.environ.get("ORIALIS_NEWS_PUBLISHER_TOKEN", "")).strip()
        self.timeout = timeout

    class _NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, new_url):
            return None

    @staticmethod
    def _endpoint(api_url, period):
        parts = urlsplit(api_url)
        if (parts.scheme not in {"http", "https"} or not parts.netloc or
                parts.username or parts.password or parts.query or parts.fragment):
            raise ValueError("ORIALIS_NEWS_API_URL must be an HTTP(S) server URL without credentials or query parameters.")
        path = parts.path.rstrip("/")
        for suffix in ("/api/v1/agent/ws", "/api/v1/news", "/api/v1"):
            if path.endswith(suffix):
                path = path[:-len(suffix)]
        return urlunsplit((parts.scheme, parts.netloc,
                           path + "/api/v1/news/publish/github/" + period, "", ""))

    def publish(self, payload):
        if not self.api_url or not self.token:
            raise RuntimeError("News publishing is not configured on this gateway.")
        if not isinstance(payload, dict):
            raise ValueError("news.publish payload must be an object.")
        period = payload.get("kind")
        if period not in {"daily", "weekly"} or payload.get("channel") != "github":
            raise ValueError("Only GitHub daily and weekly news can be published by this gateway.")
        task_id = payload.get("taskId")
        generated_at = payload.get("generatedAt")
        result = payload.get("result")
        if (not isinstance(task_id, str) or not task_id.strip() or task_id != task_id.strip()
                or len(task_id) > 128 or any(ord(char) < 32 for char in task_id)):
            raise ValueError("news.publish requires a stable taskId.")
        if not isinstance(generated_at, str) or not generated_at.strip():
            raise ValueError("news.publish requires generatedAt in RFC3339 format.")
        if not isinstance(result, dict) or not isinstance(result.get("repositories"), list) or not isinstance(result.get("brief"), dict):
            raise ValueError("GitHub news result requires repositories and brief objects.")
        body = {
            "taskId": task_id,
            "source": "githot.dev",
            "generatedAt": generated_at,
            "period": period,
            "result": result,
            "idempotencyKey": task_id,
        }
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > 1024 * 1024:
            raise ValueError("news.publish payload exceeds 1 MiB.")
        request = Request(self._endpoint(self.api_url, period), data=encoded, method="POST", headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Idempotency-Key": task_id,
        })
        try:
            with build_opener(ProxyHandler({}), self._NoRedirect()).open(request, timeout=self.timeout) as response:
                raw = response.read(256 * 1024 + 1)
                status = response.status
        except HTTPError as exc:
            # Avoid returning server bodies that may contain deployment details.
            raise RuntimeError(f"News server rejected publication (HTTP {exc.code}).") from None
        except (URLError, TimeoutError, OSError):
            raise RuntimeError("News server could not be reached; retry with the same taskId.") from None
        if len(raw) > 256 * 1024:
            raise RuntimeError("News server response exceeded the allowed size.")
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise RuntimeError("News server returned invalid JSON.") from None
        if status < 200 or status >= 300 or not isinstance(data, dict):
            raise RuntimeError("News server did not accept the publication.")
        return data


class Gateway:
    def __init__(self, store, codex, news_publisher=None):
        self.store, self.codex = store, codex
        self.news_publisher = news_publisher or NewsPublisher()
        self.locks = {}
        self.tasks = set()

    async def handle(self, message, send):
        kind = message.get("type")
        if message.get("version") != 1:
            await send(failure(message.get("message_id"), "UNSUPPORTED_VERSION", "Only Gateway version 1 is supported."))
        elif kind == "ping":
            await send(frame("pong"))
        elif kind == "message.send":
            if not all(isinstance(message.get(k), str) and message[k].strip()
                       for k in ("message_id", "conversation_id", "content")):
                await send(failure(message.get("message_id"), "INVALID_MESSAGE", "Nonempty message ID, conversation ID and text are required."))
                return
            claimed, cached = self.store.claim(message)
            if claimed:
                task = asyncio.create_task(self.execute(message, send))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
            await send(frame("message.ack", message_id=message["message_id"], status="received"))
            if cached:
                await send(cached)
        elif kind not in {"hello_ack", "pong", "message.ack", "capabilities.ack", "error"}:
            await send(failure(message.get("request_id") or message.get("message_id"),
                "UNSUPPORTED_OPERATION", "This Codex gateway supports text messages only; Hermes commands and attachments are unavailable."))

    async def execute(self, message, send):
        conversation, request_id = message["conversation_id"], message["message_id"]
        async with self.locks.setdefault(conversation, asyncio.Lock()):
            if message.get("attachments"):
                response = failure(request_id, "UNSUPPORTED_ATTACHMENT", "This Codex gateway supports text only.")
            else:
                try:
                    text = await self.codex.run(message["content"], self.store.thread(conversation),
                        lambda thread: self.store.set_thread(conversation, thread))
                    content = text
                    try:
                        candidate = json.loads(text)
                    except (ValueError, TypeError):
                        candidate = None
                    if isinstance(candidate, dict) and candidate.get("type") == "news.publish":
                        publish_request_id = candidate.get("requestId")
                        request = candidate.get("payload")
                        try:
                            if not isinstance(publish_request_id, str) or not publish_request_id.strip():
                                raise ValueError("news.publish requires requestId.")
                            result = await asyncio.to_thread(self.news_publisher.publish, request)
                            content = json.dumps({"type": "news.publish.ack",
                                "requestId": publish_request_id, "taskId": request.get("taskId"),
                                "result": result}, ensure_ascii=False, separators=(",", ":"))
                        except Exception as error:
                            content = json.dumps({"type": "news.publish.error",
                                "requestId": publish_request_id,
                                "taskId": request.get("taskId") if isinstance(request, dict) else None,
                                "message": str(error)},
                                ensure_ascii=False, separators=(",", ":"))
                    response = frame("message.reply", message_id=str(uuid.uuid4()), reply_to=request_id,
                                     conversation_id=conversation, content=content)
                except asyncio.TimeoutError:
                    response = failure(request_id, "EXECUTION_TIMEOUT", "Codex timed out; the turn will not execute again.")
                except Exception:
                    response = failure(request_id, "EXECUTION_FAILED", "Codex could not complete this turn; check the gateway runtime and login.")
            self.store.finish(request_id, response)
            # Cache before sending: reconnects replay the exact reply without rerunning CLI.
            try:
                await send(response)
            except Exception:
                pass

    async def serve(self, url, token, device):
        import websockets
        reported_platform = device_platform()
        delay = 1
        try:
            while True:
                try:
                    async with websockets.connect(url, additional_headers={"Authorization": "Bearer " + token},
                                                  max_size=2 ** 20) as socket:
                        async def send(value):
                            await socket.send(json.dumps(value))
                        await send(frame("hello", device_id=device, client="orialis-codex-gateway",
                                         plugin_version="1.1.0", platform=reported_platform,
                                         capabilities=["messages", "news.publish"]))
                        await send(frame("capabilities.hello", capabilities=["messages", "news.publish"]))
                        delay = 1
                        async for raw in socket:
                            try:
                                message = json.loads(raw)
                                if not isinstance(message, dict):
                                    raise ValueError()
                            except (ValueError, UnicodeDecodeError):
                                await send(failure(None, "INVALID_JSON", "Expected a JSON object."))
                                continue
                            await self.handle(message, send)
                except (OSError, websockets.exceptions.WebSocketException):
                    await asyncio.sleep(delay)
                    delay = min(30, delay * 2)
        finally:
            for task in self.tasks:
                task.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)


def main():
    home = Path(os.environ["CODEX_HOME"]).resolve()
    if home == (Path.home() / ".codex").resolve():
        raise SystemExit("Use a dedicated CODEX_HOME for this gateway.")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(home, 0o700)
    lock = (home / "orialis-gateway.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("Another gateway owns this CODEX_HOME.")
    database = home / "orialis-gateway.sqlite3"
    store = Store(database)
    os.chmod(database, 0o600)
    codex = Codex(home, os.environ["ORIALIS_CODEX_CWD"],
                  os.environ.get("ORIALIS_CODEX_BIN", "codex"),
                  float(os.environ.get("ORIALIS_CODEX_TIMEOUT", "180")),
                  os.environ.get("ORIALIS_CODEX_MODEL"))
    asyncio.run(Gateway(store, codex).serve(os.environ["ORIALIS_SERVER_URL"],
        os.environ["ORIALIS_DEVICE_TOKEN"], os.environ.get("ORIALIS_DEVICE_ID", "JXCZ_AOZORA_Codex")))


if __name__ == "__main__":
    main()
