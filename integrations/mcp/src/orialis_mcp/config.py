"""Operator-controlled connection settings; tools cannot change destinations."""

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


def validate_url(value: str, name: str) -> str:
    url = urlsplit(value)
    loopback = url.hostname in {"localhost", "127.0.0.1", "::1"}
    if (
        url.scheme not in {"https", "http"}
        or not url.hostname
        or (url.scheme == "http" and not loopback)
        or url.username or url.password or url.query or url.fragment
        or url.path not in {"", "/"}
    ):
        raise ValueError(f"{name} must be an HTTPS origin (HTTP allowed only on loopback)")
    return value.rstrip("/")


@dataclass(frozen=True)
class Settings:
    api_url: str
    public_url: str
    database_path: Path
    host: str = "127.0.0.1"
    port: int = 18444
    session_token: str | None = None
    scopes: tuple[str, ...] = ("orialis:read",)

    def __post_init__(self):
        object.__setattr__(self, "api_url", validate_url(self.api_url, "ORIALIS_API_URL"))
        object.__setattr__(self, "public_url", validate_url(self.public_url, "ORIALIS_MCP_PUBLIC_URL"))
        if not 1 <= self.port <= 65535:
            raise ValueError("ORIALIS_MCP_PORT must be between 1 and 65535")
        if not self.scopes or set(self.scopes) - {"orialis:read", "orialis:write", "orialis:memory:read", "orialis:memory:write"}:
            raise ValueError("Scopes must be Orialis read/write or explicitly granted memory read/write scopes")

    @classmethod
    def from_env(cls):
        return cls(
            api_url=os.environ.get("ORIALIS_API_URL", "http://127.0.0.1:18443").rstrip("/"),
            public_url=os.environ.get("ORIALIS_MCP_PUBLIC_URL", "http://127.0.0.1:18444").rstrip("/"),
            database_path=Path(os.environ.get("ORIALIS_MCP_DATABASE", "./data/mcp.sqlite")),
            host=os.environ.get("ORIALIS_MCP_HOST", "127.0.0.1"),
            port=int(os.environ.get("ORIALIS_MCP_PORT", "18444")),
            session_token=os.environ.get("ORIALIS_SESSION_TOKEN"),
            scopes=tuple(os.environ.get("ORIALIS_MCP_SCOPES", "orialis:read").split()),
        )
