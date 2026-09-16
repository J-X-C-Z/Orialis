"""Small dependency-light helpers shared by roadmap black-box tests."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any

DEFAULT_BASE_URL = "http://127.0.0.1:18443"


@dataclass
class HttpResult:
    status: int
    headers: Any
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8")) if self.body else None


def base_url() -> str:
    return os.environ.get("ORIALIS_ROADMAP_BASE_URL", DEFAULT_BASE_URL).rstrip("/")


def url(path: str) -> str:
    return f"{base_url()}/{path.lstrip('/')}"


def request(
    method: str,
    path: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 20.0,
) -> HttpResult:
    request_obj = urllib.request.Request(
        url(path), data=body, headers=headers or {}, method=method
    )
    try:
        with urllib.request.urlopen(request_obj, timeout=timeout) as response:
            return HttpResult(response.status, response.headers, response.read())
    except urllib.error.HTTPError as error:
        body = error.read()
        error.close()
        return HttpResult(error.code, error.headers, body)


def json_request(
    method: str,
    path: str,
    payload: Any | None = None,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 20.0,
) -> HttpResult:
    merged = {"Accept": "application/json"}
    if headers:
        merged.update(headers)
    body = None
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        merged["Content-Type"] = "application/json"
    return request(method, path, body=body, headers=merged, timeout=timeout)


def session_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Session {token}"}


def multipart_body(
    files: list[tuple[str, str, str, bytes]],
) -> tuple[bytes, str]:
    boundary = f"roadmap-{uuid.uuid4().hex}"
    chunks: list[bytes] = []
    for field, filename, mime, content in files:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                (
                    f'Content-Disposition: form-data; name="{field}"; '
                    f'filename="{filename}"\r\n'
                ).encode(),
                f"Content-Type: {mime}\r\n\r\n".encode(),
                content,
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def unique_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:16]}"


class LiveServerMixin:
    """Base mixin that makes live tests skip only when the real dependency is absent."""

    _live_ready = False
    _capabilities: set[str] = set()
    _shared_username: str | None = None
    _shared_password: str | None = None
    _shared_token: str | None = None

    @classmethod
    def setUpClass(cls) -> None:
        super_method = getattr(super(), "setUpClass", None)
        if super_method:
            super_method()
        try:
            health = request("GET", "/api/v1/health")
        except OSError as error:
            raise __import__("unittest").SkipTest(
                f"live Orialis server unavailable at {base_url()}: {error}"
            ) from error
        if health.status != 200:
            raise __import__("unittest").SkipTest(
                f"live Orialis server health returned HTTP {health.status}"
            )
        capabilities = request("GET", "/api/v1/capabilities")
        if capabilities.status != 200:
            raise __import__("unittest").SkipTest(
                f"/api/v1/capabilities unavailable (HTTP {capabilities.status})"
            )
        payload = capabilities.json()
        values = payload.get("capabilities") if isinstance(payload, dict) else None
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise AssertionError("/api/v1/capabilities did not return a string capability list")
        cls._capabilities = set(values)
        cls._live_ready = True

    @classmethod
    def shared_session(cls) -> tuple[str, str]:
        shared = LiveServerMixin
        if shared._shared_token and shared._shared_username and shared._shared_password:
            return shared._shared_token, shared._shared_username
        username = f"roadmap_{uuid.uuid4().hex[:12]}"
        password = f"Roadmap-{uuid.uuid4().hex[:16]}"
        result = json_request(
            "POST", "/api/v1/auth/register", {"username": username, "password": password}
        )
        if result.status != 201:
            raise AssertionError(f"register failed: HTTP {result.status}: {result.body!r}")
        payload = result.json()
        token = payload.get("accessToken") if isinstance(payload, dict) else None
        if not isinstance(token, str) or not token:
            raise AssertionError(f"register response has no accessToken: {payload!r}")
        shared._shared_username = username
        shared._shared_password = password
        shared._shared_token = token
        return token, username

    def require_capability(self, name: str, detail: str) -> None:
        if name not in self._capabilities:
            self.skipTest(
                f"{detail}: capability {name!r} is not advertised by this server"
            )


def wait_for_message(
    path: str,
    token: str,
    predicate,
    *,
    timeout: float = 5.0,
) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        result = json_request("GET", path, headers=session_headers(token))
        if result.status != 200:
            raise AssertionError(f"GET {path} failed: HTTP {result.status}: {result.body!r}")
        last = result.json()
        if predicate(last):
            return last
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {path}; last response was {last!r}")
