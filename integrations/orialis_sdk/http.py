"""Small production HTTP transport for the Orialis Node v1 SDK."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Mapping
from urllib.parse import urlsplit


class HttpTransportError(RuntimeError):
    def __init__(self, status: int | None, code: str, message: str, retryable: bool = False):
        self.status = status
        self.code = code
        self.retryable = retryable
        super().__init__(f"{code}: {message}")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HttpTransport:
    """JSON transport with explicit auth, TLS verification, deadlines, and no redirects."""

    def __init__(self, base_url: str, *, token: str | None = None,
                 auth_scheme: str = "Session", timeout: float = 8.0):
        parsed = urlsplit(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("base_url must be an absolute HTTP(S) URL")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("base_url cannot contain credentials, query, or fragment")
        if parsed.scheme != "https" and parsed.hostname not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("non-local services require HTTPS")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.auth_scheme = auth_scheme
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_NoRedirect)

    def __call__(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers = {"Accept": "application/json", "User-Agent": "orialis-node-sdk/1"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"{self.auth_scheme} {self.token}"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                payload = response.read(1_048_577)
                if len(payload) > 1_048_576:
                    raise HttpTransportError(response.status, "INVALID_RESPONSE", "response is too large")
                if not payload:
                    return {}
                return json.loads(payload.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            # Parse only stable error fields; never relay server response text or credential data.
            code, retryable = "HTTP_ERROR", exc.code == 429 or exc.code >= 500
            try:
                payload = json.loads(exc.read(65536).decode("utf-8"))
                if isinstance(payload, dict):
                    candidate = payload.get("error", code)
                    stable_codes = {
                        "INVALID_ARGUMENT", "UNAUTHENTICATED", "PERMISSION_DENIED",
                        "APPROVAL_REQUIRED", "NOT_FOUND", "DEVICE_OFFLINE",
                        "CAPABILITY_UNAVAILABLE", "CONFLICT", "RATE_LIMITED",
                        "DEADLINE_EXCEEDED", "CANCELLED", "UNSUPPORTED_VERSION",
                        "PAIRING_NOT_CONFIRMED", "PAIRING_REJECTED", "PAIRING_EXPIRED",
                        "PAIRING_DECISION_FINAL", "PAIRING_ALREADY_COMPLETED", "INTERNAL",
                    }
                    if isinstance(candidate, str) and candidate in stable_codes:
                        code = candidate
                    retryable = payload.get("retryable") is True
            except (ValueError, UnicodeDecodeError):
                pass
            finally:
                exc.close()
            raise HttpTransportError(exc.code, code, "request failed", retryable) from None
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", None)
            if isinstance(reason, TimeoutError):
                raise HttpTransportError(None, "DEADLINE_EXCEEDED", "request timed out", True) from None
            raise HttpTransportError(None, "NETWORK_ERROR", "service could not be reached", True) from None
        except (TimeoutError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            code = "DEADLINE_EXCEEDED" if isinstance(exc, TimeoutError) else "INVALID_RESPONSE"
            raise HttpTransportError(None, code, "request timed out" if code == "DEADLINE_EXCEEDED" else "service returned invalid JSON", code == "DEADLINE_EXCEEDED") from None
